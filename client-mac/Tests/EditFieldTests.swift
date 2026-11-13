// 本机纯逻辑测试，不启动输入法、不读取使用数据、不连接识别服务。
// swiftc Sources/EditField.swift Tests/EditFieldTests.swift -o /tmp/nbime-edit-field-tests
import Foundation

@main enum EditFieldTests {
    static var passed = 0
    static var failed = 0
    static func check(_ ok: @autoclosure () -> Bool, _ name: String) {
        if ok() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static func main() {
        let zero = NSRange(location: 0, length: 0)
        let labels = ["发送消息", "随心输入", "和 Codex 一起工作", "Work with Codex"]
        for label in labels {
            let empty = EditField(value: label + "\n", selection: zero)
            check(empty.segment(head: "", tail: "", app: "ChatGPT", latest: "测试正文") == nil, "发送后空态：\(label)")
            check(!empty.isEmpty(app: "ChatGPT", latest: label), "实际说出同名正文：\(label)")
            check(!empty.isEmpty(app: "Other", latest: "测试正文"), "其他应用不套固定提示：\(label)")
            let typed = EditField(value: label, selection: NSRange(location: label.utf16.count, length: 0))
            check(!typed.isEmpty(app: "ChatGPT", latest: "测试正文"), "手动改成同名正文：\(label)")
            let movedCaret = EditField(value: label, characterCount: label.utf16.count, selection: zero)
            check(!movedCaret.isEmpty(app: "ChatGPT", latest: "测试正文"), "正文光标移到开头：\(label)")
        }
        check(EditField(value: "\n ").isEmpty(app: "Other", latest: "正文"), "发送后只剩空白")
        check(EditField(value: "新的提示", characterCount: 0, selection: zero).isEmpty(app: "Other", latest: "正文"), "字数确认空态，不依赖固定提示")
        check(EditField(value: "任意提示\n", placeholder: "任意提示", selection: zero).isEmpty(app: "Other", latest: "正文"), "系统占位属性确认空态")
        check(!EditField(value: "发送消息").isEmpty(app: "ChatGPT", latest: "正文"), "缺少光标信息保留")
        check(!EditField(value: "发送消息", selection: NSRange(location: 0, length: 4)).isEmpty(app: "ChatGPT", latest: "正文"), "选中文字保留")
        check(!EditField(value: "发送消息", placeholder: "其他提示", selection: zero).isEmpty(app: "ChatGPT", latest: "正文"), "占位属性不吻合不套后备词表")
        check(!EditField(value: "请点击发送消息", selection: zero).isEmpty(app: "ChatGPT", latest: "正文"), "句中含提示词保留")
        check(!EditField(value: "普通正文", selection: zero).isEmpty(app: "ChatGPT", latest: "之前正文"), "普通正文保留")
        let field = EditField(value: "前🙂修改后正文尾")
        check(field.segment(head: "前🙂", tail: "尾", app: "Other", latest: "原文") == "修改后正文", "UTF-16 锚点提取")
        check(field.segment(head: "不存在", tail: "尾", app: "Other", latest: "原文") == nil, "头锚点消失")
        check(field.segment(head: "前🙂", tail: "不存在", app: "Other", latest: "原文") == nil, "尾锚点消失")
        check(field.segment(head: "", tail: "", app: "Other", latest: "原文") == field.value, "无锚点保留整个正文")
        // 与 poll 相同：观察到 nil 即结束，发送前的修订仍是最终正文。
        var latest = "原文"
        for snapshot in [EditField(value: "修订后的正文"), EditField(value: "发送消息\n", selection: zero)] {
            guard let text = snapshot.segment(head: "", tail: "", app: "ChatGPT", latest: latest) else { break }
            latest = text
        }
        check(latest == "修订后的正文", "发送结束保留最后修订")
        print("EditField: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
