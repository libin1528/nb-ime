// 菜单栏：图标本身就是状态（平时单色 NB，说话时声波变红，识别中声波轮流亮，连不上 / 暂停时变灰）。
// 菜单参考微信输入法，只放每天会碰的东西（design/mockup.html 第 3 节）。

import Cocoa

final class MenuBar: NSObject, NSMenuDelegate {
    enum Status: Equatable {
        case ready              // 已连接，可以说
        case offline            // 连不上
        case needsAccess        // 没有辅助功能权限
        case paused
    }

    struct State: Equatable {
        var status = Status.offline
        var recording = false
        var thinking = false
    }

    var onPause: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onSettings: (() -> Void)?
    var onAccess: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = MenuHeader()
    private var state = State()
    private var spin: Timer?
    private var spinFrame = 0

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "NB 输入法"
        update(state)
    }

    func update(_ s: State) {
        state = s
        if s.thinking && !s.recording {
            if spin == nil {
                let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.spinFrame += 1
                    self.statusItem.button?.image = Glyph.menuBarImage(.thinking(self.spinFrame))
                }
                RunLoop.main.add(t, forMode: .common)
                spin = t
            }
        } else {
            spin?.invalidate()
            spin = nil
        }
        let glyph: Glyph.MenuState = s.recording ? .recording : s.thinking ? .thinking(spinFrame) : s.status == .ready ? .normal : .dimmed
        statusItem.button?.image = Glyph.menuBarImage(glyph)
        header.status = s.status
        if menu.numberOfItems > 0 { rebuild() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        header.hotkey = Hotkey.keyLabel(Settings.current.hotkeyCode)
        let head = NSMenuItem()
        head.view = header
        menu.addItem(head)
        menu.addItem(.separator())

        // 最近识别：二级菜单列最近 5 条，点一下复制；最新一条直接摆在外面
        let recent = Array(History.items.prefix(5))
        let sub = NSMenu()
        for e in recent { sub.addItem(copyItem(e.text, width: 300)) }
        if recent.isEmpty {
            let none = NSMenuItem(title: "还没有记录", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        let recentItem = NSMenuItem(title: "最近识别", action: nil, keyEquivalent: "")
        recentItem.submenu = sub
        menu.addItem(recentItem)
        if let last = recent.first { menu.addItem(copyItem(last.text, width: 200, hint: "复制")) }
        menu.addItem(.separator())

        switch state.status {
        case .offline:
            menu.addItem(item("重新连接", "") { [weak self] in self?.onReconnect?() })
        case .needsAccess:
            menu.addItem(item("打开辅助功能权限…", "") { [weak self] in self?.onAccess?() })
        default:
            break
        }
        let pause = item("暂停语音输入", "") { [weak self] in self?.onPause?() }
        pause.state = state.status == .paused ? .on : .off
        menu.addItem(pause)
        menu.addItem(item("设置…", ",") { [weak self] in self?.onSettings?() })
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, _ key: String, _ f: @escaping () -> Void) -> NSMenuItem {
        let m = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.run), keyEquivalent: key)
        m.target = m
        m.f = f
        return m
    }

    /// 「“提个 bug，我一说 ClawChat，它就…”      复制」
    private func copyItem(_ text: String, width: CGFloat, hint: String? = nil) -> NSMenuItem {
        let font = NSFont.menuFont(ofSize: 0)
        var shown = text.replacingOccurrences(of: "\n", with: " ")
        let fits = { (s: String) in ("“\(s)”" as NSString).size(withAttributes: [.font: font]).width <= width }
        if !fits(shown) {
            while !shown.isEmpty, !fits(shown + "…") { shown.removeLast() }
            shown += "…"
        }
        let m = item("“\(shown)”", "") { Paster.copy(text) }
        m.toolTip = text
        if let hint {
            let ps = NSMutableParagraphStyle()
            ps.tabStops = [NSTextTab(textAlignment: .right, location: 300)]
            let s = NSMutableAttributedString(string: "“\(shown)”", attributes: [.font: font, .paragraphStyle: ps])
            s.append(NSAttributedString(string: "\t" + hint, attributes: [
                .font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: ps,
            ]))
            m.attributedTitle = s
        }
        return m
    }

    /// 截图用：把菜单点开
    func popUp() { statusItem.button?.performClick(nil) }
}

private final class ClosureMenuItem: NSMenuItem {
    var f: (() -> Void)?
    @objc func run() { f?() }
}

/// 菜单第一行：连接状态 + 当前快捷键
private final class MenuHeader: NSView {
    var status = MenuBar.Status.offline { didSet { needsDisplay = true } }
    var hotkey = "" { didSet { needsDisplay = true } }

    init() { super.init(frame: NSRect(x: 0, y: 0, width: 284, height: 52)) }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let (color, title): (NSColor, String) = {
            switch status {
            case .ready: return (UI.green, "已连接 ITX")
            case .offline: return (UI.orange, "连不上 ITX · 正在重试")
            case .needsAccess: return (UI.orange, "需要打开辅助功能权限")
            case .paused: return (.tertiaryLabelColor, "已暂停语音输入")
            }
        }()
        let x: CGFloat = 14
        color.withAlphaComponent(0.2).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 3, y: 9, width: 14, height: 14)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 12, width: 8, height: 8)).fill()
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        (title as NSString).draw(at: NSPoint(x: x + 15, y: 7), withAttributes: bold)

        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let y: CGFloat = 30
        var cx = x
        ("按住" as NSString).draw(at: NSPoint(x: cx, y: y), withAttributes: small)
        cx += ("按住 " as NSString).size(withAttributes: small).width
        let capFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let capW = (hotkey as NSString).size(withAttributes: [.font: capFont]).width + 12
        let cap = NSRect(x: cx, y: y, width: capW, height: 17)
        let p = NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5)
        UI.chipBG.setFill()
        p.fill()
        NSColor.tertiaryLabelColor.setStroke()
        p.lineWidth = 0.5
        p.stroke()
        (hotkey as NSString).draw(at: NSPoint(x: cx + 6, y: y + 1), withAttributes: [.font: capFont, .foregroundColor: NSColor.labelColor])
        (" 说话" as NSString).draw(at: NSPoint(x: cap.maxX + 1, y: y), withAttributes: small)
    }
}
