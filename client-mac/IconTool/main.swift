// 生成 AppIcon.icns：在 client-mac 下跑 swiftc Sources/Glyph.swift IconTool/main.swift -o build/make_icon && build/make_icon
// 按 macOS 图标网格：1024 画布里图标本体 824×824 居中，带一层投影。

import Cocoa

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s, color: CGColor(gray: 0, alpha: 0.3))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    Glyph.drawAppIcon(ctx, in: body)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! render(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! render(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "AppIcon.icns 已生成" : "iconutil 失败")
