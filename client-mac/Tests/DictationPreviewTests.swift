import Foundation

@main enum DictationPreviewTests {
    static func main() {
        let voice = Array(repeating: Float(0.1), count: 19_200)
        let silence = Array(repeating: Float.zero, count: 8_000)
        var off = DictationPreview(enabled: false)
        precondition(off.append(voice, task: "old") == nil)
        var draft = DictationPreview(enabled: true)
        precondition(draft.append(silence, task: "a") == nil)
        let first = draft.append(voice, task: "a")!["id"] as! String
        precondition(draft.append(voice, task: "a") == nil)
        precondition(draft.accept("late", text: "别句") == nil)
        precondition(draft.accept(first, text: "一点") == "一点")
        let second = draft.append(voice, task: "a")!["id"] as! String
        precondition(draft.accept(second, text: "1点25") == "1点25")
        draft.stop()
        precondition(draft.append(voice, task: "a") == nil)
        precondition(draft.accept(second, text: "过期") == nil)
        var phrases = DictationPreview(enabled: true)
        let boundary = phrases.append(Array(repeating: 0.1, count: 68_000), task: "b")!
        _ = phrases.accept(boundary["id"] as! String, text: "下午1点25。")
        precondition(phrases.append(silence, task: "b") == nil)
        let next = phrases.append(voice, task: "b")!
        precondition(next["start"] as? Int == 68_000)
        precondition(phrases.accept(next["id"] as! String, text: "打开 ClawChat。") == "下午1点25。打开 ClawChat。")
        print("DictationPreview lifecycle and phrase boundary PASS")
    }
}
