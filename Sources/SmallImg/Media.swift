import Foundation
import UniformTypeIdentifiers

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SmallImg", isDirectory: true)
    }()
    static let backups = support.appendingPathComponent("Backups", isDirectory: true)
    static let clipboard = support.appendingPathComponent("Clipboard", isDirectory: true)
    static let temp = FileManager.default.temporaryDirectory.appendingPathComponent("SmallImg", isDirectory: true)

    static func ensure(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func tempFile(ext: String) -> URL {
        ensure(temp)
        return temp.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    static func tempDir() -> URL {
        let d = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ensure(d)
        return d
    }

    static var screenshotFolder: URL {
        if let custom = SettingsStore.load().screenshotFolder, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            var isDir: ObjCBool = false
            let path = (loc as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}

enum MediaKind: String, Codable, CaseIterable {
    case image, video, pdf, audio, other

    var label: String {
        switch self {
        case .image: return "圖片"
        case .video: return "影片"
        case .pdf: return "PDF"
        case .audio: return "音訊"
        case .other: return "其他"
        }
    }
}

extension URL {
    var mediaKind: MediaKind {
        let ext = pathExtension.lowercased()
        if ext == "gif" { return .image }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }

    var fileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 與自己同資料夾、同名但副檔名不同的路徑。
    func withExtension(_ ext: String) -> URL {
        deletingPathExtension().appendingPathExtension(ext)
    }

    /// 若檔案已存在，回傳加上「 2」「 3」的可用名稱。
    var uniqueAvailable: URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return self }
        let base = deletingPathExtension().lastPathComponent
        let ext = pathExtension
        let dir = deletingLastPathComponent()
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}

enum Target: String, Codable, CaseIterable, Identifiable {
    case keep, png, jpeg, webp, avif, jxl, heic, gif, mp4, hevc, av1, webm, mp3, aac

    var id: String { rawValue }

    var ext: String {
        switch self {
        case .keep: return ""
        case .jpeg: return "jpg"
        case .mp4, .hevc, .av1: return "mp4"
        case .aac: return "m4a"
        default: return rawValue
        }
    }

    var label: String {
        switch self {
        case .keep: return "保持原格式"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .jxl: return "JPEG XL"
        case .heic: return "HEIC"
        case .gif: return "GIF"
        case .mp4: return "MP4"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        case .webm: return "WebM"
        case .mp3: return "MP3"
        case .aac: return "AAC"
        }
    }

    var kind: MediaKind {
        switch self {
        case .keep: return .other
        case .png, .jpeg, .webp, .avif, .jxl, .heic: return .image
        case .gif, .mp4, .hevc, .av1, .webm: return .video
        case .mp3, .aac: return .audio
        }
    }

    static let imageTargets: [Target] = [.webp, .avif, .jxl, .jpeg, .png]
    static let videoTargets: [Target] = [.mp4, .hevc, .av1, .webm, .gif]
    static let audioTargets: [Target] = [.mp3, .aac]

    static func targets(for kind: MediaKind) -> [Target] {
        switch kind {
        case .image: return imageTargets
        case .video: return videoTargets
        case .audio: return audioTargets
        default: return []
        }
    }
}

struct CropSpec: Codable, Hashable {
    var w: Double
    var h: Double
    /// true：依比例置中裁切；false：裁成指定像素大小
    var isAspect: Bool = true

    var label: String { isAspect ? "\(fmt(w)):\(fmt(h))" : "\(Int(w))x\(Int(h))" }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// 在 width x height 中求出置中的裁切矩形（左上原點）。
    func rect(width: Double, height: Double) -> CGRect {
        var cw: Double, ch: Double
        if isAspect {
            let ratio = w / h
            if width / height > ratio { ch = height; cw = height * ratio } else { cw = width; ch = width / ratio }
        } else {
            cw = min(w, width); ch = min(h, height)
        }
        cw = cw.rounded(.down); ch = ch.rounded(.down)
        return CGRect(x: ((width - cw) / 2).rounded(.down), y: ((height - ch) / 2).rounded(.down), width: cw, height: ch)
    }

    static func parse(_ s: String) -> CropSpec? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "")
        if let i = t.firstIndex(of: ":"), let a = Double(t[..<i]), let b = Double(t[t.index(after: i)...]), a > 0, b > 0 {
            return CropSpec(w: a, h: b, isAspect: true)
        }
        if let i = t.firstIndex(of: "x"), let a = Double(t[..<i]), let b = Double(t[t.index(after: i)...]), a > 0, b > 0 {
            return CropSpec(w: a, h: b, isAspect: false)
        }
        return nil
    }

    static let presets: [CropSpec] = [
        .init(w: 16, h: 9), .init(w: 4, h: 3), .init(w: 1, h: 1), .init(w: 3, h: 2),
        .init(w: 9, h: 16), .init(w: 3, h: 4), .init(w: 21, h: 9),
    ]
}

struct Options: Codable, Hashable {
    var aggressive = false
    var scale: Double = 1
    var maxWidth: Int?
    var crop: CropSpec?
    var fitUnder: Int64?
    var speed: Double = 1
    var mute = false
    var loudness: Double?
    var watermark: String?
    /// 目標格式；nil 代表依設定自動決定
    var format: Target?

    /// 使用者明確要求的變形（就算檔案沒變小也要套用）
    var isTransform: Bool {
        scale < 1 || maxWidth != nil || crop != nil || fitUnder != nil || speed != 1 || mute || loudness != nil
            || watermark != nil || (format != nil && format != .keep)
    }
}

func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB, .useGB]
    return f.string(fromByteCount: n)
}

func parseBytes(_ s: String) -> Int64? {
    let t = s.uppercased().replacingOccurrences(of: " ", with: "")
    let units: [(String, Double)] = [("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000), ("G", 1_000_000_000), ("M", 1_000_000), ("K", 1_000), ("B", 1)]
    for (u, m) in units where t.hasSuffix(u) {
        if let v = Double(t.dropLast(u.count)) { return Int64(v * m) }
    }
    if let v = Double(t) { return Int64(v * 1_000_000) }
    return nil
}

// MARK: - 延伸屬性

enum XAttr {
    static let marker = "com.zilong.smallimg.done"
    static let screenCapture = "com.apple.metadata:kMDItemIsScreenCapture"

    static func has(_ url: URL, _ name: String) -> Bool {
        getxattr(url.path, name, nil, 0, 0, 0) >= 0
    }

    static func set(_ url: URL, _ name: String = marker) {
        let v: [UInt8] = [0x31]
        _ = setxattr(url.path, name, v, v.count, 0, 0)
    }

    static func remove(_ url: URL, _ name: String = marker) {
        _ = removexattr(url.path, name, 0)
    }
}

func preserveDates(from attrs: [FileAttributeKey: Any]?, to url: URL) {
    guard let attrs else { return }
    var keep: [FileAttributeKey: Any] = [:]
    if let c = attrs[.creationDate] { keep[.creationDate] = c }
    if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
    try? FileManager.default.setAttributes(keep, ofItemAtPath: url.path)
}
