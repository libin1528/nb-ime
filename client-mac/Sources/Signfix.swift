// 服务端把中文数字转成阿拉伯数字时，「正」「负」后面跟着数就当成正负号：「更正一下」→「更+1下」、「辜负一番」→「辜-1番」、「纠正两个」→「纠+2个」。
// 前一个字和它连成常用词（更正、纠正、欺负、辜负……）的，换回「正」「负」，后面的数也换回汉字。
// 不在词表里的（「零下-20度」）不动。

import Foundation

enum Signfix {
    /// 和「正」连成词的前一个字：更正 改正 纠正 修正 校正 订正 矫正 指正 真正 反正 端正 公正 方正 刚正 严正 立正 扶正 转正
    private static let beforePlus = Set("更改纠修校订矫指真反端公方刚严立扶转")
    /// 和「负」连成词的前一个字：欺负 辜负 抱负 自负 胜负 担负 背负 肩负 身负 重负 不负
    private static let beforeMinus = Set("欺辜抱自胜担背肩身重不")
    private static let hanDigits = Array("零一二三四五六七八九")

    static func apply(_ text: String) -> String {
        let c = Array(text)
        guard c.contains(where: { $0 == "+" || $0 == "-" }) else { return text }
        var out: [Character] = [], i = 0
        while i < c.count {
            let ch = c[i]
            guard i > 0, (ch == "+" && beforePlus.contains(c[i - 1])) || (ch == "-" && beforeMinus.contains(c[i - 1])) else {
                out.append(ch); i += 1; continue
            }
            out.append(ch == "+" ? "正" : "负")
            i += 1
            // 后面紧跟的数换回汉字；「修+一个」这种数没被转的，只换符号
            var j = i
            while j < c.count, c[j].isASCII, c[j].isNumber { j += 1 }
            guard j > i, let n = Int(String(c[i..<j])) else { continue }
            let next = j < c.count ? c[j] : nil
            out += read(n, digits: String(c[i..<j]), beforeWord: next.map { $0.isLetter && !$0.isASCII } ?? false)
            i = j
            // 小数部分逐位读：「修+1.5」→「修正一点五」
            if i + 1 < c.count, c[i] == ".", c[i + 1].isASCII, c[i + 1].isNumber {
                out.append("点"); i += 1
                while i < c.count, c[i].isASCII, let d = c[i].wholeNumberValue { out.append(hanDigits[d]); i += 1 }
            }
        }
        return String(out)
    }

    /// 一百以内按中文读法，再大的逐位读；「2」后面跟着量词读「两」（纠正两个）
    private static func read(_ n: Int, digits: String, beforeWord: Bool) -> [Character] {
        if n == 2, beforeWord { return ["两"] }
        if n < 10 { return [hanDigits[n]] }
        if n < 100 {
            let (t, u) = (n / 10, n % 10)
            return (t == 1 ? [] : [hanDigits[t]]) + ["十"] + (u == 0 ? [] : [hanDigits[u]])
        }
        return digits.compactMap(\.wholeNumberValue).map { hanDigits[$0] }
    }
}
