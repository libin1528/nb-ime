// 全局热键：用 CGEventTap（.defaultTap）听键盘。NSEvent 的全局监听在有的机器上收不到修饰键。
// 修饰键当热键时原样放行，普通键当热键时吞掉，免得打出字来。

import Cocoa

final class Hotkey {
    var code: UInt16
    var paused = false               // 「暂停语音输入」
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onOtherKey: (() -> Void)?    // 按住热键时又按了别的键
    private(set) var installed = false
    private var tap: CFMachPort?
    private var held = false
    private var capture: ((UInt16?) -> Void)?

    init(code: UInt16) { self.code = code }

    func install() -> Bool {
        guard !installed else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                let me = Unmanaged<Hotkey>.fromOpaque(info!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    Log.w("事件钩子被系统停用，重新打开")
                    if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return me.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: me)
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        installed = true
        return true
    }

    /// 等用户按下新的快捷键；nil 表示按了 Esc 取消
    func beginCapture(_ done: @escaping (UInt16?) -> Void) { capture = done }
    func cancelCapture() { capture = nil }
    var capturing: Bool { capture != nil }

    // 修饰键：keyCode → 区分左右的设备位
    static let modifierMasks: [UInt16: UInt64] = [
        61: 0x40, 58: 0x20,       // 右 / 左 Option
        54: 0x10, 55: 0x08,       // 右 / 左 Command
        60: 0x04, 56: 0x02,       // 右 / 左 Shift
        62: 0x2000, 59: 0x01,     // 右 / 左 Control
        63: 0x800000,             // Fn
    ]

    static func keyName(_ code: UInt16) -> String {
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

    /// 返回 true 表示吞掉这个事件
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        if let capture { return captureKey(type, code, flags, capture) }
        if paused { return false }

        if let mask = Self.modifierMasks[self.code] {
            if type == .flagsChanged, code == self.code {
                let down = flags & mask != 0
                guard down != held else { return false }
                held = down
                Log.w(down ? "热键按下" : "热键松开")
                if down { onDown?() } else { onUp?() }
            } else if type == .keyDown, held {
                onOtherKey?()
            }
            return false
        }

        // 普通键当热键：只认不带修饰键的单按，按住期间的自动重复也吞掉
        guard code == self.code, type == .keyDown || type == .keyUp else { return false }
        let mods: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
        if type == .keyDown {
            if held { return true }
            guard flags & mods == 0 else { return false }
            held = true
            Log.w("热键按下")
            onDown?()
            return true
        }
        guard held else { return false }
        held = false
        Log.w("热键松开")
        onUp?()
        return true
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
        self.code = code
        held = false
        Log.w("快捷键改成 \(Self.keyName(code))（keyCode=\(code)）")
        DispatchQueue.main.async { done(code) }
        return type == .keyDown
    }
}
