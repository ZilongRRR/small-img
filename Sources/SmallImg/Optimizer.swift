import Foundation

struct OptimiseResult {
    var url: URL
    var originalSize: Int64
    var newSize: Int64
    var skipped: Bool
}

typealias ProgressHandler = (Double) -> Void

enum Optimizer {
    static let imageLimiter = Limiter(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    static let videoLimiter = Limiter(1)

    static func limiter(for kind: MediaKind) -> Limiter {
        kind == .video ? videoLimiter : imageLimiter
    }

    /// 決定輸出格式與副檔名。
    static func resolveTarget(_ src: URL, _ o: Options, _ s: SettingsData) -> (Target, String) {
        let ext = src.pathExtension.lowercased()
        let kind = src.mediaKind
        if let f = o.format, f != .keep {
            if kind == .video, f == .mp4, ["mov", "m4v"].contains(ext), !s.convertMOV { return (.mp4, ext) }
            return (f, f.ext)
        }
        switch kind {
        case .image:
            switch ext {
            case "png": return (.png, "png")
            case "jpg", "jpeg": return (.jpeg, ext)
            case "gif": return (.gif, "gif")
            case "webp": return (.webp, "webp")
            case "avif": return (.avif, "avif")
            case "jxl": return (.jxl, "jxl")
            case "heic", "heif": return s.convertHEIC ? (.jpeg, "jpg") : (.heic, ext)
            case "tif", "tiff", "bmp": return s.convertTIFF ? (.jpeg, "jpg") : (.png, "png")
            default: return (.png, "png")
            }
        case .video:
            switch ext {
            case "mov": return s.convertMOV ? (.mp4, "mp4") : (.mp4, "mov")
            case "webm": return (.webm, "webm")
            case "mp4", "m4v": return (.mp4, ext)
            default: return (.mp4, "mp4")
            }
        case .audio:
            switch ext {
            case "mp3": return (.mp3, "mp3")
            case "m4a", "aac", "mp4": return (.aac, "m4a")
            case "wav", "wave": return s.convertAudio ? (.mp3, "mp3") : (.keep, ext)
            case "aif", "aiff", "aifc", "flac", "caf": return s.convertAudio ? (.aac, "m4a") : (.keep, ext)
            default: return (.aac, "m4a")
            }
        default:
            return (.keep, ext)
        }
    }

    /// 就地最佳化：永遠從原檔（備份）重新開始，只在變小或使用者明確要求變形時才取代。
    static func optimise(_ url: URL, _ o: Options, settings: SettingsData, progress: ProgressHandler? = nil) async throws -> OptimiseResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw ToolError.message(L("檔案不存在：%@", url.lastPathComponent)) }
        let src = Backups.shared.original(for: url) ?? url
        let originalSize = src.fileSize
        let kind = src.mediaKind
        guard kind != .other else { throw ToolError.message(L("不支援的檔案類型")) }
        let (target, ext) = resolveTarget(src, o, settings)
        if target == .keep && kind != .pdf {
            return OptimiseResult(url: url, originalSize: originalSize, newSize: url.fileSize, skipped: true)
        }

        let tmp = try await limiter(for: kind).run {
            try await render(src, kind: kind, target: target, ext: ext, o, settings, progress)
        }
        let newSize = tmp.fileSize
        guard newSize > 0 else {
            try? fm.removeItem(at: tmp)
            throw ToolError.message(L("輸出檔是空的"))
        }
        let formatChanged = ext != src.pathExtension.lowercased()
        if !o.isTransform && !formatChanged && newSize >= Int64(Double(originalSize) * 0.98) {
            try? fm.removeItem(at: tmp)
            if url.path == src.path { XAttr.set(url) }
            return OptimiseResult(url: url, originalSize: originalSize, newSize: url.fileSize, skipped: true)
        }
        let finalURL = formatChanged ? url.withExtension(ext) : url
        let out = try commit(tmp, current: url, final: finalURL)
        return OptimiseResult(url: out, originalSize: originalSize, newSize: out.fileSize, skipped: false)
    }

    /// 轉檔：另存在原檔旁邊，不動原檔。
    static func convert(
        _ url: URL, to target: Target, _ o: Options, settings: SettingsData,
        keepPrevious: Bool, previous: URL?, progress: ProgressHandler? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        let src = Backups.shared.original(for: url) ?? url
        let kind = src.mediaKind
        var oo = o
        oo.format = target
        oo.fitUnder = nil
        let tmp = try await limiter(for: kind).run {
            try await render(src, kind: kind, target: target, ext: target.ext, oo, settings, progress)
        }
        var dest = url.withExtension(target.ext)
        if dest.path == url.path {
            dest = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(target.rawValue)")
                .appendingPathExtension(target.ext)
        }
        if keepPrevious {
            dest = dest.uniqueAvailable
        } else if fm.fileExists(atPath: dest.path) {
            if dest.path == previous?.path || XAttr.has(dest, XAttr.marker) {
                try fm.removeItem(at: dest)
            } else {
                dest = dest.uniqueAvailable
            }
        }
        try fm.moveItem(at: tmp, to: dest)
        XAttr.set(dest)
        return dest
    }

    static func render(
        _ src: URL, kind: MediaKind, target: Target, ext: String, _ o: Options,
        _ s: SettingsData, _ progress: ProgressHandler?
    ) async throws -> URL {
        switch kind {
        case .image:
            if target.kind == .video || target.kind == .audio { throw ToolError.message(L("圖片不能轉成 %@", target.label)) }
            return try await ImageRender.render(src, target: target, o)
        case .video:
            if target.kind == .image || target.kind == .audio { throw ToolError.message(L("影片不能轉成 %@", target.label)) }
            return try await VideoRender.render(src, target: target, ext: ext, o, s, progress)
        case .audio:
            return try await AudioRender.render(src, target: target, ext: ext, o, progress)
        case .pdf:
            return try await PDFRender.render(src, o)
        case .other:
            throw ToolError.message(L("不支援的檔案類型"))
        }
    }

    /// 以原子方式替換檔案，先備份原檔並保留建立日期。
    static func commit(_ tmp: URL, current: URL, final: URL) throws -> URL {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: current.path)
        try Backups.shared.backupIfNeeded(current)
        // 先搬到同一個資料夾，避免跨磁碟區替換失敗
        let staged = current.deletingLastPathComponent().appendingPathComponent(".smallimg-\(UUID().uuidString.prefix(8)).\(final.pathExtension)")
        try fm.moveItem(at: tmp, to: staged)
        var dest = final
        do {
            if final.path == current.path {
                _ = try fm.replaceItemAt(current, withItemAt: staged)
            } else {
                if fm.fileExists(atPath: final.path) { dest = final.uniqueAvailable }
                try fm.moveItem(at: staged, to: dest)
                try fm.removeItem(at: current)
                Backups.shared.moved(from: current, to: dest)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        preserveDates(from: attrs, to: dest)
        XAttr.set(dest)
        return dest
    }

    static func restore(_ url: URL) throws -> URL {
        try Backups.shared.restore(url)
    }
}
