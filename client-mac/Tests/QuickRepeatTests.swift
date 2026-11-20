// swiftc -swift-version 5 $(rg --files Sources -g '*.swift' | rg -v '/main.swift$') Tests/PasteClock.swift Tests/QuickRepeatTests.swift -o /tmp/nbime-quick-repeat-tests
// 从生产 Hotkey.process 进入 RecentRepeat 和 PasteDelivery；不安装钩子、不开麦、不发远端按键。
import Cocoa

@main enum QuickRepeatTests {
    static var passed = 0, failed = 0
    static func check(_ ok: @autoclosure () -> Bool, _ name: String) {
        if ok() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static let option = CGEventFlags.maskAlternate.rawValue | 0x20
    static let control = CGEventFlags.maskControl.rawValue | 0x1
    static func context(remote: Bool = true, pid: pid_t = 42, element: pid_t = 100, peer: String = "one", editable: Bool = true) -> RecentRepeat.Context {
        let focus = AXUIElementCreateApplication(element)
        let target = PasteTarget(pid: pid, bundleID: remote ? "com.carriez.rustdesk" : "com.example.editor",
                                 rustDeskSession: remote ? RustDeskPasteSession(peer: peer,platform: "Windows",swapped: false) : nil)
        let canvas = RetypeFocus.Observation(target: target,element: focus,window: AXUIElementCreateApplication(200),role: "AXGroup",inFocusedWindow: true,blocked: false)
        return RecentRepeat.Context(target: target,element: focus,editable: editable,remote: remote ? canvas : nil)
    }
    final class Harness {
        let clock = PasteClock(), pb = NSPasteboard.withUniqueName()
        let hotkey: Hotkey
        var current: RecentRepeat.Context? = QuickRepeatTests.context()
        var latest: HistoryEntry? = HistoryEntry(text: "原句 Claw、Cloud。\n第二行🙂",date: Date(timeIntervalSince1970: 100),seconds: 1,app: "test")
        var prepared = 0, requested = 0, rejected = 0, pasted: [String] = [], order: [String] = []
        var threshold = 0.3
        lazy var repeatInput = RecentRepeat(recent: { [unowned self] in latest },context: { [unowned self] in current },later: clock.later)
        lazy var delivery = PasteDelivery(pasteboard: pb,target: { [unowned self] in current?.target },post: { [unowned self] e in
            if e.type == .keyDown && e.getIntegerValueField(.keyboardEventKeycode) == 9 { pasted.append(pb.string(forType: .string) ?? "") }
        },later: clock.later,log: { _ in })
        init(_ codes: [UInt16] = [58,96,1003]) {
            let timer = clock
            hotkey = Hotkey(codes: codes,now: { timer.now })
            hotkey.tapThreshold = { [unowned self] in threshold }
            hotkey.onDown = { [unowned self] in order.append("down") }
            hotkey.onUp = { [unowned self] in order.append("up") }
            hotkey.onRepeatPrepare = { [unowned self] in prepared += 1;repeatInput.prepare() }
            hotkey.onRepeat = { [unowned self] in
                requested += 1;order.append("repeat")
                repeatInput.send(paste: { [unowned self] text,valid in delivery.paste(text,restore: true,validating: valid) },rejected: { [unowned self] in rejected += 1 })
            }
            pb.setString("原剪贴板",forType: .string)
        }
        func key(_ code: UInt16, _ down: Bool, flags: UInt64? = nil) {
            let e = CGEvent(keyboardEventSource: nil,virtualKey: code,keyDown: down)!
            if let mask = Hotkey.modifierMasks[code] {
                e.type = .flagsChanged
                let generic: UInt64 = [58,61].contains(code) ? CGEventFlags.maskAlternate.rawValue : [59,62].contains(code) ? CGEventFlags.maskControl.rawValue : 0
                e.flags = CGEventFlags(rawValue: flags ?? (down ? generic | mask : 0))
            } else { e.flags = CGEventFlags(rawValue: flags ?? 0) }
            _ = hotkey.process(e,remote: { self.current?.target.isRustDesk == true },replay: { _ in })
        }
        func mouse(_ type: CGEventType, button: Int64 = 3) {
            let e = CGEvent(source: nil)!;e.type = type;e.flags = [];e.setIntegerValueField(.mouseEventButtonNumber,value: button)
            _ = hotkey.process(e,remote: { self.current?.target.isRustDesk == true },replay: { _ in })
        }
        func tap(_ code: UInt16 = 58, duration: Double = 0.05, gap: Double = 0.1) {
            if Hotkey.isMouse(code) { mouse(.otherMouseDown,button: Int64(code-1000)) } else { key(code,true) }
            clock.advance(duration)
            if Hotkey.isMouse(code) { mouse(.otherMouseUp,button: Int64(code-1000)) } else { key(code,false) }
            clock.advance(gap)
        }
        func triple(_ code: UInt16 = 58) { for _ in 0..<3 { tap(code) } }
        deinit { pb.releaseGlobally() }
    }
    static func main() {
        _ = NSApplication.shared
        for remote in [false,true] {
            for code: UInt16 in [58,63,96,1003,1004] {
                let h = Harness([code]);h.current = context(remote: remote);let original = h.latest!.text
                h.triple(code)
                check(h.requested == 1 && h.prepared == 1,"键盘修饰键、普通键和鼠标侧键三次完整短按只触发一次")
                check(h.order == ["down","up","down","up","down","up","repeat"],"第三次松开先结束短按，不推迟正常按下和松开回调")
                h.clock.advance(4)
                check(h.pasted == [original],"逐字重贴最终结果，保留 Claw、Cloud、标点和换行")
                check(h.pb.string(forType: .string) == "原剪贴板","本机和远程仍恢复原剪贴板")
            }
        }
        for interrupt in [false, true] {
            let h = Harness([63,1004])
            for i in 0..<3 {
                h.key(63,true,flags: 0x800100)
                h.clock.advance(0.10)
                h.key(63,false,flags: 0x100)
                h.key(179,true,flags: 0x100)
                h.key(179,false,flags: 0x100)
                if interrupt && i == 1 { h.key(0,true); h.key(0,false) }
                h.clock.advance(0.05)
            }
            h.clock.advance(4)
            check(h.pasted == (interrupt ? [] : [h.latest!.text]),"地球键附带事件属于同一次短按，真正的其他输入仍打断连击")
        }
        for count in [1,2] {
            let h = Harness();for _ in 0..<count { h.tap() };h.clock.advance(4)
            check(h.pasted.isEmpty && h.requested == 0,"一两次短按不输入，也不覆盖最近结果")
        }
        for duration in [0.3,0.5,1.2] {
            let h = Harness();h.tap();h.tap(duration: duration);h.tap();h.clock.advance(4)
            check(h.requested == 0 && h.pasted.isEmpty,"任意一次达到起录阈值就不是三连按")
        }
        do {
            let h = Harness();h.threshold = 0.1;h.tap();h.tap(duration: 0.15);h.tap();h.clock.advance(4)
            check(h.requested == 0,"沿用用户当前的起录阈值")
        }
        for ending in [1.0,1.001] {
            let h = Harness();h.tap(gap: 0.1);h.tap(gap: 0.1)
            h.clock.advance(ending-h.clock.now-0.05);h.tap(gap: 0);h.clock.advance(4)
            check(h.requested == (ending == 1 ? 1 : 0),"一秒窗口从首次按下计到第三次松开")
        }
        do {
            let h = Harness();h.key(96,true);for _ in 0..<5 { h.key(96,true) };h.clock.advance(0.1);h.key(96,false);h.clock.advance(4)
            check(h.requested == 0 && h.order == ["down","up"],"按住时自动重复不算多次按下")
        }
        for kind: CGEventType in [.leftMouseDown,.rightMouseDown,.scrollWheel,.otherMouseDown] {
            let h = Harness();h.tap();h.tap();h.mouse(kind,button: 4);h.tap();h.clock.advance(4)
            check(h.requested == 0,"点击、滚动或未绑定鼠标键打断连击")
        }
        do {
            let h = Harness();h.tap();h.tap();h.key(0,true);h.key(0,false);h.tap();h.clock.advance(4)
            check(h.requested == 0,"普通打字打断连击")
        }
        for remote in [false,true] {
            let h = Harness();h.current = context(remote: remote)
            for _ in 0..<3 { h.key(59,true,flags: control);h.key(58,true,flags: control|option);h.clock.advance(0.05);h.key(58,false,flags: control);h.key(59,false) }
            h.clock.advance(4);check(h.requested == 0,"本机和远程的组合键不触发重贴")
        }
        do {
            let h = Harness();h.tap(96);h.tap(58);h.tap(96);h.clock.advance(4)
            check(h.requested == 0,"交替敲不同快捷键不算同一键三连按")
        }
        do {
            let h = Harness();h.current = context(remote: false)
            for _ in 0..<3 { h.key(58,true);h.key(96,true,flags: option);h.key(96,false,flags: option);h.key(58,false) }
            h.clock.advance(4);check(h.requested == 0,"两个快捷键同时按着只算原来的录音手势")
        }
        for interrupt in ["pause","codes","capture","resync","settings"] {
            let h = Harness();h.tap();h.tap()
            switch interrupt {
            case "pause":h.hotkey.paused = true;h.hotkey.paused = false
            case "codes":h.hotkey.codes = [58]
            case "capture":h.hotkey.beginCapture { _ in };h.hotkey.cancelCapture()
            case "settings":h.hotkey.cancelRepeat()
            default:h.hotkey.resync()
            }
            h.tap();h.clock.advance(4);check(h.requested == 0,"暂停、改绑定、录制快捷键或钩子恢复清掉旧连击")
        }
        do {
            let h = Harness();h.triple();h.triple();h.clock.advance(8)
            check(h.requested == 2 && h.pasted.count == 2,"每组三次短按各重贴一次，连续重贴仍走串行队列")
        }
        for changed in [context(pid: 43),context(element: 101),context(peer: "two"),context(remote: false)] {
            let h = Harness();h.tap();h.current = changed;h.tap();h.tap();h.clock.advance(4)
            check(h.pasted.isEmpty && h.rejected == 1,"连击期间切换应用、焦点或会话直接取消")
            check(h.pb.string(forType: .string) == "原剪贴板","拒绝时不写剪贴板")
        }
        for missing in ["empty","unreadable","notEditable"] {
            let h = Harness()
            if missing == "empty" { h.latest = nil } else if missing == "unreadable" { h.current = nil } else { h.current = context(remote: false,editable: false) }
            h.triple();h.clock.advance(4)
            check(h.pasted.isEmpty && h.rejected == 1,"无最近结果、读不到焦点或本机非输入区域不猜测粘贴")
        }
        do {
            let h = Harness();h.tap();h.latest = HistoryEntry(text: "新结果",date: Date(timeIntervalSince1970: 101),seconds: 1,app: "test");h.tap();h.tap();h.clock.advance(4)
            check(h.pasted.isEmpty && h.rejected == 1,"连击中收到另一句最终结果，不把手势切换到新句或重贴旧句")
        }
        do {
            let h = Harness();h.triple();h.clock.advance(0.06);h.current = context(element: 101);h.clock.advance(4)
            check(h.pasted.isEmpty,"远程同步等待期间换焦点不发送按键")
        }
        do {
            let h = Harness();h.triple();h.clock.advance(0.06);h.pb.clearContents();h.pb.setString("用户新复制",forType: .string);h.clock.advance(4)
            check(h.pasted.isEmpty && h.pb.string(forType: .string) == "用户新复制","远程同步期间用户复制的内容不被覆盖")
        }
        do {
            let h = Harness();h.triple();h.clock.advance(0.06)
            h.latest = HistoryEntry(text: "更晚的最终结果",date: Date(timeIntervalSince1970: 101),seconds: 1,app: "test")
            h.clock.advance(4)
            check(h.pasted.isEmpty && h.pb.string(forType: .string) == "原剪贴板","发键前收到另一句结果也取消并恢复剪贴板")
        }
        do {
            let h = Harness();h.repeatInput.prepare(expectedPID: 43,expectedElement: h.current!.element)
            h.clock.advance(0);h.repeatInput.send(paste: { _,_ in check(false,"不应在另一进程准备成功") },rejected: { h.rejected += 1 });h.clock.advance(1)
            check(h.rejected == 1,"延后 AX 查询仍核对首次按下的应用")
        }
        do {
            let h = Harness();h.repeatInput.prepare(expectedPID: 42,expectedElement: AXUIElementCreateApplication(101))
            h.clock.advance(0);h.repeatInput.send(paste: { _,_ in check(false,"不应在另一焦点准备成功") },rejected: { h.rejected += 1 });h.clock.advance(1)
            check(h.rejected == 1,"延后 AX 查询仍核对首次按下的焦点")
        }
        do {
            let h = Harness();h.repeatInput.prepare();h.repeatInput.cancel();h.clock.advance(0)
            h.repeatInput.send(paste: { _,_ in check(false,"旧查询不应复活") },rejected: { h.rejected += 1 });h.clock.advance(1)
            check(h.rejected == 1,"取消后异步焦点查询不能复活旧快照")
        }
        do {
            let h = Harness();h.repeatInput.prepare()
            for _ in 0..<2 {
                h.repeatInput.send(paste: { _,_ in check(false,"未准备好的查询不应发出") },rejected: { h.rejected += 1 });h.clock.advance(1)
            }
            check(h.rejected == 2,"手势结束时尚未读到焦点就取消，不给下一次发送遗留快照")
        }
        do {
            let h = Harness();h.tap();h.tap();h.key(58,true)
            let e = CGEvent(source: nil)!;e.type = .mouseMoved;e.flags = CGEventFlags(rawValue: option)
            _ = h.hotkey.process(e,remote: { true },replay: { _ in })
            h.clock.advance(0.05);h.key(58,false);h.clock.advance(4)
            check(h.pasted.count == 1,"普通鼠标移动不把短按误判为组合键")
        }
        print("QuickRepeat: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
