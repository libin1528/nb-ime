import Foundation

/// 按音频时间替换不稳定区间，不能把每次中间结果直接拼接起来。
struct StreamingTranscript {
    struct WordTime {
        let range: NSRange
        let start: Double
        let end: Double
    }

    private struct Segment {
        let start: Double
        let end: Double
        let text: String
        let times: [WordTime]
    }
    private var segments: [Segment] = []
    var text: String { segments.map(\.text).joined() }
    var wordTimes: [WordTime] {
        var offset = 0
        var result: [WordTime] = []
        for segment in segments {
            result += segment.times.map {
                WordTime(range: NSRange(location: offset + $0.range.location, length: $0.range.length),
                         start: $0.start, end: $0.end)
            }
            offset += segment.text.utf16.count
        }
        return result
    }

    @discardableResult mutating func update(start: Double, end: Double, text: String, times: [WordTime] = []) -> String {
        segments.removeAll { $0.start >= start || $0.end > start }
        segments.append(Segment(start: start, end: end, text: text, times: times))
        return self.text
    }
}
