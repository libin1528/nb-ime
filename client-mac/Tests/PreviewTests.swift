// swiftc -swift-version 5 Sources/LivePreview.swift Sources/HotwordEcho.swift Sources/PreviewFilter.swift Tests/PreviewTests.swift -o /tmp/nbime-preview-tests
import Foundation

@main enum PreviewTests {
    static var passed = 0, failed = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        if value() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static let words = ["ClawChat", "ClawNest", "Liveware", "小圆", "NewBase", "金波", "Eros", "Wan3", "develop-ui", "session", "joe", "集卡", "Grokbot", "小柚", "Agent", "Claude Code", "hover"]
    static func clean(_ s: String) -> String { PreviewFilter.apply(s, words: words) }
    static func main() {
        let echo = words.joined(separator: "，")
        check(clean("可以做概念上的汇总，比如说" + echo + "。") == "可以做概念上的汇总，比如说。", "真实漏口：热词表紧贴正常句子，不要求前面有分隔符")
        check(clean("另一台设备上的" + echo + "。高德协同。") == "另一台设备上的。高德协同。", "真实漏口：嵌在句中的热词表不带走后面的正常文字")
        check(clean("开始说话。ClawChat，ClawNest，Liveware，小圆。然后继续") == "开始说话。然后继续", "原顺序四个热词的回声仍会过滤")
        check(clean(echo) == "", "整段热词表不显示")
        check(clean("ClawNest，Liveware，小圆，NewBase，金波。继续说话") == "继续说话", "从表中间开始的长串也去掉")
        check(clean("先做这件事。Agent，Liveware，Agent。然后继续") == "先做这件事。然后继续", "含重复的热词串也去掉")
        check(clean("ClawChat，ClawNest") == "", "沿用整段两个热词的预览抑制")
        check(clean("用ClawChat和ClawNest协作") == "用ClawChat和ClawNest协作", "正常句中提到两个热词照常显示")
        check(clean("ClawChat、ClawNest、Liveware 这三个") == "ClawChat、ClawNest、Liveware 这三个", "真实短枚举不隐藏")
        check(clean("ClawChats, ClawNest, Livewares, NewBases, Agentic") == "ClawChats, ClawNest, Livewares, NewBases, Agentic", "英文热词不拆长词")
        check(clean("ClawChat 和 ClawNest 的连接体验很好") == "ClawChat 和 ClawNest 的连接体验很好", "连接词打断枚举，不删除正常语句")
        check(clean("clawchat, CLAWNEST, LIVEWARE, 小圆, NEWBASE.继续") == "继续", "大小写和英文标点")
        check(clean("ClawChat\nClawNest\tLiveware；小圆、NewBase。继续") == "继续", "换行和制表符分隔")
        check(clean(echo + "。说ClawNest。连接体验。") == "说ClawNest。连接体验。", "后续累积预览仍过滤完整回声，保留真正提到的词")
        check(PreviewFilter.apply("ClawChat，ClawNest", words: []) == "ClawChat，ClawNest", "空热词表不改文本")
        check(clean("🙂这是正常预览") == "🙂这是正常预览", "无热词原样保留")
        do {
            var p = LivePreview(); p.update("你好", at: 10)
            check(p.text == "你好" && p.glyphs.count == 2, "只展示服务返回的实际文本")
            check(p.opacity(for: p.glyphs[0], at: 10) == 0 && p.opacity(for: p.glyphs[1], at: 10.3) == 1, "新增字有渐进淡入并及时结束")
            let times = p.glyphs.map(\.appearsAt); p.update("你好世界", at: 12)
            check(Array(p.glyphs.prefix(2).map(\.appearsAt)) == times, "追加文字不重新淡入稳定前文")
            check(p.glyphs[2].appearsAt == 12 && p.glyphs[3].appearsAt > 12, "同批新增字依次出现")
            p.update("你好世界", at: 13)
            check(p.glyphs[2].appearsAt == 12, "重复更新不重播动画")
            p.finish(at: 13)
            check(p.glyphs.allSatisfy { p.opacity(for: $0, at: 13) == 1 }, "松开后立即显示完整预览，不继续等待动画")
        }
        do {
            var p = LivePreview(); p.update("我在测试连接体验", at: 0)
            let suffixTime = p.glyphs.last!.appearsAt
            p.update("我在调试连接体验", at: 2)
            check(p.glyphs[0].appearsAt == 0 && p.glyphs[2].appearsAt == 2, "中间修词只淡入变动位置")
            check(p.glyphs.last!.appearsAt == suffixTime, "中间修词不让相同后缀闪烁")
            p.update("我在测试", at: 3)
            check(p.text == "我在测试" && p.glyphs.count == 4, "识别回撤不保留已经撤销的文字")
        }
        do {
            var p = LivePreview(); let text = "🙂👨‍👩‍👧‍👦e\u{301}中文"
            p.update(text, at: 0)
            check(p.glyphs.count == 5 && p.glyphs.map { (text as NSString).substring(with: $0.range) } == text.map(String.init), "UTF-16 范围不拆 emoji、家庭表情或组合字形")
            p.update(String(repeating: "字", count: 200), at: 2)
            check(p.glyphs.last!.appearsAt <= 2.28001 && p.glyphs.allSatisfy { p.opacity(for: $0, at: 2.5) == 1 }, "超长更新不增加超过半秒的动画延迟")
            p.update("减少动态效果", at: 4, animated: false)
            check(p.glyphs.allSatisfy { p.opacity(for: $0, at: 4) == 1 }, "减少动态效果时立即显示")
            p.update("", at: 5)
            check(p.text.isEmpty && p.glyphs.isEmpty, "下一次录音清除全部呈现状态")
        }
        print("Preview: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
