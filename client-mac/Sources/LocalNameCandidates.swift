import Foundation

enum LocalNameCandidates {
    struct Candidate: Encodable {
        let original: String
        let name: String
        let applied: Bool
    }

    private struct Match {
        let range: NSRange
        let lastToken: Int
        let original: String
        let name: String
        var isExact: Bool { original == name }
    }

    private static let words = try! NSRegularExpression(pattern: "[A-Za-z0-9]+")
    private static let wordsWithHan = try! NSRegularExpression(pattern: "[A-Za-z0-9]+|\\p{Han}")
    private static let han = try! NSRegularExpression(pattern: "\\p{Han}")
    private static let separators = CharacterSet(charactersIn: " \t-‐‑")
    private static let identifierNeighbors = CharacterSet(charactersIn: "_'’/@-‐‑")
    private static let phraseEdge = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    private static let listPunctuation = CharacterSet(charactersIn: "、,，")
    private static let listJoiners = ["和", "及", "与", "與", "and"]
    private static let nameIntroductions = ["叫", "名为", "项目是", "名字是", "项目名是", "the project is called", "the project named"]
    private static let spokenIntroductions = ["我说", "我说的是", "说的词是", "读作"]
    private static let nameLabels = ["项目", "仓库", "应用", "平台", "客户端"]

    static func resolve(_ text: String, hotwords: [String], aliases: [ReplaceRule],
                        times: [StreamingTranscript.WordTime]) -> (text: String, candidates: [Candidate]) {
        var names: [String: Set<String>] = [:]
        for name in hotwords {
            if let key = key(name) { names[key, default: []].insert(name) }
        }
        var byAlias: [String: Set<String>] = [:]
        for rule in aliases where rule.isPronunciationAlias {
            for value in rule.from {
                if let key = key(value, allowHan: true) { byAlias[key, default: []].insert(rule.to) }
            }
        }
        let maxLength = (Array(names.keys) + Array(byAlias.keys)).map(\.utf8.count).max() ?? 0
        let source = text as NSString
        let tokenPattern = byAlias.keys.contains(where: containsHan) ? wordsWithHan : words
        let tokens = tokenPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        var matches = Array(repeating: [Match](), count: tokens.count)
        for i in tokens.indices {
            var spelling = ""
            for j in i..<tokens.count {
                if j > i {
                    let gap = NSRange(location: NSMaxRange(tokens[j - 1]), length: tokens[j].location - NSMaxRange(tokens[j - 1]))
                    if !only(source.substring(with: gap), in: separators) { break }
                }
                spelling += source.substring(with: tokens[j]).lowercased()
                if spelling.utf8.count > maxLength { break }
                let span = NSRange(location: tokens[i].location, length: NSMaxRange(tokens[j]) - tokens[i].location)
                guard let choices = names[spelling] ?? byAlias[spelling], choices.count == 1,
                      let name = choices.first, bounded(span, in: source) else { continue }
                matches[i].append(.init(range: span, lastToken: j, original: source.substring(with: span), name: name))
            }
        }

        let inLists = confirmedListMembers(matches, in: source)
        let output = NSMutableString(string: text)
        var edits: [(NSRange, String)] = []
        var candidates: [Candidate] = []
        var next = 0
        for i in matches.indices where i >= next {
            var selected: Match?
            for match in matches[i] {
                // 已经是词表里的原写法，保住词及其内部词组。
                if match.isExact || inLists.contains(match.range)
                    || inNameContext(match.range, in: source, hanAlias: containsHan(match.original))
                    || separatedByPauses(match.range, in: source, times: times) {
                    selected = match
                } else {
                    candidates.append(.init(original: match.original, name: match.name, applied: false))
                }
            }
            if let selected {
                if !selected.isExact {
                    edits.append((selected.range, selected.name))
                    candidates.append(.init(original: selected.original, name: selected.name, applied: true))
                }
                next = selected.lastToken + 1
            }
        }
        for (span, name) in edits.reversed() { output.replaceCharacters(in: span, with: name) }
        return (output as String, candidates)
    }

    /// 连读名单可以缺少部分逗号。要有一个已写对的热词、一处明确的列举连接，
    /// 以及三个不同的名字；两侧连着英文正文时保留原文。
    private static func confirmedListMembers(_ matches: [[Match]], in text: NSString) -> Set<NSRange> {
        var confirmed = Set<NSRange>()
        var group: [Match] = []
        var explicit = false
        var next = 0
        func commit() {
            guard explicit, Set(group.map(\.name)).count >= 3, group.contains(where: \.isExact),
                  let first = group.first, let last = group.last else { return }
            let left = text.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = text.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isListEdge(left.unicodeScalars.last), isListEdge(right.unicodeScalars.first) else { return }
            confirmed.formUnion(group.map(\.range))
        }
        for i in matches.indices where i >= next {
            let latin = matches[i].filter { !containsHan($0.original) }
            guard let match = latin.last(where: \.isExact) ?? latin.last else { continue }
            if let last = group.last {
                let end = NSMaxRange(last.range)
                let gap = text.substring(with: NSRange(location: end, length: match.range.location - end))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !gap.isEmpty {
                    let connector = gap.trimmingCharacters(in: .whitespaces.union(listPunctuation)).lowercased()
                    if connector.isEmpty || listJoiners.contains(connector) {
                        explicit = true
                    } else {
                        commit()
                        group.removeAll(keepingCapacity: true)
                        explicit = false
                    }
                }
            }
            group.append(match)
            next = match.lastToken + 1
        }
        commit()
        return confirmed
    }

    private static func isListEdge(_ scalar: UnicodeScalar?) -> Bool {
        guard let scalar else { return true }
        return !identifierNeighbors.contains(scalar) && !(scalar.isASCII && CharacterSet.alphanumerics.contains(scalar))
    }

    private static func key(_ text: String, allowHan: Bool = false) -> String? {
        let value = text.unicodeScalars.filter { !separators.contains($0) }
        let compact = String(String.UnicodeScalarView(value))
        let length = compact.utf16.count
        let range = NSRange(location: 0, length: length)
        if allowHan, containsHan(compact) {
            let tokens = wordsWithHan.matches(in: compact, range: range)
            guard length >= 2, tokens.reduce(0, { $0 + $1.range.length }) == length else { return nil }
            return compact.lowercased()
        }
        guard length >= 2, compact.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }),
              words.firstMatch(in: compact, range: range)?.range.length == length else { return nil }
        return compact.lowercased()
    }

    private static func containsHan(_ text: String) -> Bool {
        han.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    private static func only(_ value: String, in allowed: CharacterSet) -> Bool {
        value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func bounded(_ span: NSRange, in source: NSString) -> Bool {
        let end = NSMaxRange(span)
        func isConnector(_ offset: Int) -> Bool {
            UnicodeScalar(source.character(at: offset)).map(identifierNeighbors.contains) ?? false
        }
        return (span.location == 0 || !isConnector(span.location - 1)) && (end == source.length || !isConnector(end))
    }

    private static func inNameContext(_ span: NSRange, in source: NSString, hanAlias: Bool) -> Bool {
        let prefix = source.substring(to: span.location)
        let suffix = source.substring(from: NSMaxRange(span))
        let left = prefix.trimmingCharacters(in: phraseEdge).lowercased()
        let right = suffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let atPhraseEnd = right.isEmpty || right.unicodeScalars.first.map(phraseEdge.contains) == true
        if left.isEmpty, only(right, in: phraseEdge) { return true }
        if hanAlias {
            if nameLabels.contains(where: { right.hasPrefix($0) }) { return true }
            guard atPhraseEnd else { return false }
            return (spokenIntroductions + nameIntroductions).contains { left.hasSuffix($0) }
        }
        if nameIntroductions.contains(where: { left.hasSuffix($0) }) { return true }
        return nameLabels.contains { right.hasPrefix($0) }
    }

    private static func separatedByPauses(_ span: NSRange, in text: NSString, times: [StreamingTranscript.WordTime]) -> Bool {
        let end = NSMaxRange(span)
        guard let first = times.firstIndex(where: { NSIntersectionRange($0.range, span).length > 0 }),
              let last = times.lastIndex(where: { NSIntersectionRange($0.range, span).length > 0 }),
              times[first].range.location <= span.location, NSMaxRange(times[last].range) >= end else { return false }
        let before = NSRange(location: times[first].range.location, length: span.location - times[first].range.location)
        let after = NSRange(location: end, length: NSMaxRange(times[last].range) - end)
        guard only(text.substring(with: before), in: phraseEdge), only(text.substring(with: after), in: phraseEdge) else { return false }
        let pause = 0.2
        let left = first > 0 ? times[first].start - times[first - 1].end >= pause : only(text.substring(to: span.location), in: phraseEdge)
        let right = last + 1 < times.count ? times[last + 1].start - times[last].end >= pause : only(text.substring(from: end), in: phraseEdge)
        return left && right
    }
}
