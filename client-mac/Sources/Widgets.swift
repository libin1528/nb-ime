// 设置窗口、引导窗口共用的小部件：圆角分组、一行设置、键帽、开关的闭包回调。

import Cocoa

enum UI {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    static let windowBG = dynamic(light: .white, dark: NSColor(hex: 0x1e1e20))
    static let groupBG = dynamic(light: NSColor(hex: 0xf5f5f7), dark: NSColor(white: 1, alpha: 0.05))
    static let groupEdge = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.06))
    static let chipBG = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.1))
    static let green = NSColor(hex: 0x30d158), orange = NSColor(hex: 0xff9f0a)

    static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    static func wrapping(_ s: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor, width: CGFloat) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.preferredMaxLayoutWidth = width
        l.isSelectable = false
        return l
    }

    static func sectionTitle(_ s: String) -> NSView {
        pad(label(s, size: 12, weight: .semibold, color: .secondaryLabelColor), NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0))
    }

    static func footnote(_ s: String, width: CGFloat = 600) -> NSView {
        pad(wrapping(s, width: width), NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    }

    static func pad(_ v: NSView, _ e: NSEdgeInsets) -> NSView {
        let box = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: e.left),
            v.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -e.right),
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: e.top),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -e.bottom),
        ])
        return box
    }

    static func vstack(_ views: [NSView], spacing: CGFloat, align: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = align
        s.spacing = spacing
        return s
    }

    static func hstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    /// 一行设置：左边标题（可带一行说明），右边控件
    static func row(_ title: String, _ detail: String? = nil, _ accessory: NSView) -> NSView {
        var left: [NSView] = [label(title)]
        if let detail { left.append(wrapping(detail, size: 11.5, width: 360)) }
        let l = vstack(left, spacing: 1)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let h = hstack([l, spacer, accessory], spacing: 16)
        h.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        h.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return h
    }

    static func button(_ title: String, primary: Bool = false, _ f: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        if primary { b.keyEquivalent = "\r"; b.bezelColor = .controlAccentColor }
        b.onAction { _ in f() }
        return b
    }

    static func toggle(_ on: Bool, _ f: @escaping (Bool) -> Void) -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .small
        s.state = on ? .on : .off
        s.onAction { f(($0 as! NSSwitch).state == .on) }
        return s
    }

    static func segmented(_ labels: [String], selected: Int, _ f: @escaping (Int) -> Void) -> NSSegmentedControl {
        let s = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        s.selectedSegment = selected
        s.controlSize = .small
        s.onAction { f(($0 as! NSSegmentedControl).selectedSegment) }
        return s
    }
}

// MARK: - 圆角分组：一组设置放进一块浅灰底，行与行之间一条细线

final class GroupView: NSView {
    let stack = NSStackView()

    init(_ rows: [NSView]) {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for r in rows { add(r) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ r: NSView) {
        stack.addArrangedSubview(r)
        r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 10, yRadius: 10)
        UI.groupBG.setFill()
        p.fill()
        UI.groupEdge.setStroke()
        p.lineWidth = 0.5
        p.stroke()
        NSColor.separatorColor.setFill()
        for v in stack.arrangedSubviews.dropFirst() where !v.isHidden {
            NSRect(x: 14, y: v.frame.minY, width: bounds.width - 28, height: 1 / (window?.backingScaleFactor ?? 2)).fill()
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

// MARK: - 键帽：「⌥ 左 Option」

final class KeyCap: NSView {
    var text: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var font: NSFont { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var recording = false { didSet { needsDisplay = true } }
    var pad: CGFloat

    init(_ text: String, size: CGFloat = 11, pad: CGFloat = 6) {
        self.text = text
        self.font = .systemFont(ofSize: size, weight: .semibold)
        self.pad = pad
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width) + pad * 2, height: ceil(s.height) + pad * 0.6 + 2)
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let radius = min(8, r.height * 0.3)
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
            let halo = NSBezierPath(roundedRect: bounds.insetBy(dx: -2, dy: -2), xRadius: radius + 3, yRadius: radius + 3)
            halo.lineWidth = 3
            halo.stroke()
        }
        UI.chipBG.setFill()
        p.fill()
        (recording ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        p.lineWidth = recording ? 1 : 0.5
        p.stroke()
        let color: NSColor = recording ? .controlAccentColor : .labelColor
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (text as NSString).size(withAttributes: a)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: a)
    }
}

// MARK: - 控件用闭包回调

private final class ActionBox: NSObject {
    let f: (NSControl) -> Void
    init(_ f: @escaping (NSControl) -> Void) { self.f = f }
    @objc func run(_ sender: NSControl) { f(sender) }
}

private var actionKey = 0

extension NSControl {
    func onAction(_ f: @escaping (NSControl) -> Void) {
        let box = ActionBox(f)
        objc_setAssociatedObject(self, &actionKey, box, .OBJC_ASSOCIATION_RETAIN)
        target = box
        action = #selector(ActionBox.run(_:))
    }
}
