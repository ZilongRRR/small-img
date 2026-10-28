import Foundation
import PDFKit

struct MediaInfo {
    var duration: Double = 0
    var width = 0
    var height = 0
    var fps: Double = 30
    var hasVideo = false
    var hasAudio = false
    var hasCover = false
    var audioBitrate: Int = 0

    static func probe(_ url: URL) async throws -> MediaInfo {
        let r = try await runTool(.ffprobe, ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path])
        guard let json = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] else {
            throw ToolError.message(L("無法讀取媒體資訊"))
        }
        var info = MediaInfo()
        if let fmt = json["format"] as? [String: Any], let d = fmt["duration"] as? String { info.duration = Double(d) ?? 0 }
        for s in (json["streams"] as? [[String: Any]]) ?? [] {
            let type = s["codec_type"] as? String
            let disposition = s["disposition"] as? [String: Any]
            let attached = (disposition?["attached_pic"] as? Int) == 1
            if type == "video" && attached { info.hasCover = true; continue }
            if type == "video" && !info.hasVideo {
                info.hasVideo = true
                info.width = s["width"] as? Int ?? 0
                info.height = s["height"] as? Int ?? 0
                if let rate = s["avg_frame_rate"] as? String {
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0, parts[0] > 0 { info.fps = parts[0] / parts[1] }
                }
                var rotation = 0
                if let side = s["side_data_list"] as? [[String: Any]] {
                    for d in side { if let r = d["rotation"] as? Int { rotation = r } }
                }
                if let tags = s["tags"] as? [String: Any], let r = tags["rotate"] as? String, let v = Int(r) { rotation = v }
                if abs(rotation) % 180 == 90 { swap(&info.width, &info.height) }
            }
            if type == "audio" && !info.hasAudio {
                info.hasAudio = true
                if let b = s["bit_rate"] as? String { info.audioBitrate = Int(b) ?? 0 }
            }
        }
        return info
    }
}

enum FFmpeg {
    static func run(_ args: [String], duration: Double, progress: ProgressHandler?, range: (Double, Double) = (0, 1)) async throws {
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + args
        try await runTool(.ffmpeg, full, onLine: { line in
            guard let progress, duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
            let p = min(1, max(0, us / 1_000_000 / duration))
            progress(range.0 + (range.1 - range.0) * p)
        })
    }

    /// atempo 只接受 0.5 到 2，超出範圍時串接多個。
    static func atempo(_ speed: Double) -> [String] {
        var s = speed
        var parts: [String] = []
        while s > 2 { parts.append("atempo=2"); s /= 2 }
        while s < 0.5 { parts.append("atempo=0.5"); s /= 0.5 }
        if abs(s - 1) > 0.001 { parts.append("atempo=\(s)") }
        return parts
    }
}

enum VideoRender {
    static func render(_ src: URL, target: Target, ext: String, _ o: Options, _ s: SettingsData, _ progress: ProgressHandler?) async throws -> URL {
        let info = try await MediaInfo.probe(src)
        guard info.hasVideo else { throw ToolError.message(L("找不到影像軌")) }
        if target == .gif { return try await gif(src, info, o, s, progress) }

        var scale = o.scale
        var cw = Double(info.width), ch = Double(info.height)
        if let c = o.crop { let r = c.rect(width: cw, height: ch); cw = r.width; ch = r.height }
        if let mw = o.maxWidth, cw * scale > Double(mw) { scale = Double(mw) / cw }
        let outDuration = max(0.1, info.duration / o.speed)
        let audio = info.hasAudio && !o.mute
        let out = Paths.tempFile(ext: ext)

        guard let limit = o.fitUnder else {
            let args = inputArgs(src) + filterArgs(info, o, scale: scale) + codecArgs(target, o, s, bitrateK: nil)
                + audioArgs(target, o, audio, bitrateK: nil) + containerArgs(ext) + [out.path]
            try await FFmpeg.run(args, duration: outDuration, progress: progress)
            return out
        }

        let audioK = audio ? 96.0 : 0
        var videoK = Double(limit) * 8 * 0.93 / outDuration / 1000 - audioK
        guard videoK > 40 else { throw ToolError.message(L("影片太長，無法壓到 %@ 以下", formatBytes(limit))) }
        let fps = min(info.fps, 60)
        // 每像素位元太低時先降解析度，畫質比硬壓好
        func bpp() -> Double { videoK * 1000 / max(1, cw * ch * scale * scale * fps) }
        while bpp() < 0.04 && scale > 0.25 { scale *= 0.85 }

        for attempt in 0..<3 {
            let twoPass = target == .mp4
            if twoPass {
                let passlog = Paths.temp.appendingPathComponent("pass-\(UUID().uuidString)").path
                let pass1 = inputArgs(src) + filterArgs(info, o, scale: scale)
                    + ["-c:v", "libx264", "-preset", "medium", "-b:v", "\(Int(videoK))k", "-pass", "1", "-passlogfile", passlog, "-an", "-f", "null", "/dev/null"]
                try await FFmpeg.run(pass1, duration: outDuration, progress: progress, range: (0, 0.5))
                let pass2 = inputArgs(src) + filterArgs(info, o, scale: scale)
                    + ["-c:v", "libx264", "-preset", "medium", "-b:v", "\(Int(videoK))k", "-pass", "2", "-passlogfile", passlog, "-pix_fmt", "yuv420p"]
                    + audioArgs(target, o, audio, bitrateK: audioK) + containerArgs(ext) + [out.path]
                try await FFmpeg.run(pass2, duration: outDuration, progress: progress, range: (0.5, 1))
                for suffix in ["-0.log", "-0.log.mbtree"] { try? FileManager.default.removeItem(atPath: passlog + suffix) }
            } else {
                let args = inputArgs(src) + filterArgs(info, o, scale: scale) + codecArgs(target, o, s, bitrateK: videoK)
                    + audioArgs(target, o, audio, bitrateK: audioK) + containerArgs(ext) + [out.path]
                try await FFmpeg.run(args, duration: outDuration, progress: progress)
            }
            if out.fileSize <= limit || attempt == 2 { break }
            videoK *= 0.85
        }
        return out
    }

    static func inputArgs(_ src: URL) -> [String] {
        ["-i", src.path, "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"]
    }

    static func filterArgs(_ info: MediaInfo, _ o: Options, scale: Double) -> [String] {
        var vf: [String] = []
        if let c = o.crop {
            let r = c.rect(width: Double(info.width), height: Double(info.height))
            vf.append("crop=\(Int(r.width)):\(Int(r.height)):\(Int(r.minX)):\(Int(r.minY))")
        }
        if scale < 0.999 {
            vf.append("scale=trunc(iw*\(String(format: "%.4f", scale))/2)*2:-2")
        } else {
            vf.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        if o.speed != 1 { vf.append("setpts=PTS/\(o.speed)") }
        var args = ["-vf", vf.joined(separator: ",")]
        var af = FFmpeg.atempo(o.speed)
        if let l = o.loudness { af.append("loudnorm=I=\(Int(l)):TP=-1.5:LRA=11") }
        if !af.isEmpty && !o.mute && info.hasAudio { args += ["-af", af.joined(separator: ",")] }
        return args
    }

    static func codecArgs(_ target: Target, _ o: Options, _ s: SettingsData, bitrateK: Double?) -> [String] {
        let a = o.aggressive
        let br: [String] = bitrateK.map { ["-b:v", "\(Int($0))k", "-maxrate", "\(Int($0 * 1.4))k", "-bufsize", "\(Int($0 * 2))k"] } ?? []
        switch target {
        case .hevc:
            if s.mediaEngine {
                return ["-c:v", "hevc_videotoolbox"] + (bitrateK == nil ? ["-q:v", a ? "45" : "55"] : br) + ["-tag:v", "hvc1"]
            }
            return ["-c:v", "libx265", "-preset", "medium", "-x265-params", "log-level=error"]
                + (bitrateK == nil ? ["-crf", a ? "32" : "28"] : br) + ["-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
        case .av1:
            return ["-c:v", "libsvtav1", "-preset", "8", "-pix_fmt", "yuv420p"]
                + (bitrateK == nil ? ["-crf", a ? "42" : "36"] : ["-b:v", "\(Int(bitrateK!))k"])
        case .webm:
            return ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
                + (bitrateK == nil ? ["-crf", a ? "40" : "34", "-b:v", "0"] : ["-b:v", "\(Int(bitrateK!))k"])
        default:
            if s.mediaEngine {
                return ["-c:v", "h264_videotoolbox"] + (bitrateK == nil ? ["-q:v", a ? "45" : "55"] : br) + ["-pix_fmt", "yuv420p"]
            }
            return ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"]
                + (bitrateK == nil ? ["-crf", a ? "30" : "26"] : br)
        }
    }

    static func audioArgs(_ target: Target, _ o: Options, _ hasAudio: Bool, bitrateK: Double?) -> [String] {
        guard hasAudio else { return ["-an"] }
        let k = bitrateK.map { Int($0) } ?? (o.aggressive ? 96 : 128)
        if target == .webm { return ["-c:a", "libopus", "-b:a", "\(min(k, 128))k"] }
        return ["-c:a", "aac", "-b:a", "\(k)k"]
    }

    static func containerArgs(_ ext: String) -> [String] {
        ["mp4", "mov", "m4v"].contains(ext.lowercased()) ? ["-movflags", "+faststart"] : []
    }

    static func gif(_ src: URL, _ info: MediaInfo, _ o: Options, _ s: SettingsData, _ progress: ProgressHandler?) async throws -> URL {
        let out = Paths.tempFile(ext: "gif")
        var cw = Double(info.width)
        if let c = o.crop { cw = c.rect(width: Double(info.width), height: Double(info.height)).width }
        var width = min(Double(s.gifMaxWidth), cw * o.scale)
        if let mw = o.maxWidth { width = min(width, Double(mw)) }
        let fps = o.aggressive ? 12 : 15
        let duration = max(0.1, info.duration / o.speed)
        for attempt in 0..<4 {
            let dir = Paths.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            var vf: [String] = []
            if let c = o.crop {
                let r = c.rect(width: Double(info.width), height: Double(info.height))
                vf.append("crop=\(Int(r.width)):\(Int(r.height)):\(Int(r.minX)):\(Int(r.minY))")
            }
            if o.speed != 1 { vf.append("setpts=PTS/\(o.speed)") }
            vf.append("fps=\(fps)")
            vf.append("scale=\(Int(width)):-2:flags=lanczos")
            try await FFmpeg.run(["-i", src.path, "-vf", vf.joined(separator: ","), dir.appendingPathComponent("f%05d.png").path],
                                 duration: duration, progress: progress, range: (0, 0.6))
            let frames = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
                .filter { $0.hasSuffix(".png") }.sorted().map { dir.appendingPathComponent($0).path }
            guard !frames.isEmpty else { throw ToolError.message(L("無法擷取影格")) }
            try await runTool(.gifski, ["--fps", "\(fps)", "--quality", o.aggressive ? "70" : "85", "-o", out.path] + frames)
            progress?(1)
            guard let limit = o.fitUnder, out.fileSize > limit, attempt < 3 else { break }
            width *= 0.75
        }
        return out
    }
}

enum AudioRender {
    static func render(_ src: URL, target: Target, ext: String, _ o: Options, _ progress: ProgressHandler?) async throws -> URL {
        let info = try await MediaInfo.probe(src)
        guard info.hasAudio else { throw ToolError.message(L("找不到音訊軌")) }
        let out = Paths.tempFile(ext: ext)
        let duration = max(0.1, info.duration / o.speed)
        var bitrateK: Int?
        if let limit = o.fitUnder {
            bitrateK = min(320, Int(Double(limit) * 8 * 0.95 / duration / 1000))
            if bitrateK! < 24 { throw ToolError.message(L("音訊太長，無法壓到 %@ 以下", formatBytes(limit))) }
        }
        var af = FFmpeg.atempo(o.speed)
        if let l = o.loudness { af.append("loudnorm=I=\(Int(l)):TP=-1.5:LRA=11") }

        func args(cover: Bool) -> [String] {
            var a = ["-i", src.path, "-map", "0:a:0", "-map_metadata", "0"]
            if cover {
                a += ["-map", "0:v:0", "-c:v", "mjpeg", "-q:v", "4", "-vf", "scale='min(600,iw)':-2", "-disposition:v:0", "attached_pic"]
            } else {
                a += ["-vn"]
            }
            if !af.isEmpty { a += ["-af", af.joined(separator: ",")] }
            switch target {
            case .mp3:
                a += ["-c:a", "libmp3lame", "-id3v2_version", "3"]
                a += bitrateK.map { ["-b:a", "\($0)k"] } ?? ["-q:a", o.aggressive ? "5" : "2"]
            default:
                a += ["-c:a", "aac", "-b:a", "\(bitrateK ?? (o.aggressive ? 128 : 192))k"]
                if ["m4a", "mp4"].contains(ext) { a += ["-movflags", "+faststart"] }
            }
            return a + [out.path]
        }

        do {
            try await FFmpeg.run(args(cover: info.hasCover), duration: duration, progress: progress)
        } catch {
            // 封面轉檔失敗時改成不帶封面
            guard info.hasCover else { throw error }
            try await FFmpeg.run(args(cover: false), duration: duration, progress: progress)
        }
        return out
    }
}

enum PDFRender {
    static func render(_ src: URL, _ o: Options) async throws -> URL {
        guard let limit = o.fitUnder else {
            return try await gs(src, preset: o.aggressive ? "/screen" : "/ebook", dpi: nil)
        }
        var best: URL?
        let steps: [(String?, Int?)] = [("/ebook", nil), ("/screen", nil), ("/screen", 100), ("/screen", 72), ("/screen", 50)]
        for (preset, dpi) in steps {
            let out = try await gs(src, preset: preset, dpi: dpi)
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
        return best!
    }

    static func gs(_ src: URL, preset: String?, dpi: Int?) async throws -> URL {
        let out = Paths.tempFile(ext: "pdf")
        var args = [
            "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6", "-dNOPAUSE", "-dBATCH", "-dQUIET", "-dSAFER",
            "-dDetectDuplicateImages=true", "-dCompressFonts=true", "-dSubsetFonts=true",
        ]
        if let preset { args.append("-dPDFSETTINGS=\(preset)") }
        if let dpi {
            args += [
                "-dDownsampleColorImages=true", "-dColorImageResolution=\(dpi)", "-dColorImageDownsampleThreshold=1.0",
                "-dDownsampleGrayImages=true", "-dGrayImageResolution=\(dpi)", "-dGrayImageDownsampleThreshold=1.0",
                "-dDownsampleMonoImages=true", "-dMonoImageResolution=\(dpi * 2)",
            ]
        }
        args += ["-sOutputFile=\(out.path)", src.path]
        try await runTool(.gs, args)
        return out
    }
}

/// 把 PDF 的頁邊裁掉並對齊裝置螢幕比例。
enum PDFCropper {
    static let devices: [(String, Double, Double)] = [
        ("iPad Air", 1640, 2360),
        ("iPad Pro 11", 1668, 2420),
        ("iPad Pro 13", 2064, 2752),
        ("iPad mini", 1488, 2266),
        ("iPad", 1640, 2360),
        ("iPhone 16 Pro", 1206, 2622),
        ("iPhone 16 Pro Max", 1320, 2868),
        ("iPhone 16", 1179, 2556),
        ("Kindle Paperwhite", 1236, 1648),
        ("Kindle Scribe", 1860, 2480),
        ("reMarkable 2", 1404, 1872),
        ("MacBook Air 13", 2560, 1664),
        ("MacBook Pro 14", 3024, 1964),
    ]

    static func aspect(forDevice name: String) -> Double? {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        guard let d = devices.first(where: { $0.0.lowercased().replacingOccurrences(of: " ", with: "") == key }) else { return nil }
        return d.1 / d.2
    }

    /// aspect 為寬除以高
    static func crop(_ url: URL, aspect: Double) async throws -> URL {
        let src = Backups.shared.original(for: url) ?? url
        let r = try await runTool(.gs, ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=bbox", src.path])
        let boxes: [CGRect] = r.stderr.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("%%HiResBoundingBox:") else { return nil }
            let n = line.dropFirst(19).split(separator: " ").compactMap { Double($0) }
            guard n.count == 4 else { return nil }
            return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
        }
        guard let doc = PDFDocument(url: src) else { throw ToolError.message(L("無法開啟 PDF")) }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), i < boxes.count else { continue }
            let media = page.bounds(for: .mediaBox)
            var box = boxes[i].insetBy(dx: -8, dy: -8)
            if box.width <= 16 || box.height <= 16 { continue }
            box.origin.x += media.minX
            box.origin.y += media.minY
            let ratio = page.rotation % 180 == 0 ? aspect : 1 / aspect
            if box.width / box.height < ratio {
                let w = box.height * ratio
                box = box.insetBy(dx: -(w - box.width) / 2, dy: 0)
            } else {
                let h = box.width / ratio
                box = box.insetBy(dx: 0, dy: -(h - box.height) / 2)
            }
            // 超出頁面時往內推回
            if box.minX < media.minX { box.origin.x = media.minX }
            if box.minY < media.minY { box.origin.y = media.minY }
            if box.maxX > media.maxX { box.origin.x = max(media.minX, media.maxX - box.width) }
            if box.maxY > media.maxY { box.origin.y = max(media.minY, media.maxY - box.height) }
            page.setBounds(box.intersection(media), for: .cropBox)
        }
        let tmp = Paths.tempFile(ext: "pdf")
        guard doc.write(to: tmp) else { throw ToolError.message(L("寫出 PDF 失敗")) }
        return try Optimizer.commit(tmp, current: url, final: url)
    }
}
