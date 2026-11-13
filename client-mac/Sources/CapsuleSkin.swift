import Cocoa

enum CapsuleSkin: String, CaseIterable {
    case intelligence, glass, minimal

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .intelligence
    }

    var title: String {
        switch self {
        case .intelligence: return "AI 流光"
        case .glass: return "通透玻璃"
        case .minimal: return "极简平面"
        }
    }

    var detail: String {
        switch self {
        case .intelligence: return "彩色流光描边，文字清晰醒目"
        case .glass: return "高透毛玻璃，轻薄、没有彩色光效"
        case .minimal: return "小字号、小状态条，纯色平面更安静"
        }
    }

    var rowHeight: CGFloat { self == .minimal ? 28 : (self == .glass ? 40 : 44) }
    var lineHeight: CGFloat { self == .minimal ? 18 : (self == .glass ? 23 : 25) }
    var expandedWidth: CGFloat { self == .minimal ? 300 : (self == .glass ? 360 : 400) }
    var radius: CGFloat { self == .minimal ? 8 : rowHeight / 2 }
    var inset: CGFloat { self == .minimal ? 12 : 18 }
    var topInset: CGFloat { self == .minimal ? 10 : 14 }
    var badgeSize: CGFloat { self == .minimal ? 16 : (self == .glass ? 24 : 28) }
    var contentX: CGFloat { 8 + badgeSize + (self == .minimal ? 7 : 10) }
    var trailingInset: CGFloat { self == .minimal ? 12 : 16 }
    var waveWidth: CGFloat { self == .minimal ? 68 : 118 }
    var textFont: NSFont { .systemFont(ofSize: self == .minimal ? 12 : (self == .glass ? 15 : 16), weight: self == .intelligence ? .medium : .regular) }
    var messageFont: NSFont { .systemFont(ofSize: self == .minimal ? 11 : 13, weight: self == .intelligence ? .medium : .regular) }
    var smallFont: NSFont { .systemFont(ofSize: self == .minimal ? 10 : 12) }
    var timeFont: NSFont { .monospacedDigitSystemFont(ofSize: self == .minimal ? 10 : 13, weight: .regular) }

    func background(dark: Bool, reduceTransparency: Bool) -> NSColor {
        if self == .minimal || reduceTransparency {
            return NSColor(white: dark ? 0.12 : 0.97, alpha: 1)
        }
        let alpha: CGFloat = self == .glass ? (dark ? 0.04 : 0.06) : (dark ? 0.28 : 0.32)
        return NSColor(white: dark ? 0 : 1, alpha: alpha)
    }
}

/// 设置预览与实际浮窗共用同一个表面；平面皮肤不经过玻璃合成。
final class CapsuleSurface: NSView {
    let content = CapsuleView()
    private let glass = NSGlassEffectView()
    var skin = CapsuleSkin.intelligence { didSet { applySkin() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.style = .clear
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        applySkin()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applySkin() {
        content.skin = skin
        glass.cornerRadius = skin.radius
        glass.contentView = nil
        content.removeFromSuperview()
        glass.isHidden = skin == .minimal
        // 通透皮肤只减薄玻璃材质，文字单独叠在上面，保持完整不透明度。
        glass.alphaValue = skin == .glass ? 0.4 : 1
        if skin == .intelligence {
            glass.contentView = content
        } else {
            // NSGlassEffectView 会接管内容布局；移出后恢复按父视图伸缩。
            content.translatesAutoresizingMaskIntoConstraints = true
            addSubview(content)
        }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.needsDisplay = true
    }
}
