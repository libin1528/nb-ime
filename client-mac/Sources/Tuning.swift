// 和 Agent 一起调优：菜单里点一下，复制一段提示词，粘给自己的 agent（Claude Code、Codex……）。
// agent 照 docs/tune-with-agent.md 读本机的日志和改字记录，找反复出现的错，先给用户看、用户同意了再改热词或代码，
// 每次调完在 tuning.md 末尾记一节（「## 2026-11-01」开头）。菜单里那行「又攒了几处改字」就是从上一节的日期往后数的。

import Foundation

enum Tuning {
    static var recordURL: URL { Settings.dir.appendingPathComponent("tuning.md") }
    static let repo = "https://github.com/libin1528/nb-ime"

    /// 源码目录：build.sh 编译时写进 Info.plist；没有（别人下的包）就是 nil，让 agent 去 clone
    static var sourceDir: String? {
        guard let d = Bundle.main.object(forInfoDictionaryKey: "NBSourceDir") as? String,
              FileManager.default.fileExists(atPath: d + "/docs/tune-with-agent.md") else { return nil }
        return d
    }

    /// tuning.md 里最后一节的日期
    static func lastTuned() -> Date? {
        guard let text = try? String(contentsOf: recordURL, encoding: .utf8) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return text.split(separator: "\n").reversed().lazy
            .filter { $0.hasPrefix("## ") }
            .compactMap { f.date(from: String($0.dropFirst(3).prefix(10))) }
            .first
    }

    /// 上次调优以后：输入了几次、改过几次（没调过就从头数）
    static func since(_ date: Date?) -> (inputs: Int, edited: Int) {
        guard let text = try? String(contentsOf: EditLog.url, encoding: .utf8) else { return (0, 0) }
        let iso = ISO8601DateFormatter()
        var inputs = 0, edited = 0
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let date, let t = (row["time"] as? String).flatMap(iso.date), t < date { continue }
            inputs += 1
            if row["changed"] as? Bool == true { edited += 1 }
        }
        return (inputs, edited)
    }

    static func prompt() -> String {
        let data = Settings.dir.path
        let last = lastTuned()
        let n = since(last)
        let when: String = {
            guard let last else { return "还没调过，从头看。" }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return "上次调优是 \(f.string(from: last))，之后输入了 \(n.inputs) 次，其中 \(n.edited) 次我又手动改过。"
        }()
        let src = sourceDir.map { "源码在本机 \($0)" } ?? "源码：\(repo)，clone 到本地"
        let guide = sourceDir.map { "\($0)/docs/tune-with-agent.md" } ?? "仓库里的 docs/tune-with-agent.md"
        return """
        帮我调优 NB 输入法（我每天在用的按住说话语音输入法）：看看最近它哪里老出错，从热词或代码上改好。照 \(guide) 做，改之前先给我看。
        \(src)。
        我的使用数据都在本机，只在本机读，别贴到网上：
        - 日志：\(NSHomeDirectory())/Library/Logs/NBIME.log
        - 改字记录（我输入后又改成了什么，最有用）：\(EditLog.url.path)
        - 热词和一定替换：\(Settings.hotwordsURL.path)
        - 设置：\(data)/config.json
        - 录音：最近 20 段在 \(data)/recordings，改过字的在 \(EditLog.dir.path)
        - 调优记录：\(recordURL.path)
        \(when)
        """
    }
}
