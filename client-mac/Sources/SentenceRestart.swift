// 完整句边界两侧的重复词可能承担不同语法角色，不能当作同一句里的重说删掉。
import Foundation

enum SentenceRestart {
    private static let boundaries = CharacterSet(charactersIn: "。！？!?；;\n\r.")
    static func isBoundary(_ c: Character) -> Bool { c.unicodeScalars.contains(where: boundaries.contains) }

    /// 找到上一句结尾与下一句开头重复的汉字短语，留给模型输出检查按次数保护。
    static func anchors(_ text: String) -> [String] {
        let chars = Array(text)
        func han(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } }
        var words: [String] = []
        for at in chars.indices where isBoundary(chars[at]) {
            var end = at
            while end > 0, chars[end - 1].isWhitespace { end -= 1 }
            var start = end
            while start > 0, han(chars[start - 1]) { start -= 1 }
            var next = at + 1
            while next < chars.count, chars[next].isWhitespace || isBoundary(chars[next]) { next += 1 }
            var tail = next
            while tail < chars.count, han(chars[tail]) { tail += 1 }
            let limit = min(end - start, tail - next)
            guard limit >= 3 else { continue }
            for n in stride(from: limit, through: 3, by: -1) {
                let word = chars[(end - n)..<end]
                if word == chars[next..<(next + n)], Set(word).count > 1 {
                    let s = String(word)
                    if !words.contains(s) { words.append(s) }
                    break
                }
            }
        }
        return words
    }
}
