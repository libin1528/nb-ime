// 一定替换的规则：热词里写「日色=润色」「Clochat、Claw Chat=ClawChat」，识别结果里的左边一律换成右边。
// 补的是读音纠正（Hotfix）管不到的：读音不一样的错（日色 / 润色）、拆不成拼音的英文词（Clochat / ClawChat）。
// 规矩：左边至少两个字，免得一个字到处误换；英文两头按整词算、不分大小写；长的先匹配；只换一遍，不会 A→B 再 B→C。

import Foundation

struct ReplaceRule {
    let from: [String]
    let to: String

    static let seps = ["=>", "->", "→", "＝", "="]

    /// 写了等号的行都按规则看，哪怕写错了没生效，也不再当普通热词
    static func isRule(_ line: String) -> Bool { seps.contains { line.contains($0) } }

    /// 一行里有等号（半角、全角，也认 -> → =>）就是规则；左边几种错法用顿号、斜杠或逗号隔开。左边不到两个字的不生效，返回 nil
    static func parse(_ line: String) -> ReplaceRule? {
        guard let r = seps.compactMap({ line.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let to = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        let from = line[..<r.lowerBound].split(whereSeparator: { "、/／,，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 && $0 != to }
        guard !to.isEmpty, !from.isEmpty else { return nil }
        return ReplaceRule(from: from, to: to)
    }
}

enum Replace {
    /// 按规则替换一遍，返回替换后的文字和换了哪些（日志用）
    static func apply(_ text: String, _ rules: [ReplaceRule]) -> (text: String, hits: [String]) {
        let pairs = rules.flatMap { r in r.from.map { ($0 as NSString, r.to) } }.sorted { $0.0.length > $1.0.length }
        guard !pairs.isEmpty else { return (text, []) }
        let s = text as NSString
        var out = "", hits: [String] = [], i = 0
        while i < s.length {
            if let (from, to) = pairs.first(where: { matches($0.0, in: s, at: i) }) {
                out += to
                hits.append("\(s.substring(with: NSRange(location: i, length: from.length)))→\(to)")
                i += from.length
            } else {
                let r = s.rangeOfComposedCharacterSequence(at: i)
                out += s.substring(with: r)
                i = NSMaxRange(r)
            }
        }
        return (out, hits)
    }

    private static func matches(_ from: NSString, in s: NSString, at i: Int) -> Bool {
        guard i + from.length <= s.length,
              s.compare(from as String, options: .caseInsensitive, range: NSRange(location: i, length: from.length)) == .orderedSame
        else { return false }
        // 英文字母、数字开头或结尾的，旁边不能紧挨着字母数字（Clochat 不会把 Clochats 拆开换）
        func word(_ c: unichar) -> Bool { c < 128 && (isalnum(Int32(c)) != 0) }
        if word(from.character(at: 0)), i > 0, word(s.character(at: i - 1)) { return false }
        let end = i + from.length
        if word(from.character(at: from.length - 1)), end < s.length, word(s.character(at: end)) { return false }
        return true
    }
}
