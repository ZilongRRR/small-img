// 產生 App 圖示：圓角方塊中兩個向內的箭頭
import AppKit

let out = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.75, alpha: 1))!.draw(in: bg, angle: -90)
    NSColor.white.setStroke()
    let line = NSBezierPath()
    line.lineWidth = s * 0.065
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    let c = s / 2, d = s * 0.08, far = s * 0.27, head = s * 0.11
    // 右上箭頭指向中心
    line.move(to: NSPoint(x: c + far, y: c + far)); line.line(to: NSPoint(x: c + d, y: c + d))
    line.move(to: NSPoint(x: c + d, y: c + d + head)); line.line(to: NSPoint(x: c + d, y: c + d)); line.line(to: NSPoint(x: c + d + head, y: c + d))
    // 左下箭頭指向中心
    line.move(to: NSPoint(x: c - far, y: c - far)); line.line(to: NSPoint(x: c - d, y: c - d))
    line.move(to: NSPoint(x: c - d, y: c - d - head)); line.line(to: NSPoint(x: c - d, y: c - d)); line.line(to: NSPoint(x: c - d - head, y: c - d))
    line.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in sizes {
    if px <= 512 { try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(px)x\(px).png")) }
    if px >= 32 { try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(px / 2)x\(px / 2)@2x.png")) }
}
