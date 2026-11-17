// 只用紧邻名字的释字依据纠正同音字，不推测一般语义、不全局替换。
import Foundation

enum Spelling {
    struct Correction {
        let name: String
        let correctedName: String
        let explanation: String
    }
    struct Result {
        let text: String
        let corrections: [Correction]
    }

    // 必须明说名字，且释字后有断句。普通的「岛屿的雨很大」不属于释字。
    private static let pattern = try! NSRegularExpression(pattern:
        "(?:名字(?:叫|是)|名叫|名为|叫|姓)([\\p{Han}]{1,8})[，,：:（(][ \\t]*([\\p{Han}]{2,4})的([\\p{Han}])(?=$|[。！？!?，,；;）)])")

    static func apply(_ text: String, hotwords: [String] = []) -> Result {
        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        var result = text, corrections: [Correction] = []
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text), !isQuoted(text, at: range.lowerBound) else { continue }
            let clause = text[..<range.lowerBound].split(whereSeparator: { "。！？!?；;\n".contains($0) }).last.map(String.init) ?? ""
            // 引述、反例和否定命名保留原文，避免把讨论错字的内容也改掉。
            if ["比如", "例如", "原文", "原话", "识别成", "错写", "他说", "她说", "不要", "不能", "不是", "不", "别"].contains(where: clause.contains) { continue }
            let name = source.substring(with: match.range(at: 1))
            let word = source.substring(with: match.range(at: 2))
            let stated = source.substring(with: match.range(at: 3))
            guard let sound = readings(stated).first, let last = name.last else { continue }
            let chars = Array(word), sounds = readings(word)
            guard chars.count == sounds.count else { continue }
            let candidates = Set(zip(chars, sounds).filter { $0.1 == sound }.map { $0.0 })
            guard candidates.count == 1, let correct = candidates.first,
                  last == correct || readings(String(last)).first == sound else { continue }
            let fixedName = String(name.dropLast()) + String(correct)
            let explanation = word + "的" + String(correct)
            guard fixedName != name || stated != String(correct) else { continue }
            // 已有热词的写法优先；不让释字规则改掉词表中的专有名词。
            let affected = source.substring(with: match.range)
            if hotwords.contains(where: { affected.localizedCaseInsensitiveContains($0) }) { continue }
            var local = affected as NSString
            let nameRange = NSRange(location: match.range(at: 1).location - match.range.location, length: match.range(at: 1).length)
            let charRange = NSRange(location: match.range(at: 3).location - match.range.location, length: match.range(at: 3).length)
            local = local.replacingCharacters(in: charRange, with: String(correct)) as NSString
            local = local.replacingCharacters(in: nameRange, with: fixedName) as NSString
            result.replaceSubrange(range, with: local as String)
            corrections.insert(Correction(name: name, correctedName: fixedName, explanation: explanation), at: 0)
        }
        return Result(text: result, corrections: corrections)
    }

    /// 带声调、按词读音匹配；多个同音候选时上面直接放弃。
    private static func readings(_ text: String) -> [String] {
        let value = NSMutableString(string: text)
        CFStringTransform(value, nil, kCFStringTransformMandarinLatin, false)
        return (value as String).lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
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
