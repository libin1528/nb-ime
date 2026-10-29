// 改字记录：语音输入粘贴以后，盯着那个输入框看你把这段字改成了什么，只记在本机，给以后的主动优化攒数据（评测集、热词建议、调润色）。
// 做法：粘贴后用辅助功能接口读输入框的全文，记下这段字前后各 16 个字当锚点；之后每秒读一次，两个锚点中间的就是它现在的样子。
// 焦点离开这个输入框、又按下快捷键、锚点找不到了（比如聊天框发出去被清空）、或者过了 2 分钟，就停，按最后一次读到的记。
// 密码框不读；读不到全文的应用（不少 Electron、网页编辑器、终端）跳过，每个应用在日志里提一次。
// 记录在数据文件夹的 edits/edits.jsonl，一行一条；改过的那几条把录音另存一份到 edits/，不跟着「最近 20 段」被删。

import Cocoa

final class EditWatcher {
    struct Inserted {
        let recognized: String    // 识别结果（热词换好、润色之前）
        let typed: String         // 实际粘进去的
        let app: String
        let audio: String?
        let seconds: Double
    }

    private struct Watch {
        let info: Inserted
        let element: AXUIElement
        let head: String          // 这段字前面的锚点
        let tail: String          // 后面的锚点
        let started: Date
        var latest: String        // 最后一次找到的样子
    }

    static let anchor = 16, maxSeconds = 120.0
    private var watch: Watch?
    private var timer: Timer?
    private var unreadable = Set<String>()   // 读不到的应用，日志里只提一次

    /// 刚粘贴完：等目标应用把字放进去，再开始盯
    func start(_ info: Inserted) {
        finish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.begin(info) }
    }

    private func begin(_ info: Inserted, retried: Bool = false) {
        guard let el = Self.focused(), !Self.isSecure(el) else { return }
        guard let value = Self.value(el) else {
            // Electron 应用（Claude、Slack……）默认不开辅助功能树，读不到输入框；请它打开一次再读
            if !retried, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.begin(info, retried: true) }
                return
            }
            if unreadable.insert(info.app).inserted { Log.w("改字记录：\(info.app) 读不到输入框的文字（焦点在 \(Self.role(el))），跳过") }
            return
        }
        let v = value as NSString, t = info.typed as NSString
        // 光标在刚粘进去的字后面；对不上就从后往前找这段字
        var r = NSRange(location: NSNotFound, length: 0)
        if let caret = Self.caret(el), caret >= t.length, v.substring(with: NSRange(location: caret - t.length, length: t.length)) == info.typed {
            r = NSRange(location: caret - t.length, length: t.length)
        } else {
            r = v.range(of: info.typed, options: .backwards)
        }
        guard r.location != NSNotFound else {
            if unreadable.insert(info.app).inserted { Log.w("改字记录：\(info.app) 的输入框里找不到刚输入的字，跳过") }
            return
        }
        let headStart = max(0, r.location - Self.anchor)
        let head = v.substring(with: NSRange(location: headStart, length: r.location - headStart))
        let tail = v.substring(with: NSRange(location: NSMaxRange(r), length: min(Self.anchor, v.length - NSMaxRange(r))))
        watch = Watch(info: info, element: el, head: head, tail: tail, started: Date(), latest: info.typed)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard var w = watch else { return }
        // 焦点换了地方、超时、或者这段字找不到了，就按最后一次的记
        guard let el = Self.focused(), CFEqual(el, w.element), Date().timeIntervalSince(w.started) < Self.maxSeconds,
              let now = Self.value(el).flatMap({ Self.segment($0, head: w.head, tail: w.tail) }) else {
            finish()
            return
        }
        w.latest = now
        watch = w
    }

    /// 两个锚点之间的字；锚点找不到、或者整个输入框空了（发出去了）返回 nil
    private static func segment(_ value: String, head: String, tail: String) -> String? {
        let v = value as NSString
        guard v.length > 0 else { return nil }
        var start = 0
        if !head.isEmpty {
            let r = v.range(of: head)
            guard r.location != NSNotFound else { return nil }
            start = NSMaxRange(r)
        }
        var end = v.length
        if !tail.isEmpty {
            let r = v.range(of: tail, options: [], range: NSRange(location: start, length: v.length - start))
            guard r.location != NSNotFound else { return nil }
            end = r.location
        }
        return v.substring(with: NSRange(location: start, length: end - start))
    }

    /// 停下来，记一条
    func finish() {
        timer?.invalidate()
        timer = nil
        guard let w = watch else { return }
        watch = nil
        EditLog.add(w.info, final: w.latest)
    }

    // MARK: 辅助功能接口

    private static func focused() -> AXUIElement? {
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let f, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.3)   // 目标应用卡住时别把我们也拖住
        return el
    }

    private static func role(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        return r as? String ?? "?"
    }

    private static func isSecure(_ el: AXUIElement) -> Bool {
        var sub: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub)
        return sub as? String == kAXSecureTextFieldSubrole
    }

    private static func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// 光标位置（UTF-16 下标）
    private static func caret(_ el: AXUIElement) -> Int? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success,
              let r, CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(r as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }
}

// MARK: - 存

enum EditLog {
    static var dir: URL { Settings.dir.appendingPathComponent("edits") }
    static var url: URL { dir.appendingPathComponent("edits.jsonl") }
    static let keepAudio = 300                 // 改过的录音最多另存这么多段
    static var dryRun = false                  // --edit-test 时只写日志，不进记录
    private static let queue = DispatchQueue(label: "nbime.edits")

    static func add(_ i: EditWatcher.Inserted, final: String) {
        let changed = final != i.typed
        let row: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()), "app": i.app, "audio": i.audio ?? "",
            "seconds": i.seconds, "recognized": i.recognized, "typed": i.typed,
            "final": String(final.prefix(2000)), "changed": changed,
        ]
        Log.w("改字记录 \(i.app)：" + (changed ? "「\(i.typed)」→「\(final.prefix(200))」" : "没改"))
        if dryRun { return }
        if changed, let audio = i.audio { History.markEdited(audio: audio, final: final) }
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
            line.append(0x0a)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                try? line.write(to: url)
            }
            // 改过的录音另存，评测要用；只留最近 300 段
            guard changed, let audio = i.audio else { return }
            try? fm.copyItem(at: Recordings.url(audio), to: dir.appendingPathComponent(audio))
            let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
            for old in all.dropLast(keepAudio) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        }
    }
}
