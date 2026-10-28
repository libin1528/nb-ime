// 识别历史：本地存最近 200 条（文字、时间、时长、当时的前台应用）。

import Foundation

extension Notification.Name {
    static let historyChanged = Notification.Name("NBHistoryChanged")
}

struct HistoryEntry {
    var text: String
    var date: Date
    var seconds: Double
    var app: String
}

enum History {
    static let limit = 200
    static var url: URL { Settings.dir.appendingPathComponent("history.json") }
    private(set) static var items: [HistoryEntry] = load()   // 新的在前

    private static func load() -> [HistoryEntry] {
        if !FileManager.default.fileExists(atPath: url.path) {
            let old = importLegacyLog()
            if !old.isEmpty { write(old) }
            return old
        }
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { j in
            guard let text = j["text"] as? String, let t = j["time"] as? Double else { return nil }
            return HistoryEntry(text: text, date: Date(timeIntervalSince1970: t),
                                seconds: j["seconds"] as? Double ?? 0, app: j["app"] as? String ?? "")
        }
    }

    /// v0.1 没有存历史，只在日志里记了识别结果；第一次启动时从旧日志里捞回来
    private static func importLegacyLog() -> [HistoryEntry] {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ITXVoice.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let year = Calendar.current.component(.year, from: Date())
        var secs: [String: Double] = [:]
        var out: [HistoryEntry] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4).map(String.init)
            guard parts.count == 5 else { continue }
            if parts[2] == "送出", parts[4].hasPrefix("时长 ") {
                secs[parts[3]] = Double(parts[4].dropFirst(3).prefix { $0 != "s" })
            } else if parts[2] == "结果", let i = parts[4].firstIndex(of: "："), parts[4].hasPrefix("松开后") {
                let t = String(parts[4][parts[4].index(after: i)...]).trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, var d = f.date(from: "\(year)-\(parts[0]) \(parts[1])") else { continue }
                if d > Date() { d = Calendar.current.date(byAdding: .year, value: -1, to: d) ?? d }
                out.append(HistoryEntry(text: t, date: d, seconds: secs[parts[3]] ?? 0, app: ""))
            }
        }
        Log.w("从旧日志里找回 \(out.count) 条识别记录")
        return Array(out.reversed().prefix(limit))
    }

    private static func save() {
        write(items)
        NotificationCenter.default.post(name: .historyChanged, object: nil)
    }

    private static func write(_ items: [HistoryEntry]) {
        let arr: [[String: Any]] = items.map {
            ["text": $0.text, "time": $0.date.timeIntervalSince1970, "seconds": $0.seconds, "app": $0.app]
        }
        if let d = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
            try? d.write(to: url, options: .atomic)
        }
    }

    static func add(_ e: HistoryEntry) {
        items.insert(e, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
    }

    static func clear() {
        items = []
        save()
    }

    /// 「今天 15:13」「昨天 09:02」「10月21日 18:40」
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if cal.isDateInToday(d) { return "今天 " + f.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天 " + f.string(from: d) }
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}
