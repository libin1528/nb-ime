import Cocoa

/// RustDesk 的单独 Option 录音手势留在本机。确认是组合操作后，先补回按下，再放行。
final class RemoteOption {
    struct Route {
        var swallow = false
        var replay: CGEvent?
        var combination = false
        var beganCombination = false
    }
    private var deferred: CGEvent?
    private var activeCode: UInt16?
    private var forwarding = false
    private var keysDown = Set<UInt16>()

    func route(_ event: CGEvent, enabled: Bool, codes: [UInt16], remote: Bool) -> Route {
        let type = event.type
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        defer {
            if type == .keyDown { keysDown.insert(code) }
            if type == .keyUp { keysDown.remove(code) }
        }
        if let active = activeCode {
            let mask = Hotkey.modifierMasks[active]!
            if type == .flagsChanged, code == active, flags & mask == 0 {
                let result = Route(swallow: !forwarding, combination: forwarding)
                deferred = nil; activeCode = nil; forwarding = false
                return result
            }
            // 鼠标移动也携带 Option 标志；录音期间去掉它，避免远端合成 Alt 按下。
            if type == .mouseMoved {
                if !forwarding { event.flags = CGEventFlags(rawValue: flags & ~mask & ~CGEventFlags.maskAlternate.rawValue) }
                return Route(combination: forwarding)
            }
            if !forwarding, type == .flagsChanged, code == active { return Route(swallow: true) }
            let result = Route(replay: deferred, combination: true, beganCombination: !forwarding)
            deferred = nil; forwarding = true
            return result
        }
        let otherModifiers: UInt64 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x2000
            | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
        if enabled, remote, type == .flagsChanged, code == 58 || code == 61,
           codes.contains(code), let mask = Hotkey.modifierMasks[code], flags & mask != 0 {
            activeCode = code
            if flags & (otherModifiers & ~mask) != 0 || !keysDown.isEmpty {
                forwarding = true
                return Route(combination: true, beganCombination: true)
            }
            deferred = event.copy()
            return Route(swallow: true)
        }
        return Route()
    }

    /// 钩子恢复时清掉已松开的延期事件，不能在之后的普通输入前补一个过期的 Alt。
    func resync(flags: UInt64, keyDown: (UInt16) -> Bool) {
        keysDown = keysDown.filter(keyDown)
        if let code = activeCode, flags & Hotkey.modifierMasks[code]! == 0 {
            deferred = nil; activeCode = nil; forwarding = false
        }
    }
}
