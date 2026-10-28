// 主控：按住快捷键说话，松开后把录音送到 ITX 上的 CapsWriter 服务端识别，结果粘贴到当前输入框。
// 开了流式预览时，同一段录音同时走两条连接：预览连接每 2 秒出一次到目前为止的文字，只用来显示；
// 完整连接松开后出最终结果，粘贴用它。服务端的音频缓存按连接分，两个任务不能挤在一条连接上。

import AVFoundation
import Cocoa
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, SettingsHost {
    private enum Phase { case idle, holding, recording, finishing }

    private var tunnel: Tunnel?
    private var client: ASRClient!            // 完整识别
    private var preview: ASRClient!           // 流式预览
    private var connKey = ""
    /// ssh 报 No route to host：多半是系统设置里没允许 NB 输入法访问本地网络
    private var localNetworkBlocked = false
    private let recorder = Recorder()
    private var hotkey: Hotkey!
    private lazy var capsule = Capsule()
    private var menuBar: MenuBar?
    private lazy var settingsWindow = SettingsWindow(host: self)
    private lazy var onboarding = Onboarding()

    private var phase = Phase.idle
    private var taskId = ""
    private var startTime = 0.0
    private var pending: [Float] = []
    private var sentSamples = 0
    private var peakLevel: Float = 0
    private var frontApp = ""
    private var discard = Set<String>()
    private var taskAudio: [String: [Float]] = [:]
    private var taskMeta: [String: (seconds: Double, app: String)] = [:]
    // 复核任务 id → 原任务、第一次抄出来的热词、原任务松开的时间
    private var retryOf: [String: (orig: String, first: [String], started: Date?)] = [:]
    private var releasedAt: [String: Date] = [:]

    // 流式预览
    static let previewSeg = 2.0, previewOverlap = 0.5
    private var previewId: String?
    private var previewShown = ""
    private var previewEchoes: [String] = []      // 抄出来的热词段，之后的预览里也去掉
    private var previewStarted = Date()

    private let args = CommandLine.arguments
    private lazy var testFile: String? = arg("--test-file")
    private lazy var demo: String? = arg("--demo")
    private func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let s = Settings.current
        hotkey = Hotkey(code: s.hotkeyCode)
        Log.w("启动 \(Bundle.main.bundleIdentifier ?? "") → \(s.url)，热键 \(Hotkey.keyName(s.hotkeyCode))")
        connect()
        if let testFile {
            runFileTest(testFile)
            return
        }
        setupMenuBar()
        recorder.onSamples = { [weak self] in self?.handleSamples($0) }
        hotkey.onDown = { [weak self] in self?.hotkeyDown() }
        hotkey.onUp = { [weak self] in self?.hotkeyUp() }
        hotkey.onOtherKey = { [weak self] in
            guard let self, self.phase == .holding || self.phase == .recording else { return }
            // 按住热键时又按了别的键 = 在用快捷键，不是在说话
            self.cancelRecording("组合键")
        }
        onboarding.onDone = { [weak self] in self?.refreshStatus() }
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
        if let demo {
            runDemo(demo)
            return
        }
        if !s.onboarded || !Onboarding.micOK || !Onboarding.accessOK {
            onboarding.show()
        }
        waitForAccessibility(first: true)
    }

    func applicationWillTerminate(_ n: Notification) { tunnel?.stop() }

    // MARK: 连接

    /// 测试和截图时用客户端已经开着的隧道，不动它
    private var useExistingTunnel: Bool {
        (testFile != nil || demo != nil) && Self.portOpen(Settings.current.localPort)
    }

    private func connect() {
        tunnel?.stop()
        client?.stop()
        preview?.stop()
        let s = Settings.current
        connKey = s.connectionKey
        tunnel = nil
        if !s.tunnelHost.isEmpty, !useExistingTunnel {
            let t = Tunnel(s)
            t.onExit = { [weak self] msg in
                guard let self else { return }
                let blocked = msg.contains("No route to host")
                if blocked != self.localNetworkBlocked { self.localNetworkBlocked = blocked; self.refreshStatus() }
            }
            t.killStale()
            t.start()
            tunnel = t
        }
        client = ASRClient(url: s.url, name: "完整")
        preview = ASRClient(url: s.url, name: "预览")
        client.onState = { [weak self] in
            if self?.client.connected == true { self?.localNetworkBlocked = false }
            self?.refreshStatus()
            NotificationCenter.default.post(name: .connectionChanged, object: nil)
        }
        client.onResult = { [weak self] id, final, text in self?.handleResult(id, final, text) }
        preview.onResult = { [weak self] id, final, text in self?.handlePreview(id, final, text) }
        let c = client!, p = preview!
        DispatchQueue.main.asyncAfter(deadline: .now() + (tunnel == nil ? 0 : 1)) {
            c.connect()
            p.connect()
        }
    }

    private static func portOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private func settingsChanged() {
        let s = Settings.current
        if s.connectionKey != connKey {
            Log.w("连接设置改了 → \(s.url)")
            connect()
        }
        if hotkey.code != s.hotkeyCode { hotkey.code = s.hotkeyCode }
        refreshStatus()
    }

    // MARK: 辅助功能权限：监听全局按键、模拟 ⌘V 都要它

    private func waitForAccessibility(first: Bool) {
        if AXIsProcessTrusted() {
            // 运行中途才拿到权限时，事件钩子收不到事件，重启一次才生效
            if !first {
                Log.w("刚拿到辅助功能权限，重启自己")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-n", Bundle.main.bundlePath]
                tunnel?.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    try? p.run()
                    NSApp.terminate(nil)
                }
                return
            }
            installHotkey()
        } else {
            refreshStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.waitForAccessibility(first: false) }
        }
    }

    private func installHotkey() {
        guard hotkey.install() else {
            Log.w("事件钩子建不起来，2 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installHotkey() }
            return
        }
        Log.w("辅助功能权限已有，开始监听热键（\(Hotkey.keyName(hotkey.code))）")
        if Settings.current.onboarded, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { ok in Log.w("麦克风权限 \(ok)") }
        }
        refreshStatus()
    }

    // MARK: 录音

    private func hotkeyDown() {
        guard phase == .idle else { return }
        guard client.connected else {
            capsule.show(.offline, for: 2.2)
            return
        }
        taskId = UUID().uuidString
        startTime = Date().timeIntervalSince1970
        pending = []
        sentSamples = 0
        peakLevel = 0
        frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        do {
            try recorder.start()
        } catch {
            capsule.show(.note("mic.slash", "麦克风打不开"), for: 2)
            Log.w("录音失败 \(error.localizedDescription)")
            return
        }
        phase = .holding
        let id = taskId
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.current.holdThreshold) { [weak self] in
            guard let self, self.taskId == id, self.phase == .holding else { return }
            self.phase = .recording
            self.startPreview()
            self.flush()
            Sounds.start()
            self.capsule.showListening()
            self.refreshStatus()
        }
    }

    private func hotkeyUp() {
        switch phase {
        case .holding:
            recorder.stop()
            phase = .idle
        case .recording:
            phase = .finishing
            Sounds.stop()
            let id = taskId
            DispatchQueue.main.asyncAfter(deadline: .now() + Settings.current.tailSeconds) { [weak self] in
                guard let self, self.taskId == id else { return }
                self.recorder.stop()
                // 让最后几块转换好的音频先进队列
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.finishTask(id) }
            }
        default:
            break
        }
    }

    private func finishTask(_ id: String) {
        // 松开后预览就不再喂了；它的结尾等完整结果回来再发，免得服务端先去算预览、完整结果排在后面
        holdPreview()
        flush()
        send(data: "", final: true)
        releasedAt[id] = Date()
        armTimeout(id)
        phase = .idle
        let secs = Double(sentSamples) / 16000
        taskMeta[id] = (secs, frontApp)
        Log.w("送出 \(id.prefix(8)) 时长 \(String(format: "%.1f", secs))s 音量峰值 \(String(format: "%.2f", peakLevel))")
        if sentSamples < 16000 / 5 {
            discard.insert(id)
            capsule.hide()
        } else if testFile == nil {
            capsule.showThinking()
        }
        refreshStatus()
    }

    private func armTimeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.releasedAt.removeValue(forKey: id) != nil, !self.discard.contains(id) else { return }
            self.taskAudio[id] = nil
            self.retryOf[id] = nil
            self.capsule.show(.note("clock", "识别超时"), for: 2)
            self.refreshStatus()
        }
    }

    private func cancelRecording(_ why: String) {
        Log.w("取消录音：\(why)")
        recorder.stop()
        if phase == .recording || phase == .finishing {
            discard.insert(taskId)
            send(data: "", final: true)
            holdPreview()
            closePreview()
        }
        phase = .idle
        capsule.hide()
        refreshStatus()
    }

    private func handleSamples(_ samples: [Float]) {
        guard phase != .idle else { return }
        let v = Recorder.level(samples)
        peakLevel = max(peakLevel, v)
        capsule.setLevel(v)
        pending += samples
        if phase != .holding, pending.count >= 1600 { flush() }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let b64 = pending.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        sentSamples += pending.count
        taskAudio[taskId, default: []] += pending
        pending = []
        send(data: b64, final: false)
        if let pid = previewId {
            preview.send(message(pid, b64, false, Settings.hotwordList().joined(separator: "，"),
                                 seg: Self.previewSeg, overlap: Self.previewOverlap))
        }
    }

    private func send(data: String, final: Bool) {
        client.send(message(taskId, data, final, Settings.hotwordList().joined(separator: "，")))
    }

    private func message(_ id: String, _ data: String, _ final: Bool, _ context: String,
                         seg: Double = 60, overlap: Double = 4) -> [String: Any] {
        [
            "task_id": id, "source": "mic", "data": data, "is_final": final,
            "time_start": startTime, "seg_duration": seg, "seg_overlap": overlap,
            "context": context, "language": Settings.current.language,
        ]
    }

    // MARK: 流式预览

    private func startPreview() {
        closePreview()
        previewId = nil
        previewShown = ""
        previewEchoes = []
        guard Settings.current.streamPreview, preview.connected else { return }
        previewId = UUID().uuidString
        previewStarted = Date()
    }

    private var previewToClose: String?

    private func holdPreview() {
        guard let pid = previewId else { return }
        previewId = nil
        previewToClose = pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.previewToClose == pid { self?.closePreview() }
        }
    }

    /// 结束服务端那边的预览任务，清掉这条连接上的音频缓存
    private func closePreview() {
        guard let pid = previewToClose else { return }
        previewToClose = nil
        preview.send(message(pid, "", true, "", seg: Self.previewSeg, overlap: Self.previewOverlap))
    }

    private func handlePreview(_ id: String, _ final: Bool, _ raw: String) {
        guard id == previewId, !final else { return }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for e in previewEchoes { text = text.replacingOccurrences(of: e, with: "") }
        // 新冒出来的这一段要是整段都是热词，就是短片段遇上静音抄了热词表，这一段不显示
        let fresh = String(text.dropFirst(text.commonPrefix(with: previewShown).count))
        if Settings.echoedHotwords(fresh, Settings.hotwordList()) != nil {
            Log.w("预览这一段像是抄了热词表：\(fresh)，不显示")
            previewEchoes.append(fresh)
            return
        }
        guard !text.isEmpty, text != previewShown else { return }
        previewShown = text
        let t = String(format: "%.1f", Date().timeIntervalSince(previewStarted))
        if testFile != nil { print("PREVIEW \(t)s \(text)") }
        Log.w("预览 \(t)s：\(text)")
        capsule.setPreview(Hotfix.apply(text, Settings.hotwordList()))
    }

    // MARK: 结果

    /// 同一段录音换成倒序热词再认一次
    private func recheck(_ id: String, first: [String], started: Date?, audio: [Float]) {
        let rid = UUID().uuidString
        retryOf[rid] = (id, first, started)
        taskMeta[rid] = taskMeta.removeValue(forKey: id)
        releasedAt[rid] = Date()
        armTimeout(rid)
        let b64 = audio.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        let ctx = Settings.hotwordList().reversed().joined(separator: "，")
        client.send(message(rid, b64, false, ctx))
        client.send(message(rid, "", true, ctx))
    }

    private func handleResult(_ id: String, _ final: Bool, _ raw: String) {
        guard final else { return }
        closePreview()
        var started = releasedAt.removeValue(forKey: id)
        let audio = taskAudio.removeValue(forKey: id)
        if discard.remove(id) != nil {
            taskMeta[id] = nil
            return
        }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let echo = Settings.echoedHotwords(text, Settings.hotwordList())
        if let retry = retryOf.removeValue(forKey: id) {
            // 两次都抄：开头一致说明真说了这个词，只留它；不一致就是凭空抄的
            if let echo {
                text = echo.first == retry.first.first ? echo[0] : ""
            }
            Log.w("复核 \(retry.orig.prefix(8))：第一次 \(retry.first)，倒序后「\(raw)」→「\(text)」")
            started = retry.started
        } else if let echo, let audio {
            Log.w("结果 \(id.prefix(8)) 像是抄了热词表：\(raw)，换倒序热词复核")
            recheck(id, first: echo, started: started, audio: audio)
            return
        }
        let meta = taskMeta.removeValue(forKey: id)
        let ms = started.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        if Settings.current.stripShortTrailingPeriod, text.count <= 12, let last = text.last, "。.".contains(last) {
            text.removeLast()
        }
        let fixed = Hotfix.apply(text, Settings.hotwordList())
        if fixed != text {
            Log.w("按读音换回热词：\(text) → \(fixed)")
            text = fixed
        }
        Log.w("结果 \(id.prefix(8)) 松开后 \(ms)ms：\(text)")
        refreshStatus()
        if testFile != nil {
            print("RESULT \(ms)ms \(text)")
            NSApp.terminate(nil)
            return
        }
        guard !text.isEmpty else {
            capsule.show(.miss, for: 2.2)
            return
        }
        Paster.paste(text, restore: Settings.current.restoreClipboard)
        capsule.show(.done(text.count), for: 1.6)
        History.add(HistoryEntry(text: text, date: Date(), seconds: meta?.seconds ?? 0, app: meta?.app ?? ""))
        onboarding.heard(text)
        refreshStatus()
    }

    // MARK: 菜单栏

    private func setupMenuBar() {
        let m = MenuBar()
        m.onPause = { [weak self] in
            guard let self else { return }
            self.hotkey.paused.toggle()
            Log.w(self.hotkey.paused ? "暂停语音输入" : "恢复语音输入")
            if self.hotkey.paused, self.phase != .idle { self.cancelRecording("暂停") }
            self.refreshStatus()
        }
        m.onReconnect = { [weak self] in self?.connect() }
        m.onSettings = { [weak self] in self?.settingsWindow.show() }
        m.onAccess = { [weak self] in self?.onboarding.show() }
        m.onLocalNetwork = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
        }
        menuBar = m
        refreshStatus()
    }

    private func refreshStatus() {
        guard let menuBar else { return }
        var st = MenuBar.State()
        st.status = hotkey.paused ? .paused : !hotkey.installed ? .needsAccess : client.connected ? .ready
            : localNetworkBlocked ? .noLocalNetwork : .offline
        st.recording = phase == .recording || phase == .finishing
        st.thinking = !releasedAt.isEmpty
        menuBar.update(st)
    }

    static func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.w("登录项设置失败 \(error.localizedDescription)")
        }
        Log.w("登录项状态 \(SMAppService.mainApp.status.rawValue)")
    }

    // MARK: SettingsHost

    var isConnected: Bool { client?.connected ?? false }
    var needsLocalNetwork: Bool { localNetworkBlocked }
    var latency: Double? { client?.latency }
    func testConnection(_ done: @escaping (Double?) -> Void) {
        guard client.connected else {
            connect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.client.ping(done) ?? done(nil) }
            return
        }
        client.ping(done)
    }

    func captureHotkey(_ done: @escaping (UInt16?) -> Void) -> Bool {
        guard hotkey.installed else { return false }
        hotkey.beginCapture(done)
        return true
    }

    func cancelHotkeyCapture() { hotkey.cancelCapture() }

    // MARK: 不用麦克风，把音频文件按实时节奏走一遍同样的发送路径（预览也走）

    private func runFileTest(_ path: String) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: file.processingFormat, to: out),
              let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate + 64))
        else { print("读不了 \(path)"); exit(1) }
        var fed = false
        var err: NSError?
        conv.convert(to: dst, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return buf
        }
        let all = Array(UnsafeBufferPointer(start: dst.floatChannelData![0], count: Int(dst.frameLength)))
        func go() {
            guard client.connected, preview.connected || !Settings.current.streamPreview else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go() }
                return
            }
            taskId = UUID().uuidString
            startTime = Date().timeIntervalSince1970
            phase = .recording
            startPreview()
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
                guard let self else { return }
                let end = min(i + 1600, all.count)
                self.handleSamples(Array(all[i..<end]))
                i = end
                if i >= all.count {
                    t.invalidate()
                    print("RELEASE \(String(format: "%.1f", Date().timeIntervalSince(self.previewStarted)))s")
                    self.finishTask(self.taskId)
                }
            }
        }
        go()
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("超时"); exit(2) }
    }

    // MARK: 截图用：--demo <界面>

    private func runDemo(_ what: String) {
        let text = "我们这一轮把 NB 输入法做成正式产品，说话的时候能实时看到文字，"
        let long = text + "松开以后再一次性修正，这样等的时候心里有底。还有一点，预览也要带热词，不然 ClawChat 会被听成 Clochat，所以短片段也要过一遍抄热词的检测"
        let wobble = { [weak self] in
            var t = 0.0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                t += 0.05
                self?.capsule.setLevel(Float(0.15 + 0.75 * abs(sin(t * 7.3) * sin(t * 2.1 + 1))))
            }
        }
        switch what {
        case "listen": capsule.showListening(); wobble()
        case "quiet": capsule.showListening()
        case "preview": capsule.showListening(); wobble(); capsule.setPreview(text)
        case "long": capsule.showListening(); wobble(); capsule.setPreview(long)
        case "think": capsule.showListening(); capsule.setPreview(text + "松开以后再一次性休整"); capsule.showThinking()
        case "done": capsule.show(.done(55), for: 600)
        case "miss": capsule.show(.miss, for: 600)
        case "offline": capsule.show(.offline, for: 600)
        case "onboarding": onboarding.show()
        case "menu": DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.menuBar?.popUp() }
        default:
            if what.hasPrefix("settings:"), let i = Int(what.dropFirst(9)), let tab = SettingsWindow.Tab(rawValue: i) {
                settingsWindow.show(tab)
            }
        }
    }
}
