// 手动集成探针：先把 RustDesk 中的空白记事本置前，再运行 --single 或 --combo。
// 使用输入法的应用签名；安装真实 Hotkey 钩子，但不启动录音或识别服务。
import Cocoa

@main enum RemoteOptionProbe {
    static func main() {
        if CommandLine.arguments.contains("--activate") {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.carriez.rustdesk").first?.activate(options: [])
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        guard let target = PasteTarget.frontmost(), target.isRustDesk,
              target.rustDeskSession?.platform == "Windows",
              let mode = CommandLine.arguments.dropFirst().first, ["--single", "--combo"].contains(mode) else {
            print("先聚焦 RustDesk 的 Windows 测试记事本，再指定 --single 或 --combo"); exit(1)
        }
        let hotkey = Hotkey(codes: [58, 96])
        hotkey.onDown = { print("record down") }
        hotkey.onUp = { print("record up") }
        hotkey.onOtherKey = { print("combination: cancel recording") }
        guard hotkey.install() else { print("需要辅助功能权限"); exit(1) }
        let source = CGEventSource(stateID: .privateState)
        let option = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        var sentOption = false
        func send(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.2) {
            guard PasteTarget.frontmost() == target else { return }
            sentOption = true
            send(58, true, option)
        }
        if mode == "--combo" {
            DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
                guard sentOption, PasteTarget.frontmost() == target else { return }
                send(3, true, option); send(3, false, option) // Alt+F 打开记事本文件菜单
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+1) {
            if sentOption { send(58, false, []) }
        }
        let delivery = PasteDelivery(log: { print($0) })
        if mode == "--single" {
            DispatchQueue.main.asyncAfter(deadline: .now()+1.3) {
                guard sentOption, PasteTarget.frontmost() == target else { return }
                delivery.paste("【Option 单按后自动输入成功】", restore: true)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        withExtendedLifetime(hotkey) {}
    }
}
