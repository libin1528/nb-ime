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
    var hotkeyCode2: UInt16?         // 第二个快捷键，可以不设；老配置里没有这一项
    var holdThreshold = 0.3          // 按住不到这么久算误触，不录
    var tailSeconds = 0.25           // 松开后多录一小段，免得吞掉最后一个字
    var language = "auto"
    var restoreClipboard = true
    var stripShortTrailingPeriod = true
    var commaBetween = true   // 接着上一句说时，上一句末尾没标点就在这一句开头补逗号
    var hudPosition = "bottom"       // bottom 屏幕底部 / caret 跟着光标
    var sounds = false               // 开始和结束时的提示音
    var streamPreview = true         // 说话时实时显示文字
    var polishClean = Polish.Level.mid    // 识别后去掉口误：重复、改口、语气词
    var polishFormat = Polish.Level.mid   // 识别后整理格式：标点、分段、列表
    var polishPort = 6017            // ITX 上润色模型（llama-server）的端口
    var polishLocalPort = 16017      // 隧道在本机的端口
    var onboarded = false            // 首次引导走完了
    var micUID = ""                  // 录音用的麦克风（CoreAudio 设备 UID）；空 = 跟着系统默认
    var micName = ""                 // 它的名字，拔掉以后设置里还能显示
    var trackEdits = true            // 输入后记下我把这段字改成了什么（只存本机，见 Edits.swift）

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
        if let v = j["hotkeyCode2"] as? Int, UInt16(v) != s.hotkeyCode { s.hotkeyCode2 = UInt16(v) }
        if let v = j["holdThreshold"] as? Double { s.holdThreshold = v }
        if let v = j["tailSeconds"] as? Double { s.tailSeconds = v }
        if let v = j["language"] as? String { s.language = v }
        if let v = j["restoreClipboard"] as? Bool { s.restoreClipboard = v }
        if let v = j["stripShortTrailingPeriod"] as? Bool { s.stripShortTrailingPeriod = v }
        if let v = j["commaBetween"] as? Bool { s.commaBetween = v }
        if let v = j["hudPosition"] as? String { s.hudPosition = v }
        if let v = j["sounds"] as? Bool { s.sounds = v }
        if let v = j["streamPreview"] as? Bool { s.streamPreview = v }
        if let v = j["polishClean"] as? String, let l = Polish.Level(rawValue: v) { s.polishClean = l }
        if let v = j["polishFormat"] as? String, let l = Polish.Level(rawValue: v) { s.polishFormat = l }
        if let v = j["polishPort"] as? Int { s.polishPort = v }
        if let v = j["polishLocalPort"] as? Int { s.polishLocalPort = v }
        if let v = j["onboarded"] as? Bool { s.onboarded = v }
        if let v = j["micUID"] as? String { s.micUID = v }
        if let v = j["micName"] as? String { s.micName = v }
        if let v = j["trackEdits"] as? Bool { s.trackEdits = v }
        return s
    }

    func save() {
        var j: [String: Any] = [
            "tunnelHost": tunnelHost, "serverHost": serverHost, "serverPort": serverPort,
            "localPort": localPort, "hotkeyCode": Int(hotkeyCode), "holdThreshold": holdThreshold,
            "tailSeconds": tailSeconds, "language": language, "restoreClipboard": restoreClipboard,
            "stripShortTrailingPeriod": stripShortTrailingPeriod, "commaBetween": commaBetween, "hudPosition": hudPosition,
            "sounds": sounds, "streamPreview": streamPreview, "onboarded": onboarded,
            "polishClean": polishClean.rawValue, "polishFormat": polishFormat.rawValue,
            "polishPort": polishPort, "polishLocalPort": polishLocalPort,
            "micUID": micUID, "micName": micName, "trackEdits": trackEdits,
        ]
        if let hotkeyCode2 { j["hotkeyCode2"] = Int(hotkeyCode2) }
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: Settings.configURL)
        }
    }

    /// 两个快捷键都能按住说话；没设第二个时只有一个
    var hotkeyCodes: [UInt16] { [hotkeyCode] + (hotkeyCode2.map { [$0] } ?? []) }

    var url: URL {
        tunnelHost.isEmpty
            ? URL(string: "ws://\(serverHost):\(serverPort)")!
            : URL(string: "ws://127.0.0.1:\(localPort)")!
    }

    /// 连接相关的几项，变了才需要重连
    var connectionKey: String { "\(tunnelHost)|\(serverHost)|\(serverPort)|\(localPort)|\(polishPort)|\(polishLocalPort)" }

    // MARK: 热词

    private static var cachedLines: [String]?

    /// 热词文件里的每一行（去掉空行和 # 开头的注释），热词页原样编辑的就是这些
    static func hotwordLines() -> [String] {
        if let cachedLines { return cachedLines }
        let text = (try? String(contentsOf: hotwordsURL, encoding: .utf8)) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        cachedLines = lines
        return lines
    }

    /// 交给模型、读音纠正、润色用的热词：普通的行，加上替换规则等号右边的词
    static func hotwordList() -> [String] {
        var seen = Set<String>()
        return hotwordLines().compactMap { ReplaceRule.isRule($0) ? ReplaceRule.parse($0)?.to : $0 }.filter { seen.insert($0).inserted }
    }

    /// 「错的=对的」这样的行
    static func replaceRules() -> [ReplaceRule] { hotwordLines().compactMap(ReplaceRule.parse) }

    /// 文件可能被手改过，打开设置时重读一次
    static func reloadHotwords() { cachedLines = nil }

    static func saveHotwords(_ lines: [String]) {
        let text = "# 一行一个词，识别时作为上下文提示给模型；「错的=对的」是一定替换的规则，几种错法用顿号隔开\n"
            + lines.map { $0 + "\n" }.joined()
        try? text.write(to: hotwordsURL, atomically: true, encoding: .utf8)
        cachedLines = lines
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

    /// 结果里有一串只隔着标点的热词：连着五个及以上，或者三个及以上里有同一个词出现两次，返回这一串，否则 nil。
    /// 念一串名字、头一个正好是热词时，模型会顺着热词表往下背（顺序不定、常带重复，长的能背上百个），盖掉后面真说的话。
    static func hotwordRun(_ text: String, _ words: [String]) -> [String]? {
        let canon = Dictionary(words.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var run: [String] = []
        for token in text.split(whereSeparator: { "，,、。.；;！!？? \n".contains($0) }).map(String.init) + [""] {
            if let w = canon[token.lowercased()] { run.append(w); continue }
            if run.count >= 5 || (run.count >= 3 && Set(run).count < run.count) { return run }
            run = []
        }
        return nil
    }

    /// 结果里夹着一段热词表：从第一个热词起、按送给模型的顺序连着四个及以上（热词不到四个就要全部），
    /// 后面还跟着别的话。去掉这一段返回剩下的；整句都是热词的不管，交给 echoedHotwords 复核。
    /// 人声开头前有一小段静音时，模型偶尔把提示原样抄在真话前面，就是这个样子。
    static func strippedEcho(_ text: String, _ words: [String]) -> (text: String, echo: [String])? {
        let need = min(4, words.count)
        guard need >= 2 else { return nil }
        let order = Dictionary(words.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let seps = "，,、。.；;！!？? \n"
        var tokens: [(range: Range<String.Index>, at: Int?)] = []
        var i = text.startIndex
        while i < text.endIndex {
            if seps.contains(text[i]) { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !seps.contains(text[j]) { j = text.index(after: j) }
            tokens.append((i..<j, order[text[i..<j].lowercased()]))
            i = j
        }
        for s in tokens.indices where tokens[s].at == 0 {
            var e = s + 1
            while e < tokens.count, let a = tokens[e - 1].at, tokens[e].at == a + 1 { e += 1 }
            guard e - s >= need, e - s < tokens.count else { continue }
            // 去到下一个词开头，抄的那段后面的标点一起去掉；在句末就从上一个词结尾去起
            let cut = e < tokens.count ? tokens[s].range.lowerBound..<tokens[e].range.lowerBound
                                       : tokens[s - 1].range.upperBound..<text.endIndex
            var rest = text
            rest.removeSubrange(cut)
            return (rest.trimmingCharacters(in: .whitespacesAndNewlines), tokens[s..<e].map { words[$0.at!] })
        }
        return nil
    }
}
