// 图标：logo 方向 B「声音落成光标」（2026-11-01 PM 选定）：深色底上几道声波由低到高再落下，最后一道变成打字的光标。
// 应用图标和菜单栏单色版都在这里画，坐标照搬 design/homepage/logo/B-caret.svg（1024 画布里图标本体 824 见方，
// 这里换算成 100×100、y 朝下）和 design/homepage/src/logo-board.html 里的 #m-b（40×24）。

import Cocoa

enum Glyph {
    /// 把 viewBox（y 朝下）的稿子坐标映射进 rect
    private static func enter(_ ctx: CGContext, _ rect: CGRect, viewBox: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) {
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / viewBox.width, y: -rect.height / viewBox.height)
        ctx.translateBy(x: -viewBox.minX, y: -viewBox.minY)
    }

    /// 圆角矩形；圆角取宽的一半就是两头半圆的竖条
    private static func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat? = nil) -> CGPath {
        let r = min(r ?? w / 2, h / 2)
        return CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func gradient(_ hexes: [UInt32], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: hexes.map { NSColor(hex: $0).cgColor } as CFArray, locations: locations)!
    }

    // MARK: 应用图标

    /// 五道声波（x、y、高），宽都是 6.8
    private static let waves: [(CGFloat, CGFloat, CGFloat)] = [(16.0, 42.7, 14.6), (27.2, 34.2, 31.6), (38.3, 26.9, 46.1), (49.5, 36.7, 26.7), (60.7, 43.9, 12.1)]

    static func drawAppIcon(_ ctx: CGContext, in rect: CGRect) {
        ctx.saveGState()
        enter(ctx, rect)
        let body = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil)
        ctx.addPath(body)
        ctx.clip()
        ctx.drawLinearGradient(gradient([0x1b2133, 0x2b2458], [0, 1]), start: .zero, end: CGPoint(x: 100, y: 100), options: [])
        // 左上角一层很淡的光
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 30, y: 15), startRadius: 0, endCenter: CGPoint(x: 30, y: 15), endRadius: 80, options: [])

        // 声波：一道横跨五条的渐变，珊瑚红 → 品牌粉 → 紫
        ctx.saveGState()
        let bars = CGMutablePath()
        for (x, y, h) in waves { bars.addPath(pill(x, y, 6.8, h)) }
        ctx.addPath(bars)
        ctx.clip()
        ctx.drawLinearGradient(gradient([0xff7a59, 0xff3d6e, 0xb14dff], [0, 0.55, 1]),
                               start: CGPoint(x: 16, y: 26.7), end: CGPoint(x: 68, y: 72.8), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()

        // 光标：一竖加上下两横
        ctx.setFillColor(.white)
        ctx.addPath(pill(73.9, 26.9, 4.4, 46.1))
        ctx.addPath(pill(68.9, 26.9, 14.6, 4.1))
        ctx.addPath(pill(68.9, 68.9, 14.6, 4.1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: 菜单栏单色版

    enum MenuState: Equatable {
        case normal
        case recording            // 声波变红
        case thinking(Int)        // 识别中，声波隔一道亮一道、轮流换
        case dimmed               // 连不上 / 暂停：整体变灰
    }

    /// 四道声波（x、y、高），宽 3.4
    private static let menuWaves: [(CGFloat, CGFloat, CGFloat)] = [(2, 9, 6), (8, 5.5, 13), (14, 3, 18), (20, 7, 10)]

    /// 光标：一竖加上下两横
    private static func caret() -> CGPath {
        let p = CGMutablePath()
        p.addPath(pill(30.6, 2, 2.8, 20))
        p.addPath(pill(26.8, 1.6, 10.4, 2.8))
        p.addPath(pill(26.8, 19.6, 10.4, 2.8))
        return p
    }

    /// 稿子里图形实际占的范围，菜单栏图按它裁，不留空边
    private static let menuViewBox = CGRect(x: 1.5, y: 1.5, width: 36.2, height: 21)

    static func menuBarImage(_ state: MenuState, height: CGFloat = 15) -> NSImage {
        let size = NSSize(width: (height * menuViewBox.width / menuViewBox.height).rounded(), height: height)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // 模板图只看透明度；录音时是彩色图，光标要跟着菜单栏的深浅色走
            let ink: CGColor = state == .recording ? NSColor.labelColor.cgColor : .black
            let alpha: CGFloat = state == .dimmed ? 0.35 : 1
            ctx.saveGState()
            enter(ctx, rect, viewBox: menuViewBox)
            for (i, (x, y, h)) in menuWaves.enumerated() {
                switch state {
                case .recording: ctx.setFillColor(NSColor.systemRed.cgColor)
                case .thinking(let f): ctx.setFillColor(ink.copy(alpha: (i + f) % 2 == 0 ? 1 : 0.3)!)
                default: ctx.setFillColor(ink.copy(alpha: alpha)!)
                }
                ctx.addPath(pill(x, y, 3.4, h))
                ctx.fillPath()
            }
            ctx.setFillColor(ink.copy(alpha: alpha)!)
            ctx.addPath(caret())
            ctx.fillPath()
            ctx.restoreGState()
            return true
        }
        img.isTemplate = state != .recording
        img.accessibilityDescription = "NB 输入法"
        return img
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}
