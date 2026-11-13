import Foundation

/// 同一次观察读到的输入框状态。占位文字可能出现在 AXValue 中，但不是用户正文。
struct EditField {
    let value: String
    var placeholder: String? = nil
    var characterCount: Int? = nil
    var selection: NSRange? = nil

    private static let chatGPTPlaceholders: Set<String> = [
        "发送消息", "随心输入", "和 Codex 一起工作", "Work with Codex",
    ]

    /// 只有正文为空的证据才结束观察；属性缺失或互相矛盾时保留文字。
    func isEmpty(app: String, latest: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        // 真正说出或已观察到的同名正文不当占位；非零字数或选区也说明仍有正文。
        if text == latest.trimmingCharacters(in: .whitespacesAndNewlines) { return false }
        if let characterCount, characterCount > 0 { return false }
        guard selection == NSRange(location: 0, length: 0) else { return false }
        if characterCount == 0 { return true }
        if let placeholder, !placeholder.isEmpty {
            return text == placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // ChatGPT 的部分输入框不提供占位属性，且发送后 AXValue 会返回这些空态提示。
        return app == "ChatGPT" && Self.chatGPTPlaceholders.contains(text)
    }

    /// nil 表示发送、清空或锚点消失；调用方结束观察，保留上一次正文。
    func segment(head: String, tail: String, app: String, latest: String) -> String? {
        guard !isEmpty(app: app, latest: latest) else { return nil }
        let v = value as NSString
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
}
