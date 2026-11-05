// 内存音频设备与线程安全时钟；不写系统音量或用户日志。
import Foundation
import CoreAudio

final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
enum Log {
    private static let storage = Locked<[String]>([])
    static var lines: [String] { storage.use { $0 } }
    static func w(_ s: String) { storage.use { $0.append(s) } }
}

final class TestAudio: MediaAudio {
    private struct State {
        var device: UInt32 = 1
        var pids: Set<pid_t> = [42]
        var muted = false
        var volume: [Float] = [0.7, 0.4]
        var writes: [[Float]] = []
        var writeDevices: [UInt32] = []
        var writeTimes: [TimeInterval] = []
        var failWrite = false
        var failRead = false
        var activity: ((MediaOutput) -> Set<pid_t>?)?
    }
    private let state = Locked(State())
    var device: UInt32 { get { state.use { $0.device } } set { state.use { $0.device = newValue } } }
    var pids: Set<pid_t> { get { state.use { $0.pids } } set { state.use { $0.pids = newValue } } }
    var muted: Bool { get { state.use { $0.muted } } set { state.use { $0.muted = newValue } } }
    var volume: [Float] { get { state.use { $0.volume } } set { state.use { $0.volume = newValue } } }
    var writes: [[Float]] { state.use { $0.writes } }
    var writeDevices: [UInt32] { state.use { $0.writeDevices } }
    var writeTimes: [TimeInterval] { state.use { $0.writeTimes } }
    var failWrite: Bool { get { state.use { $0.failWrite } } set { state.use { $0.failWrite = newValue } } }
    var failRead: Bool { get { state.use { $0.failRead } } set { state.use { $0.failRead = newValue } } }
    var activity: ((MediaOutput) -> Set<pid_t>?)? {
        get { state.use { $0.activity } }
        set { state.use { $0.activity = newValue } }
    }
    func output() -> MediaOutput? { MediaOutput(id: device, name: "测试设备", elements: [1, 2]) }
    func running(_ output: MediaOutput) -> Set<pid_t>? { if let activity { return activity(output) }; return pids }
    func isMuted(_ output: MediaOutput) -> Bool { muted }
    func volumes(_ output: MediaOutput) -> [Float]? { failRead ? nil : volume }
    func setVolumes(_ output: MediaOutput, _ values: [Float]) -> Bool {
        state.use {
            guard !$0.failWrite else { return false }
            $0.writes.append(values); $0.writeDevices.append(output.id)
            $0.writeTimes.append(ProcessInfo.processInfo.systemUptime); $0.volume = values
            return true
        }
    }
}

final class TestClock {
    private let value = Locked(100.0)
    let queue = DispatchQueue(label: "test.volume")
    var time: TimeInterval { value.use { $0 } }
    func flush() { queue.sync {} }
    func step(_ seconds: Double) {
        flush()
        value.use { $0 += seconds }
        Thread.sleep(forTimeInterval: 0.025) // 主线程不跑，后台定时器仍须推进
        flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01)) // 只接收提示音回调
        flush()
    }
}

@main enum MediaDuckTests {
    static var passed = 0
    static func check(_ ok: @autoclosure () -> Bool, _ name: String) {
        guard ok() else { fatalError("FAIL: \(name)") }; passed += 1
    }
    static func make() -> (MediaDuck, TestAudio, TestClock) {
        let a = TestAudio(), c = TestClock()
        return (MediaDuck(audio: a, now: { c.time }, queue: c.queue), a, c)
    }
    static func zero(_ m: MediaDuck, _ c: TestClock) { m.begin(); c.step(0.15) }
    static func main() {
        do {
            let (m, a, c) = make(); a.pids = []; var sounds = 0
            m.begin(); c.flush(); m.playStartSound { sounds += 1 }; c.step(0)
            m.end { sounds += 1 }; c.step(0); m.shutdown()
            check(a.writes.isEmpty && sounds == 2, "无外部输出：不写音量，开始结束提示音照常")
        }
        do {
            let (m, a, c) = make(); a.volume = [0, 0]
            zero(m, c); m.end(); m.shutdown(); check(a.writes.isEmpty, "原音量为零不接管")
        }
        do {
            let (m, a, c) = make(); a.muted = true
            zero(m, c); m.end(); m.shutdown(); check(a.writes.isEmpty, "已静音不接管")
        }
        do {
            let (m, a, c) = make(); a.activity = { _ in fatalError("关闭设置不应检测") }
            m.begin(enabled: false); c.step(0.3); var sound = false
            m.playStartSound { sound = true }; c.step(0); m.end(); m.shutdown()
            check(sound && a.writes.isEmpty, "关闭设置不检测、不压音量，开始提示音照常")
        }
        do {
            let (m, a, c) = make(); m.begin(); c.flush()
            check(a.writes.isEmpty, "按下只提交下降，不一刀切")
            c.step(0.075)
            check(a.volume[0] > 0 && a.volume[0] < 0.7, "0.15 秒下降存在中间值")
            check(abs(a.volume[0] / 0.7 - a.volume[1] / 0.4) < 0.001, "下降保留声道比例")
            c.step(0.075); check(a.volume == [0, 0], "不等长按和开麦，0.15 秒到零")
            let downWrites = a.writes
            check(zip(downWrites, downWrites.dropFirst()).allSatisfy { x, y in zip(x, y).allSatisfy { $0 >= $1 } }, "下降单调无过冲")
            var sound = false; m.playStartSound { sound = true }; c.step(0.3)
            check(!sound && a.volume == [0, 0], "这次压低后长按确认不播放开始提示音、不抬音量")
            let from = a.writes.count; m.end(); c.flush()
            check(a.volume == [0, 0], "无结束提示音时不突然抬音量")
            c.step(0.625); check(a.volume[0] > 0 && a.volume[0] < 0.7, "恢复存在中间值")
            c.step(0.65); check(a.volume == [0.7, 0.4], "1.25 秒恢复原值")
            let upWrites = Array(a.writes.dropFirst(from))
            check(zip(upWrites, upWrites.dropFirst()).allSatisfy { x, y in zip(x, y).allSatisfy { $0 <= $1 } }, "恢复单调无过冲")
            m.shutdown()
        }
        do {
            let (m, a, c) = make(); zero(m, c); var heard: [Float] = [], onMain = false
            m.end { heard = a.volume; onMain = Thread.isMainThread }; c.step(0)
            check(abs(heard[0] - 0.21) < 0.001 && abs(heard[1] - 0.12) < 0.001 && onMain, "先抬到原值 30%，结束提示音回主线程立即播放")
            c.step(0.625); check(a.volume[0] > 0.21 && a.volume[0] < 0.7, "结束提示音后继续上升")
            c.step(0.65); check(a.volume == [0.7, 0.4], "结束提示音后恢复原值")
            m.shutdown()
        }
        do {
            let (m, a, c) = make(); m.begin(); c.step(0.03); let value = a.volume; var heard: [Float] = []
            m.end { heard = a.volume }; c.step(0)
            check(heard == value, "高于 30% 时不为了提示音反而调低")
            m.shutdown()
        }
        do {
            let (m, a, c) = make(); var sounds = 0
            m.begin(); c.step(0.06); let value = a.volume
            m.playStartSound { sounds += 1 }; m.end(); c.step(0)
            check(value[0] > 0 && value[0] < 0.7 && a.volume == value && sounds == 0, "holding 短按松开即恢复，不放提示音、不跳音量")
            c.step(1.3); check(a.volume == [0.7, 0.4], "短按也完整恢复原值")
            m.shutdown()
        }
        do {
            let (m, a, c) = make(); zero(m, c); m.end(); c.step(0.4)
            let value = a.volume; m.begin(); c.flush()
            check(a.volume == value, "连续录音从恢复中间值接续，不跳到零")
            c.step(0.075); check(a.volume[0] < value[0] && a.volume[0] > 0, "连续录音平滑再降")
            c.step(0.1); m.end(); c.step(1.3)
            check(a.volume == [0.7, 0.4], "连续录音保留最初原值")
            m.shutdown()
        }
        do {
            let (m, a, c) = make(); m.begin(); c.step(0.075)
            a.volume = [0.3, 0.2]; let count = a.writes.count; c.step(0.3); m.end(); m.shutdown()
            check(a.volume == [0.3, 0.2] && a.writes.count == count, "下降中手调后停止覆盖，退出也保留新值")
        }
        do {
            let (m, a, c) = make(); zero(m, c); m.end(); c.step(0.2)
            a.volume = [0.3, 0.2]; let count = a.writes.count; c.step(0.3); m.shutdown()
            check(a.volume == [0.3, 0.2] && a.writes.count == count, "恢复中手调后停止覆盖")
        }
        do {
            let (m, a, c) = make(); zero(m, c); a.volume = [0.1, 0.05]; var heard: [Float] = []
            m.end { heard = a.volume }; c.step(0); m.shutdown()
            check(heard == [0.1, 0.05], "手调后结束提示音不强抬音量")
        }
        do {
            let (m, a, c) = make(); m.begin(); c.step(0.075); m.shutdown(); let count = a.writes.count; c.step(2)
            check(a.volume == [0.7, 0.4] && a.writes.count == count, "退出等待归还音量，之后不再写入")
        }
        do {
            let (m, a, c) = make(); zero(m, c); m.end(); c.step(0.2); m.shutdown()
            check(a.volume == [0.7, 0.4], "恢复中退出立即归还")
        }
        do {
            let (m, a, c) = make(); zero(m, c); m.end(); c.step(0.2); m.end(); c.step(1.1)
            check(a.volume == [0.7, 0.4], "tail 重复结束不取消或重启恢复")
            m.shutdown()
        }
        do {
            let (m, a, c) = make(); zero(m, c); a.device = 2; c.step(0.1)
            check(a.volume == [0.7, 0.4] && a.writeDevices.last == 1 && !a.writeDevices.contains(2), "切换设备只归还旧设备")
            m.shutdown()
        }
        do {
            let (m, a, c) = make(); zero(m, c); a.failWrite = true; m.end(); c.step(0.1)
            a.failWrite = false; m.shutdown(); check(a.volume == [0.7, 0.4], "写入失败退出重试归还")
        }
        do {
            let (m, a, c) = make(); zero(m, c); a.failRead = true; m.end(); c.flush(); a.failRead = false; m.shutdown()
            check(a.volume == [0.7, 0.4], "回读出错仍归还音量")
        }
        do {
            let (m, a, c) = make(); zero(m, c); a.pids = []; m.end(); c.step(0.2); m.begin(); c.step(1)
            check(a.volume == [0.7, 0.4], "下一句已无外部输出就只归还旧音量")
            m.shutdown()
        }
        do {
            let (m, a, c) = make(); a.activity = { _ in nil }; m.begin(); c.step(1); m.end(); m.shutdown()
            check(a.writes.isEmpty, "输出状态不可知不接管")
        }
        concurrencyChecks()
        do {
            let (m, a, c) = make(); zero(m, c); var sounds = 0
            m.end { sounds += 1 }; m.begin(); c.step(0.15)
            check(sounds == 0 && a.volume == [0, 0], "新录音开始后旧结束提示音不能迟到")
            m.end(); c.step(1.3); m.shutdown()
        }
        do {
            let (m, a, c) = make(); zero(m, c)
            m.end { m.begin() }; c.step(0); c.step(0.15)
            check(a.volume == [0, 0], "结束提示音回调中开始新录音，旧恢复不能覆盖新下降")
            m.end(); c.step(1.3); m.shutdown()
        }
        processChecks()
        check(Log.lines.contains { $0.hasPrefix("压低音量：") } && Log.lines.contains { $0.hasPrefix("恢复音量：") }, "日志前缀正确")
        print("MediaDuck: \(passed) checks passed")
    }

    static func concurrencyChecks() {
        do {
            let a = TestAudio()
            let real = MediaDuck(audio: a), at = ProcessInfo.processInfo.systemUptime
            real.begin()
            Thread.sleep(forTimeInterval: 0.075)
            check(a.volume[0] > 0 && a.volume[0] < 0.7, "主线程模拟开麦阻塞时后台仍经过下降中间值")
            Thread.sleep(forTimeInterval: 0.18)
            check(a.volume == [0, 0], "主线程不跑 run loop 也能降到零")
            let firstZero = a.writes.firstIndex { $0 == [0, 0] }!
            let elapsed = a.writeTimes[firstZero] - at
            check(elapsed >= 0.14 && elapsed < 0.25, "按下到零约 0.15 秒，不叠加开麦和长按延迟")
            real.end(); Thread.sleep(forTimeInterval: 1.35)
            check(a.volume == [0.7, 0.4], "主线程阻塞也能完成恢复")
            real.shutdown()
        }
        do {
            let (m, a, c) = make(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            a.activity = { _ in entered.signal(); _ = release.wait(timeout: .now() + 2); return [42] }
            let at = Date(); m.begin()
            check(Date().timeIntervalSince(at) < 0.05 && entered.wait(timeout: .now() + 1) == .success, "慢检测不阻塞 begin 返回")
            let endAt = Date(); m.end()
            check(Date().timeIntervalSince(endAt) < 0.05, "慢检测期间短按松开也立即返回")
            release.signal(); c.step(0.5); m.shutdown()
            check(a.writes.isEmpty, "已经松开后迟到的检测不能再降音量")
        }
        do {
            let (m, a, c) = make(); var sounds = 0
            m.begin(); m.end(); m.begin(); c.step(0.15); m.playStartSound { sounds += 1 }; c.step(0)
            check(a.volume == [0, 0] && sounds == 0, "快速连按仅最新一次接管，旧请求不覆盖")
            m.end(); c.step(1.3); m.shutdown(); check(a.volume == [0.7, 0.4], "快速连按保留原值")
        }
        do {
            let (m, a, c) = make(); a.pids = []; var sounds = 0
            m.begin(); m.playStartSound { sounds += 1 }; m.end(); c.step(0)
            check(sounds == 0, "取消后不播放排队的开始提示音")
            m.shutdown()
        }
    }

    static func processChecks() {
        do {
            var fallbackReads = 0, reports: [String] = []
            let detector = SystemMediaAudio(processes: { [] }, deviceRunning: { _ in fallbackReads += 1; return true },
                                            ownPID: 100, log: { reports.append($0) })
            let (m, a, c) = make(); a.activity = { detector.running($0) }
            m.begin(); c.step(1); m.end(); m.shutdown()
            check(a.writes.isEmpty && fallbackReads == 0 && reports.count == 1, "设备忙但外部进程为空不动音量")
        }
        do {
            let detector = SystemMediaAudio(processes: {
                [MediaAudioProcess(pid: 100, bundleID: "self"), MediaAudioProcess(pid: 42, bundleID: "player"),
                 MediaAudioProcess(pid: 43, bundleID: "input", isRunningOutput: false)]
            }, ownPID: 100, log: { _ in })
            check(detector.running(TestAudio().output()!) == [42], "排除自身输出和只有输入的进程")
        }
        do {
            var reports: [String] = []
            let detector = SystemMediaAudio(processes: {
                [MediaAudioProcess(pid: 42, bundleID: "empty"), MediaAudioProcess(pid: 43, bundleID: "empty.player"),
                 MediaAudioProcess(pid: 44, bundleID: "")]
            }, ownPID: 100, ignoredBundleIDs: ["empty"], log: { reports.append($0) })
            check(detector.running(TestAudio().output()!) == [43, 44] && reports[0].contains("empty(PID 42)"), "精确排除 bundle id，并记日志")
        }
        do {
            for name in ["ProcessObjectList", "IsRunningOutput", "PID", "BundleID"] {
                var reports: [String] = []
                let detector = SystemMediaAudio(processes: {
                    throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: name])
                }, deviceRunning: { _ in true }, log: { reports.append($0) })
                check(detector.running(TestAudio().output()!) == [SystemMediaAudio.deviceFallbackPID]
                      && reports[0].contains("退回设备级") && reports[0].contains(name), "\(name) 失败时退回设备并记录")
            }
        }
        do {
            let failure: () throws -> [MediaAudioProcess] = { throw NSError(domain: "test", code: -1) }
            let output = TestAudio().output()!
            let idle = SystemMediaAudio(processes: failure, deviceRunning: { _ in false }, log: { _ in })
            let unknown = SystemMediaAudio(processes: failure, deviceRunning: { _ in nil }, log: { _ in })
            check(idle.running(output) == [] && unknown.running(output) == nil, "失败降级保持空闲和未知区别")
        }
        do {
            let detector = SystemMediaAudio(processes: {
                [MediaAudioProcess(pid: 42, bundleID: "com.newbaselab.nbime"),
                 MediaAudioProcess(pid: 43, bundleID: "com.newbaselab.clawchattest"),
                 MediaAudioProcess(pid: 44, bundleID: "com.newbaselab.clawchat")]
            }, ownPID: 100, ownBundleID: "com.newbaselab.nbime", log: { _ in })
            check(detector.running(TestAudio().output()!) == [44], "保留本机测试宿主和自身 bundle 排除规则")
        }
    }
}
