// swiftc -swift-version 5 $(rg --files Sources -g '*.swift' | rg -v '/main.swift$') Tests/TranscriptTests.swift -o /tmp/nbime-transcript-tests
// 可选参数：本机历史样本 JSON；只读，不连接服务、不修改用户数据。
import Foundation

@main enum TranscriptTests {
    static var passed = 0, failed = 0
    static let words = ["ClawChat", "ClawNest", "Liveware", "小圆", "NewBase", "金波", "Eros", "Wan3", "develop-ui", "session", "joe", "集卡", "Grokbot", "小柚", "Agent", "Claude Code", "hover"]
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        if value() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static func main() throws {
        let echo = words.joined(separator: "，")
        check(HotwordEcho.resolve(echo, words: words, retry: false) == .reread, "带空格和连字符的完整热词表需要重认")
        check(HotwordEcho.runs(echo, words: words).first?.count == words.count, "Claude Code 和 develop-ui 不拆开")
        check(HotwordEcho.resolve("前面真说的话" + echo + "。后面还有话", words: words, retry: false) == .reread, "正文紧贴热词串也重认，不直接删掉可疑部分")
        check(HotwordEcho.resolve("Agent、Liveware、Agent", words: words, retry: false) == .reread, "重复热词串")
        for blank in ["", " \n\t", "。……！"] {
            check(HotwordEcho.resolve(blank, words: words, retry: true) == .reject, "重认空白或只有标点时不恢复原结果")
        }
        check(HotwordEcho.resolve(echo, words: words, retry: true) == .reject, "重认仍抄表时不输出、不循环重认")
        for normal in ["我接入了一个 Cloud Code Agent。", "ClawChat 和 ClawNest 的连接很好。", "ClawChat、ClawNest、Liveware 这三个", "ClawChats、ClawNest、Livewares、NewBases、Agentic", "Agent、Liveware、别的事情、Agent", "第一个是 ClawChat，第二个是 Claude Code。"] {
            check(HotwordEcho.resolve(normal, words: words, retry: false) == .accept(normal), "正常提词不触发重认：\(normal)")
            check(HotwordEcho.resolve(normal, words: words, retry: true) == .accept(normal), "无热词重认的正常正文保留：\(normal)")
        }
        check(HotwordEcho.resolve("ClawChat、Claude Code", words: words, retry: true) == .accept("ClawChat、Claude Code"), "重认确认的两个正常名字不吞掉")
        check(HotwordEcho.resolve("正常正文", words: [], retry: false) == .accept("正常正文"), "空热词表")
        check(HotwordEcho.resolve("Agent", words: ["Agent", "agent"], retry: false) == .accept("Agent"), "大小写重复不把一个名字当热词表")

        let positives = [
            ("这个种植园叫可可雨，岛屿的雨。", "这个种植园叫可可屿，岛屿的屿。"),
            ("这个名字叫可可雨，岛屿的屿。", "这个名字叫可可屿，岛屿的屿。"),
            ("名字是李宇，宇宙的雨。", "名字是李宇，宇宙的宇。"),
            ("他名叫李雨，宇宙的雨。", "他名叫李宇，宇宙的宇。"),
        ]
        for (raw, expected) in positives {
            check(Spelling.apply(raw).text == expected, "按句内释字纠正：\(raw)")
            check(Spelling.apply(expected).text == expected, "正确释字再次处理不变")
        }
        let negatives = [
            "我姓章，弓长的章。", "我姓章，文章的章。", "这家店叫可可雨。", "岛屿的雨。",
            "这家店叫可可雨，岛屿的雨很大。", "夏日的雨很好看。", "这个名字叫小雨，下雨的雨。",
            "名字叫小宇，雨语的宇。", "他叫小王，国王的汪。", "叫小林，岛屿的雨。",
            "不要叫可可雨，岛屿的雨。", "这不是叫可可雨，岛屿的雨。", "比如这个名字叫可可雨，岛屿的雨。",
            "保留原文：名字叫可可雨，岛屿的雨。", "他说名字叫可可雨，岛屿的雨。",
            "他说：“名字叫可可雨，岛屿的雨。”", "`名字叫可可雨，岛屿的雨。`", "'名字叫可可雨，岛屿的雨。'",
            "叫小雨，岛屿的雨天。", "账号叫abc，岛屿的雨。", "叫可可雨，岛屿的雨。雨量是20毫米。",
        ]
        // 最后一条只允许改紧邻名字和释字，后句「雨量」保留。
        for raw in negatives.dropLast() {
            check(Spelling.apply(raw).text == raw, "正常、歧义、引述、否定内容不改：\(raw)")
        }
        check(Spelling.apply(negatives.last!).text == "叫可可屿，岛屿的屿。雨量是20毫米。", "不全局替换同音字、数字不变")
        check(Spelling.apply(positives[0].0, hotwords: ["可可雨"]).text == positives[0].0, "既有热词优先，不改热词写法")
        check(Spelling.apply("这家叫可可雨，岛屿的雨。那家叫小雨，宇宙的雨。").text == "这家叫可可屿，岛屿的屿。那家叫小宇，宇宙的宇。", "各次释字只改各自紧邻名字")
        check(Spelling.apply("“这家叫可可雨，岛屿的雨。”另一家叫可可雨，岛屿的雨。").text == "“这家叫可可雨，岛屿的雨。”另一家叫可可屿，岛屿的屿。", "引述结束后恢复正常释字")
        let prepared = Polish.prepare(positives[0].0, clean: .mid, hotwords: words)
        check(prepared.text == positives[0].1, "润色生产入口使用本机释字纠错")
        check(Polish.prepare(positives[0].0, clean: .off, hotwords: words).text == positives[0].0, "去口误关闭时不纠字")
        check(Polish.prepare("我找的这这个种植园叫可可雨，岛屿的雨。", clean: .mid, hotwords: words).text == "我找的这这个种植园叫可可屿，岛屿的屿。", "释字预处理不趁机删除邻近正常字")
        check(Polish.problem(raw: prepared.text, out: prepared.text, clean: .mid, hotwords: words, preserving: prepared.preserved) == nil, "修好的文字通过原有防改字检查")
        check(Polish.problem(raw: prepared.text, out: positives[0].0, clean: .mid, hotwords: words, preserving: prepared.preserved) != nil, "模型改回错字时退回修好的文字")
        check(Polish.problem(raw: prepared.text, out: "这个种植园叫可可屿。", clean: .mid, hotwords: words, preserving: prepared.preserved) != nil, "模型不能删掉释字依据")
        check(Polish.problem(raw: "请明天给小李转20元。", out: "请明天给小王转30元。", clean: .mid, hotwords: []) != nil, "不能借释字功能任意改人名数字")

        if let path = CommandLine.arguments.dropFirst().first {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            var fixed = 0, reread = 0, rejected = 0
            for (i, row) in rows.enumerated() {
                let text = row["text"] as! String
                let kind = row["kind"] as! String
                if kind == "spelling" {
                    let result = Spelling.apply(text, hotwords: words)
                    let expected = row["expected"] as! String
                    check(result.text == expected, "历史释字样本 \(i)")
                    if result.text != text { fixed += 1 }
                } else {
                    let decision = HotwordEcho.resolve(text, words: words, retry: kind == "retry")
                    switch row["expected"] as! String {
                    case "reread": check(decision == .reread, "历史热词串 \(i)"); reread += 1
                    case "reject": check(decision == .reject, "历史重认空白 \(i)"); rejected += 1
                    default: check(decision == .accept(text.trimmingCharacters(in: .whitespacesAndNewlines)), "历史正常正文 \(i)")
                    }
                }
            }
            print("History: \(rows.count) rows; spelling fixed \(fixed), reread \(reread), rejected \(rejected)")
        }
        print("Transcript: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
