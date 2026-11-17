// 只收掉指示词在「个」前的紧邻结巴，不跨标点，不删量词或后面的正文。
import Foundation

enum DeterminerRestart {
    struct Result {
        let text: String
        let kept: [String]
    }

    private static let pattern = try! NSRegularExpression(pattern: "([这那])\\1+个")

    static func apply(_ text: String, hotwords: [String] = []) -> Result {
        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        let hotRanges = hotwords.filter { !$0.isEmpty }.flatMap { word -> [NSRange] in
            var ranges: [NSRange] = [], start = 0
            while start < source.length {
                let r = source.range(of: word, options: .caseInsensitive, range: NSRange(location: start, length: source.length - start))
                if r.location == NSNotFound { break }
                ranges.append(r)
                start = NSMaxRange(r)
            }
            return ranges
        }
        var result = text, kept: [String] = []
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text), !isQuoted(text, at: range.lowerBound) else { continue }
            if hotRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            let before = text[..<range.lowerBound], after = text[range.upperBound...]
            func technical(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || "_./\\-".contains(c)) }
            if before.last.map(technical) == true || after.first.map(technical) == true { continue }
            let clause = before.split(whereSeparator: { "。！？!?；;\n".contains($0) }).last.map(String.init) ?? ""
            if ["原文", "原话", "字符串", "字面", "正则", "示例", "举例", "比如", "例如", "删成", "替换"].contains(where: clause.contains)
                || ["这个词", "这几个字", "的写法", "删成", "替换成"].contains(where: after.hasPrefix) { continue }
            let word = source.substring(with: match.range(at: 1)) + "个"
            result.replaceSubrange(range, with: word)
            kept.insert(word, at: 0)
        }
        return Result(text: result, kept: kept)
    }

    private static func isQuoted(_ text: String, at end: String.Index) -> Bool {
        var stack: [Character] = []
        let pairs: [Character: Character] = ["“": "”", "‘": "’", "「": "」", "『": "』", "\"": "\"", "'": "'", "`": "`"]
        for c in text[..<end] {
            if c == stack.last { stack.removeLast() }
            else if let close = pairs[c] { stack.append(close) }
        }
        return !stack.isEmpty
    }
}
