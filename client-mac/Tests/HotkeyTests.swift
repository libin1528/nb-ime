// 走真实 Hotkey.process 入口，在内存里记录向下游传递的事件；不安装钩子、不发送按键。
import Cocoa

private final class Harness {
    let hotkey: Hotkey
    var remote = true
    var output: [CGEvent] = []
    var down = 0, up = 0, cancelled = 0
    init(_ codes: [UInt16] = [58, 96]) {
        hotkey = Hotkey(codes: codes)
        hotkey.onDown = { [weak self] in self?.down += 1 }
        hotkey.onUp = { [weak self] in self?.up += 1 }
        hotkey.onOtherKey = { [weak self] in self?.cancelled += 1 }
    }
    func send(_ code: UInt16, _ pressed: Bool, _ flags: UInt64 = 0) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: pressed)!
        event.flags = CGEventFlags(rawValue: flags)
        send(event)
    }
    func send(_ event: CGEvent) {
        if !hotkey.process(event, remote: { self.remote }, replay: { self.output.append($0) }) { output.append(event) }
    }
    var keys: [Int64] { output.map { $0.getIntegerValueField(.keyboardEventKeycode) } }
}

@main enum HotkeyTests {
    static var passed = 0, failed = 0
    static let option = CGEventFlags.maskAlternate.rawValue | 0x20
    static let control = CGEventFlags.maskControl.rawValue | 0x1
    static func check(_ ok: @autoclosure () -> Bool, _ name: String) {
        if ok() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static func main() {
        do {
            let h = Harness()
            h.send(58, true, option); h.send(58, false)
            check(h.output.isEmpty, "远端单按 Option 不发送 Alt 按下或松开")
            check(h.down == 1 && h.up == 1 && h.cancelled == 0, "本机录音仍完整开始结束")
            h.send(0, true); h.send(0, false)
            check(h.keys == [0, 0], "后续普通文字没有残留 Option")
        }
        for reverseRelease in [false, true] {
            let h = Harness()
            h.send(58, true, option); h.send(3, true, option)
            h.send(3, true, option) // 自动重复
            if reverseRelease {
                h.send(58, false); h.send(3, false)
            } else {
                h.send(3, false, option); h.send(58, false)
            }
            check(h.keys == (reverseRelease ? [58, 3, 3, 58, 3] : [58, 3, 3, 3, 58]), "Option+F 先补修饰键，含重复和两种松键顺序")
            check(h.output[0].flags.rawValue == option && h.output[1].flags.rawValue == option, "组合键保留通用与左右设备位")
            check(h.down == 1 && h.up == 1 && h.cancelled == 1, "组合操作只取消一次录音")
        }
        do {
            let h = Harness()
            h.send(58, true, option); h.send(96, true, option); h.send(96, false, option); h.send(58, false)
            check(h.keys == [58, 96, 96, 58], "Option+F5 即使 F5 是录音键也完整放行")
            check(h.down == 1 && h.up == 1 && h.cancelled == 1, "组合里的 F5 不再次启动录音")
        }
        for remote in [false, true] {
            let h = Harness([61]); h.remote = remote
            h.send(58, true, option); h.send(58, false)
            check(h.keys == [58, 58], "未绑定的左 Option 不拦截")
        }
        do {
            let h = Harness(); h.remote = false
            h.send(58, true, option); h.send(3, true, option); h.send(3, false, option); h.send(58, false)
            check(h.keys == [58, 3, 3, 58], "本机应用的 Option 组合键不变")
        }
        do {
            let h = Harness(); h.hotkey.paused = true
            h.send(58, true, option); h.send(58, false)
            check(h.keys == [58, 58] && h.down == 0, "暂停时单按 Option 恢复正常 Alt")
        }
        do {
            let h = Harness([61]); let right = CGEventFlags.maskAlternate.rawValue | 0x40
            h.send(61, true, right); h.send(61, false)
            check(h.output.isEmpty && h.down == 1 && h.up == 1, "绑定右 Option 时同样隔离")
        }
        for kind: CGEventType in [.leftMouseDown, .rightMouseDown, .scrollWheel, .otherMouseDown] {
            let h = Harness(); h.send(58, true, option)
            let e = CGEvent(source: nil)!; e.type = kind; e.flags = CGEventFlags(rawValue: option)
            h.send(e); h.send(58, false)
            check(h.output.count == 3 && h.output[0].type == .flagsChanged && h.output[1].type == kind && h.cancelled == 1, "Option+鼠标操作补回修饰键并取消录音")
        }
        do {
            let h = Harness(); h.send(58, true, option)
            let move = CGEvent(source: nil)!; move.type = .mouseMoved; move.flags = CGEventFlags(rawValue: option)
            h.send(move); h.send(58, false)
            check(h.output.count == 1 && h.output[0].flags.rawValue & option == 0 && h.cancelled == 0, "录音时移动鼠标不泄漏 Alt，也不取消录音")
        }
        do {
            let h = Harness(); h.send(59, true, control); h.send(58, true, control | option)
            h.send(3, true, control | option); h.send(3, false, control | option)
            h.send(58, false, control); h.send(59, false)
            check(h.keys == [59, 58, 3, 3, 58, 59] && h.down == 0, "Ctrl 先按下的多修饰键组合不丢事件、不录音")
        }
        do {
            let h = Harness(); h.send(58, true, option); h.send(59, true, control | option)
            h.send(3, true, control | option); h.send(3, false, control | option)
            h.send(59, false, option); h.send(58, false)
            check(h.keys == [58, 59, 3, 3, 59, 58] && h.cancelled == 1, "Option 先按下的多修饰键组合完整放行")
        }
        do {
            let h = Harness(); h.send(58, true, option); h.remote = false; h.hotkey.codes = [96]
            h.send(58, false); h.send(0, true)
            check(h.keys == [0], "中途切应用或改绑定仍吞掉对应松开，不补过期 Alt")
        }
        do {
            let router = RemoteOption()
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: true)!; e.flags = CGEventFlags(rawValue: option)
            _ = router.route(e, enabled: true, codes: [58], remote: true)
            router.resync(flags: 0, keyDown: { _ in false })
            let a = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!; a.flags = []
            check(router.route(a, enabled: true, codes: [58], remote: true).replay == nil, "漏收松开后重同步清除延期 Alt")
        }
        do {
            let h = Harness(); h.send(58, true, option); h.hotkey.paused = true; h.send(58, false)
            h.hotkey.paused = false; h.send(58, true, option); h.send(58, false)
            check(h.output.isEmpty && h.down == 2 && h.up == 2, "按住时暂停不会遗留本机热键状态")
        }
        do {
            let h = Harness(); h.send(0, true); h.send(58, true, option); h.send(0, false, option); h.send(58, false)
            check(h.keys == [0, 58, 0, 58] && h.down == 0, "普通键先按下再按 Option 也保留组合操作")
        }
        do {
            let h = Harness(); h.send(58, true, CGEventFlags.maskControl.rawValue | option); h.send(58, false, CGEventFlags.maskControl.rawValue)
            check(h.keys == [58, 58] && h.down == 0, "只带通用 Control 位也不误判成单按")
        }
        do {
            let h = Harness(); var captured: UInt16?
            h.hotkey.beginCapture { captured = $0 }
            h.send(58, true, option); h.send(58, false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            check(h.keys == [58, 58] && captured == 58 && h.down == 0, "录制快捷键设置不经过隔离")
        }
        print("Hotkey: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
