// 热词按读音改回来：模型听到「wan san」会写成「万三」，不会写成热词表里的「Wan3」。
// 识别结果里读音和某个热词一样的一段（不管声调），换成热词本来的写法。
// 热词的读音：汉字取拼音，数字按中文读，字母要能拆成拼音音节（Wan → wan）；拆不开的英文词（ClawChat）不参与。

import Foundation

enum Hotfix {
    /// 一个音节：plain 不带声调；toned 带声调，只有汉字有（字母、数字读不出声调）
    private struct Sound: Equatable { let plain: String; let toned: String? }
    private struct Rule { let word: String; let sounds: [Sound]; let endsWithDigit: Bool }

    private static var cacheKey: [String] = []
    private static var cacheRules: [Rule] = []
    private static var pinyinCache: [Character: Sound] = [:]

    private static let digits: [Character: String] = [
        "0": "ling", "1": "yi", "2": "er", "3": "san", "4": "si",
        "5": "wu", "6": "liu", "7": "qi", "8": "ba", "9": "jiu",
    ]
    /// 旁边挨着这些字就是在说数（「一万三千」），不换
    private static let numerals = Set("0123456789零一二两三四五六七八九十百千万亿")
    /// 热词以数字结尾时，后面跟着这些字也是在说数（「晚三点」「第三个」）
    private static let units = Set("点号天个分秒年月日岁次回位名块元楼层期周章节届倍成折遍种份页条")

    private static let syllables = Set("""
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang cao ce cen
    ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci
    cong cou cu cuan cui cun cuo da dai dan dang dao de den deng di dia dian diao die ding diu dong dou du duan
    dui dun duo e ei en eng er fa fan fang fei fen feng fiao fo fou fu ga gai gan gang gao ge gei gen geng gong
    gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang
    hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng
    kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin
    ling liu lo long lou lu luan lue lun luo ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo
    mou mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nun nuo o
    ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing
    qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo sa sai san sang sao se
    sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si
    song sou su suan sui sun suo ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
    wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yan yang
    yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao
    zhe zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    static func apply(_ text: String, _ words: [String]) -> String {
        let rules = rulesFor(words)
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var chars = Array(text)
        var sounds = chars.map(sound)
        var i = 0
        while i < chars.count {
            var hit = false
            for r in rules {
                let n = r.sounds.count
                guard i + n <= chars.count, (0..<n).allSatisfy({ same(sounds[i + $0], r.sounds[$0]) }) else { continue }
                if String(chars[i..<i + n]) == r.word { continue }
                if i > 0, numerals.contains(chars[i - 1]) { continue }
                if i + n < chars.count, numerals.contains(chars[i + n]) { continue }
                if r.endsWithDigit, i + n < chars.count, units.contains(chars[i + n]) { continue }
                let w = Array(r.word)
                chars.replaceSubrange(i..<i + n, with: w)
                sounds.replaceSubrange(i..<i + n, with: w.map { _ in nil })
                i += w.count
                hit = true
                break
            }
            if !hit { i += 1 }
        }
        return String(chars)
    }

    private static func rulesFor(_ words: [String]) -> [Rule] {
        if words == cacheKey { return cacheRules }
        cacheKey = words
        // 长的先配，免得短词抢了长词的一截
        cacheRules = words.compactMap { w in
            guard let s = reading(w), s.count >= 2 else { return nil }
            return Rule(word: w, sounds: s, endsWithDigit: w.last?.isNumber ?? false)
        }.sorted { $0.sounds.count > $1.sounds.count }
        return cacheRules
    }

    /// 热词怎么读；有读不出来的部分就是 nil
    private static func reading(_ word: String) -> [Sound]? {
        var out: [Sound] = []
        var letters = ""
        func flushLetters() -> Bool {
            guard !letters.isEmpty else { return true }
            guard let parts = split(letters.lowercased()) else { return false }
            out += parts.map { Sound(plain: $0, toned: nil) }
            letters = ""
            return true
        }
        for c in word {
            if c.isASCII, c.isLetter { letters.append(c); continue }
            guard flushLetters() else { return nil }
            if c == " " || c == "-" { continue }
            guard let s = sound(c) else { return nil }
            out.append(s)
        }
        return flushLetters() ? out : nil
    }

    /// 一串字母拆成拼音音节，拆不开就是 nil
    private static func split(_ s: String) -> [String]? {
        let a = Array(s)
        var best = [[String]?](repeating: nil, count: a.count + 1)
        best[0] = []
        for end in 1...max(1, a.count) where end <= a.count {
            for start in max(0, end - 6)..<end {
                guard let prev = best[start], syllables.contains(String(a[start..<end])) else { continue }
                best[end] = prev + [String(a[start..<end])]
                break
            }
        }
        return best[a.count]
    }

    /// 热词带声调的音节要声调也一样（小圆不换小院），不带的只比拼音
    private static func same(_ a: Sound?, _ rule: Sound) -> Bool {
        guard let a else { return false }
        if let t = rule.toned, let u = a.toned { return t == u }
        return a.plain == rule.plain
    }

    /// 一个字怎么读；不是汉字也不是数字就是 nil
    private static func sound(_ c: Character) -> Sound? {
        if let d = digits[c] { return Sound(plain: d, toned: nil) }
        guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1,
              (0x4E00...0x9FFF).contains(u.value) else { return nil }
        if let p = pinyinCache[c] { return p }
        let m = NSMutableString(string: String(c))
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        let toned = (m as String).lowercased()
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let p = Sound(plain: (m as String).lowercased(), toned: toned)
        pinyinCache[c] = p
        return p
    }
}
