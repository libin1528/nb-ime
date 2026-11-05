// 只控制系统输出音量，不控制播放器。外部输出快照在开麦、提示音之前取。

import Cocoa
import CoreAudio
import Darwin

struct MediaOutput {
    let id: AudioDeviceID
    let name: String
    let elements: [AudioObjectPropertyElement]
}

protocol MediaAudio {
    func output() -> MediaOutput?
    func running(_ output: MediaOutput) -> Set<pid_t>?
    func isMuted(_ output: MediaOutput) -> Bool
    func volumes(_ output: MediaOutput) -> [Float]?
    func setVolumes(_ output: MediaOutput, _ values: [Float]) -> Bool
}

extension MediaAudio {
    func isMuted(_ output: MediaOutput) -> Bool { false }
}

/// CoreAudio 和曲线只在专用队列运行，开麦占住主线程也不影响压低音量。
final class MediaDuck {
    private final class Session {
        let output: MediaOutput
        let original: [Float]
        var expected: [Float]
        var ownsVolume = true
        var released = false
        init(_ output: MediaOutput, _ volumes: [Float]) {
            self.output = output; original = volumes; expected = volumes
        }
    }
    private struct Fade {
        let from: [Float]
        let to: [Float]
        let at: TimeInterval
        let duration: TimeInterval
        let restoring: Bool
        let pressedAt: TimeInterval
    }

    private let audio: MediaAudio
    private let now: () -> TimeInterval
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    // 这里只保护请求编号，不在锁里读音频设备；松开可立即撤销尚未完成的检测。
    private let control = NSLock()
    private var request = 0
    private var recording = false
    private var stopped = false
    // 以下状态仅由 queue 访问。
    private var cycle = 0
    private var didDuck = false
    private var session: Session?
    private var timer: DispatchSourceTimer?
    private var fade: Fade?
    private var pendingRestore: [Session] = []

    init(audio: MediaAudio = SystemMediaAudio(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         queue: DispatchQueue = DispatchQueue(label: "NBIME.volume", qos: .userInitiated)) {
        self.audio = audio; self.now = now; self.queue = queue
        queue.setSpecific(key: queueKey, value: true)
    }

    private func current(_ id: Int, active: Bool = false) -> Bool {
        control.lock(); defer { control.unlock() }
        return !stopped && request == id && (!active || recording)
    }

    /// 按下进入 holding 时即提交；检测和音量写入都不等待主线程、长按阈值或开麦。
    func begin(enabled: Bool = true) {
        control.lock()
        guard !stopped else { control.unlock(); return }
        request += 1
        let id = request
        recording = true
        control.unlock()
        let pressedAt = now()
        queue.async { self.beginOnQueue(enabled: enabled, id: id, pressedAt: pressedAt) }
    }

    private func beginOnQueue(enabled: Bool, id: Int, pressedAt: TimeInterval) {
        guard current(id, active: true) else { return }
        cycle = id; didDuck = false
        guard enabled else {
            if let s = session { restore(s) }
            clear()
            return
        }
        if let s = session {
            let output = audio.output()
            guard current(id, active: true) else { return }
            if output?.id == s.output.id, checkVolume(s) {
                let muted = audio.isMuted(s.output), pids = audio.running(s.output)
                guard current(id, active: true) else { return }
                guard !muted, let pids, !pids.isEmpty else { restore(s); clear(); return }
                s.released = false
                lower(s, pressedAt: pressedAt)
                return
            }
            restore(s)
            clear()
        }
        guard let output = audio.output(), !audio.isMuted(output),
              let pids = audio.running(output), !pids.isEmpty,
              let volumes = audio.volumes(output), volumes.contains(where: { $0 > 0 }),
              current(id, active: true) else { return }
        let s = Session(output, volumes)
        session = s
        Log.w("压低音量：输出 \(output.name)，外部进程 \(pids.sorted())，原音量 \(volumes)，检测 \(Int((now() - pressedAt) * 1000))ms")
        ensureTimer()
        lower(s, pressedAt: pressedAt)
    }

    /// 长按确认后只决定是否播放，不等待或抬音量；本次决定压低就跳过开始提示音。
    func playStartSound(_ play: @escaping () -> Void) {
        control.lock(); let id = request; control.unlock()
        queue.async { [self] in
            guard self.current(id, active: true) else { return }
            guard self.cycle != id || !self.didDuck else { return }
            DispatchQueue.main.async { [weak self] in
                guard self?.current(id, active: true) == true else { return }
                play()
            }
        }
    }

    private func lower(_ s: Session, pressedAt: TimeInterval) {
        guard checkVolume(s) else { return }
        didDuck = true
        fade = Fade(from: s.expected, to: s.original.map { _ in 0 }, at: now(),
                    duration: 0.15, restoring: false, pressedAt: pressedAt)
        Log.w("压低音量：\(s.output.name) 立即用 0.15 秒降到 0，跳过本次开始提示音")
    }

    /// 先撤销本次下降请求，再异步归还。结束提示音在抬至至少 30% 后回主线程立即播放。
    func end(playSound: (() -> Void)? = nil) {
        control.lock()
        guard !stopped, recording else { control.unlock(); return }
        let id = request
        recording = false
        control.unlock()
        queue.async { self.endOnQueue(id: id, playSound: playSound) }
    }

    private func endOnQueue(id: Int, playSound: (() -> Void)?) {
        guard current(id) else { return }
        if let s = session, !s.released {
            fade = nil
            s.released = true
            if checkVolume(s), playSound != nil {
                let audible = zip(s.expected, s.original).map { max($0, $1 * 0.3) }
                if audible != s.expected { _ = write(s, audible) }
            }
            if checkVolume(s), s.expected != s.original {
                fade = Fade(from: s.expected, to: s.original, at: now(), duration: 1.25,
                            restoring: true, pressedAt: 0)
                Log.w("恢复音量：\(s.output.name) 用 1.25 秒平滑恢复至 \(s.original)")
            } else { clear() }
        }
        if let playSound {
            DispatchQueue.main.async { [weak self] in
                guard self?.current(id) == true else { return }
                playSound()
            }
        }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard let s = session else { return }
        if audio.output()?.id != s.output.id {
            restore(s)
            Log.w("恢复音量：输出设备已切换，归还旧设备音量")
            clear()
            return
        }
        guard checkVolume(s) else {
            if s.released { clear() }
            return
        }
        guard let fade else { return }
        // 松开或下一次按下已经到达时，旧下降不能抢在排队的 end/begin 前继续写。
        if !fade.restoring, !current(cycle, active: true) { self.fade = nil; return }
        let t = min(1, max(0, (now() - fade.at) / fade.duration))
        let curve = Float(t * t * (3 - 2 * t))
        let values = t >= 1 ? fade.to : zip(fade.from, fade.to).map { $0 + ($1 - $0) * curve }
        if values != s.expected, !write(s, values) { return }
        if t >= 1 {
            self.fade = nil
            if fade.restoring { Log.w("恢复音量：已恢复 \(s.original)"); clear() }
            else { Log.w("压低音量：已降到 0，按下至此 \(Int((now() - fade.pressedAt) * 1000))ms") }
        }
    }

    @discardableResult private func checkVolume(_ s: Session) -> Bool {
        guard s.ownsVolume else { return false }
        guard let actual = audio.volumes(s.output) else {
            Log.w("恢复音量：读音量失败，尝试归还原值")
            restore(s)
            s.ownsVolume = false
            return false
        }
        guard same(actual, s.expected) else {
            s.ownsVolume = false
            fade = nil
            Log.w("恢复音量：用户或其它应用调整了音量，停止自动调节")
            return false
        }
        return true
    }

    private func same(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.002 }
    }

    @discardableResult private func write(_ s: Session, _ values: [Float]) -> Bool {
        guard s.ownsVolume else { return false }
        guard audio.setVolumes(s.output, values) else {
            Log.w("恢复音量：写音量失败，尝试归还原值")
            restore(s)
            s.ownsVolume = false
            return false
        }
        s.expected = values
        guard let actual = audio.volumes(s.output) else {
            Log.w("恢复音量：写入后读音量失败，尝试归还原值")
            restore(s, force: true)
            s.ownsVolume = false
            return false
        }
        s.expected = actual
        return true
    }

    private func restore(_ s: Session, force: Bool = false) {
        guard s.ownsVolume else { return }
        if !force, let actual = audio.volumes(s.output), !same(actual, s.expected) {
            s.ownsVolume = false
            return
        }
        if audio.setVolumes(s.output, s.original) { s.expected = s.original }
        else {
            if !pendingRestore.contains(where: { $0 === s }) { pendingRestore.append(s) }
            Log.w("恢复音量：设备 \(s.output.name) 不可写，退出时重试归还 \(s.original)")
        }
    }

    private func clear() {
        timer?.cancel(); timer = nil
        session = nil; fade = nil
    }

    func shutdown() {
        control.lock()
        stopped = true; recording = false; request += 1
        control.unlock()
        let cleanup = {
            if let s = self.session { self.restore(s) }
            let retry = self.pendingRestore
            self.pendingRestore = []
            for s in retry { s.ownsVolume = true; self.restore(s) }
            self.clear()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { cleanup() }
        else { queue.sync(execute: cleanup) }
    }
}

struct MediaAudioProcess {
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
    init(pid: pid_t, bundleID: String, isRunningOutput: Bool = true) {
        self.pid = pid; self.bundleID = bundleID; self.isRunningOutput = isRunningOutput
    }
}

final class SystemMediaAudio: MediaAudio {
    // 设备级兜底只表示存在输出，不伪造真实的进程 PID。
    static let deviceFallbackPID: pid_t = -1
    // 本机空闲场景中持续报告输出的测试宿主；它真发声时也会被忽略，见实现记录。
    static let ignoredBundleIDs: Set<String> = ["com.newbaselab.clawchattest"]

    private let readProcesses: () throws -> [MediaAudioProcess]
    private let readDeviceRunning: ((MediaOutput) -> Bool?)?
    private let ownPID: pid_t
    private let ownBundleID: String?
    private let ignored: Set<String>
    private let log: (String) -> Void
    private var lastReport = ""

    init(processes: (() throws -> [MediaAudioProcess])? = nil,
         deviceRunning: ((MediaOutput) -> Bool?)? = nil,
         ownPID: pid_t = getpid(), ownBundleID: String? = Bundle.main.bundleIdentifier,
         ignoredBundleIDs: Set<String>? = nil,
         log: ((String) -> Void)? = nil) {
        readProcesses = processes ?? Self.processes
        readDeviceRunning = deviceRunning
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
        ignored = ignoredBundleIDs ?? Self.ignoredBundleIDs
        self.log = log ?? Log.w
    }

    private static func processes() throws -> [MediaAudioProcess] {
        func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        }
        func check(_ status: OSStatus, _ property: String) throws {
            if status != noErr {
                throw NSError(domain: "NBIME.CoreAudio", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "\(property) 失败，OSStatus \(status)"])
            }
        }
        func uint(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ name: String) throws -> UInt32 {
            var addr = address(sel), value: UInt32 = 0, size: UInt32 = 4
            try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), name)
            return value
        }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size), "ProcessObjectList 大小")
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids), "ProcessObjectList")
        var active: [MediaAudioProcess] = []
        for id in ids {
            guard try uint(id, kAudioProcessPropertyIsRunningOutput, "IsRunningOutput 对象 \(id)") == 1 else { continue }
            let pid = try uint(id, kAudioProcessPropertyPID, "PID 对象 \(id)")
            var bundle: Unmanaged<CFString>?, bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            addr = address(kAudioProcessPropertyBundleID)
            try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &bytes, &bundle), "BundleID 对象 \(id)")
            active.append(MediaAudioProcess(pid: pid_t(bitPattern: pid), bundleID: bundle?.takeRetainedValue() as String? ?? ""))
        }
        return active
    }

    private func report(_ message: String) {
        guard message != lastReport else { return }
        lastReport = message
        log("压低音量：\(message)")
    }

    private func address(_ sel: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    private func uint(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(sel, scope), v: UInt32 = 0, size: UInt32 = 4
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    func output() -> MediaOutput? {
        guard let id = uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice), id != 0 else { return nil }
        var addr = address(kAudioObjectPropertyName), name: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        var elements: [AudioObjectPropertyElement] = []
        // 优先主音量；没有主控时记下每个输出声道，保持左右声道原来的平衡。
        if writable(id, 0) { elements = [0] }
        else {
            var streams = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput), bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let data = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { data.deallocate() }
            guard AudioObjectGetPropertyData(id, &streams, 0, nil, &bytes, data) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
            let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { return nil }
            elements = (1...channels).map { UInt32($0) }
            guard elements.allSatisfy({ writable(id, $0) }) else { return nil }
        }
        return MediaOutput(id: id, name: status == noErr ? (name?.takeRetainedValue() as String? ?? "输出设备") : "输出设备", elements: elements)
    }

    private func writable(_ id: AudioObjectID, _ element: AudioObjectPropertyElement) -> Bool {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element), yes = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &addr, &yes) == noErr && yes.boolValue
    }

    private func isOurs(_ process: MediaAudioProcess) -> Bool {
        process.pid == ownPID || (ownBundleID?.isEmpty == false && process.bundleID == ownBundleID)
    }

    func running(_ output: MediaOutput) -> Set<pid_t>? {
        do {
            let all = try readProcesses().filter { $0.isRunningOutput }
            let active = all.filter { !isOurs($0) && !ignored.contains($0.bundleID) }
            func describe(_ values: [MediaAudioProcess]) -> String {
                values.sorted { $0.pid < $1.pid }.map { "\($0.bundleID.isEmpty ? "<无 bundle id>" : $0.bundleID)(PID \($0.pid))" }.joined(separator: "，")
            }
            let skipped = all.filter { isOurs($0) || ignored.contains($0.bundleID) }
            report("按进程检测，外部输出 [\(describe(active))]，已排除 [\(describe(skipped))]")
            return Set(active.map(\.pid))
        } catch {
            let running: Bool?
            if let readDeviceRunning { running = readDeviceRunning(output) }
            else { running = uint(output.id, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 == 1 } }
            report("读取音频进程失败（\(error.localizedDescription)），退回设备级判断：\(output.name) 运行=\(running.map(String.init) ?? "读取失败")")
            return running.map { $0 ? [Self.deviceFallbackPID] : [] }
        }
    }

    func isMuted(_ output: MediaOutput) -> Bool {
        uint(output.id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput) == 1
    }

    func volumes(_ output: MediaOutput) -> [Float]? {
        var values: [Float] = []
        for element in output.elements {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element), v: Float = 0, size: UInt32 = 4
            guard AudioObjectGetPropertyData(output.id, &addr, 0, nil, &size, &v) == noErr, v.isFinite else { return nil }
            values.append(v)
        }
        return values
    }

    func setVolumes(_ output: MediaOutput, _ values: [Float]) -> Bool {
        guard values.count == output.elements.count, let old = volumes(output) else { return false }
        for (i, element) in output.elements.enumerated() {
            if !set(output.id, element, values[i]) {
                // 声道写入失败时回滚已经写过的声道，不能只剩一侧静音。
                for j in 0..<i { _ = set(output.id, output.elements[j], old[j]) }
                return false
            }
        }
        return true
    }

    private func set(_ id: AudioObjectID, _ element: AudioObjectPropertyElement, _ value: Float) -> Bool {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element), v = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, 4, &v) == noErr
    }
}

