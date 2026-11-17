// 全局热键：用 CGEventTap（.defaultTap）听键盘。NSEvent 的全局监听在有的机器上收不到修饰键。
// 修饰键当热键时原样放行；RustDesk 中单按 Option 留在本机，组合操作完整放行。
// 普通键当热键时吞掉，免得打出字来。
// 可以设两个快捷键，效果一样；两个同时按着只算一次，都松开了才算松开。
// 鼠标侧键（左右键以外的键）也能当快捷键，存成 1000 + 按键号，和键盘的 keyCode 不会撞；按下时同样吞掉，免得浏览器跟着后退。

import Cocoa

final class Hotkey {
    var codes: [UInt16] {
        didSet {
            repeatTap.cancel()
            // 改掉的键正按着的话当它松开了
            for c in held where !codes.contains(c) { press(c, false, note: "（快捷键改了）") }
        }
    }
    var paused = false { didSet { if paused != oldValue { repeatTap.cancel() } } } // 「暂停语音输入」
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onOtherKey: (() -> Void)?    // 按住热键时又按了别的键
    var onRepeatPrepare: (() -> Void)?
    var onRepeat: (() -> Void)?
    var tapThreshold: () -> TimeInterval = { 0.3 }
    private(set) var installed = false
    private var tap: CFMachPort?
    private var held = Set<UInt16>()          // 正按着的快捷键
    private var capture: ((UInt16?) -> Void)?
    private let remoteOption = RemoteOption()
    private let repeatTap: ShortTapRepeat
    private var repeatBlocked = false

    init(codes: [UInt16], now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.codes = codes
        self.repeatTap = ShortTapRepeat(now: now)
    }

    func install() -> Bool {
        guard !installed else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, info in
                let me = Unmanaged<Hotkey>.fromOpaque(info!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    Log.w("事件钩子被系统停用（\(type == .tapDisabledByTimeout ? "超时" : "系统输入保护")），重新打开")
                    if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    // 停用期间可能漏掉了松开，按现在实际按着的键对一遍
                    me.resync()
                    return Unmanaged.passUnretained(event)
                }
                return me.process(event, remote: {
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.carriez.rustdesk"
                }, replay: { $0.tapPostEvent(proxy) }) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: me)
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        installed = true
        return true
    }

    /// 等用户按下新的快捷键；nil 表示按了 Esc 取消
    func beginCapture(_ done: @escaping (UInt16?) -> Void) { repeatTap.cancel(); capture = done }
    func cancelCapture() { capture = nil }
    func cancelRepeat() { repeatTap.cancel() }
    var capturing: Bool { capture != nil }

    // 修饰键：keyCode → 区分左右的设备位
    static let modifierMasks: [UInt16: UInt64] = [
        61: 0x40, 58: 0x20,       // 右 / 左 Option
        54: 0x10, 55: 0x08,       // 右 / 左 Command
        60: 0x04, 56: 0x02,       // 右 / 左 Shift
        62: 0x2000, 59: 0x01,     // 右 / 左 Control
        63: 0x800000,             // Fn
    ]

    static let mouseBase: UInt16 = 1000
    static func isMouse(_ code: UInt16) -> Bool { code >= mouseBase }

    static func keyName(_ code: UInt16) -> String {
        if isMouse(code) {
            // 按键号从 0 数：2 是中键，3、4 一般是两个侧键（鼠标驱动里常叫「按键 4 / 5」）
            let n = code - mouseBase
            return n == 2 ? "鼠标中键" : "鼠标侧键 \(n + 1)"
        }
        let names: [UInt16: String] = [
            61: "右 Option", 58: "左 Option", 54: "右 Command", 55: "左 Command",
            60: "右 Shift", 56: "左 Shift", 62: "右 Control", 59: "左 Control", 63: "Fn",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 49: "空格", 50: "`", 53: "Esc", 36: "回车", 48: "Tab",
        ]
        if let n = names[code] { return n }
        // 其它键按当前键盘布局取字符
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) {
            var len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
            let s = String(utf16CodeUnits: chars, count: len).uppercased()
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return "键 \(code)"
    }

    /// 键帽上的字：「⌥ 左 Option」
    static func keyLabel(_ code: UInt16) -> String {
        let glyph: [UInt16: String] = [61: "⌥", 58: "⌥", 54: "⌘", 55: "⌘", 60: "⇧", 56: "⇧", 62: "⌃", 59: "⌃", 63: "fn"]
        return glyph[code].map { "\($0) \(keyName(code))" } ?? keyName(code)
    }

    /// 「右 Option 或 F5」
    static func describe(_ codes: [UInt16]) -> String { codes.map(keyName).joined(separator: " 或 ") }

    /// 与真实事件钩子共用入口；replay 从当前钩子之后继续传递，不再触发录音热键。
    func process(_ event: CGEvent, remote: () -> Bool, replay: (CGEvent) -> Void) -> Bool {
        let type = event.type
        let code = type == .otherMouseDown || type == .otherMouseUp
            ? Self.mouseBase + UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
            : UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let generic = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
        let ownGeneric: UInt64
        switch code {
        case 54, 55: ownGeneric = CGEventFlags.maskCommand.rawValue
        case 58, 61: ownGeneric = CGEventFlags.maskAlternate.rawValue
        case 59, 62: ownGeneric = CGEventFlags.maskControl.rawValue
        case 56, 60: ownGeneric = CGEventFlags.maskShift.rawValue
        default: ownGeneric = 0
        }
        let devices = Self.modifierMasks.values.reduce(UInt64(0), |) & ~0x800000
        let ownDevice = Self.modifierMasks[code] ?? 0
        repeatBlocked = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp].contains(type)
            && event.flags.rawValue & ((generic | devices) & ~ownGeneric & ~ownDevice) != 0
        if repeatBlocked { repeatTap.cancel() }
        if [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp].contains(type) {
            if !codes.contains(code) { repeatTap.cancel() }
        } else if [.leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
            repeatTap.cancel()
        }
        let isOption = event.type == .flagsChanged && [58, 61].contains(Int(event.getIntegerValueField(.keyboardEventKeycode)))
        let routed = remoteOption.route(event, enabled: !paused && capture == nil, codes: codes,
                                        remote: isOption && remote())
        if routed.beganCombination { repeatTap.cancel(); onOtherKey?() }
        if let original = routed.replay { replay(original) }
        if routed.swallow || routed.combination, event.type == .flagsChanged {
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if held.contains(code), let mask = Self.modifierMasks[code], event.flags.rawValue & mask == 0 {
                press(code, false)
            }
        }
        if routed.combination {
            // 包括 Option+另一个录音热键：它属于组合键，不吞键，也不另开录音。
            return false
        }
        let handled = handle(event.type, event)
        return routed.swallow || handled
    }

    /// 返回 true 表示吞掉这个事件
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp].contains(type) else { return false }
        if type == .otherMouseDown || type == .otherMouseUp {
            let code = Self.mouseBase + UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
            if let capture {
                guard type == .otherMouseDown else { return true }
                self.capture = nil
                Log.w("录到快捷键 \(Self.keyName(code))")
                DispatchQueue.main.async { capture(code) }
                return true
            }
            guard !paused, codes.contains(code) else { return false }
            let down = type == .otherMouseDown
            if down != held.contains(code) { press(code, down) }
            return true
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        if let capture { return captureKey(type, code, flags, capture) }
        if paused { return false }
        let ours = codes.contains(code)

        // 修饰键的松开漏收了（比如钩子被停用过），下一次修饰键变化时按标志位补上
        if type == .flagsChanged {
            for c in held where c != code {
                if let m = Self.modifierMasks[c], flags & m == 0 { press(c, false, note: "（没收到松开，补上）") }
            }
        }

        if let mask = Self.modifierMasks[code] {
            if type == .flagsChanged, ours {
                let down = flags & mask != 0
                if down != held.contains(code) { press(code, down) }
            }
            return false
        }

        // 普通键当热键：只认不带修饰键的单按（另一个修饰键快捷键正按着时除外），按住期间的自动重复也吞掉
        if ours, type == .keyDown || type == .keyUp {
            let mods: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
            if type == .keyDown {
                if held.contains(code) { return true }
                guard flags & mods == 0 || !held.isEmpty else { return false }
                press(code, true)
                return true
            }
            guard held.contains(code) else { return false }
            press(code, false)
            return true
        }

        // 按住修饰键快捷键时又按了别的键
        if type == .keyDown, held.contains(where: { Self.modifierMasks[$0] != nil }) { onOtherKey?() }
        return false
    }

    /// 按住的键里，实际已经松开的补一个松开
    func resync() {
        repeatTap.cancel()
        let src = CGEventSourceStateID.combinedSessionState
        let flags = CGEventSource.flagsState(src).rawValue
        remoteOption.resync(flags: flags, keyDown: { CGEventSource.keyState(src, key: $0) })
        for c in held {
            let down: Bool
            if Self.isMouse(c) {
                down = CGEventSource.buttonState(src, button: CGMouseButton(rawValue: UInt32(c - Self.mouseBase)) ?? .center)
            } else if let m = Self.modifierMasks[c] {
                down = flags & m != 0
            } else {
                down = CGEventSource.keyState(src, key: c)
            }
            if !down { press(c, false, note: "（没收到松开，补上）") }
        }
    }

    /// 第一个按下才算开始，最后一个松开才算结束
    private func press(_ code: UInt16, _ down: Bool, note: String? = nil) {
        let before = held.isEmpty
        if down { held.insert(code) } else { held.remove(code) }
        if note != nil || (down && !before) || (!down && !held.isEmpty) { repeatTap.cancel() }
        let note = note ?? (before != held.isEmpty ? "" : down ? "（另一个已经按着，不另算一次）" : "（另一个还按着，接着录）")
        Log.w("热键\(down ? "按下" : "松开") \(Self.keyName(code))\(note)")
        if before, !held.isEmpty {
            let began = !repeatBlocked && repeatTap.down(code)
            onDown?()
            if began { onRepeatPrepare?() }
        } else if !before, held.isEmpty {
            let repeated = repeatTap.up(code, threshold: tapThreshold())
            onUp?()
            if repeated { onRepeat?() }
        }
    }

    private func captureKey(_ type: CGEventType, _ code: UInt16, _ flags: UInt64, _ done: @escaping (UInt16?) -> Void) -> Bool {
        switch type {
        case .flagsChanged:
            // 修饰键在按下那一刻记下
            guard let mask = Self.modifierMasks[code], flags & mask != 0 else { return false }
        case .keyDown:
            if code == 53 {
                capture = nil
                DispatchQueue.main.async { done(nil) }
                return true
            }
        default:
            return true
        }
        capture = nil
        Log.w("录到快捷键 \(Self.keyName(code))（keyCode=\(code)）")
        DispatchQueue.main.async { done(code) }
        return type == .keyDown
    }
}
