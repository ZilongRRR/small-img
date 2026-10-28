import AppKit
import Foundation

enum Step: Codable, Hashable {
    case optimise(aggressive: Bool)
    case scale(percent: Int)
    case maxWidth(px: Int)
    case crop(CropSpec)
    case convert(Target)
    case fitUnder(mb: Double)
    case watermark(text: String)
    case mute
    case speed(Double)
    case loudness(Double)
    case moveTo(path: String)
    case copyFile
    case copyPath
    case copyMarkdown
    case shell(command: String)

    var label: String {
        switch self {
        case .optimise(let a): return a ? L("強力最佳化") : L("最佳化")
        case .scale(let p): return L("縮放到 %@%", p)
        case .maxWidth(let px): return L("寬度上限 %@ px", px)
        case .crop(let c): return L("裁切 %@", c.label)
        case .convert(let t): return L("轉成 %@", t.label)
        case .fitUnder(let mb): return L("壓到 %@ MB 以下", mb.clean)
        case .watermark(let t): return L("浮水印：%@", t)
        case .mute: return L("移除音訊")
        case .speed(let s): return L("速度 %@x", s.clean)
        case .loudness(let l): return L("響度 %@ LUFS", Int(l))
        case .moveTo(let p): return L("移到 %@", p)
        case .copyFile: return L("複製檔案到剪貼簿")
        case .copyPath: return L("複製路徑")
        case .copyMarkdown: return L("複製成 Markdown 連結")
        case .shell(let c): return L("執行指令：%@", c)
        }
    }

    /// 新增步驟選單用的預設值
    static let templates: [(String, Step)] = [
        (L("最佳化"), .optimise(aggressive: false)),
        (L("縮放"), .scale(percent: 50)),
        (L("寬度上限"), .maxWidth(px: 1920)),
        (L("裁切"), .crop(CropSpec(w: 16, h: 9))),
        (L("轉檔"), .convert(.webp)),
        (L("壓到指定大小以下"), .fitUnder(mb: 8)),
        (L("浮水印"), .watermark(text: L("© 我的名字"))),
        (L("移除音訊"), .mute),
        (L("調整速度"), .speed(2)),
        (L("響度標準化"), .loudness(-14)),
        (L("移到資料夾"), .moveTo(path: L("~/Pictures/截圖/{yyyy}-{MM}"))),
        (L("複製檔案到剪貼簿"), .copyFile),
        (L("複製路徑"), .copyPath),
        (L("複製成 Markdown 連結"), .copyMarkdown),
        (L("執行 shell 指令"), .shell(command: "open -R \"$FILE\"")),
    ]
}

extension Double {
    var clean: String { self == rounded() ? String(Int(self)) : String(format: "%g", self) }
}

struct Pipeline: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var steps: [Step]
    var showInDropZone = false

    static var builtins: [Pipeline] {
        [
            Pipeline(name: L("轉成 WebP"), steps: [.convert(.webp)], showInDropZone: true),
            Pipeline(name: L("整理截圖"), steps: [.optimise(aggressive: false), .moveTo(path: L("~/Pictures/截圖/{yyyy}-{MM}"))]),
            Pipeline(name: L("縮小一半再轉 WebP"), steps: [.scale(percent: 50), .convert(.webp)], showInDropZone: true),
            Pipeline(name: L("壓到 8 MB（Discord）"), steps: [.fitUnder(mb: 8)], showInDropZone: true),
            Pipeline(name: L("裁成 16:9 並複製路徑"), steps: [.crop(CropSpec(w: 16, h: 9)), .optimise(aggressive: false), .copyPath]),
        ]
    }
}

enum PipelineRunner {
    struct Outcome {
        var url: URL
        var result: OptimiseResult?
        var extra: [URL] = []
    }

    static func run(_ p: Pipeline, url: URL, base: Options, settings: SettingsData, progress: ProgressHandler? = nil) async throws -> Outcome {
        var current = url
        var opts = base
        var dirty = false
        var last: OptimiseResult?
        var extra: [URL] = []

        func flush() async throws {
            guard dirty else { return }
            let r = try await Optimizer.optimise(current, opts, settings: settings, progress: progress)
            current = r.url
            last = r
            dirty = false
        }

        for step in p.steps {
            switch step {
            case .optimise(let a):
                opts.aggressive = opts.aggressive || a
                dirty = true
                try await flush()
            case .scale(let pct): opts.scale = Double(pct) / 100; dirty = true
            case .maxWidth(let px): opts.maxWidth = px; dirty = true
            case .crop(let c): opts.crop = c; dirty = true
            case .fitUnder(let mb): opts.fitUnder = Int64(mb * 1_000_000); dirty = true
            case .watermark(let t): opts.watermark = t; dirty = true
            case .mute: opts.mute = true; dirty = true
            case .speed(let s): opts.speed = s; dirty = true
            case .loudness(let l): opts.loudness = l; dirty = true
            case .convert(let t):
                guard Target.targets(for: current.mediaKind).contains(t) else { continue }
                try await flush()
                let converted = try await Optimizer.convert(current, to: t, opts, settings: settings, keepPrevious: false, previous: nil, progress: progress)
                extra.append(current)
                current = converted
                last = OptimiseResult(url: converted, originalSize: (last?.originalSize ?? url.fileSize), newSize: converted.fileSize, skipped: false)
            case .moveTo(let template):
                try await flush()
                let dir = URL(fileURLWithPath: (expand(template, for: current) as NSString).expandingTildeInPath, isDirectory: true)
                Paths.ensure(dir)
                let dest = dir.appendingPathComponent(current.lastPathComponent).uniqueAvailable
                try FileManager.default.moveItem(at: current, to: dest)
                Backups.shared.moved(from: current, to: dest)
                current = dest
                last?.url = dest
            case .copyFile, .copyPath, .copyMarkdown:
                try await flush()
                let target = current
                await MainActor.run { Clipboard.copy(step, target) }
            case .shell(let cmd):
                try await flush()
                let r = try await runProcess("/bin/zsh", ["-lc", cmd], env: ["FILE": current.path])
                if r.status != 0 { throw ToolError.failed(L("指令"), r.status, r.stderr) }
            }
        }
        try await flush()
        return Outcome(url: current, result: last, extra: extra)
    }

    static func expand(_ template: String, for url: URL) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var s = template
        for token in ["yyyy", "MM", "dd"] {
            f.dateFormat = token
            s = s.replacingOccurrences(of: "{\(token)}", with: f.string(from: Date()))
        }
        return s.replacingOccurrences(of: "{name}", with: url.deletingPathExtension().lastPathComponent)
    }
}

enum Clipboard {
    @MainActor
    static func copy(_ step: Step, _ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch step {
        case .copyFile: pb.writeObjects([url as NSURL])
        case .copyMarkdown:
            let name = url.deletingPathExtension().lastPathComponent
            let encoded = url.absoluteString
            let md = url.mediaKind == .image ? "![\(name)](\(encoded))" : "[\(name)](\(encoded))"
            pb.setString(md, forType: .string)
        default: pb.setString(url.path, forType: .string)
        }
    }
}
