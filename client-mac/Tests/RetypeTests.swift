// 生产重新输入协调器 + 生产粘贴队列；独立剪贴板、虚拟时钟、内存按键，不向远端发字。
// swiftc -swift-version 5 $(rg --files Sources -g '*.swift' | rg -v '/main.swift$') Tests/PasteClock.swift Tests/RetypeTests.swift -o /tmp/nbime-retype-tests
import Cocoa

@main enum RetypeTests {
    static var passed = 0, failed = 0
    static func check(_ ok: @autoclosure () -> Bool, _ name: String) {
        if ok() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static func frame(pid: pid_t = 42, bundle: String = "com.carriez.rustdesk", peer: String? = "one", swapped: Bool = false,
                      role: String = "AXGroup", element: pid_t = 100, window: pid_t = 200,
                      inside: Bool = true, blocked: Bool = false) -> RetypeFocus.Observation {
        let session = peer.map { RustDeskPasteSession(peer: $0, platform: "Windows", swapped: swapped) }
        return RetypeFocus.Observation(target: PasteTarget(pid: pid, bundleID: bundle, rustDeskSession: session),
                                      element: AXUIElementCreateApplication(element), window: AXUIElementCreateApplication(window),
                                      role: role, inFocusedWindow: inside, blocked: blocked)
    }
    final class Harness {
        let clock = PasteClock(), pb = NSPasteboard.withUniqueName()
        var current: RetypeFocus.Observation? = RetypeTests.frame()
        var regular: [String] = [], remote: [String] = [], pasted: [String] = [], logs: [String] = []
        var cancelled = 0, observations = 0
        lazy var action = RetypeAction(observe: { [unowned self] _ in observations += 1; return current }, later: clock.later)
        lazy var delivery = PasteDelivery(pasteboard: pb, target: { [unowned self] in current?.target }, post: { [unowned self] event in
            if event.getIntegerValueField(.keyboardEventKeycode) == 9 && event.type == .keyDown { pasted.append(pb.string(forType: .string) ?? "") }
        }, later: clock.later, log: { [unowned self] in logs.append($0) })
        func send(_ text: String) {
            action.send(text, regular: { [unowned self] in regular.append($0) }, remote: { [unowned self] text, valid in
                remote.append(text); delivery.paste(text, restore: true, validating: valid)
            }, cancelled: { [unowned self] in cancelled += 1 })
        }
        func copy(_ text: String) { pb.clearContents(); pb.setString(text, forType: .string) }
        deinit { pb.releaseGlobally() }
    }
    static func main() {
        _ = NSApplication.shared
        let original = frame(), captured = RetypeFocus.capture(original)!
        check(RetypeFocus.capture(nil) == nil, "读不到上下文不猜")
        check(captured.matches(frame()), "相同应用、会话、窗口、焦点可以恢复")
        let unsuitable = [frame(bundle: "other.com.carriez.rustdesk"), frame(peer: nil), frame(inside: false), frame(blocked: true)]
            + ["AXButton", "AXWindow", "AXTextField", "AXTextArea", "AXComboBox", "AXMenu", "AXUnknown"].map { frame(role: $0) }
        for observation in unsuitable { check(RetypeFocus.capture(observation) == nil, "其他应用、启动页、弹层和非画面角色不走快速路径") }
        let changed = [frame(pid: 43), frame(bundle: "com.apple.TextEdit"), frame(peer: "two"), frame(swapped: true),
                       frame(role: "AXTextField"), frame(element: 101), frame(window: 201), frame(inside: false), frame(blocked: true)]
        for observation in changed { check(!captured.matches(observation), "应用、会话、映射、窗口、焦点任一变化均拒绝复用") }
        do {
            let h = Harness(); h.copy("旧剪贴板"); h.action.prepare(); h.send("重新输入🙂")
            h.clock.advance(0.149); check(h.remote.isEmpty, "菜单关闭等待仍保留")
            h.clock.advance(0.001); check(h.remote == ["重新输入🙂"] && h.regular.isEmpty, "0.15秒后直接进入原粘贴队列，不等四秒")
            h.clock.advance(0.699); check(h.pasted.isEmpty, "RustDesk原0.7秒同步等待未缩短")
            h.clock.advance(0.001); check(h.pasted == ["重新输入🙂"], "约0.85秒发送一次粘贴")
            h.clock.advance(2); check(h.pb.string(forType: .string) == "旧剪贴板", "原剪贴板恢复机制保留")
            h.send("不用旧快照"); h.clock.advance(0.15); check(h.regular == ["不用旧快照"], "快照用过即清，不跨菜单复用")
        }
        for next in changed {
            let h = Harness(); h.copy("原文"); h.action.prepare(); h.send("不要误粘"); h.current = next
            h.clock.advance(10)
            check(h.cancelled == 1 && h.pasted.isEmpty && h.regular.isEmpty, "菜单关闭期间变更目标直接取消，不回退粘进新应用")
            check(h.pb.string(forType: .string) == "原文", "取消不写剪贴板")
        }
        do {
            let h = Harness(); h.copy("旧内容"); h.action.prepare(); h.send("延迟发送前核对")
            h.clock.advance(0.15); h.current = frame(element: 101); h.clock.advance(10)
            check(h.remote.count == 1 && h.pasted.isEmpty, "同步等待期间同一会话换焦点也取消按键")
            check(h.pb.string(forType: .string) == "旧内容", "取消后仍按原规则恢复剪贴板")
        }
        do {
            let h = Harness(); h.copy("旧内容"); h.action.prepare(); h.send("不能覆盖用户复制")
            h.clock.advance(0.15); h.copy("用户新复制"); h.clock.advance(10)
            check(h.pasted.isEmpty && h.pb.string(forType: .string) == "用户新复制", "同步期间新复制不被覆盖或误粘")
        }
        do {
            let h = Harness(); h.copy("原来内容"); h.delivery.paste("前一句", restore: true); h.action.prepare(); h.send("排队的重输")
            h.clock.advance(0.15); h.clock.advance(0.55); h.current = frame(element: 101); h.clock.advance(10)
            check(h.pasted == ["前一句"], "排队期间焦点变化，旧重输不写下一句也不抢点按")
            check(h.pb.string(forType: .string) == "原来内容", "拒绝排队重输后保留原剪贴板")
        }
        for observation in unsuitable {
            let h = Harness(); h.current = observation; h.action.prepare(); h.send("原判断")
            h.clock.advance(0.15)
            check(h.regular == ["原判断"] && h.remote.isEmpty && h.cancelled == 0, "不适用场景继续使用原焦点判断")
        }
        do {
            let h = Harness()
            let text = "菜单重输测试"
            let menu = MenuBar(recentEntries: { [HistoryEntry(text: text,date: Date(),seconds: 0,app: "test")] }, hotkeys: { [] }, editedCount: { 0 }, retypeAction: h.action)
            let native = NSMenu()
            menu.onRetype = { value, valid in
                if let valid { h.delivery.paste(value,restore: true,validating: valid) } else { h.regular.append(value) }
            }
            menu.menuNeedsUpdate(native); menu.menuWillOpen(native)
            h.current = frame(role: "AXMenu"); menu.menuNeedsUpdate(native)
            check(h.observations == 1, "跟踪菜单时刷新不把菜单自身保存为原焦点")
            h.current = original
            let index = menu.menu.items.firstIndex { $0.title.contains(text) }!
            menu.menu.performActionForItem(at: index);h.clock.advance(0.85)
            check(h.pasted == [text] && h.regular.isEmpty, "从生产菜单项打开并使用原焦点")
            menu.menuDidClose(native);let before = h.observations;menu.menuNeedsUpdate(native)
            check(h.observations == before + 1, "下次打开菜单重新获取焦点")
        }
        print("Retype: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
