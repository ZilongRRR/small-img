import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageRender {
    static func defaultQuality(_ t: Target, aggressive: Bool) -> Int {
        let base: Int
        switch t {
        case .png: base = 90
        case .jpeg: base = 85
        case .gif: base = 85
        case .webp: base = 80
        case .avif: base = 65
        case .jxl: base = 85
        case .heic: base = 70
        default: base = 80
        }
        return aggressive ? base - 15 : base
    }

    static func render(_ src: URL, target: Target, _ o: Options) async throws -> URL {
        let q = defaultQuality(target, aggressive: o.aggressive)
        guard let limit = o.fitUnder else {
            return try await renderOnce(src, target: target, o, quality: q, scale: o.scale)
        }
        // 先降品質，不夠再縮小尺寸
        let qualities = [q, q - 10, q - 20, q - 35].map { max(10, $0) }
        let scales = [1.0, 0.85, 0.7, 0.55, 0.4, 0.3, 0.2].map { $0 * o.scale }
        var best: URL?
        for (i, s) in scales.enumerated() {
            for qq in (i == 0 ? qualities : [qualities.last!]) {
                let out = try await renderOnce(src, target: target, o, quality: qq, scale: s)
                if out.fileSize <= limit {
                    if let best { try? FileManager.default.removeItem(at: best) }
                    return out
                }
                if let b = best, b.fileSize <= out.fileSize {
                    try? FileManager.default.removeItem(at: out)
                } else {
                    if let b = best { try? FileManager.default.removeItem(at: b) }
                    best = out
                }
            }
        }
        return best!
    }

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        if let orient = props[kCGImagePropertyOrientation] as? Int, orient >= 5 { return (h, w) }
        return (w, h)
    }

    static func renderOnce(_ src: URL, target: Target, _ o: Options, quality q: Int, scale s: Double) async throws -> URL {
        let fm = FileManager.default
        let srcExt = src.pathExtension.lowercased()
        let out = Paths.tempFile(ext: target.ext)

        if target == .gif {
            guard srcExt == "gif" else { throw ToolError.message("只有 GIF 可以輸出 GIF 圖片") }
            var args = ["-O3", "--lossy=\(max(0, (100 - q) * 2))", "--no-warnings"]
            if let size = pixelSize(src) {
                let (w0, h0) = size
                var w = Double(w0)
                if let c = o.crop {
                    let r = c.rect(width: Double(w0), height: Double(h0))
                    args += ["--crop", "\(Int(r.minX)),\(Int(r.minY))+\(Int(r.width))x\(Int(r.height))"]
                    w = r.width
                }
                var tw = w * s
                if let mw = o.maxWidth, tw > Double(mw) { tw = Double(mw) }
                if tw < w - 0.5 { args += ["--resize-width", "\(Int(tw))"] }
            }
            args += [src.path, "-o", out.path]
            try await runTool(.gifsicle, args)
            return out
        }

        let isJPEGSource = ["jpg", "jpeg"].contains(srcExt)
        let needsPixels = s < 0.999 || o.maxWidth != nil || o.crop != nil || (o.watermark?.isEmpty == false)
        var input = src
        switch target {
        case .heic:
            return try drawPixels(src, o, scale: s, type: .heic, quality: q, to: out)
        case .png:
            if needsPixels || srcExt != "png" { input = try drawPixels(src, o, scale: s, type: .png, quality: 100) }
        case .jpeg:
            if needsPixels || !isJPEGSource { input = try drawPixels(src, o, scale: s, type: .jpeg, quality: 95) }
        case .webp:
            if needsPixels || !["png", "jpg", "jpeg", "tif", "tiff", "webp"].contains(srcExt) {
                input = try drawPixels(src, o, scale: s, type: .png, quality: 100)
            }
        case .avif, .jxl:
            if needsPixels || !["png", "jpg", "jpeg"].contains(srcExt) {
                input = try drawPixels(src, o, scale: s, type: .png, quality: 100)
            }
        default:
            throw ToolError.message("不支援輸出 \(target.label) 圖片")
        }
        defer { if input != src { try? fm.removeItem(at: input) } }

        switch target {
        case .png:
            let r = try await runTool(
                .pngquant,
                ["--quality", "\(max(0, q - 25))-\(q)", "--speed", "3", "--force", "--output", out.path, "--", input.path],
                allowed: [0, 98, 99]
            )
            if r.status != 0 { try fm.copyItem(at: input, to: out) }
        case .jpeg:
            try fm.copyItem(at: input, to: out)
            try await runTool(.jpegoptim, ["-m\(q)", "--all-progressive", "-q", out.path])
        case .webp:
            try await runTool(.cwebp, ["-quiet", "-q", "\(q)", "-m", "6", "-mt", "-metadata", "icc", input.path, "-o", out.path])
        case .avif:
            try await runTool(.avifenc, ["-q", "\(q)", "-s", "6", "-j", "all", input.path, out.path])
        case .jxl:
            var args = [input.path, out.path, "-e", "7", "--quiet"]
            // JPEG 原檔不改像素時使用無損轉碼，之後可還原成一模一樣的 JPEG
            if !(isJPEGSource && input == src) { args += ["-q", "\(q)"] }
            try await runTool(.cjxl, args)
        default:
            break
        }
        return out
    }

    /// 解碼、轉正、裁切、縮放、加浮水印後寫出中繼檔。
    static func drawPixels(_ src: URL, _ o: Options, scale s: Double, type: UTType, quality q: Int, to dest: URL? = nil) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ToolError.message("無法讀取圖片") }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var img = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            throw ToolError.message("無法解碼圖片")
        }
        if let c = o.crop {
            let r = c.rect(width: Double(img.width), height: Double(img.height))
            if let cropped = img.cropping(to: r) { img = cropped }
        }
        var tw = Double(img.width) * s
        if let mw = o.maxWidth, tw > Double(mw) { tw = Double(mw) }
        let factor = tw / Double(img.width)
        let watermark = o.watermark?.isEmpty == false ? o.watermark : nil
        if factor < 0.999 || watermark != nil {
            let w = max(1, Int((Double(img.width) * factor).rounded()))
            let h = max(1, Int((Double(img.height) * factor).rounded()))
            var cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            if cs.model != .rgb { cs = CGColorSpace(name: CGColorSpace.sRGB)! }
            guard let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ToolError.message("無法建立繪圖區") }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let watermark { drawWatermark(watermark, in: ctx, width: w, height: h) }
            if let scaled = ctx.makeImage() { img = scaled }
        }

        let out = dest ?? Paths.tempFile(ext: type.preferredFilenameExtension ?? "png")
        guard let destRef = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ToolError.message("無法寫出圖片")
        }
        var meta: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = props[key] { meta[key] = v }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta[kCGImagePropertyOrientation] = 1
        if type != .png { meta[kCGImageDestinationLossyCompressionQuality] = Double(q) / 100 }
        CGImageDestinationAddImage(destRef, img, meta as CFDictionary)
        guard CGImageDestinationFinalize(destRef) else { throw ToolError.message("寫出圖片失敗") }
        return out
    }

    /// 浮水印：文字，或填入圖片路徑則放上標誌。
    static func drawWatermark(_ mark: String, in ctx: CGContext, width: Int, height: Int) {
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }
        let margin = CGFloat(min(width, height)) / 30
        let path = (mark as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path), let logo = NSImage(contentsOfFile: path), logo.size.width > 0 {
            let lw = CGFloat(width) * 0.15
            let lh = lw * logo.size.height / logo.size.width
            logo.draw(
                in: NSRect(x: CGFloat(width) - lw - margin, y: margin, width: lw, height: lh),
                from: .zero, operation: .sourceOver, fraction: 0.8
            )
            return
        }
        let size = max(12, CGFloat(min(width, height)) / 22)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = size / 5
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .shadow: shadow,
        ]
        let str = NSAttributedString(string: mark, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: CGFloat(width) - sz.width - margin, y: margin))
    }
}
