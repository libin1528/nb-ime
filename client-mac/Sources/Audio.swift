// 录音（转成 16kHz 单声道 float32）、能录音的设备、提示音。

import AVFoundation
import Cocoa
import CoreAudio

/// 所有状态都在主线程修改；音频线程只负责转换并把采样送回主线程。
final class Recorder {
    private var engine: RecordingEngine?
    private var engineDevice: AudioDeviceID?
    private var builtFormat = RecordingFormat(rate: 0, channels: 0)
    private let makeEngine: () -> RecordingEngine
    private let currentDevice: () -> InputDevice?
    private let now: () -> TimeInterval
    private let later: (TimeInterval, @escaping () -> Void) -> Void
    private let notifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var generation = 0
    private var lastSamplesAt: TimeInterval = 0
    private var receivedSamples = false
    private var recoveries = 0
    private var recoveryAllowed = false
    private(set) var running = false
    var onSamples: (([Float]) -> Void)?
    var onFailure: ((Error) -> Void)?
    static let noDataTimeout: TimeInterval = 1
    static let recoveryLimit = 2

    init(makeEngine: @escaping () -> RecordingEngine = { SystemRecordingEngine() },
         currentDevice: @escaping () -> InputDevice? = { InputDevices.current() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         later: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }, notifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.makeEngine = makeEngine
        self.currentDevice = currentDevice
        self.now = now
        self.later = later
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications
        observers.append(notifications.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
            guard let self, let engine = self.engine, n.object as AnyObject? === engine.notificationObject else { return }
            // 同采样率的配置变化也可能停掉引擎；刚初始化时发的通知则不该反复重建。
            if !engine.isRunning || engine.format != self.builtFormat { self.engineDevice = nil }
        })
        observers.append(notifications.addObserver(forName: .inputDevicesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.engineDevice = nil
            self.refreshAfterChange("输入设备变化")
        })
        wakeObserver = workspaceNotifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.engineDevice = nil
            self.refreshAfterChange("睡眠唤醒")
        }
    }

    deinit {
        for observer in observers { notifications.removeObserver(observer) }
        if let wakeObserver { workspaceNotifications.removeObserver(wakeObserver) }
        engine?.stop()
    }

    /// 启动时和设备变化时先建好引擎，免得第一次按热键时才等待硬件。
    func prepare() throws {
        guard !running else { return }
        guard let dev = currentDevice() else { throw Self.error("没有能录音的设备") }
        guard dev.id != engineDevice else { return }
        let old = engine
        engine = nil
        old?.stop()
        // CoreAudio 可能仍在退出 IO 回调，且配置通知中不能同步释放引擎。
        later(2) { _ = old }
        let next = makeEngine()
        try next.selectDevice(dev.id)
        let format = next.format
        guard format.rate > 0, format.channels > 0 else { throw Self.error("拿不到麦克风") }
        engine = next
        builtFormat = format
        engineDevice = dev.id
        Log.w("录音设备换成 \(dev.name)（\(Int(format.rate)) Hz \(format.channels) 声道）")
    }

    func start() throws {
        guard !running else { return }
        recoveries = 0
        try beginCapture()
    }

    private func beginCapture() throws {
        try prepare()
        if engine?.format != builtFormat {
            engineDevice = nil
            try prepare()
        }
        guard let engine else { throw Self.error("拿不到麦克风") }
        generation += 1
        let token = generation
        lastSamplesAt = now()
        receivedSamples = false
        do {
            try engine.start { [weak self] samples in
                guard let self, self.generation == token, !samples.isEmpty else { return }
                self.lastSamplesAt = self.now()
                self.receivedSamples = true  // 全零采样仍是正常收音，不是引擎断流。
                self.onSamples?(samples)
            }
            running = true
            recoveryAllowed = true
            watch(token)
        } catch {
            engine.stop()
            engineDevice = nil
            generation += 1
            throw error
        }
    }

    private func watch(_ token: Int) {
        later(0.25) { [weak self] in
            guard let self, self.running, self.recoveryAllowed, self.generation == token else { return }
            if self.engine?.isRunning != true || self.now() - self.lastSamplesAt >= Self.noDataTimeout {
                self.recover("收不到音频数据")
            } else {
                self.watch(token)
            }
        }
    }

    private func refreshAfterChange(_ reason: String) {
        // 离开硬件通知栈再拆旧引擎。延迟任务必须确认录音还是原来那次。
        let token = generation
        later(0) { [weak self] in
            guard let self, self.generation == token else { return }
            if self.running { self.recover(reason) }
            else {
                do { try self.prepare() }
                catch { Log.w("预备麦克风失败：\(error.localizedDescription)，下次开麦重试") }
            }
        }
    }

    private func recover(_ reason: String) {
        guard running, recoveryAllowed else { return }
        stop()
        engineDevice = nil
        generation += 1  // 丢弃旧引擎迟到的采样和定时任务。
        guard recoveries < Self.recoveryLimit else {
            fail(Self.error("麦克风持续收不到音频，请检查输入设备"))
            return
        }
        recoveries += 1
        Log.w("\(reason)，自动重建录音引擎（\(recoveries)/\(Self.recoveryLimit)）")
        do { try beginCapture() }
        catch { fail(error) }
    }

    private func fail(_ error: Error) {
        Log.w("录音恢复失败：\(error.localizedDescription)")
        onFailure?(error)
    }

    /// 松开后只收尾音，后台不再开新引擎。
    func finish() { recoveryAllowed = false }

    func stop() {
        recoveryAllowed = false
        guard running else { return }
        running = false
        engine?.stop()
        if !receivedSamples { engineDevice = nil } // 短按还没到 watchdog 时，下次也不复用断流引擎。
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "NBIME", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static var deviceName: String { InputDevices.current()?.name ?? "麦克风" }

    /// 一段采样的音量，映射到 0…1（-55 dB 以下算 0，-15 dB 以上算 1）。
    static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples { sum += x * x }
        let db = 10 * log10(max(sum / Float(samples.count), 1e-12))
        return min(1, max(0, (db + 55) / 40))
    }
}

// MARK: - 能录音的设备

extension Notification.Name {
    static let inputDevicesChanged = Notification.Name("NBInputDevicesChanged")
}

struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum InputDevices {
    /// 所有有输入通道的设备，按系统给的顺序
    static func all() -> [InputDevice] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    static var systemDefault: InputDevice? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return all().first { $0.id == id }
    }

    /// 录音实际用的：设置里选了而且还连着就用它，否则用系统默认的
    static func current() -> InputDevice? {
        let uid = Settings.current.micUID
        return (uid.isEmpty ? nil : all().first { $0.uid == uid }) ?? systemDefault
    }

    /// 插拔设备、系统换默认麦克风时发 .inputDevicesChanged
    static func watch() {
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = address(sel)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
                NotificationCenter.default.post(name: .inputDevicesChanged, object: nil)
            }
        }
    }

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }
}

enum Sounds {
    static func start() { if Settings.current.sounds { NSSound(named: "Tink")?.play() } }
    static func stop() { if Settings.current.sounds { NSSound(named: "Pop")?.play() } }
}
