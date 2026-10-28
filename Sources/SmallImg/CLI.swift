import Foundation

enum CLI {
    static let commands: Set<String> = ["optimise", "optimize", "o", "convert", "crop-pdf", "pipeline", "restore", "devices", "help", "--help", "-h", "tools"]

    static func shouldHandle(_ args: [String]) -> Bool {
        args.count > 1 && commands.contains(args[1])
    }

    static var usage: String { Lang.english ? usageEnglish : usageChinese }

    static let usageChinese = """
    SmallImg 命令列

    用法：
      smallimg optimise [選項] 檔案...        就地最佳化（原檔會備份）
      smallimg convert --to <格式> 檔案...     另存成其他格式
      smallimg crop-pdf (--for-device <裝置> | --aspect 3:4) 檔案...
      smallimg pipeline <流程名稱> 檔案...
      smallimg restore 檔案...                 還原成原檔
      smallimg devices                         列出 crop-pdf 支援的裝置
      smallimg tools                           檢查壓縮工具是否齊全

    選項：
      -a, --aggressive      強力壓縮
      --fit <大小>          壓到指定大小以下，例如 8MB、500KB
      --scale <比例>        縮放，例如 50% 或 0.5
      --width <像素>        寬度上限
      --crop <比例或尺寸>   例如 16:9 或 1920x1080
      --mute                移除音訊
      --speed <倍數>        影片或音訊速度
      --loudness <LUFS>     響度標準化，例如 -14
      --watermark <文字>    浮水印文字或圖片路徑

    格式：webp avif jxl jpeg png heic mp4 hevc av1 webm gif mp3 aac
    """

    static let usageEnglish = """
    SmallImg command line

    Usage:
      smallimg optimise [options] files...       optimise in place (originals are backed up)
      smallimg convert --to <format> files...    save a copy in another format
      smallimg crop-pdf (--for-device <device> | --aspect 3:4) files...
      smallimg pipeline <pipeline name> files...
      smallimg restore files...                  restore the originals
      smallimg devices                           list devices supported by crop-pdf
      smallimg tools                             check that all compression tools are installed

    Options:
      -a, --aggressive      aggressive compression
      --fit <size>          fit under a file size, e.g. 8MB, 500KB
      --scale <ratio>       scale, e.g. 50% or 0.5
      --width <pixels>      maximum width
      --crop <ratio|size>   e.g. 16:9 or 1920x1080
      --mute                remove audio
      --speed <factor>      video or audio speed
      --loudness <LUFS>     loudness normalisation, e.g. -14
      --watermark <text>    watermark text or image path

    Formats: webp avif jxl jpeg png heic mp4 hevc av1 webm gif mp3 aac
    """

    static func run(_ argv: [String]) async -> Int32 {
        var args = Array(argv.dropFirst())
        let cmd = args.removeFirst()
        let settings = SettingsStore.load()
        var o = Options()
        o.aggressive = settings.aggressive
        var files: [URL] = []
        var to: Target?
        var device: String?
        var aspect: Double?
        var pipelineName: String?

        var i = 0
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        if cmd == "pipeline", !args.isEmpty { pipelineName = args.removeFirst() }
        while i < args.count {
            let a = args[i]
            switch a {
            case "-a", "--aggressive": o.aggressive = true
            case "--fit": o.fitUnder = next().flatMap(parseBytes)
            case "--scale":
                if let v = next() {
                    let n = Double(v.replacingOccurrences(of: "%", with: "")) ?? 1
                    o.scale = v.hasSuffix("%") || n > 1 ? n / 100 : n
                }
            case "--width": o.maxWidth = next().flatMap { Int($0) }
            case "--crop": o.crop = next().flatMap(CropSpec.parse)
            case "--mute": o.mute = true
            case "--speed": o.speed = next().flatMap { Double($0) } ?? 1
            case "--loudness": o.loudness = next().flatMap { Double($0) }
            case "--watermark": o.watermark = next()
            case "--to": to = next().flatMap(parseTarget)
            case "--for-device": device = next()
            case "--aspect": aspect = next().flatMap(CropSpec.parse).map { $0.w / $0.h }
            default:
                files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath).standardizedFileURL)
            }
            i += 1
        }

        switch cmd {
        case "help", "--help", "-h":
            print(usage)
            return 0
        case "devices":
            for d in PDFCropper.devices { print("\(d.0)  \(Int(d.1))x\(Int(d.2))") }
            return 0
        case "tools":
            for t in Tool.allCases { print("\(t.rawValue): \(Tools.path(t) ?? L("缺少，brew install %@", t.brewPackage))") }
            return Tools.missing.isEmpty ? 0 : 1
        default: break
        }

        guard !files.isEmpty else {
            print(usage)
            return 1
        }

        var failed = false
        for f in files {
            do {
                switch cmd {
                case "convert":
                    guard let to else { print(L("請用 --to 指定格式")); return 1 }
                    let out = try await Optimizer.convert(f, to: to, o, settings: settings, keepPrevious: false, previous: nil)
                    print("\(f.lastPathComponent) -> \(out.lastPathComponent)  \(formatBytes(f.fileSize)) -> \(formatBytes(out.fileSize))")
                case "crop-pdf":
                    let ratio = aspect ?? device.flatMap(PDFCropper.aspect(forDevice:))
                    guard let ratio else { print(L("請用 --for-device 或 --aspect 指定比例（smallimg devices 可看裝置清單）")); return 1 }
                    let out = try await PDFCropper.crop(f, aspect: ratio)
                    print(L("已裁切：%@", out.path))
                case "pipeline":
                    guard let p = settings.pipelines.first(where: { $0.name == pipelineName }) else {
                        print(L("找不到流程「%@」。現有流程：%@", pipelineName ?? "", settings.pipelines.map(\.name).joined(separator: L("、"))))
                        return 1
                    }
                    let r = try await PipelineRunner.run(p, url: f, base: o, settings: settings)
                    print("\(f.lastPathComponent) -> \(r.url.path)")
                case "restore":
                    let out = try Optimizer.restore(f)
                    print(L("已還原：%@", out.path))
                default:
                    let r = try await Optimizer.optimise(f, o, settings: settings)
                    if r.skipped {
                        print(L("%@：已經是最佳大小（%@）", f.lastPathComponent, formatBytes(r.newSize)))
                    } else {
                        let pct = r.originalSize > 0 ? Int((1 - Double(r.newSize) / Double(r.originalSize)) * 100) : 0
                        print(L("%@：%@ -> %@（-%@%）", r.url.lastPathComponent, formatBytes(r.originalSize), formatBytes(r.newSize), pct))
                    }
                }
            } catch {
                failed = true
                print(L("%@：%@", f.lastPathComponent, error.localizedDescription))
            }
        }
        return failed ? 1 : 0
    }

    static func parseTarget(_ s: String) -> Target? {
        switch s.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "jpegxl", "jxl": return .jxl
        case "h264", "mp4": return .mp4
        case "h265", "hevc": return .hevc
        case "m4a", "aac": return .aac
        default: return Target(rawValue: s.lowercased())
        }
    }
}
