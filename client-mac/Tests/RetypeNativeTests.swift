// 原生 AX 与生产菜单集成测试；由 tools/retype_native_test.py 在隔离窗口中运行。
// 仅按下本测试菜单项，粘贴按键记录在内存，不发往真实应用或远端。
import Cocoa
@main enum RetypeNativeTests {
    static var passed = 0, failed = 0, serial = 0
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOCUS_TEST_DIR"]!)
    static var pid: pid_t = 0
    static func check(_ ok: Bool, _ name: String) { if ok { passed += 1 } else { failed += 1;print("FAIL: \(name)") } }
    static func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true };RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
        return condition()
    }
    static func command(_ op: String) {
        serial += 1
        try! JSONSerialization.data(withJSONObject: ["serial": serial,"op": op]).write(to: root.appendingPathComponent("command.json"), options: .atomic)
        check(wait(4) {
            guard let d = try? Data(contentsOf: root.appendingPathComponent("ack.json")),let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
            return obj["serial"] as? Int == serial
        }, "fixture completed \(op)")
    }
    static func observe(beforeMenu: Bool = false) -> RetypeFocus.Observation? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let target = PasteTarget(pid: pid, bundleID: "com.carriez.rustdesk", rustDeskSession: RustDeskPaste.current(pid: pid, directory: root.appendingPathComponent("peers")))
        return RetypeFocus.observe(beforeMenu: beforeMenu, target: target)
    }
    static func run() {
        guard AXIsProcessTrusted() else { print("BLOCKED: 原生测试需要辅助功能权限及已解锁的桌面");exit(3) }
        pid = pid_t(try! String(contentsOf: root.appendingPathComponent("host.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        command("canvas")
        let ready = wait(4) { RetypeFocus.capture(observe()) != nil }
        check(ready, "real AX group in confirmed fixture session captured")
        if !ready {
            print("Native observation:",observe()?.role as Any,"blocked",observe()?.blocked as Any,"inWindow",observe()?.inFocusedWindow as Any,"front",NSWorkspace.shared.frontmostApplication?.processIdentifier as Any)
            if let e = EditWatcher.focused() { print("Focused role:",EditWatcher.role(e)) }
            print("NativeFocus: \(passed) passed, \(failed) failed");exit(1)
        }
        check(RecentRepeat.Context.current()?.eligible == false,"普通应用的 AXGroup 不作快捷重贴输入框")
        let captured = RetypeFocus.capture(observe())!
        for op in ["field","button","modal","launcher"] {
            command(op)
            check(wait(3) { RetypeFocus.capture(observe()) == nil }, "real \(op) excluded from remote fast path")
            if op == "field" {
                check(EditWatcher.strayFocus(from: nil) == nil, "normal native text field still accepted")
                check(RecentRepeat.Context.current()?.eligible == true,"原生文本框可以快捷重贴")
            }
            if op == "button" {
                check(EditWatcher.strayFocus(from: nil) != nil, "native button still classified as stray")
                check(RecentRepeat.Context.current()?.eligible == false,"原生按钮不能快捷重贴")
            }
        }
        for op in ["session","window"] {
            command(op);check(wait(3) { !captured.matches(observe()) }, "real \(op) identity change detected")
        }
        command("canvas");check(wait(3) { RetypeFocus.capture(observe()) != nil }, "canvas restored")
        let text = "NBIME_RETYPE_NATIVE_123", pb = NSPasteboard.withUniqueName()
        pb.clearContents();pb.setString("BEFORE",forType: .string)
        var pasted: Date?, actionAt: Date?, regular = false, cancelled = false, prepared = false
        var observations: [RetypeFocus.Observation?] = []
        let action = RetypeAction(observe: { beforeMenu in
            let o = observe(beforeMenu: beforeMenu);observations.append(o)
            return o
        })
        let delivery = PasteDelivery(pasteboard: pb, target: { observe()?.target }, post: { event in
            if event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 9 { pasted = Date() }
        }, log: { print($0) })
        let bar = MenuBar(recentEntries: { [HistoryEntry(text: text,date: Date(),seconds: 0,app: "fixture")] }, hotkeys: { [] }, editedCount: { 0 }, retypeAction: action)
        bar.onRetype = { value, valid in
            if let valid { delivery.paste(value,restore: true,validating: valid) } else { regular = true }
        }
        bar.onRetypeCancelled = { cancelled = true }
        // 定位生产菜单项；只在 AX 命中本进程的测试标题时执行 Press。
        bar.menuNeedsUpdate(bar.menu)
        let item = bar.menu.items.first { $0.title.contains(text) }!
        var point = CGPoint(x: 350, y: NSScreen.screens[0].frame.height - 350)
        let select = Timer(timeInterval: 0.3, repeats: false) { _ in
            var hit: AXUIElement?
            var selected: AXUIElement?
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit)
            var owner: pid_t = 0;var title: CFTypeRef?
            if let hit { AXUIElementGetPid(hit,&owner);AXUIElementCopyAttributeValue(hit,kAXTitleAttribute as CFString,&title) }
            if owner == getpid(), let hit {
                var parent: CFTypeRef?, children: CFTypeRef?
                AXUIElementCopyAttributeValue(hit,kAXParentAttribute as CFString,&parent)
                if let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                    AXUIElementCopyAttributeValue(parent as! AXUIElement,kAXChildrenAttribute as CFString,&children)
                    for child in (children as? [AXUIElement]) ?? [] {
                        var name: CFTypeRef?,pos: CFTypeRef?,size: CFTypeRef?
                        AXUIElementCopyAttributeValue(child,kAXTitleAttribute as CFString,&name)
                        guard (name as? String)?.contains(text) == true else { continue }
                        AXUIElementCopyAttributeValue(child,kAXPositionAttribute as CFString,&pos)
                        AXUIElementCopyAttributeValue(child,kAXSizeAttribute as CFString,&size)
                        var p=CGPoint.zero,z=CGSize.zero
                        if let pos,let size,CFGetTypeID(pos) == AXValueGetTypeID(),CFGetTypeID(size) == AXValueGetTypeID(),
                           AXValueGetValue(pos as! AXValue,.cgPoint,&p),AXValueGetValue(size as! AXValue,.cgSize,&z) {
                            point = CGPoint(x:p.x+z.width/2,y:p.y+z.height/2)
                        }
                    }
                }
                var final: AXUIElement?
                AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&final)
                if let final { selected = final;AXUIElementGetPid(final,&owner);AXUIElementCopyAttributeValue(final,kAXTitleAttribute as CFString,&title) }
            }
            guard owner == getpid(), (title as? String)?.contains(text) == true else { print("fixture menu hit failed",owner,title as Any);bar.menu.cancelTracking();return }
            actionAt = Date()
            if let selected { check(AXUIElementPerformAction(selected,kAXPressAction as CFString) == .success,"native menu AX Press completed") }
        }
        RunLoop.main.add(select, forMode: .common)
        let timeout = Timer(timeInterval: 4,repeats: false) { _ in bar.menu.cancelTracking() }
        RunLoop.main.add(timeout,forMode: .common)
        bar.menu.popUp(positioning: item,at: NSPoint(x:350,y:350),in:nil)
        timeout.invalidate()
        prepared = observations.first.flatMap { RetypeFocus.capture($0) } != nil
        check(prepared, "actual NSMenu needsUpdate sees pre-menu AX focus")
        check(wait(4) { pasted != nil || regular || cancelled }, "actual menu action completed")
        check(!regular && !cancelled && pasted != nil, "actual menu uses validated remote path")
        if let pasted,let actionAt {
            let elapsed = pasted.timeIntervalSince(actionAt);print(String(format:"Native retype key delay %.3fs",elapsed))
            check(elapsed < 3.5 && elapsed >= 0.7,"no fixed four-second focus wait; synchronization delay retained")
        }
        check(wait(4) { pb.string(forType: .string) == "BEFORE" }, "native paste queue restored isolated clipboard")
        pasted = nil
        var tapTime = 0.0, captures = 0, repeated = 0
        let quick = RecentRepeat(recent: { HistoryEntry(text:text,date:Date(timeIntervalSince1970:100),seconds:0,app:"fixture") },context: {
            captures += 1
            guard let o = observe() else { return nil }
            return RecentRepeat.Context(target:o.target,element:o.element,editable:false,remote:o)
        })
        let keys = Hotkey(codes:[63],now:{tapTime})
        keys.onRepeatPrepare = {
            guard let o = observe() else { return }
            quick.prepare(expectedPID:pid,expectedElement:o.element)
        }
        keys.onRepeat = { repeated += 1;quick.send(paste:{ value,valid in delivery.paste(value,restore:true,validating:valid) },rejected:{ cancelled = true }) }
        func key(_ down:Bool) {
            let e=CGEvent(keyboardEventSource:nil,virtualKey:63,keyDown:down)!
            e.type = .flagsChanged;e.flags=CGEventFlags(rawValue:down ? 0x800000 : 0)
            _ = keys.process(e,remote:{true},replay:{_ in})
        }
        key(true);check(wait(2){captures > 0},"首次按下异步捕获原生焦点")
        tapTime=0.05;key(false);tapTime=0.15;key(true);tapTime=0.2;key(false)
        check(repeated == 0 && pasted == nil && pb.string(forType:.string) == "BEFORE","前两次短按不重贴也不写剪贴板")
        tapTime=0.3;key(true);tapTime=0.35;actionAt=Date();key(false)
        check(repeated == 1,"第三次完整短按调用生产重贴协调器")
        check(wait(4){pasted != nil || cancelled} && pasted != nil && !cancelled,"三连按经真实 AX 焦点校验后进入粘贴队列")
        if let pasted,let actionAt { check(pasted.timeIntervalSince(actionAt) >= 0.7 && pasted.timeIntervalSince(actionAt) < 3.5,"快捷重贴保留同步等待且没有固定四秒等待") }
        check(wait(4){pb.string(forType:.string) == "BEFORE"},"快捷重贴恢复独立剪贴板")
        pb.releaseGlobally()
        print("NativeFocus: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
    static func main() { let app = NSApplication.shared;app.setActivationPolicy(.accessory);let start = Timer(timeInterval: 0.1,repeats: false) { _ in run() };RunLoop.main.add(start,forMode: .common);app.run() }
}
