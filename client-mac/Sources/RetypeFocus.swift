// 菜单重新输入只复用打开菜单前的、已确认 RustDesk 会话焦点，不把普通 AXGroup 当输入框。
import Cocoa

struct RetypeFocus {
    struct Observation {
        let target: PasteTarget
        let element: AXUIElement
        let window: AXUIElement
        let role: String
        let inFocusedWindow: Bool
        let blocked: Bool
    }
    let observed: Observation

    static func capture(_ observation: Observation?) -> RetypeFocus? {
        guard let o = observation, o.target.isRustDesk, o.target.rustDeskSession != nil,
              o.role == "AXGroup", o.inFocusedWindow, !o.blocked else { return nil }
        return RetypeFocus(observed: o)
    }

    func matches(_ observation: Observation?) -> Bool {
        guard let current = Self.capture(observation)?.observed else { return false }
        return current.target == observed.target && CFEqual(current.element, observed.element) && CFEqual(current.window, observed.window)
    }

    static func observe(beforeMenu: Bool = false, target: PasteTarget? = PasteTarget.frontmost()) -> Observation? {
        guard let target, target.isRustDesk, target.rustDeskSession != nil else { return nil }
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let application = AXUIElementCreateApplication(target.pid)
        // 菜单接管全局键盘焦点时，系统的 focused UI element 可能为空；只在捕获阶段读原应用自己的焦点。
        let focused = beforeMenu ? element(value(application, kAXFocusedUIElementAttribute)) : EditWatcher.focused()
        guard let focus = focused else { return nil }
        AXUIElementSetMessagingTimeout(focus, 0.3)
        var pid: pid_t = 0
        guard AXUIElementGetPid(focus, &pid) == .success, pid == target.pid else { return nil }
        guard let window = element(value(application, kAXFocusedWindowAttribute)),
              let owner = element(value(focus, kAXWindowAttribute)) else { return nil }
        var blocked = (value(window, kAXModalAttribute) as? Bool) != false
        if let children = value(window, kAXChildrenAttribute) as? [AXUIElement],
           children.contains(where: { EditWatcher.role($0) == "AXSheet" }) { blocked = true }
        var parent: AXUIElement? = focus
        for _ in 0..<12 {
            guard let p = parent, !CFEqual(p, window) else { break }
            let role = EditWatcher.role(p)
            if ["AXDialog", "AXSheet", "AXToolbar", "AXMenu", "AXMenuBar", "AXPopover", "AXButton", "AXTextField", "AXTextArea", "AXComboBox"].contains(role) { blocked = true }
            parent = element(value(p, kAXParentAttribute))
        }
        return Observation(target: target, element: focus, window: window, role: EditWatcher.role(focus),
                           inFocusedWindow: CFEqual(owner, window), blocked: blocked)
    }
}

final class RetypeAction {
    typealias Valid = () -> Bool
    private let observe: (_ beforeMenu: Bool) -> RetypeFocus.Observation?
    private let later: PasteDelivery.Later
    private var origin: RetypeFocus?

    init(observe: @escaping (Bool) -> RetypeFocus.Observation? = { RetypeFocus.observe(beforeMenu: $0) },
         later: @escaping PasteDelivery.Later = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.observe = observe
        self.later = later
    }

    func prepare() { origin = RetypeFocus.capture(observe(true)) }

    func send(_ text: String, regular: @escaping (String) -> Void,
              remote: @escaping (String, @escaping Valid) -> Void, cancelled: @escaping () -> Void) {
        let captured = origin
        origin = nil
        later(0.15) { [observe] in
            guard let captured else { regular(text); return }
            let valid = { captured.matches(observe(false)) }
            guard valid() else { cancelled(); return }
            remote(text, valid)
        }
    }
}
