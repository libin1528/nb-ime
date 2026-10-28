// ITX 语音输入：按住快捷键（默认右 Option）说话，松开后把录音送到 ITX 上的 CapsWriter 服务端识别，结果粘贴到当前输入框。
// 协议见 CapsWriter-Offline core/protocol.py：JSON 文本帧，音频是 16kHz 单声道 float32 的 base64。

import AVFoundation
import ApplicationServices
import Cocoa
import ServiceManagement

// MARK: - 配置

struct Settings {
    var tunnelHost = "winrig"        // ssh 主机名；留空就直连 serverHost:serverPort
    var serverHost = "itx-1.local"
    var serverPort = 6016
    var localPort = 16016            // 隧道在本机的端口
    var hotkeyCode: UInt16 = 61      // 61 = 右 Option
    var holdThreshold = 0.3          // 按住不到这么久算误触，不录
    var tailSeconds = 0.25           // 松开后多录一小段，免得吞掉最后一个字
    var language = "auto"
    var restoreClipboard = true
    var stripShortTrailingPeriod = true

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ITXVoice")
    static var configURL: URL { dir.appendingPathComponent("config.json") }
    static var hotwordsURL: URL { dir.appendingPathComponent("hotwords.txt") }

    static func load() -> Settings {
        var s = Settings()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: hotwordsURL.path) {
            try? "# 一行一个词，识别时作为上下文提示给模型\nClawChat\nLiveware\n".write(to: hotwordsURL, atomically: true, encoding: .utf8)
        }
        guard let data = try? Data(contentsOf: configURL),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            s.save()
            return s
        }
        if let v = j["tunnelHost"] as? String { s.tunnelHost = v }
        if let v = j["serverHost"] as? String { s.serverHost = v }
        if let v = j["serverPort"] as? Int { s.serverPort = v }
        if let v = j["localPort"] as? Int { s.localPort = v }
        if let v = j["hotkeyCode"] as? Int { s.hotkeyCode = UInt16(v) }
        if let v = j["holdThreshold"] as? Double { s.holdThreshold = v }
        if let v = j["tailSeconds"] as? Double { s.tailSeconds = v }
        if let v = j["language"] as? String { s.language = v }
        if let v = j["restoreClipboard"] as? Bool { s.restoreClipboard = v }
        if let v = j["stripShortTrailingPeriod"] as? Bool { s.stripShortTrailingPeriod = v }
        return s
    }

    func save() {
        let j: [String: Any] = [
            "tunnelHost": tunnelHost, "serverHost": serverHost, "serverPort": serverPort,
            "localPort": localPort, "hotkeyCode": Int(hotkeyCode), "holdThreshold": holdThreshold,
            "tailSeconds": tailSeconds, "language": language, "restoreClipboard": restoreClipboard,
            "stripShortTrailingPeriod": stripShortTrailingPeriod,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: Settings.configURL)
        }
    }

    var url: URL {
        tunnelHost.isEmpty
            ? URL(string: "ws://\(serverHost):\(serverPort)")!
            : URL(string: "ws://127.0.0.1:\(localPort)")!
    }

    static func hotwords() -> String {
        let text = (try? String(contentsOf: hotwordsURL, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: "，")
    }
}

// MARK: - 日志

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ITXVoice.log")
    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func w(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        let data = Data(line.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
        if isatty(2) != 0 { FileHandle.standardError.write(data) }
    }
}

// MARK: - ssh 隧道（不用在 ITX 上开防火墙端口）

final class Tunnel {
    private var proc: Process?
    private var stopped = false
    let s: Settings

    init(_ s: Settings) { self.s = s }

    func start() {
        guard !s.tunnelHost.isEmpty, !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "ConnectTimeout=8",
            "-L", "127.0.0.1:\(s.localPort):127.0.0.1:\(s.serverPort)", s.tunnelHost,
        ]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] pr in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Log.w("隧道退出 code=\(pr.terminationStatus) \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.start() }
        }
        do {
            try p.run()
            proc = p
            Log.w("隧道启动 pid=\(p.processIdentifier) → \(s.tunnelHost)")
        } catch {
            Log.w("隧道启动失败 \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
        }
    }

    func stop() {
        stopped = true
        proc?.terminate()
    }
}

// MARK: - WebSocket 客户端

final class ASRClient: NSObject, URLSessionWebSocketDelegate {
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var reconnectScheduled = false
    private var pingTimer: Timer?
    let url: URL
    var connected = false { didSet { if oldValue != connected { onState?() } } }
    var onState: (() -> Void)?
    var onResult: ((String, Bool, String) -> Void)?   // taskId, isFinal, text

    init(url: URL) {
        self.url = url
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.task?.sendPing { _ in }
        }
    }

    func connect() {
        reconnectScheduled = false
        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: url, protocols: ["binary"])
        t.maximumMessageSize = 64 << 20
        task = t
        t.resume()
        receive(t)
    }

    private func scheduleReconnect() {
        connected = false
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] r in
            DispatchQueue.main.async {
                guard let self, t === self.task else { return }
                switch r {
                case .success(let m):
                    var data: Data?
                    switch m {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let id = j["task_id"] as? String {
                        self.onResult?(id, j["is_final"] as? Bool ?? false, j["text"] as? String ?? "")
                    }
                    self.receive(t)
                case .failure(let e):
                    Log.w("接收失败 \(e.localizedDescription)")
                    self.scheduleReconnect()
                }
            }
        }
    }

    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { e in if let e { Log.w("发送失败 \(e.localizedDescription)") } }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        Log.w("已连上 \(url)")
        connected = true
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        scheduleReconnect()
    }
}

// MARK: - 录音（转成 16kHz 单声道 float32）

final class Recorder {
    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private(set) var running = false
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "ITXVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "拿不到麦克风"])
        }
        let out = outFormat
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 20), format: inFormat) { [weak self] buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFormat.sampleRate + 64)
            guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: dst, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard dst.frameLength > 0, let ch = dst.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(dst.frameLength)))
            DispatchQueue.main.async { self?.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}

// MARK: - 屏幕底部的状态提示

final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 18
        bg.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        bg.addSubview(label)
        panel.contentView = bg
    }

    func show(_ text: String, for seconds: Double? = nil) {
        hideWork?.cancel()
        label.stringValue = text
        label.sizeToFit()
        let w = max(120, label.frame.width + 40), h: CGFloat = 36
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 72, width: w, height: h), display: true)
        }
        label.frame = NSRect(x: 0, y: (h - label.frame.height) / 2, width: w, height: label.frame.height)
        panel.orderFrontRegardless()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }
}

// MARK: - 粘贴

enum Paster {
    static func paste(_ text: String, restore: Bool) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // 让剪贴板管理器不记这一条
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let ours = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // 9 = V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        guard restore, !saved.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }
}

// MARK: - 主控

final class AppController: NSObject, NSApplicationDelegate {
    private enum Phase { case idle, holding, recording, finishing }

    private var s = Settings.load()
    private lazy var tunnel = Tunnel(s)
    private lazy var client = ASRClient(url: s.url)
    private let recorder = Recorder()
    private let hud = HUD()
    private var statusItem: NSStatusItem!
    private let stateMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastMenuItem = NSMenuItem(title: "最近：—", action: nil, keyEquivalent: "")
    private let loginMenuItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")

    private var phase = Phase.idle
    private var taskId = ""
    private var startTime = 0.0
    private var pending: [Float] = []
    private var sentSamples = 0
    private var discard = Set<String>()
    private var releasedAt: [String: Date] = [:]
    private var monitorsInstalled = false
    private let testFile: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--test-file"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.w("启动 → \(s.url)，热键 keyCode=\(s.hotkeyCode)")
        killStaleTunnel()
        tunnel.start()
        client.onState = { [weak self] in self?.refreshStatus() }
        client.onResult = { [weak self] id, final, text in self?.handleResult(id, final, text) }
        recorder.onSamples = { [weak self] samples in self?.handleSamples(samples) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (s.tunnelHost.isEmpty ? 0 : 1)) { [weak self] in
            self?.client.connect()
        }
        if let testFile {
            runFileTest(testFile)
            return
        }
        setupStatusItem()
        AVCaptureDevice.requestAccess(for: .audio) { ok in Log.w("麦克风权限 \(ok)") }
        waitForAccessibility(prompt: true)
    }

    func applicationWillTerminate(_ n: Notification) { tunnel.stop() }

    private func killStaleTunnel() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "127.0.0.1:\(s.localPort):127.0.0.1:\(s.serverPort)"]
        try? p.run()
        p.waitUntilExit()
    }

    // 辅助功能权限：监听全局按键、模拟 ⌘V 都要它
    private func waitForAccessibility(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            // 运行中途才拿到权限时，全局按键监听收不到事件，重启一次才生效
            if !prompt {
                Log.w("刚拿到辅助功能权限，重启自己")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-n", Bundle.main.bundlePath]
                tunnel.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    try? p.run()
                    NSApp.terminate(nil)
                }
                return
            }
            installMonitors()
        } else {
            refreshStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.waitForAccessibility(prompt: false) }
        }
    }

    // 用事件钩子听键盘：修饰键当热键时原样放行，普通键当热键时吞掉，免得打出字来
    private var eventTap: CFMachPort?
    private var capturing = false        // 正在等用户按下新的快捷键
    private var hotkeyHeld = false

    private func installMonitors() {
        guard !monitorsInstalled else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                let me = Unmanaged<AppController>.fromOpaque(info!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    Log.w("事件钩子被系统停用，重新打开")
                    if let t = me.eventTap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return me.handleKey(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: me)
        else {
            Log.w("事件钩子建不起来，2 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installMonitors() }
            return
        }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        monitorsInstalled = true
        Log.w("辅助功能权限已有，开始监听热键（\(Self.keyName(s.hotkeyCode))）")
        refreshStatus()
    }

    // 修饰键：keyCode → 区分左右的设备位
    private static let modifierMasks: [UInt16: UInt64] = [
        61: 0x40, 58: 0x20,       // 右 / 左 Option
        54: 0x10, 55: 0x08,       // 右 / 左 Command
        60: 0x04, 56: 0x02,       // 右 / 左 Shift
        62: 0x2000, 59: 0x01,     // 右 / 左 Control
        63: 0x800000,             // Fn
    ]

    static func keyName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            61: "右 Option", 58: "左 Option", 54: "右 Command", 55: "左 Command",
            60: "右 Shift", 56: "左 Shift", 62: "右 Control", 59: "左 Control", 63: "Fn",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 49: "空格", 50: "`", 53: "Esc", 36: "回车", 48: "Tab",
        ]
        if let n = names[code] { return n }
        // 其它键按当前键盘布局取字符
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) {
            var len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
            let s = String(utf16CodeUnits: chars, count: len).uppercased()
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return "键 \(code)"
    }

    /// 返回 true 表示吞掉这个事件
    private func handleKey(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        if capturing { return captureKey(type, code, flags) }

        if let mask = Self.modifierMasks[s.hotkeyCode] {
            if type == .flagsChanged, code == s.hotkeyCode {
                let down = flags & mask != 0
                Log.w(down ? "热键按下" : "热键松开")
                if down { hotkeyDown() } else { hotkeyUp() }
            } else if type == .keyDown, phase == .holding || phase == .recording {
                // 按住热键时又按了别的键 = 在用快捷键，不是在说话
                cancelRecording("组合键")
            }
            return false
        }

        // 普通键当热键：只认不带修饰键的单按，按住期间的自动重复也吞掉
        guard code == s.hotkeyCode, type == .keyDown || type == .keyUp else { return false }
        let mods: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
        if type == .keyDown {
            if hotkeyHeld { return true }
            guard flags & mods == 0 else { return false }
            hotkeyHeld = true
            Log.w("热键按下")
            hotkeyDown()
            return true
        }
        guard hotkeyHeld else { return false }
        hotkeyHeld = false
        Log.w("热键松开")
        hotkeyUp()
        return true
    }

    @objc private func startCapture() {
        guard monitorsInstalled else {
            hud.show("先打开辅助功能权限", for: 1.5)
            return
        }
        capturing = true
        hud.show("按下想用的快捷键（Esc 取消）")
    }

    private func captureKey(_ type: CGEventType, _ code: UInt16, _ flags: UInt64) -> Bool {
        switch type {
        case .flagsChanged:
            // 修饰键在按下那一刻记下
            guard let mask = Self.modifierMasks[code], flags & mask != 0 else { return false }
        case .keyDown:
            if code == 53 {
                capturing = false
                hud.show("没改", for: 1)
                return true
            }
        default:
            return capturing
        }
        capturing = false
        s.hotkeyCode = code
        s.save()
        Log.w("快捷键改成 \(Self.keyName(code))（keyCode=\(code)）")
        hud.show("快捷键：按住 \(Self.keyName(code)) 说话", for: 2)
        refreshStatus()
        return type == .keyDown
    }

    private func hotkeyDown() {
        guard phase == .idle else { return }
        guard client.connected else {
            hud.show("没连上 ITX", for: 1.5)
            return
        }
        taskId = UUID().uuidString
        startTime = Date().timeIntervalSince1970
        pending = []
        sentSamples = 0
        do {
            try recorder.start()
        } catch {
            hud.show("麦克风打不开", for: 1.5)
            Log.w("录音失败 \(error.localizedDescription)")
            return
        }
        phase = .holding
        let id = taskId
        DispatchQueue.main.asyncAfter(deadline: .now() + s.holdThreshold) { [weak self] in
            guard let self, self.taskId == id, self.phase == .holding else { return }
            self.phase = .recording
            self.flush()
            self.hud.show("🎙 正在听…")
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
            let id = taskId
            DispatchQueue.main.asyncAfter(deadline: .now() + s.tailSeconds) { [weak self] in
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
        flush()
        send(data: "", final: true)
        releasedAt[id] = Date()
        phase = .idle
        Log.w("送出 \(id.prefix(8)) 时长 \(String(format: "%.1f", Double(sentSamples) / 16000))s")
        if sentSamples < 16000 / 5 {
            discard.insert(id)
            hud.hide()
        } else {
            hud.show("识别中…")
        }
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.releasedAt.removeValue(forKey: id) != nil, !self.discard.contains(id) else { return }
            self.hud.show("识别超时", for: 1.5)
            self.refreshStatus()
        }
    }

    private func cancelRecording(_ why: String) {
        Log.w("取消录音：\(why)")
        recorder.stop()
        if phase == .recording { discard.insert(taskId); send(data: "", final: true) }
        phase = .idle
        hud.hide()
        refreshStatus()
    }

    private func handleSamples(_ samples: [Float]) {
        guard phase != .idle else { return }
        pending += samples
        if phase != .holding, pending.count >= 1600 { flush() }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let b64 = pending.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        sentSamples += pending.count
        pending = []
        send(data: b64, final: false)
    }

    private func send(data: String, final: Bool) {
        client.send([
            "task_id": taskId, "source": "mic", "data": data, "is_final": final,
            "time_start": startTime, "seg_duration": 60.0, "seg_overlap": 4.0,
            "context": Settings.hotwords(), "language": s.language,
        ])
    }

    private func handleResult(_ id: String, _ final: Bool, _ raw: String) {
        guard final else { return }
        let started = releasedAt.removeValue(forKey: id)
        if discard.remove(id) != nil { return }
        let ms = started.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.stripShortTrailingPeriod, text.count <= 12, let last = text.last, "。.".contains(last) {
            text.removeLast()
        }
        Log.w("结果 \(id.prefix(8)) 松开后 \(ms)ms：\(text)")
        if testFile != nil {
            print("RESULT \(ms)ms \(text)")
            NSApp.terminate(nil)
            return
        }
        guard !text.isEmpty else {
            hud.show("没听清", for: 1.2)
            return
        }
        hud.hide()
        Paster.paste(text, restore: s.restoreClipboard)
        lastMenuItem.title = "最近：" + (text.count > 30 ? String(text.prefix(30)) + "…" : text)
        refreshStatus()
    }

    // 不用麦克风，把音频文件按实时节奏走一遍同样的发送路径
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
            guard client.connected else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go() }
                return
            }
            taskId = UUID().uuidString
            startTime = Date().timeIntervalSince1970
            phase = .recording
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
                guard let self else { return }
                let end = min(i + 1600, all.count)
                self.handleSamples(Array(all[i..<end]))
                i = end
                if i >= all.count { t.invalidate(); self.finishTask(self.taskId) }
            }
        }
        go()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("超时"); exit(2) }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        stateMenuItem.isEnabled = false
        lastMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(lastMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "更换快捷键…", action: #selector(startCapture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "编辑热词…", action: #selector(openHotwords), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开设置文件…", action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开日志", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新连接", action: #selector(reconnect), keyEquivalent: "").target = self
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ITX 语音输入", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        refreshStatus()
    }

    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        let (symbol, tint, title): (String, NSColor?, String) = {
            if !monitorsInstalled { return ("mic.badge.xmark", nil, "需要在「系统设置 › 隐私与安全性 › 辅助功能」里打开 ITX 语音输入") }
            if !client.connected { return ("mic.slash", nil, "没连上 ITX，正在重试…") }
            switch phase {
            case .recording, .finishing: return ("mic.fill", .systemRed, "正在听…")
            default: return releasedAt.isEmpty ? ("mic", nil, "已连上 ITX · 按住 \(Self.keyName(s.hotkeyCode)) 说话") : ("waveform", nil, "识别中…")
            }
        }()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ITX 语音输入")
        button.image?.isTemplate = tint == nil
        button.contentTintColor = tint
        stateMenuItem.title = title
        loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLoginItem() {
        Self.setLoginItem(SMAppService.mainApp.status != .enabled)
        refreshStatus()
    }

    static func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.w("登录项设置失败 \(error.localizedDescription)")
        }
        Log.w("登录项状态 \(SMAppService.mainApp.status.rawValue)")
    }

    @objc private func openHotwords() { NSWorkspace.shared.open(Settings.hotwordsURL) }
    @objc private func openConfig() { NSWorkspace.shared.open(Settings.configURL) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func reconnect() { client.connect() }
}

if CommandLine.arguments.contains("--enable-login-item") {
    AppController.setLoginItem(true)
    exit(SMAppService.mainApp.status == .enabled ? 0 : 1)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(CommandLine.arguments.contains("--test-file") ? .prohibited : .accessory)
app.run()
