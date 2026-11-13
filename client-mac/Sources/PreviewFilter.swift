// 预览只负责显示：拦住热词表回声，不改变最终识别或用户的热词设置。
import Foundation

enum PreviewFilter {
    static func apply(_ text: String, words: [String]) -> String {
        let promptOrder = Dictionary(words.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let words = Array(Set(words.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
        guard words.count >= 2 else { return text }
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        func isSeparator(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { separators.contains($0) } }
        func isASCIIWord(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
        }
        var runs: [[(range: Range<String.Index>, word: String)]] = []
        var run: [(range: Range<String.Index>, word: String)] = []
        var i = text.startIndex
        while i < text.endIndex {
            if isSeparator(text[i]) { i = text.index(after: i); continue }
            let match = words.compactMap { word -> (Range<String.Index>, String)? in
                guard let r = text.range(of: word, options: [.anchored, .caseInsensitive], range: i..<text.endIndex) else { return nil }
                // 英文热词不能拆开更长的英文词；汉字与英文交界处允许紧贴，正是原来的漏口。
                if let first = word.first, isASCIIWord(first), i > text.startIndex, isASCIIWord(text[text.index(before: i)]) { return nil }
                if let last = word.last, isASCIIWord(last), r.upperBound < text.endIndex, isASCIIWord(text[r.upperBound]) { return nil }
                return (r, word.lowercased())
            }.first
            if let match {
                run.append((match.0, match.1))
                i = match.0.upperBound
            } else {
                if !run.isEmpty { runs.append(run); run = [] }
                i = text.index(after: i)
            }
        }
        if !run.isEmpty { runs.append(run) }
        var cuts: [Range<String.Index>] = []
        for run in runs {
            let onlyWords = text[..<run[0].range.lowerBound].allSatisfy(isSeparator)
                && text[run.last!.range.upperBound...].allSatisfy(isSeparator)
            let repeated = run.count >= 3 && Set(run.map(\.word)).count < run.count
            let ordered = run.count >= min(4, words.count) && run.enumerated().allSatisfy { promptOrder[$0.element.word] == $0.offset }
            if run.count >= 5 || repeated || ordered || (onlyWords && run.count >= 2) {
                var end = run.last!.range.upperBound
                // 从句首开始的整串热词，连末尾分隔符一起去掉；嵌在句中的保留句号衔接正常文字。
                if text[..<run[0].range.lowerBound].last.map(isSeparator) ?? true {
                    while end < text.endIndex, isSeparator(text[end]) { end = text.index(after: end) }
                }
                cuts.append(run[0].range.lowerBound..<end)
            }
        }
        var result = text
        for cut in cuts.reversed() { result.removeSubrange(cut) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
