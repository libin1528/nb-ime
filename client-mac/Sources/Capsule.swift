// 录音提示 A：屏幕底部的胶囊。跟音量跳的波形、计时、没听到声音、识别中、已输入、没听清、连不上。
// 开了流式预览时，第一段文字回来后胶囊向上展开成一块，实时显示文字（design/mockup.html 2.1 节）。

import Cocoa

final class Capsule {
    enum Mode: Equatable {
        case listening
        case thinking
        case done(Int)              // 已输入 N 字
        case miss                   // 没听清
        case offline                // 连不上识别服务
        case note(String, String)   // 其它一句话的提示：SF Symbol 名、文字
    }

    private let panel: NSPanel
    private let blur = NSVisualEffectView()
    private let view = CapsuleView()
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var visible = false
    private var anchorTop: NSPoint?          // 跟着光标时：胶囊左上角；nil 表示屏幕底部正中
    private var screen: NSScreen?
    private var targetSize = NSSize.zero

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        view.autoresizingMask = [.width, .height]
        let root = NSView()
        root.addSubview(blur)
        root.addSubview(view)
        panel.contentView = root
    }

    // MARK: 对外

    func showListening() {
        view.reset()
        view.mode = .listening
        place()
        present()
    }

    func setLevel(_ v: Float) { view.target = v }

    /// 预览文字：服务端每次发回到目前为止的全文，整段替换
    func setPreview(_ text: String) {
        guard view.mode == .listening else { return }
        view.setPreview(text)
        resize(animated: true)
    }

    func showThinking() {
        view.mode = .thinking
        view.freeze()
        resize(animated: true)
        present()
    }

    func show(_ mode: Mode, for seconds: Double) {
        view.mode = mode
        view.clearPreview()
        if !visible { place() }
        resize(animated: visible)
        present()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.visible else { return }
            self.panel.orderOut(nil)
            self.timer?.invalidate()
            self.timer = nil
        })
    }

    var isExpanded: Bool { view.expanded }

    // MARK: 位置与大小

    /// 定下这一次出现在哪：屏幕底部正中，或者光标下方
    private func place() {
        anchorTop = nil
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if Settings.current.hudPosition == "caret", let r = Caret.rect() {
            screen = NSScreen.screens.first { $0.frame.contains(r.origin) } ?? screen
            anchorTop = NSPoint(x: r.minX - 14, y: r.minY - 10)
        }
        resize(animated: false)
    }

    private func frame(for size: NSSize) -> NSRect {
        guard let f = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        if let a = anchorTop {
            let x = min(max(a.x, f.minX + 8), f.maxX - size.width - 8)
            let y = max(a.y - size.height, f.minY + 8)
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        return NSRect(x: (f.midX - size.width / 2).rounded(), y: f.minY + 64, width: size.width, height: size.height)
    }

    private func resize(animated: Bool) {
        let size = view.desiredSize()
        targetSize = size
        let target = frame(for: size)
        blur.maskImage = Self.mask(radius: view.radius)
        guard target != panel.frame else { return }
        if animated && visible {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.35
                c.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.3, 1)
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self] in self?.panel.invalidateShadow() }
        } else {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
    }

    private func present() {
        hideWork?.cancel()
        if !visible {
            visible = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.view.tick()
                // 「没听到声音」的提示比波形宽，出现和消失时跟着变
                if !self.view.expanded, self.view.desiredSize() != self.targetSize { self.resize(animated: true) }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private static func mask(radius r: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - 胶囊里面画的东西

private final class CapsuleView: NSView {
    var mode = Capsule.Mode.listening { didSet { needsDisplay = true } }
    var target: Float = 0 { didSet { if target > 0.25 { lastLoud = Date() } } }
    private var level: Float = 0
    private var hist = [Float](repeating: 0, count: 80)
    private var frame_ = 0
    private var start = Date()
    private var frozen: TimeInterval?
    private var lastLoud = Date()
    private var preview = ""
    private var newFrom = 0                  // 预览里从这个位置（UTF-16）往后是刚变的，淡入
    private var newAt = Date.distantPast

    static let rowH: CGFloat = 44
    static let lineH: CGFloat = 22
    static let maxLines = 3
    static let expandedW: CGFloat = 400
    static let textFont = NSFont.systemFont(ofSize: 14)
    static let msgFont = NSFont.systemFont(ofSize: 13)
    static let smallFont = NSFont.systemFont(ofSize: 12)
    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static let red = NSColor(hex: 0xff453a), green = NSColor(hex: 0x30d158), orange = NSColor(hex: 0xff9f0a)

    override var isFlipped: Bool { true }

    func reset() {
        start = Date()
        lastLoud = Date()
        frozen = nil
        level = 0
        target = 0
        hist = hist.map { _ in 0 }
        clearPreview()
    }

    func freeze() { frozen = Date().timeIntervalSince(start) }

    func clearPreview() {
        preview = ""
        newFrom = 0
    }

    func setPreview(_ text: String) {
        let old = preview as NSString, new = text as NSString
        var i = 0
        while i < old.length, i < new.length, old.character(at: i) == new.character(at: i) { i += 1 }
        if i < new.length { newFrom = i; newAt = Date() }
        preview = text
        needsDisplay = true
    }

    var expanded: Bool { !preview.isEmpty && (mode == .listening || mode == .thinking) }
    var radius: CGFloat { expanded ? 18 : 22 }
    private var elapsed: TimeInterval { frozen ?? Date().timeIntervalSince(start) }
    private var quiet: Bool { mode == .listening && elapsed > 1.5 && Date().timeIntervalSince(lastLoud) > 1.5 }

    func tick() {
        level = level * 0.55 + target * 0.45
        frame_ += 1
        if frame_ % 2 == 0 { hist.removeFirst(); hist.append(level) }
        needsDisplay = true
    }

    // MARK: 尺寸

    private func textHeight(_ width: CGFloat) -> CGFloat {
        let h = attributed(preview, now: Date()).boundingRect(with: NSSize(width: width, height: 10_000),
                                                               options: [.usesLineFragmentOrigin]).height
        return max(Self.lineH, (h / Self.lineH).rounded() * Self.lineH)
    }

    func desiredSize() -> NSSize {
        if expanded {
            let h = min(textHeight(Self.expandedW - 36), Self.lineH * CGFloat(Self.maxLines))
            return NSSize(width: Self.expandedW, height: Self.rowH + 14 + h + 2)
        }
        return NSSize(width: (8 + 28 + 10 + contentWidth() + 16).rounded(), height: Self.rowH)
    }

    private static let timeW: CGFloat = 32
    private static let waveW: CGFloat = 24 * 5 - 2

    private func contentWidth() -> CGFloat {
        switch mode {
        case .listening: return quiet ? width(Self.quietText, Self.msgFont) + 10 + Self.timeW : Self.waveW + 10 + Self.timeW
        case .thinking: return width("识别中", Self.msgFont) + 10 + 22 + 14 + Self.timeW
        case .done(let n): return width("已输入", Self.msgFont) + 6 + width("\(n) 字", Self.smallFont)
        case .miss: return width("没听清，再说一次", Self.msgFont)
        case .offline: return width("连不上识别服务", Self.msgFont) + 6 + width("正在重试", Self.smallFont)
        case .note(_, let t): return width(t, Self.msgFont)
        }
    }

    private static let quietText = "没听到声音，靠近一点说"

    private func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }

    // MARK: 画

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        // 底色：在毛玻璃上再压一层深灰，和稿子里的 rgba(28,28,30,.8) 接近；外加一圈细白边
        let shape = NSBezierPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        NSColor(hex: 0x1c1c1e, alpha: 0.72).setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()

        // 宽度跟着窗口动画在变，按当前宽度决定是不是展开着
        if !preview.isEmpty, b.height > Self.rowH + 8 { drawPreview(ctx, b) }

        let cy = b.height - Self.rowH / 2
        let badge = NSRect(x: 8, y: cy - 14, width: 28, height: 28)
        var x: CGFloat = 46
        let now = Date()

        switch mode {
        case .listening:
            let ring = badge.insetBy(dx: -CGFloat(level) * 7.7, dy: -CGFloat(level) * 7.7)
            Self.red.withAlphaComponent(CGFloat(0.15 + level * 0.6)).setStroke()
            let rp = NSBezierPath(ovalIn: ring.insetBy(dx: 1, dy: 1))
            rp.lineWidth = 2
            rp.stroke()
            fillBadge(badge, Self.red, symbol: "mic.fill")
            drawTime(cy, b)
            if quiet {
                drawText(Self.quietText, Self.msgFont, .init(white: 1, alpha: 0.92), x: x, cy: cy)
            } else {
                let n = Int((b.width - x - 10 - Self.timeW - 16) / 5)
                let vals = hist.suffix(n)
                for (i, v) in vals.enumerated() {
                    let h = 3 + CGFloat(v) * 21
                    let bar = NSRect(x: x + CGFloat(i) * 5, y: cy - h / 2, width: 3, height: h)
                    NSColor(white: 1, alpha: CGFloat(0.55 + v * 0.45)).setFill()
                    NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
        case .thinking:
            drawShimmer(ctx, b, now)
            fillBadge(badge, NSColor(white: 1, alpha: 0.12), symbol: nil)
            drawSpinner(ctx, badge, now)
            x += drawText("识别中", Self.msgFont, .init(white: 1, alpha: 0.92), x: x, cy: cy) + 10
            for i in 0..<3 {
                let phase = (now.timeIntervalSinceReferenceDate - Double(i) * 0.15).truncatingRemainder(dividingBy: 1)
                let up = phase < 0.4 ? sin(phase / 0.4 * .pi) : 0
                NSColor(white: 1, alpha: 0.25 + 0.75 * up).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + CGFloat(i) * 9, y: cy - 2.5 - 3 * up, width: 5, height: 5)).fill()
            }
            drawTime(cy, b)
        case .done(let n):
            fillBadge(badge, Self.green, symbol: "checkmark")
            x += drawText("已输入", Self.msgFont, .init(white: 1, alpha: 0.92), x: x, cy: cy) + 6
            drawText("\(n) 字", Self.smallFont, .init(white: 1, alpha: 0.55), x: x, cy: cy)
        case .miss:
            fillBadge(badge, NSColor(white: 1, alpha: 0.16), symbol: "questionmark")
            drawText("没听清，再说一次", Self.msgFont, .init(white: 1, alpha: 0.92), x: x, cy: cy)
        case .offline:
            fillBadge(badge, Self.orange, symbol: "wifi.slash")
            x += drawText("连不上识别服务", Self.msgFont, .init(white: 1, alpha: 0.92), x: x, cy: cy) + 6
            drawText("正在重试", Self.smallFont, .init(white: 1, alpha: 0.55), x: x, cy: cy)
        case .note(let sym, let t):
            fillBadge(badge, NSColor(white: 1, alpha: 0.16), symbol: sym)
            drawText(t, Self.msgFont, .init(white: 1, alpha: 0.92), x: x, cy: cy)
        }
    }

    private func fillBadge(_ r: NSRect, _ color: NSColor, symbol: String?) {
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        guard let symbol else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white]))
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    @discardableResult
    private func drawText(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, cy: CGFloat) -> CGFloat {
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
        let size = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: NSPoint(x: x, y: cy - size.height / 2), withAttributes: a)
        return ceil(size.width)
    }

    private func drawTime(_ cy: CGFloat, _ b: NSRect) {
        let t = Int(elapsed)
        let s = "\(t / 60):" + String(format: "%02d", t % 60)
        let a: [NSAttributedString.Key: Any] = [.font: Self.timeFont, .foregroundColor: NSColor(white: 1, alpha: 0.72)]
        let size = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: NSPoint(x: b.width - 16 - size.width, y: cy - size.height / 2), withAttributes: a)
    }

    private func drawSpinner(_ ctx: CGContext, _ r: NSRect, _ now: Date) {
        let c = CGPoint(x: r.midX, y: r.midY)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        ctx.strokeEllipse(in: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
        let a = CGFloat(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8) * 2 * .pi
        ctx.setStrokeColor(.white)
        ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: 7, startAngle: a, endAngle: a + .pi / 2, clockwise: false)
        ctx.strokePath()
    }

    private func drawShimmer(_ ctx: CGContext, _ b: NSRect, _ now: Date) {
        let p = CGFloat(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3)
        let w = b.width
        let cx = w * 1.5 - p * w * 2           // 从右往左扫
        let colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0)] as CFArray
        guard let g = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.5, 1]) else { return }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: b, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: cx - w * 0.2, y: 0), end: CGPoint(x: cx + w * 0.2, y: 0), options: [])
        ctx.restoreGState()
    }

    private func attributed(_ text: String, now: Date) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = Self.lineH
        ps.maximumLineHeight = Self.lineH
        ps.lineBreakMode = .byWordWrapping
        let base: CGFloat = mode == .thinking ? 0.5 : 0.95
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: Self.textFont, .paragraphStyle: ps, .foregroundColor: NSColor(white: 1, alpha: base),
        ])
        let t = min(1, now.timeIntervalSince(newAt) / 0.5)
        let n = (text as NSString).length
        if t < 1, newFrom < n {
            s.addAttribute(.foregroundColor, value: NSColor(white: 1, alpha: base * (0.25 + 0.75 * t)),
                           range: NSRange(location: newFrom, length: n - newFrom))
        }
        return s
    }

    /// 文字贴着底下那一行往上排，超过三行只露最后三行，上沿渐隐
    private func drawPreview(_ ctx: CGContext, _ b: NSRect) {
        let area = NSRect(x: 18, y: 14, width: b.width - 36, height: b.height - Self.rowH - 16)
        guard area.height > 2, area.width > 40 else { return }
        let str = attributed(preview, now: Date())
        let full = str.boundingRect(with: NSSize(width: area.width, height: 10_000), options: [.usesLineFragmentOrigin])
        let h = max(Self.lineH, (full.height / Self.lineH).rounded() * Self.lineH)
        let overflow = h > area.height + 1
        ctx.saveGState()
        ctx.clip(to: area)
        if overflow { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        str.draw(with: NSRect(x: area.minX, y: area.maxY - h, width: area.width, height: h), options: [.usesLineFragmentOrigin])
        if overflow {
            // 上沿 26 点渐隐
            let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray
            if let g = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) {
                ctx.setBlendMode(.destinationIn)
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: area.minY), end: CGPoint(x: 0, y: area.minY + 26),
                                       options: [.drawsAfterEndLocation])
            }
            ctx.endTransparencyLayer()
        }
        ctx.restoreGState()
    }
}

// MARK: - 光标位置（「跟着光标」用）

enum Caret {
    /// 当前输入框里光标的位置（屏幕坐标，原点左下）；拿不到返回 nil
    static func rect() -> NSRect? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let el = focused as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &r), r.height > 0, r.origin != .zero else { return nil }
        // AX 的坐标原点在主屏左上角
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: max(r.width, 1), height: r.height)
    }
}
