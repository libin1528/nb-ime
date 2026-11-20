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
        case .glass: return "透出窗口底色，文字随系统明暗切换"
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
    var textFont: NSFont { .systemFont(ofSize: self == .minimal ? 12 : (self == .glass ? 15 : 16), weight: self == .minimal ? .regular : .medium) }
    var messageFont: NSFont { .systemFont(ofSize: self == .minimal ? 11 : 13, weight: self == .minimal ? .regular : .medium) }
    var smallFont: NSFont { .systemFont(ofSize: self == .minimal ? 10 : 12) }
    var timeFont: NSFont { .monospacedDigitSystemFont(ofSize: self == .minimal ? 10 : 13, weight: .regular) }

    func glassInk(dark: Bool) -> NSColor {
        NSColor(srgbRed: dark ? 1 : 0.06, green: dark ? 1 : 0.06, blue: dark ? 1 : 0.06, alpha: 1)
    }

    func background(dark: Bool, reduceTransparency: Bool) -> NSColor {
        // 浮窗和下方应用可能明暗相反；半透明底与字色配对，也让下方窗口颜色可见。
        if self == .glass {
            let channel: CGFloat = dark ? 0 : 1
            return NSColor(srgbRed: channel, green: channel, blue: channel, alpha: reduceTransparency ? 1 : (dark ? 0.56 : 0.52))
        }
        if self == .minimal || reduceTransparency {
            return NSColor(white: dark ? 0.12 : 0.97, alpha: 1)
        }
        let alpha: CGFloat = dark ? 0.28 : 0.32
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
        applySkin()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applySkin() {
        content.skin = skin
        glass.cornerRadius = skin.radius
        glass.contentView = nil
        content.removeFromSuperview()
        glass.removeFromSuperview()
        if skin == .intelligence {
            glass.frame = bounds
            addSubview(glass)
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
