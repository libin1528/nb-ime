// 设置与本地数据：config.json、hotwords.txt 的格式不变，设置窗口读写它们。

import Foundation

extension Notification.Name {
    static let settingsChanged = Notification.Name("NBSettingsChanged")
    static let hotwordsChanged = Notification.Name("NBHotwordsChanged")
}

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
    var hudPosition = "bottom"       // bottom 屏幕底部 / caret 跟着光标
    var sounds = false               // 开始和结束时的提示音
    var streamPreview = true         // 说话时实时显示文字
    var onboarded = false            // 首次引导走完了

    /// 全局唯一的一份；改了就写回 config.json 并通知界面
    static var current = Settings.load() {
        didSet {
            current.save()
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NBIME")
    /// v0.1（ITX Voice）的数据目录，第一次启动时搬过来
    static let legacyDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ITXVoice")
    static var configURL: URL { dir.appendingPathComponent("config.json") }
    static var hotwordsURL: URL { dir.appendingPathComponent("hotwords.txt") }

    private static func migrate() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacyDir.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["config.json", "hotwords.txt"] {
            try? fm.copyItem(at: legacyDir.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        Log.w("从 \(legacyDir.path) 搬来了设置和热词")
    }

    static func load() -> Settings {
        migrate()
        var s = Settings()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: hotwordsURL.path) {
            saveHotwords(["ClawChat", "Liveware"])
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
        if let v = j["hudPosition"] as? String { s.hudPosition = v }
        if let v = j["sounds"] as? Bool { s.sounds = v }
        if let v = j["streamPreview"] as? Bool { s.streamPreview = v }
        if let v = j["onboarded"] as? Bool { s.onboarded = v }
        return s
    }

    func save() {
        let j: [String: Any] = [
            "tunnelHost": tunnelHost, "serverHost": serverHost, "serverPort": serverPort,
            "localPort": localPort, "hotkeyCode": Int(hotkeyCode), "holdThreshold": holdThreshold,
            "tailSeconds": tailSeconds, "language": language, "restoreClipboard": restoreClipboard,
            "stripShortTrailingPeriod": stripShortTrailingPeriod, "hudPosition": hudPosition,
            "sounds": sounds, "streamPreview": streamPreview, "onboarded": onboarded,
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

    /// 连接相关的几项，变了才需要重连
    var connectionKey: String { "\(tunnelHost)|\(serverHost)|\(serverPort)|\(localPort)" }

    // MARK: 热词

    private static var cachedHotwords: [String]?

    static func hotwordList() -> [String] {
        if let cachedHotwords { return cachedHotwords }
        let text = (try? String(contentsOf: hotwordsURL, encoding: .utf8)) ?? ""
        let words = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        cachedHotwords = words
        return words
    }

    /// 文件可能被手改过，打开设置时重读一次
    static func reloadHotwords() { cachedHotwords = nil }

    static func saveHotwords(_ words: [String]) {
        let text = "# 一行一个词，识别时作为上下文提示给模型\n" + words.map { $0 + "\n" }.joined()
        try? text.write(to: hotwordsURL, atomically: true, encoding: .utf8)
        cachedHotwords = words
        NotificationCenter.default.post(name: .hotwordsChanged, object: nil)
    }

    /// 结果整句都由热词拼成（两个及以上）时返回这些词，否则 nil。
    /// 录音里人声太弱时，模型会把热词提示原样抄出来，就是这个样子。
    static func echoedHotwords(_ text: String, _ words: [String]) -> [String]? {
        let canon = Dictionary(words.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let tokens = text.split { "，,、。.；;！!？? \n".contains($0) }.map { $0.lowercased() }
        guard tokens.count >= 2 else { return nil }
        let hits = tokens.compactMap { canon[$0] }
        return hits.count == tokens.count ? hits : nil
    }
}
