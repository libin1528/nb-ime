// 预览与最终结果共用热词匹配；词内的空格、连字符属于词本身。
import Foundation

enum HotwordEcho {
    struct Item { let range: Range<String.Index>; let word: String }
    enum Decision: Equatable {
        case accept(String), reread, reject
    }

    static func isSeparator(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0)
        }
    }

    static func runs(_ text: String, words: [String]) -> [[Item]] {
        let canon = Dictionary(words.filter { !$0.isEmpty }.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let words = canon.values.sorted { $0.count > $1.count }
        guard words.count >= 2 else { return [] }
        func isASCIIWord(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
        }
        var runs: [[Item]] = [], run: [Item] = []
        var i = text.startIndex
        while i < text.endIndex {
            if isSeparator(text[i]) { i = text.index(after: i); continue }
            let match = words.compactMap { word -> Item? in
                guard let r = text.range(of: word, options: [.anchored, .caseInsensitive], range: i..<text.endIndex) else { return nil }
                if let first = word.first, isASCIIWord(first), i > text.startIndex, isASCIIWord(text[text.index(before: i)]) { return nil }
                if let last = word.last, isASCIIWord(last), r.upperBound < text.endIndex, isASCIIWord(text[r.upperBound]) { return nil }
                return Item(range: r, word: word.lowercased())
            }.first
            if let match {
                run.append(match)
                i = match.range.upperBound
            } else {
                if !run.isEmpty { runs.append(run); run = [] }
                i = text.index(after: i)
            }
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    static func suspicious(_ run: [Item], in text: String, words: [String], includeWhole: Bool = true) -> Bool {
        guard let first = run.first, let last = run.last else { return false }
        let order = Dictionary(words.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let whole = text[..<first.range.lowerBound].allSatisfy(isSeparator)
            && text[last.range.upperBound...].allSatisfy(isSeparator)
        let repeated = run.count >= 3 && Set(run.map(\.word)).count < run.count
        let ordered = run.count >= min(4, order.count) && run.enumerated().allSatisfy { order[$0.element.word] == $0.offset }
        return run.count >= 5 || repeated || ordered || (includeWhole && whole && run.count >= 2)
    }

    /// 可疑结果只允许不带热词重认一次。空白或仍可疑的重认结果不恢复旧文、不再次重试。
    static func resolve(_ raw: String, words: [String], retry: Bool) -> Decision {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if retry && text.allSatisfy(isSeparator) { return .reject }
        if runs(text, words: words).contains(where: { suspicious($0, in: text, words: words, includeWhole: !retry) }) {
            return retry ? .reject : .reread
        }
        return .accept(text)
    }
}
