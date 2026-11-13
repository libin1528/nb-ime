// swiftc -swift-version 5 Sources/Audio.swift Sources/RecordingEngine.swift Tests/RecorderTests.swift -o /tmp/nbime-recorder-tests
// 不访问真实麦克风或用户设置；运行生产 Recorder 的恢复和通知逻辑。
import AVFoundation
import Cocoa
import CoreAudio

enum Settings {
    struct Value { var micUID = ""; var sounds = false }
    static var current = Value()
}
enum Log { static func w(_ text: String) {} }

final class RecorderClock {
    var now: TimeInterval = 100
    private var jobs: [(TimeInterval, () -> Void)] = []
    func later(_ delay: TimeInterval, _ work: @escaping () -> Void) { jobs.append((now + delay, work)) }
    func advance(_ duration: TimeInterval) {
        let end = now + duration
        while let i = jobs.indices.min(by: { jobs[$0].0 < jobs[$1].0 }), jobs[i].0 <= end + 0.00001 {
            let job = jobs.remove(at: i); now = job.0; job.1()
        }
        now = end
    }
}
final class FakeRecordingEngine: RecordingEngine {
    var format = RecordingFormat(rate: 48000, channels: 1)
    var isRunning = false
    var notificationObject: AnyObject { self }
    var selected: AudioDeviceID?
    var startFailure = false
    var selectFailure = false
    var starts = 0
    var stops = 0
    var callback: (([Float]) -> Void)?
    func selectDevice(_ id: AudioDeviceID) throws {
        if selectFailure { throw NSError(domain: "test", code: 1) }
        selected = id
    }
    func start(_ onSamples: @escaping ([Float]) -> Void) throws {
        starts += 1
        if startFailure { throw NSError(domain: "test", code: 2) }
        callback = onSamples; isRunning = true
    }
    func stop() { stops += 1; isRunning = false }
}
final class RecorderHarness {
    let clock = RecorderClock()
    let notifications = NotificationCenter()
    let workspace = NotificationCenter()
    var device: InputDevice? = InputDevice(id: 1, uid: "one", name: "test")
    var engines: [FakeRecordingEngine] = []
    var setup: ((FakeRecordingEngine) -> Void)?
    var samples: [Float] = []
    var failures = 0
    lazy var recorder: Recorder = {
        let r = Recorder(makeEngine: { [unowned self] in
            let e = FakeRecordingEngine(); self.setup?(e); self.engines.append(e); return e
        }, currentDevice: { [unowned self] in self.device }, now: { [unowned self] in self.clock.now },
        later: clock.later, notifications: notifications, workspaceNotifications: workspace)
        r.onSamples = { [weak self] in self?.samples += $0 }
        r.onFailure = { [weak self] _ in self?.failures += 1 }
        return r
    }()
    func start() throws { try recorder.start() }
    func feed(_ values: [Float] = [0]) { engines.last?.callback?(values) }
    func change() { notifications.post(name: .inputDevicesChanged, object: nil); clock.advance(0) }
    func wake() { workspace.post(name: NSWorkspace.didWakeNotification, object: nil); clock.advance(0) }
}

@main enum RecorderTests {
    static var passed = 0, failed = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        if value() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static func main() throws {
        do {
            let h = RecorderHarness(); try h.start()
            h.clock.advance(0.75)
            check(h.engines.count == 1, "正常启动等待首块音频，不立即重建")
            h.clock.advance(0.25)
            check(h.engines.count == 2 && h.recorder.running, "启动成功却零回调：同一次按住自动重建")
            h.feed([0.3]); check(h.samples == [0.3], "重建后采样仍交给当前录音")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start()
            for _ in 0..<12 { h.feed(); h.clock.advance(0.25) }
            check(h.engines.count == 1 && h.samples.count == 12, "持续静音有采样，不重建、不丢弃静音")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.feed([0.4]); h.clock.advance(1)
            check(h.engines.count == 2, "录音中途断流也恢复")
            h.engines[0].callback?([0.9]); h.feed([0.5])
            check(h.samples == [0.4, 0.5], "旧引擎迟到回调不污染恢复后的音频")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.recorder.finish(); h.clock.advance(1.25)
            check(h.engines.count == 1 && h.recorder.running, "松开后的尾音期间断流不重新开麦")
            h.feed([0.1]); check(h.samples == [0.1], "收尾期间仍接收最后的音频")
            h.wake(); check(h.engines.count == 1, "收尾期间唤醒不重新开麦")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.recorder.stop(); h.clock.advance(10)
            check(h.engines.count == 1 && !h.recorder.running, "松开后 watchdog 不开麦")
            try h.start()
            check(h.engines.count == 2, "无采样短按后下一次重建")
            h.engines[0].callback?([0.9]); h.feed([0.5])
            check(h.samples == [0.5], "上一次录音迟到回调不串进下一次")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.clock.advance(4)
            check(h.engines.count == 3 && h.failures == 1 && !h.recorder.running, "恢复有上限，持续故障只报错一次并关麦")
            h.clock.advance(10); check(h.engines.count == 3, "失败后不无限重建")
            try h.start(); h.feed([0.7]); check(h.samples == [0.7], "下一次按键可重新尝试，不永久卡死")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.feed(); h.recorder.stop(); h.wake()
            check(h.engines.count == 2 && !h.recorder.running, "空闲唤醒即准备新引擎，不开启录音")
            try h.start(); check(h.engines.count == 2, "唤醒后开麦复用已准备的新引擎")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.wake(); h.feed([0.2])
            check(h.engines.count == 2 && h.recorder.running && h.samples == [0.2], "按住期间唤醒恢复原录音")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.device = InputDevice(id: 2, uid: "two", name: "new"); h.change()
            check(h.engines.count == 2 && h.engines.last?.selected == 2, "按住期间切设备重建并选择新设备")
            h.feed([0.2]); h.recorder.stop()
            h.device = InputDevice(id: 1, uid: "one", name: "old"); h.change()
            check(h.engines.count == 3 && !h.recorder.running, "空闲切设备只准备，不自动录音")
        }
        do {
            let h = RecorderHarness(); try h.start(); h.feed(); h.recorder.stop(); h.change()
            check(h.engines.count == 2, "同一 ID 的设备重连也会重建")
        }
        do {
            let h = RecorderHarness(); try h.start(); h.feed()
            h.notifications.post(name: .AVAudioEngineConfigurationChange, object: h.engines[0])
            h.clock.advance(0.25)
            check(h.engines.count == 1, "正常运行且格式没变的初始化通知不循环重建")
            h.engines[0].isRunning = false
            h.notifications.post(name: .AVAudioEngineConfigurationChange, object: h.engines[0])
            h.clock.advance(0.25)
            check(h.engines.count == 2 && h.recorder.running, "格式没变但引擎被系统停掉时仍恢复")
            h.notifications.post(name: .AVAudioEngineConfigurationChange, object: h.engines[0]); h.feed(); h.clock.advance(0.25)
            check(h.engines.count == 2, "忽略旧引擎通知")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.feed(); h.recorder.stop()
            h.engines[0].format = RecordingFormat(rate: 44100, channels: 2)
            try h.start(); check(h.engines.count == 2, "采样率或声道改变重建")
            h.recorder.stop()
        }
        do {
            let h = RecorderHarness(); try h.start(); h.setup = { $0.startFailure = true }; h.clock.advance(1)
            check(h.failures == 1 && !h.recorder.running && h.engines.last?.isRunning == false, "恢复启动失败清理引擎并报告")
        }
        do {
            let h = RecorderHarness(); h.setup = { $0.selectFailure = true }
            do { try h.start(); check(false, "设备选择失败必须抛错") } catch { check(!h.recorder.running, "设备选择失败不冒充默认设备成功") }
            h.setup = nil; try h.start(); h.feed(); h.recorder.stop()
            check(h.engines.count == 2, "选择设备失败后可重试")
        }
        do {
            let h = RecorderHarness(); try h.start()
            h.notifications.post(name: .inputDevicesChanged, object: nil); h.recorder.stop(); h.clock.advance(5)
            check(!h.recorder.running && h.engines.allSatisfy { !$0.isRunning }, "设备通知排队后松开不能再次开麦")
        }
        print("Recorder: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
