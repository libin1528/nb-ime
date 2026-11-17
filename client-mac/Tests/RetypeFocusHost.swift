// 独立 AppKit 焦点测试宿主；不读取用户历史或真实 RustDesk 配置。
import Cocoa
final class Canvas: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
}
final class FocusButton: NSButton { override var acceptsFirstResponder: Bool { true } }
final class Host: NSObject, NSApplicationDelegate {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOCUS_TEST_DIR"]!)
    var window: NSWindow!, canvas: Canvas!, field: NSTextField!, button: NSButton!, other: NSWindow?
    var serial = -1
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 520, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "nbime-focus-test - Remote Desktop - RustDesk"
        canvas = Canvas(frame: NSRect(x: 20, y: 100, width: 480, height: 220)); canvas.wantsLayer = true; canvas.layer?.backgroundColor = NSColor.lightGray.cgColor
        field = NSTextField(frame: NSRect(x: 20, y: 50, width: 350, height: 24)); field.placeholderString = "Disposable focus fixture"
        button = FocusButton(title: "Test button", target: nil, action: nil); button.frame = NSRect(x: 390, y: 45, width: 100, height: 32)
        window.contentView?.addSubview(canvas);window.contentView?.addSubview(field);window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps: true);window.makeFirstResponder(canvas)
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [self] _ in poll() }
        try! Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: root.appendingPathComponent("host.pid"))
    }
    func poll() {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("command.json")), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = obj["serial"] as? Int, id != serial else { return }
        serial = id
        let op = obj["op"] as! String
        if op == "quit" { NSApp.terminate(nil); return }
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.close() }
        other?.orderOut(nil)
        window.title = op == "launcher" ? "RustDesk" : op == "session" ? "other-test - Remote Desktop - RustDesk" : "nbime-focus-test - Remote Desktop - RustDesk"
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps: true)
        switch op {
        case "field":window.makeFirstResponder(field)
        case "button":window.makeFirstResponder(button)
        case "modal":
            let alert = NSAlert();alert.messageText = "Disposable modal fixture";alert.addButton(withTitle: "OK");alert.beginSheetModal(for: window) { _ in }
        case "window":
            let w = NSWindow(contentRect: NSRect(x: 130, y: 180, width: 420, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = window.title;let c = Canvas(frame: NSRect(x: 0,y: 0,width: 420,height: 280));w.contentView = c;w.makeKeyAndOrderFront(nil);w.makeFirstResponder(c);other = w
        default:window.makeFirstResponder(canvas)
        }
        try! JSONSerialization.data(withJSONObject: ["serial": id]).write(to: root.appendingPathComponent("ack.json"), options: .atomic)
    }
}
@main enum Main {
    static func main() { let app = NSApplication.shared;let host = Host();app.delegate = host;app.setActivationPolicy(.regular);app.run();withExtendedLifetime(host) {} }
}
