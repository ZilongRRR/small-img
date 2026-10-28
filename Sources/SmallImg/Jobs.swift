import AppKit
import Combine
import QuickLookThumbnailing

enum JobStatus: Equatable {
    case queued, working, done, skipped, restored
    case failed(String)

    var isFinal: Bool { self != .queued && self != .working }
}

@MainActor
final class ResultItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published var status: JobStatus = .queued
    @Published var progress: Double?
    @Published var originalSize: Int64
    @Published var newSize: Int64?
    @Published var thumbnail: NSImage?
    @Published var options: Options
    @Published var note: String?
    var lastConversion: URL?
    var pipeline: Pipeline?
    /// 剪貼簿來源的原始資料，還原時寫回
    var clipboardOriginal: [(NSPasteboard.PasteboardType, Data)]?
    /// 剪貼簿目前內容是否還是這張圖（使用者複製了別的東西就不寫回）
    var clipboardChangeCount = 0
    var task: Task<Void, Never>?
    var lastTouch = Date()

    init(url: URL, options: Options, pipeline: Pipeline?) {
        self.url = url
        self.options = options
        self.pipeline = pipeline
        originalSize = url.fileSize
    }

    var kind: MediaKind { url.mediaKind }
    var isClipboard: Bool { clipboardOriginal != nil }
    var displayName: String { isClipboard ? L("剪貼簿圖片") : url.lastPathComponent }

    var savedPercent: Int? {
        guard let n = newSize, originalSize > 0 else { return nil }
        return Int(((1 - Double(n) / Double(originalSize)) * 100).rounded())
    }

    #if DEBUG
    /// 文件截圖用：假裝有備份
    var previewRestorable = false
    var canRestore: Bool { previewRestorable || Backups.shared.entry(for: url) != nil }
    #else
    var canRestore: Bool { Backups.shared.entry(for: url) != nil }
    #endif
}

@MainActor
final class Jobs: ObservableObject {
    static let shared = Jobs()

    @Published var history: [ResultItem] = []
    @Published var floating: [ResultItem] = []
    @Published var hoveredID: UUID?

    private var timer: Timer?
    var settings: SettingsData { AppSettings.shared.data }

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in Jobs.shared.autoDismiss() }
        }
    }

    // MARK: - 加入工作

    /// 拖放、服務選單、Finder 快捷鍵等入口都走這裡
    func handle(_ urls: [URL], aggressive: Bool? = nil, pipeline: Pipeline? = nil, showFloating: Bool = true) {
        let files = Self.expand(urls)
        guard !files.isEmpty else { return }
        if files.count > settings.batchThreshold && pipeline == nil {
            BatchController.shared.open(files)
            return
        }
        for f in files {
            var o = Options()
            o.aggressive = aggressive ?? settings.aggressive
            let item = ResultItem(url: f, options: o, pipeline: pipeline)
            add(item, showFloating: showFloating)
            start(item)
        }
    }

    /// 網址先下載到「下載項目」再最佳化
    func handleRemote(_ urls: [URL], aggressive: Bool?, pipeline: Pipeline?) {
        for remote in urls {
            Task {
                do {
                    let (tmp, response) = try await URLSession.shared.download(from: remote)
                    let name = response.suggestedFilename ?? remote.lastPathComponent
                    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    let dest = downloads.appendingPathComponent(name.isEmpty ? "download" : name).uniqueAvailable
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    handle([dest], aggressive: aggressive, pipeline: pipeline)
                } catch {
                    Notifier.error(L("下載失敗：%@", error.localizedDescription))
                }
            }
        }
    }

    func handleClipboard(data: Data, ext: String, original: [(NSPasteboard.PasteboardType, Data)], changeCount: Int) {
        Paths.ensure(Paths.clipboard)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = Paths.clipboard.appendingPathComponent(L("剪貼簿 %@.%@", f.string(from: Date()), ext)).uniqueAvailable
        do { try data.write(to: url) } catch { return }
        var o = Options()
        o.aggressive = settings.aggressive
        let item = ResultItem(url: url, options: o, pipeline: settings.pipeline(settings.clipboardPipeline))
        item.clipboardOriginal = original
        item.clipboardChangeCount = changeCount
        add(item, showFloating: true)
        start(item)
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let en = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = en?.nextObject() as? URL {
                    if f.mediaKind != .other { out.append(f) }
                }
            } else if u.mediaKind != .other {
                out.append(u)
            }
        }
        return out
    }

    private func add(_ item: ResultItem, showFloating: Bool) {
        history.append(item)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        if showFloating {
            floating.append(item)
            if floating.count > 6 { floating.removeFirst(floating.count - 6) }
        }
        loadThumbnail(item)
    }

    // MARK: - 執行

    func start(_ item: ResultItem, pipeline: Pipeline? = nil) {
        item.task?.cancel()
        item.status = .working
        item.progress = nil
        item.note = nil
        item.lastTouch = Date()
        let url = item.url
        let opts = item.options
        let settings = self.settings
        let p = pipeline ?? item.pipeline
        item.pipeline = nil
        let progress: ProgressHandler = { [weak item] v in
            Task { @MainActor in item?.progress = v }
        }
        item.task = Task {
            do {
                var result: OptimiseResult
                if let p {
                    let outcome = try await PipelineRunner.run(p, url: url, base: opts, settings: settings, progress: progress)
                    result = outcome.result ?? OptimiseResult(url: outcome.url, originalSize: item.originalSize, newSize: outcome.url.fileSize, skipped: true)
                    result.url = outcome.url
                    item.note = L("已執行流程：%@", p.name)
                } else {
                    result = try await Optimizer.optimise(url, opts, settings: settings, progress: progress)
                }
                item.url = result.url
                item.originalSize = result.originalSize
                item.newSize = result.newSize
                item.status = result.skipped ? .skipped : .done
                item.progress = nil
                item.lastTouch = Date()
                if item.isClipboard && !result.skipped { writeClipboard(item.url, for: item) }
                loadThumbnail(item)
            } catch is CancellationError {
                item.status = .failed(L("已取消"))
            } catch {
                item.status = .failed(error.localizedDescription)
                item.progress = nil
            }
        }
    }

    func cancel(_ item: ResultItem) {
        item.task?.cancel()
    }

    // MARK: - 調整（全部從原檔重新開始）

    func rerun(_ item: ResultItem, _ change: (inout Options) -> Void) {
        change(&item.options)
        start(item)
    }

    func downscaleStep(_ item: ResultItem) {
        let s = item.options.scale
        let next: Double = s > 0.76 ? 0.75 : s > 0.51 ? 0.5 : max(0.1, ((s - 0.1) * 10).rounded() / 10)
        guard next < s - 0.001 else { return }
        rerun(item) { $0.scale = next }
    }

    func setScale(_ item: ResultItem, _ s: Double) { rerun(item) { $0.scale = s } }
    func setCrop(_ item: ResultItem, _ c: CropSpec?) { rerun(item) { $0.crop = c } }
    func setFit(_ item: ResultItem, _ b: Int64?) { rerun(item) { $0.fitUnder = b } }
    func setSpeed(_ item: ResultItem, _ v: Double) { rerun(item) { $0.speed = v } }
    func toggleMute(_ item: ResultItem) { rerun(item) { $0.mute.toggle() } }
    func toggleAggressive(_ item: ResultItem) { rerun(item) { $0.aggressive.toggle() } }
    func setLoudness(_ item: ResultItem, _ l: Double?) { rerun(item) { $0.loudness = l } }
    func setWatermark(_ item: ResultItem, _ t: String?) { rerun(item) { $0.watermark = t } }
    func runPipeline(_ item: ResultItem, _ p: Pipeline) { start(item, pipeline: p) }

    func convert(_ item: ResultItem, to target: Target, keepPrevious: Bool) {
        item.lastTouch = Date()
        item.status = .working
        item.progress = nil
        let settings = self.settings
        let url = item.url, opts = item.options, prev = item.lastConversion
        let progress: ProgressHandler = { [weak item] v in Task { @MainActor in item?.progress = v } }
        item.task?.cancel()
        item.task = Task {
            do {
                let out = try await Optimizer.convert(url, to: target, opts, settings: settings, keepPrevious: keepPrevious, previous: prev, progress: progress)
                item.lastConversion = out
                item.status = item.newSize == nil ? .skipped : .done
                item.progress = nil
                item.note = L("已另存 %@（%@）", out.lastPathComponent, formatBytes(out.fileSize))
                if item.isClipboard { writeClipboard(out, for: item) }
            } catch is CancellationError {
                item.status = .failed(L("已取消"))
            } catch {
                item.status = .failed(error.localizedDescription)
                item.progress = nil
            }
        }
    }

    func cropPDF(_ item: ResultItem, aspect: Double, name: String) {
        item.status = .working
        let url = item.url
        item.task = Task {
            do {
                let out = try await PDFCropper.crop(url, aspect: aspect)
                item.url = out
                item.newSize = out.fileSize
                item.status = .done
                item.note = L("已依 %@ 裁切頁邊", name)
                loadThumbnail(item)
            } catch {
                item.status = .failed(error.localizedDescription)
            }
        }
    }

    func restore(_ item: ResultItem) {
        item.task?.cancel()
        item.lastTouch = Date()
        if let original = item.clipboardOriginal {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.declareTypes(original.map(\.0) + [ClipboardWatcher.marker], owner: nil)
            for (t, d) in original { pb.setData(d, forType: t) }
            pb.setData(Data(), forType: ClipboardWatcher.marker)
            ClipboardWatcher.shared.lastChange = pb.changeCount
            item.clipboardChangeCount = pb.changeCount
        }
        do {
            let out = try Backups.shared.restore(item.url)
            item.url = out
            item.newSize = out.fileSize
            item.options = Options()
            item.status = .restored
            item.note = nil
            loadThumbnail(item)
        } catch {
            if item.isClipboard {
                item.status = .restored
            } else {
                item.status = .failed(error.localizedDescription)
            }
        }
    }

    func reveal(_ item: ResultItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.lastConversion ?? item.url])
    }

    func open(_ item: ResultItem) { NSWorkspace.shared.open(item.url) }

    func copy(_ item: ResultItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.isClipboard, let data = try? Data(contentsOf: item.url) {
            pb.declareTypes([.png, ClipboardWatcher.marker], owner: nil)
            pb.setData(data, forType: .png)
            pb.setData(Data(), forType: ClipboardWatcher.marker)
        } else {
            pb.writeObjects([item.url as NSURL])
        }
        ClipboardWatcher.shared.lastChange = pb.changeCount
        if item.isClipboard { item.clipboardChangeCount = pb.changeCount }
        item.note = L("已複製")
    }

    func dismiss(_ item: ResultItem) {
        floating.removeAll { $0.id == item.id }
    }

    func clearHistory() {
        history.removeAll { $0.status.isFinal }
    }

    private func autoDismiss() {
        let limit = settings.resultSeconds
        let now = Date()
        let expired = floating.filter {
            $0.status.isFinal && $0.id != hoveredID && now.timeIntervalSince($0.lastTouch) > limit
        }
        if !expired.isEmpty { floating.removeAll { item in expired.contains { $0.id == item.id } } }
    }

    // MARK: - 輔助

    func writeClipboard(_ url: URL, for item: ResultItem) {
        let pb = NSPasteboard.general
        guard pb.changeCount == item.clipboardChangeCount else {
            item.note = L("剪貼簿已換成別的內容，沒有寫回")
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let type: NSPasteboard.PasteboardType = ext == "png" ? .png : (ext == "jpg" || ext == "jpeg") ? ClipboardWatcher.jpeg : NSPasteboard.PasteboardType(UTTypeFromExt(ext))
        let others = (item.clipboardOriginal ?? []).filter { !ClipboardWatcher.isImageType($0.0) }
        pb.clearContents()
        pb.declareTypes([type, ClipboardWatcher.marker] + others.map(\.0), owner: nil)
        pb.setData(data, forType: type)
        pb.setData(Data(), forType: ClipboardWatcher.marker)
        for (t, d) in others { pb.setData(d, forType: t) }
        ClipboardWatcher.shared.lastChange = pb.changeCount
        item.clipboardChangeCount = pb.changeCount
    }

    private func UTTypeFromExt(_ ext: String) -> String {
        UTType(filenameExtension: ext)?.identifier ?? "public.data"
    }

    func loadThumbnail(_ item: ResultItem) {
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 128, height: 128), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let img = rep?.nsImage else { return }
            Task { @MainActor in item.thumbnail = img }
        }
    }
}

import UniformTypeIdentifiers

enum Notifier {
    @MainActor
    static func error(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "SmallImg"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 簡單的文字輸入對話框
    @MainActor
    static func ask(_ title: String, _ message: String, _ defaultValue: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: L("確定"))
        alert.addButton(withTitle: L("取消"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}
