// 首次引导：麦克风、辅助功能、试一下。每一步实时检查，全部打勾后自动关闭（design/mockup.html 第 5 节）。
// 换了 bundle id 以后旧的授权都不算数，第一次打开新版也会走这里。

import AVFoundation
import Cocoa

final class Onboarding: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private var heardText: String?
    private var closing = false
    /// 以前走完过引导（这次是权限被关掉了才弹出来），「试一下」就不用再做
    private let triedBefore = Settings.current.onboarded
    private let subtitle = UI.label("", color: .secondaryLabelColor)
    private var steps: [StepView] = []
    var onDone: (() -> Void)?

    static var micOK: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessOK: Bool { AXIsProcessTrusted() }

    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    /// 试一下这一步：认出了字就算通过
    func heard(_ text: String) {
        guard isOpen, heardText == nil else { return }
        heardText = text
        refresh()
    }

    var nsWindow: NSWindow? { window }

    private func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let hero = UI.vstack([icon, UI.label("开始用 NB 输入法", size: 17, weight: .semibold), subtitle], spacing: 8, align: .centerX)
        hero.setCustomSpacing(4, after: hero.arrangedSubviews[1])

        steps = [
            StepView(1, "麦克风", "用来听你说话"),
            StepView(2, "辅助功能", "用来听快捷键、把文字放进输入框。会打开「隐私与安全性 › 辅助功能」，把「NB 输入法」的开关打开"),
            StepView(3, "试一下", ""),
        ]
        let list = UI.vstack(steps, spacing: 10)
        steps.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        let root = UI.vstack([hero, list], spacing: 18, align: .centerX)
        list.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true
        root.edgeInsets = NSEdgeInsets(top: 30, left: 28, bottom: 26, right: 28)

        let content = BackgroundView()
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.setContentSize(content.fittingSize)
        w.delegate = self
        w.center()
        window = w
    }

    func windowWillClose(_ n: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let mic = Self.micOK, access = Self.accessOK, tried = heardText != nil || triedBefore
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        steps[0].set(done: mic, status: "已允许", action: micStatus == .notDetermined ? "允许" : "去打开") {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
        steps[1].set(done: access, status: "已打开", action: "去打开") {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        steps[2].detailKeys = Settings.current.hotkeyCodes.map(Hotkey.keyLabel)
        if triedBefore, heardText == nil {
            steps[2].set(done: true, status: "以前试过了", action: nil, nil)
        } else if let t = heardText {
            steps[2].set(done: true, status: "听到了：\(t.count > 10 ? String(t.prefix(10)) + "…" : t)", action: nil, nil)
        } else {
            steps[2].set(done: false, status: mic && access ? "等你说" : "先做完上面两步", action: nil, nil)
        }
        let left = [mic, access, tried].filter { !$0 }.count
        subtitle.stringValue = left == 0 ? "都好了，开始用吧" : "还差\(["", "一", "两", "三"][left])步"
        if left == 0, !closing {
            closing = true
            if !Settings.current.onboarded { Settings.current.onboarded = true }
            onDone?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.window?.close() }
        }
    }
}

private final class StepView: NSView {
    private let num: NumberBadge
    private let titleLabel: NSTextField
    private let detail: NSTextField
    private let right = NSStackView()
    private var action: (() -> Void)?
    private var shown: (Bool, String, String?)?

    /// 试一下这一步的说明里要嵌当前快捷键
    var detailKeys: [String] = [] {
        didSet {
            guard !detailKeys.isEmpty else { return }
            let k = detailKeys.map { "「\($0)」" }.joined(separator: "或")
            detail.stringValue = "按住\(k)说「你好」，听到了这里会打勾"
        }
    }

    init(_ n: Int, _ title: String, _ text: String) {
        num = NumberBadge(n)
        titleLabel = UI.label(title, weight: .semibold)
        detail = UI.wrapping(text, size: 12, width: 300)
        super.init(frame: .zero)
        let mid = UI.vstack([titleLabel, detail], spacing: 2)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let h = UI.hstack([num, mid, spacer, right], spacing: 14)
        h.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor), h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(done: Bool, status: String, action title: String?, _ f: (() -> Void)?) {
        action = f
        num.done = done
        let key = (done, status, done ? nil : title)
        guard shown.map({ $0 != key }) ?? true else { return }
        shown = key
        right.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !done, let title {
            right.addArrangedSubview(UI.button(title, primary: true) { [weak self] in self?.action?() })
        } else {
            let l = UI.label(status, size: 12, weight: done ? .semibold : .regular, color: done ? NSColor(hex: 0x16a34a) : .secondaryLabelColor)
            right.addArrangedSubview(l)
        }
    }

    override func draw(_ dirty: NSRect) {
        UI.groupBG.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

private final class NumberBadge: NSView {
    let n: Int
    var done = false { didSet { needsDisplay = true } }

    init(_ n: Int) {
        self.n = n
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(ovalIn: r)
        if done {
            UI.green.setFill()
            p.fill()
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(paletteColors: [.white]))
            if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let s = img.size
                img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            }
        } else {
            UI.chipBG.setFill()
            p.fill()
            NSColor.tertiaryLabelColor.setStroke()
            p.lineWidth = 0.5
            p.stroke()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
            let s = ("\(n)" as NSString).size(withAttributes: a)
            ("\(n)" as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: a)
        }
    }
}
