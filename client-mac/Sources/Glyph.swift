// 图标：交互稿方案 B（N + B，B 的两个弧向外扩成声波）。
// 应用图标和菜单栏单色版都在这里画，坐标照搬 design/mockup.html 里的 #i2 / #t2（100×100，y 朝下）。

import Cocoa

enum Glyph {
    /// 把 100×100、y 朝下的稿子坐标映射进 rect
    private static func enter(_ ctx: CGContext, _ rect: CGRect, viewBox: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) {
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / viewBox.width, y: -rect.height / viewBox.height)
        ctx.translateBy(x: -viewBox.minX, y: -viewBox.minY)
    }

    /// 从 (x, y) 出发、半径 r、沿顺时针（屏幕上）画到 (x, y + chord) 的弧，等价于 SVG 的 `a r r 0 0 1 0 chord`
    private static func arc(_ p: CGMutablePath, x: CGFloat, y: CGFloat, r: CGFloat, chord: CGFloat) {
        let half = chord / 2
        let cx = x - (r * r - half * half).squareRoot()
        let a = atan2(-half, x - cx)
        p.addArc(center: CGPoint(x: cx, y: y + half), radius: r, startAngle: a, endAngle: -a, clockwise: false)
    }

    // MARK: 应用图标（#i2）

    static func drawAppIcon(_ ctx: CGContext, in rect: CGRect) {
        ctx.saveGState()
        enter(ctx, rect)
        let body = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil)
        ctx.addPath(body)
        ctx.clip()
        let colors = [NSColor(hex: 0xff7a59), NSColor(hex: 0xff3d6e), NSColor(hex: 0x6a4dff)].map(\.cgColor) as CFArray
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 100, y: 100), options: [])

        ctx.setStrokeColor(.white)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let letters = CGMutablePath()
        letters.move(to: CGPoint(x: 17, y: 68)); letters.addLine(to: CGPoint(x: 17, y: 32))
        letters.addLine(to: CGPoint(x: 37, y: 68)); letters.addLine(to: CGPoint(x: 37, y: 32))
        letters.move(to: CGPoint(x: 48, y: 32)); letters.addLine(to: CGPoint(x: 48, y: 68))
        letters.move(to: CGPoint(x: 48, y: 32)); letters.addLine(to: CGPoint(x: 55, y: 32))
        arc(letters, x: 55, y: 32, r: 9, chord: 18); letters.addLine(to: CGPoint(x: 48, y: 50))
        letters.move(to: CGPoint(x: 48, y: 50)); letters.addLine(to: CGPoint(x: 57, y: 50))
        arc(letters, x: 57, y: 50, r: 9, chord: 18); letters.addLine(to: CGPoint(x: 48, y: 68))
        ctx.setLineWidth(7.5)
        ctx.addPath(letters)
        ctx.strokePath()

        ctx.setLineWidth(5)
        for (x, y, r, chord, alpha) in [(75.0, 39.0, 17.0, 22.0, 0.75), (83, 33, 26, 34, 0.45)] {
            let w = CGMutablePath()
            w.move(to: CGPoint(x: x, y: y))
            arc(w, x: x, y: y, r: r, chord: chord)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: alpha))
            ctx.addPath(w)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: 菜单栏单色版（#t2）

    enum MenuState: Equatable {
        case normal
        case recording            // 声波变红
        case thinking(Int)        // 识别中，两道声波轮流亮
        case dimmed               // 连不上 / 暂停：整体变灰
    }

    /// 字母部分
    private static func letters() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 8, y: 72)); p.addLine(to: CGPoint(x: 8, y: 28))
        p.addLine(to: CGPoint(x: 30, y: 72)); p.addLine(to: CGPoint(x: 30, y: 28))
        p.move(to: CGPoint(x: 44, y: 28)); p.addLine(to: CGPoint(x: 44, y: 72))
        p.move(to: CGPoint(x: 44, y: 28)); p.addLine(to: CGPoint(x: 52, y: 28))
        arc(p, x: 52, y: 28, r: 11, chord: 22); p.addLine(to: CGPoint(x: 44, y: 50))
        p.move(to: CGPoint(x: 44, y: 50)); p.addLine(to: CGPoint(x: 54, y: 50))
        arc(p, x: 54, y: 50, r: 11, chord: 22); p.addLine(to: CGPoint(x: 44, y: 72))
        return p
    }

    private static func wave(_ i: Int) -> CGPath {
        let p = CGMutablePath()
        let (x, y, r, chord): (CGFloat, CGFloat, CGFloat, CGFloat) = i == 0 ? (78, 38, 18, 24) : (88, 30, 28, 40)
        p.move(to: CGPoint(x: x, y: y))
        arc(p, x: x, y: y, r: r, chord: chord)
        return p
    }

    /// 稿子里字形实际占的范围（含线宽），菜单栏图按它裁，不留空边
    private static let menuViewBox = CGRect(x: 2, y: 22, width: 99, height: 56)

    static func menuBarImage(_ state: MenuState, height: CGFloat = 15) -> NSImage {
        let size = NSSize(width: (height * menuViewBox.width / menuViewBox.height).rounded(), height: height)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // 模板图只看透明度；录音时是彩色图，字母要跟着菜单栏的深浅色走
            let ink: CGColor = state == .recording ? NSColor.labelColor.cgColor : .black
            let alpha: CGFloat = state == .dimmed ? 0.35 : 1
            ctx.saveGState()
            enter(ctx, rect, viewBox: menuViewBox)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(ink.copy(alpha: alpha)!)
            ctx.setLineWidth(9)
            ctx.addPath(letters())
            ctx.strokePath()
            ctx.setLineWidth(7)
            for i in 0..<2 {
                switch state {
                case .recording: ctx.setStrokeColor(NSColor.systemRed.cgColor)
                case .thinking(let f): ctx.setStrokeColor(ink.copy(alpha: f % 2 == i ? 1 : 0.3)!)
                default: ctx.setStrokeColor(ink.copy(alpha: alpha)!)
                }
                ctx.addPath(wave(i))
                ctx.strokePath()
            }
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
