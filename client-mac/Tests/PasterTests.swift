// 使用独立剪贴板和虚拟时钟，不向当前应用发送按键，不碰用户剪贴板。
// swiftc -swift-version 5 Sources/Paster.swift Sources/Log.swift Tests/PasterTests.swift -o /tmp/nbime-paster-tests
import Cocoa

final class PasteClock {
    var now: TimeInterval = 0
    private var jobs: [(at: TimeInterval, work: () -> Void)] = []

    func later(_ delay: TimeInterval, _ work: @escaping () -> Void) { jobs.append((now + delay, work)) }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let i = jobs.indices.min(by: { jobs[$0].at < jobs[$1].at }), jobs[i].at <= end + 0.000001 {
            let job = jobs.remove(at: i)
            now = job.at
            job.work()
        }
        now = end
    }
}

final class PasteHarness {
    let pb = NSPasteboard.withUniqueName()
    let clock = PasteClock()
    var target: PasteTarget? = PasteTarget(pid: 42, bundleID: "com.carriez.rustdesk")
    var events: [CGEvent] = []
    var pasted: [String] = []
    var logs: [String] = []
    lazy var delivery = PasteDelivery(pasteboard: pb, target: { [weak self] in self?.target }, post: { [weak self] event in
        guard let self else { return }
        self.events.append(event)
        if event.getIntegerValueField(.keyboardEventKeycode) == 9, event.type == .keyDown {
            self.pasted.append(self.text)
        }
    }, later: clock.later, log: { [weak self] in self?.logs.append($0) })

    var text: String { pb.string(forType: .string) ?? "" }
    func copy(_ text: String) { pb.clearContents(); pb.setString(text, forType: .string) }
    deinit { pb.releaseGlobally() }
}

@main enum PasterTests {
    static var passed = 0
    static var failed = 0
    static func check(_ ok: @autoclosure () -> Bool, _ name: String) {
        if ok() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }

    static func main() {
        for platform in ["Windows", "Linux", "Mac OS"] {
            for swapped in [false, true] {
                let session = RustDeskPaste.parse(peer: "test", config: "allow_swap_key = \(swapped)\n[info]\nplatform = '\(platform)'")!
                check(session.useControl == ((platform != "Mac OS") != swapped), "远端平台和置换组合选对修饰键")
            }
        }
        check(RustDeskPaste.matches(title: "host:123@desktop - Remote Desktop - RustDesk", peer: "host:123"), "准确匹配会话")
        check(!RustDeskPaste.matches(title: "host:1234@desktop - Remote Desktop - RustDesk", peer: "host:123"), "不误匹配另一端口")
        check(RustDeskPaste.parse(peer: "test", config: "[info]\nplatform = 'Windows'") == nil, "设置不完整时不猜映射")
        do {
            let h = PasteHarness()
            h.target?.rustDeskSession = RustDeskPasteSession(peer: "one", platform: "Windows", swapped: false)
            h.delivery.paste("Windows 输入", restore: false); h.clock.advance(0.7)
            check(h.events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [59, 9, 9, 59], "Windows 未置换走 Control+V")
            check(h.events.prefix(3).allSatisfy { $0.flags.contains(.maskControl) && $0.flags.rawValue & 1 != 0 && !$0.flags.contains(.maskCommand) }, "不发送 Windows 键，并携带左 Control 设备位")
        }
        do {
            let h = PasteHarness()
            h.target?.rustDeskSession = RustDeskPasteSession(peer: "one", platform: "Windows", swapped: false)
            h.delivery.paste("不要串到另一台", restore: false)
            h.target?.rustDeskSession = RustDeskPasteSession(peer: "two", platform: "Windows", swapped: false)
            h.clock.advance(10)
            check(h.events.isEmpty, "同一 RustDesk 进程换会话也取消粘贴")
        }
        let events = PasteDelivery.shortcut()
        check(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [55, 9, 9, 55], "独立 Command 按下和松开包住 V")
        check(events.count == 4 && events[1].type == .keyDown && events[2].type == .keyUp, "V 按下后松开")
        check(events.first?.type == .flagsChanged && events.last?.type == .flagsChanged, "Command 用原生修饰键变化事件独立转发")
        check(events.prefix(3).allSatisfy { $0.flags.contains(.maskCommand) } && events.last?.flags.contains(.maskCommand) == false,
              "前三个事件带 Command，最后释放")
        check(events.prefix(3).allSatisfy { $0.flags.rawValue & 0x8 != 0 } && events.last!.flags.rawValue & 0x8 == 0,
              "Command 和 V 均带左侧设备标志，最后清除，不触发 Flutter 提前释放")
        check(!PasteTarget(pid: 42, bundleID: "other.com.carriez.rustdesk").isRustDesk, "只匹配 RustDesk 的准确 bundle id")
        do {
            let h = PasteHarness()
            h.copy("原来的复制")
            h.delivery.paste("语音🙂", restore: true)
            check(h.text == "语音🙂" && h.events.isEmpty, "远程先写剪贴板，不立即按粘贴")
            check(h.pb.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == nil, "远程用普通可同步文本")
            h.clock.advance(0.69)
            check(h.events.isEmpty, "同步等待期间没有按键")
            h.clock.advance(0.01)
            check(h.pasted == ["语音🙂"] && h.events.count == 4, "同步等待结束发送完整按键")
            h.clock.advance(1.99)
            check(h.text == "语音🙂", "粘贴后保留文本供远端消费")
            h.clock.advance(0.01)
            check(h.text == "原来的复制", "消费等待结束后恢复原剪贴板")
        }
        do {
            let h = PasteHarness()
            h.target = PasteTarget(pid: 7, bundleID: "com.apple.TextEdit")
            h.copy("旧内容")
            h.delivery.paste("本机输入", restore: true)
            check(h.pasted == ["本机输入"] && h.events.count == 4, "本机粘贴不增加同步等待")
            check(h.pb.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != nil, "本机仍标记临时剪贴板")
            h.clock.advance(0.79)
            check(h.text == "本机输入", "本机仍保留原有恢复延迟")
            h.clock.advance(0.01)
            check(h.text == "旧内容", "本机恢复旧剪贴板")
        }
        do {
            let h = PasteHarness()
            h.target = PasteTarget(pid: 7, bundleID: "com.apple.TextEdit")
            h.copy("原文")
            h.delivery.paste("本机第一句", restore: true)
            h.delivery.paste("本机第二句", restore: false)
            check(h.pasted == ["本机第一句", "本机第二句"], "本机连续输入不被远程等待串行阻塞")
            h.clock.advance(10)
            check(h.text == "本机第二句", "前一句的恢复任务不覆盖后一句")
        }
        do {
            let h = PasteHarness()
            h.copy("旧内容")
            h.delivery.paste("保留语音", restore: false)
            h.clock.advance(10)
            check(h.pasted == ["保留语音"] && h.text == "保留语音", "关闭恢复时保留语音")
        }
        do {
            let h = PasteHarness()
            h.pb.clearContents()
            h.delivery.paste("原来为空", restore: true)
            h.clock.advance(10)
            check(h.text == "原来为空", "原剪贴板为空时仍保留语音供补粘")
        }
        do {
            let h = PasteHarness()
            h.copy("旧内容")
            h.delivery.paste("取消输入", restore: true)
            h.target = PasteTarget(pid: 99, bundleID: "com.apple.TextEdit")
            h.clock.advance(10)
            check(h.events.isEmpty && h.text == "旧内容", "等待中切换应用不误粘，归还原剪贴板")
            check(h.logs.contains { $0.contains("取消延迟") }, "取消时留下可排查日志")
        }
        do {
            let h = PasteHarness()
            h.copy("旧内容")
            h.delivery.paste("取消输入", restore: true)
            h.copy("用户新复制")
            h.clock.advance(10)
            check(h.events.isEmpty && h.text == "用户新复制", "等待中复制新内容不误粘、不覆盖")
        }
        do {
            let h = PasteHarness()
            h.copy("旧内容")
            h.delivery.paste("已输入", restore: true)
            h.clock.advance(0.7)
            h.copy("新的复制")
            h.clock.advance(10)
            check(h.pasted == ["已输入"] && h.text == "新的复制", "粘贴后复制新内容不被旧恢复任务覆盖")
        }
        do {
            let h = PasteHarness()
            h.copy("最初的复制")
            h.delivery.paste("第一句", restore: true)
            h.delivery.paste("第二句", restore: true)
            h.clock.advance(0.7)
            check(h.pasted == ["第一句"] && h.text == "第一句", "排队第二句不覆盖第一句待同步文本")
            h.clock.advance(2.7)
            check(h.pasted == ["第一句", "第二句"], "连续两句顺序粘贴，没有丢字")
            h.clock.advance(2)
            check(h.text == "最初的复制", "连续两句最后恢复原始剪贴板")
        }
        do {
            let h = PasteHarness()
            h.delivery.paste("第一句", restore: false)
            h.delivery.paste("不要误粘的第二句", restore: false)
            h.clock.advance(0.7)
            h.target = PasteTarget(pid: 99, bundleID: "com.apple.TextEdit")
            h.clock.advance(10)
            check(h.pasted == ["第一句"], "排队期间换应用，不把第二句粘进新应用")
        }
        do {
            let h = PasteHarness()
            h.delivery.paste("取消的远程句子", restore: false)
            h.target = PasteTarget(pid: 7, bundleID: "com.apple.TextEdit")
            h.delivery.paste("转回本机的句子", restore: false)
            h.clock.advance(10)
            check(h.pasted == ["转回本机的句子"], "取消旧远程输入后队列能继续向本机输入")
        }
        do {
            let h = PasteHarness()
            let original = NSPasteboardItem()
            original.setString("带格式的原文", forType: .string)
            let rtf = Data("{\\rtf1 original}".utf8)
            original.setData(rtf, forType: .rtf)
            h.pb.clearContents(); h.pb.writeObjects([original])
            h.delivery.paste("语音", restore: true)
            h.clock.advance(10)
            check(h.text == "带格式的原文" && h.pb.data(forType: .rtf) == rtf, "恢复所有原有格式")
        }
        print("Paster: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
