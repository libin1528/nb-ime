// swiftc -module-cache-path /tmp/nbime-skin-module-cache -swift-version 5 $(rg --files Sources -g '*.swift' | rg -v '/main.swift$') Tests/CapsuleSkinTests.swift -o /tmp/nbime-skin-tests
import Cocoa

@main enum CapsuleSkinTests {
    static var passed = 0, failed = 0
    static func check(_ ok: @autoclosure () -> Bool, _ name: String) {
        if ok() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }

    static func main() throws {
        _ = NSApplication.shared
        check(CapsuleSkin(storedValue: nil) == .intelligence, "旧配置保留 AI 流光")
        check(CapsuleSkin(storedValue: "unknown") == .intelligence, "未知皮肤安全回退")
        let surface = CapsuleSurface()
        let view = surface.content
        view.setPreview("一段实际预览文字，切换皮肤后仍然保留。")
        view.freeze()
        for skin in CapsuleSkin.allCases + [.glass, .minimal, .intelligence] {
            surface.skin = skin
            check(view.expanded, "\(skin)：切换不丢实时文字")
            check(view.superview != nil && view.window == surface.window, "\(skin)：内容仍挂在表面里")
            check(view.desiredSize().width == skin.expandedWidth, "\(skin)：立即按新皮肤重排")
            if skin == .glass {
                check(view.superview === surface && view.alphaValue == 1, "通透皮肤减薄材质时不让文字一起变淡")
            }
        }
        for skin in CapsuleSkin.allCases {
            surface.skin = skin
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 230, height: 44),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = surface
            for size in [NSSize(width: skin.rowHeight, height: skin.rowHeight),
                         NSSize(width: skin.expandedWidth, height: skin.rowHeight + skin.topInset + 3 * skin.lineHeight + 2)] {
                window.setContentSize(size)
                window.layoutIfNeeded()
                check(view.frame.size == size, "\(skin)：浮窗从圆点展开时内容同步扩展（实际 \(view.frame.size)，期望 \(size)）")
            }
            window.contentView = nil
            view.skin = skin
            view.mode = .listening
            view.clearPreview()
            let collapsed = view.desiredSize()
            check(collapsed.height == skin.rowHeight, "\(skin)：收起高度")
            view.setPreview(String(repeating: "很长的识别文字🙂，", count: 40))
            let expanded = view.desiredSize()
            check(expanded.height <= skin.rowHeight + skin.topInset + 3 * skin.lineHeight + 2, "\(skin)：长文本最多三行")
            view.freeze()
            view.mode = .thinking
            check(view.desiredSize() == expanded, "\(skin)：识别中保留原尺寸和文字")
            view.clearPreview()
            for mode: Capsule.Mode in [.listening, .thinking, .done(128), .miss, .offline, .note("mic.slash", "没听到声音")] {
                view.mode = mode
                let size = view.desiredSize()
                check(size.height == skin.rowHeight && size.width > skin.contentX, "\(skin) / \(mode)：所有状态使用当前皮肤")
            }
            for dark in [false, true] {
                check(skin.background(dark: dark, reduceTransparency: true).alphaComponent == 1, "\(skin)：减少透明度有实色底")
                check(skin.background(dark: dark, reduceTransparency: false).alphaComponent == 1 || skin != .minimal, "平面皮肤始终不透明")
            }
        }
        for dark in [false, true] {
            let tint = CapsuleSkin.glass.background(dark: dark, reduceTransparency: false).usingColorSpace(.sRGB)!
            let ink = CapsuleSkin.glass.glassInk(dark: dark).usingColorSpace(.sRGB)!
            check(1 - tint.alphaComponent >= 0.4, "玻璃在两种外观下都保留下方底色")
            func luminance(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            for backdrop: CGFloat in [0, 1] {
                let surface = luminance(tint.redComponent * tint.alphaComponent + backdrop * (1 - tint.alphaComponent))
                let text = luminance(ink.redComponent)
                check((max(text, surface) + 0.05) / (min(text, surface) + 0.05) >= 4.5,
                      "浮窗与下方窗口外观相同或相反时，文字都有足够对比")
            }
        }
        check(CapsuleSkin.minimal.textFont.pointSize < CapsuleSkin.glass.textFont.pointSize, "平面字号比玻璃小")
        check(CapsuleSkin.minimal.rowHeight < CapsuleSkin.glass.rowHeight, "平面状态条比玻璃小")
        print("Capsule skins: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }

}
