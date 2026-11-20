import Foundation

@main enum LocalNameCandidatesTests {
    static func main() {
        let hotwords = ["NewBase", "ClawChat", "Claude Code", "Base"]
        let alias = ReplaceRule.parse("you beach、you base~=NewBase")!
        let competing = ReplaceRule.parse("you base~=AnotherBase")!
        let fixed = ReplaceRule.parse("you booth=YouBoot")!
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label)
            passed += 1
        }
        func correct(_ text: String, _ times: [StreamingTranscript.WordTime] = [], aliases: [ReplaceRule]? = nil) -> String {
            LocalNameCandidates.resolve(text, hotwords: hotwords, aliases: aliases ?? [alias], times: times).text
        }
        check(alias.isPronunciationAlias && alias.from == ["you beach", "you base"], "读音别名保留多词")
        check(Replace.apply("you base and you booth", [alias, fixed]).text == "you base and YouBoot", "固定替换不采纳读音别名")
        check(correct("我要找 claw chat项目。") == "我要找 ClawChat项目。", "从多词恢复 CamelCase")
        check(correct("这个项目叫 claude-code。") == "这个项目叫 Claude Code。", "恢复有空格的英文热词")
        check(correct("打开 you beach 项目") == "打开 NewBase 项目", "有专名标签才采用读音别名")
        check(correct("这个项目叫 you base") == "这个项目叫 NewBase", "明确的命名提示")
        check(correct("What do you base that on?") == "What do you base that on?", "普通问句")
        check(correct("他说 what do you base that on 然后挂了") == "他说 what do you base that on 然后挂了", "中英混说的普通问句")
        check(correct("We need a new base for the lamp.") == "We need a new base for the lamp.", "普通词和热词同拼写")
        check(correct("cloud code runs nightly") == "cloud code runs nightly", "无读音别名不猜专名")
        check(correct("这个名字是 my_new-base 项目") == "这个名字是 my_new-base 项目", "保留完整标识符")
        check(correct("项目叫 you base", aliases: [alias, competing]) == "项目叫 you base", "不同专名共享别名时保留原文")
        check(correct("打开 Claude Code项目。") == "打开 Claude Code项目。", "不拆开已有正确专名")

        let sample = "🙂先说 go chat you base cold deck 然后继续"
        let string = sample as NSString
        func time(_ value: String, _ start: Double, _ end: Double) -> StreamingTranscript.WordTime {
            .init(range: string.range(of: value), start: start, end: end)
        }
        let separated = [time("go chat", 1, 2), time("you", 2.3, 2.5), time("base", 2.5, 2.8), time("cold deck", 3.12, 4)]
        let connected = [time("go chat", 1, 2.3), time("you", 2.3, 2.5), time("base", 2.5, 2.8), time("cold deck", 2.82, 4)]
        check(correct(sample, separated) == "🙂先说 go chat NewBase cold deck 然后继续", "音频两侧有停顿的多词别名")
        check(correct(sample, connected) == sample, "词间连读时保留原文")
        let phrase = LocalNameCandidates.resolve(sample, hotwords: hotwords, aliases: [alias], times: []).candidates
        check(phrase.contains { $0.original == "you base" && $0.name == "NewBase" && !$0.applied }, "弱证据留作对照")
        let session = ReplaceRule.parse("塞神~=session")!
        check(correct("塞神。", aliases: [session]) == "session。", "单独说出的中文读音别名")
        check(correct("比如说我说塞神", aliases: [session]) == "比如说我说session", "句尾明确引用中文读音")
        check(correct("仓库名为塞神，先记一下", aliases: [session]) == "仓库名为session，先记一下", "明确的专名边界")
        check(correct("我说塞神庙有些年头了", aliases: [session]) == "我说塞神庙有些年头了", "保留以别名开头的完整中文专名")
        check(correct("因为堵塞神经受到压迫", aliases: [session]) == "因为堵塞神经受到压迫", "不能跨中文词拼出别名")
        check(correct("比如说我说塞神", aliases: []) == "比如说我说塞神", "没有明确配置时保留中文")
        let listAliases = [ReplaceRule.parse("live well~=Liveware")!, ReplaceRule.parse("new beach~=NewBase")!]
        let mixedList = "帮我把刚才30里的ClawChat live well和New beach整理一下"
        check(correct(mixedList, aliases: listAliases) == "帮我把刚才30里的ClawChat Liveware和NewBase整理一下",
              "已识别的热词与连接词给连读名单提供依据，同时保留数字")
        check(correct("ClawChat、live well 和 new beach", aliases: listAliases) == "ClawChat、Liveware 和 NewBase",
              "有逗号和连接词的名单")
        check(correct("用ClawChat and live well", aliases: listAliases) == "用ClawChat and live well",
              "两个相邻候选可能是普通英文短语")
        check(correct("I use ClawChat, live well and visit a new beach resort.", aliases: listAliases)
              == "I use ClawChat, live well and visit a new beach resort.", "普通英文正文")
        check(correct("I mention ClawChat live well and new beach resort.", aliases: listAliases)
              == "I mention ClawChat live well and new beach resort.", "同样的三个词夹在英文句子里不算名单")
        check(correct("刚才提到claw chat live well和new beach", aliases: listAliases)
              == "刚才提到claw chat live well和new beach", "没有已写对的热词时不自动推断名单")
        check(correct("刚才提到ClawChat live well new beach", aliases: listAliases)
              == "刚才提到ClawChat live well new beach", "纯空格不足以判定名单")
        check(correct("ClawChat, live well, and New beach", aliases: listAliases)
              == "ClawChat, Liveware, and NewBase", "英文逗号和连接词可以同时出现")
        check(correct("刚才提到ClawChat、NewBase 和塞神庙", aliases: [session])
              == "刚才提到ClawChat、NewBase 和塞神庙", "名单不会拆掉边缘的中文专名")
        print("Local name candidates: \(passed) passed, 0 failed")
    }
}
