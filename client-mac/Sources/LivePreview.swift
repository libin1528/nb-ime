// 只对识别服务实际返回的文字做呈现，不补字、不改变最终输入。
import Foundation

struct LivePreview {
    struct Glyph {
        let range: NSRange
        let appearsAt: TimeInterval
    }
    private(set) var text = ""
    private(set) var glyphs: [Glyph] = []
    private var characters: [Character] = []

    mutating func update(_ next: String, at now: TimeInterval, animated: Bool = true) {
        guard next != text else { return }
        let incoming = Array(next)
        var prefix = 0
        while prefix < min(characters.count, incoming.count), characters[prefix] == incoming[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(characters.count, incoming.count) - prefix,
              characters[characters.count - 1 - suffix] == incoming[incoming.count - 1 - suffix] { suffix += 1 }
        let changed = incoming.count - prefix - suffix
        // 短更新逐字浮现；长句最多错开 0.28 秒，避免动画额外拖慢阅读。
        let step = min(0.018, 0.28 / Double(max(1, changed - 1)))
        var offset = 0
        var nextGlyphs: [Glyph] = []
        for (i, character) in incoming.enumerated() {
            let length = String(character).utf16.count
            let time: TimeInterval
            if !animated { time = now - 1 }
            else if i < prefix { time = glyphs[i].appearsAt }
            else if i >= incoming.count - suffix { time = glyphs[characters.count - incoming.count + i].appearsAt }
            else { time = now + Double(i - prefix) * step }
            nextGlyphs.append(Glyph(range: NSRange(location: offset, length: length), appearsAt: time))
            offset += length
        }
        text = next
        characters = incoming
        glyphs = nextGlyphs
    }

    func opacity(for glyph: Glyph, at now: TimeInterval) -> Double {
        let t = max(0, min(1, (now - glyph.appearsAt) / 0.18))
        return t * t * (3 - 2 * t)
    }

    mutating func finish(at now: TimeInterval) {
        glyphs = glyphs.map { Glyph(range: $0.range, appearsAt: now - 1) }
    }
}
