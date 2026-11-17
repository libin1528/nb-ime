// 预览只负责显示：拦住热词表回声，不改变最终识别或用户的热词设置。
import Foundation

enum PreviewFilter {
    static func apply(_ text: String, words: [String]) -> String {
        let runs = HotwordEcho.runs(text, words: words)
        let isSeparator = HotwordEcho.isSeparator
        var cuts: [Range<String.Index>] = []
        for run in runs {
            if HotwordEcho.suspicious(run, in: text, words: words) {
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
