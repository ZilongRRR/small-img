#if DEBUG
import AppKit
import SwiftUI

/// README 用的介面截圖：用假資料把真正的 SwiftUI 介面畫成 PNG，不碰桌面。
/// 執行：swift run SmallImg render-docs docs/images
@MainActor
enum DocShots {
    static func render(to dir: URL) async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        Lang.english = true
        Paths.ensure(dir)

        save(Backdrop { resultCards }, dir.appendingPathComponent("result-cards.png"))
        save(Backdrop { FloatingDropZone() }, dir.appendingPathComponent("drop-zone.png"))
        Jobs.shared.history = historyItems
        save(MainView().frame(width: 520, height: 700).background(Color(nsColor: .windowBackgroundColor)), dir.appendingPathComponent("main-window.png"))
        print("Saved to \(dir.path)")
    }

    // MARK: - 畫面

    private static var resultCards: some View {
        let shot = item("Screenshot 2026-10-28 at 14.32.10.png", thumb: Thumbs.window, before: 4_820_000, after: 1_130_000)
        let rec = item("Screen Recording 2026-10-28 at 14.40.02.mov", thumb: Thumbs.video, before: 182_400_000, after: 7_640_000)
        rec.options.scale = 0.5
        rec.options.fitUnder = 8_000_000
        let photo = item("trip-photo.jpg", thumb: Thumbs.photo, before: 6_210_000, after: nil)
        photo.status = .working
        photo.progress = 0.62
        return VStack(alignment: .trailing, spacing: 8) {
            ResultCard(item: photo)
            ResultCard(item: rec)
            ResultCard(item: shot, hint: L("不要壓縮，換回原本的檔案（快捷鍵 z）"))
        }
    }

    private static var historyItems: [ResultItem] {
        let restored = item("Screenshot 2026-10-28 at 09.12.44.png", thumb: Thumbs.window, before: 2_310_000, after: 2_310_000)
        restored.status = .restored
        let pdf = item("slides.pdf", thumb: nil, before: 24_800_000, after: 6_900_000)
        let photo = item("trip-photo.jpg", thumb: Thumbs.photo, before: 6_210_000, after: 1_480_000)
        photo.note = L("已另存 %@（%@）", "trip-photo.webp", "612 KB")
        let shot = item("Screenshot 2026-10-28 at 14.32.10.png", thumb: Thumbs.window, before: 4_820_000, after: 1_130_000)
        return [pdf, photo, shot, restored]
    }

    private static func item(_ name: String, thumb: NSImage?, before: Int64, after: Int64?) -> ResultItem {
        let it = ResultItem(url: URL(fileURLWithPath: "/tmp/smallimg-docs").appendingPathComponent(name), options: Options(), pipeline: nil)
        it.originalSize = before
        it.newSize = after
        it.status = .done
        it.thumbnail = thumb
        it.previewRestorable = true
        return it
    }

    // MARK: - 輸出

    private static func save<V: View>(_ view: V, _ url: URL) {
        let host = NSHostingView(rootView: view.environmentObject(Jobs.shared))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// 截圖背景：柔和漸層，代替桌面
private struct Backdrop<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(28)
            .background(
                LinearGradient(colors: [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.93, green: 0.88, blue: 0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
    }
}

/// 縮圖：用程式畫的簡單插圖
private enum Thumbs {
    static func draw(_ body: @escaping (NSRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in body(r); return true }
    }

    /// 一個應用程式視窗
    static let window = draw { r in
        NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
        NSColor(white: 0.88, alpha: 1).setFill(); NSRect(x: 0, y: 108, width: 128, height: 20).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: 8 + i * 12, y: 114, width: 8, height: 8)).fill()
        }
        NSColor(white: 0.92, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 32, height: 108).fill()
        for (i, w) in [70, 52, 80, 44, 64, 58].enumerated() {
            (i == 0 ? NSColor.systemBlue : NSColor(white: 0.75, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 42, y: 90 - i * 14, width: w, height: 6), xRadius: 3, yRadius: 3).fill()
        }
    }

    /// 影片畫面加播放鍵
    static let video = draw { r in
        NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.36, alpha: 1), NSColor(red: 0.42, green: 0.25, blue: 0.48, alpha: 1)])?.draw(in: r, angle: -45)
        NSColor(white: 1, alpha: 0.9).setFill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 52, y: 44)); p.line(to: NSPoint(x: 52, y: 84)); p.line(to: NSPoint(x: 84, y: 64)); p.close()
        p.fill()
    }

    /// 風景照
    static let photo = draw { r in
        NSGradient(colors: [NSColor(red: 0.98, green: 0.78, blue: 0.55, alpha: 1), NSColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1)])?.draw(in: r, angle: 90)
        NSColor(red: 1, green: 0.95, blue: 0.75, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 78, y: 70, width: 26, height: 26)).fill()
        NSColor(red: 0.30, green: 0.45, blue: 0.55, alpha: 1).setFill()
        let m = NSBezierPath()
        m.move(to: NSPoint(x: 0, y: 0)); m.line(to: NSPoint(x: 0, y: 40)); m.line(to: NSPoint(x: 40, y: 78))
        m.line(to: NSPoint(x: 72, y: 46)); m.line(to: NSPoint(x: 96, y: 62)); m.line(to: NSPoint(x: 128, y: 34)); m.line(to: NSPoint(x: 128, y: 0)); m.close()
        m.fill()
    }
}
#endif
