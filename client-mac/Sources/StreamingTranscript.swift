import Foundation

/// 按音频时间替换不稳定区间，不能把每次中间结果直接拼接起来。
struct StreamingTranscript {
    struct Segment { let start: Double; let end: Double; let text: String }
    private var segments: [Segment] = []
    mutating func update(start: Double, end: Double, text: String) -> String {
        segments.removeAll { $0.start >= start || $0.end > start }
        segments.append(Segment(start: start, end: end, text: text))
        return segments.map(\.text).joined()
    }
}
