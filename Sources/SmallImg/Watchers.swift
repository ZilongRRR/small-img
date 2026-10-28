import AppKit
import Carbon
import CoreServices
import os
import UniformTypeIdentifiers

let watchLog = Logger(subsystem: "com.zilong.SmallImg", category: "watch")

// MARK: - 資料夾監看（截圖資料夾 + 自訂監看資料夾）

final class FolderWatcher {
    private var stream: FSEventStreamRef?
    var onFile: (URL) -> Void = { _ in }

    func start(paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            for i in 0..<count where i < paths.count {
                let f = flags[i]
                let isFile = f & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
                let interesting = f & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified) != 0
                if isFile && interesting { watcher.onFile(URL(fileURLWithPath: paths[i])) }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

@MainActor
final class AutoWatch {
    static let shared = AutoWatch()

    private let watcher = FolderWatcher()
    private var pending: Set<String> = []
    private var recent: [String: Date] = [:]

    static let screenshotPrefixes = [
        "Screenshot", "Screen Shot", "Screen Recording", "截圖", "螢幕截圖", "螢幕快照", "螢幕錄影", "截屏", "屏幕快照", "屏幕录制", "スクリーンショット", "画面収録",
    ]

    func restart() {
        let s = AppSettings.shared.data
        var paths = [Paths.screenshotFolder.path]
        paths += s.watchedFolders.filter(\.enabled).map { ($0.path as NSString).expandingTildeInPath }
        watcher.onFile = { url in Task { @MainActor in AutoWatch.shared.event(url) } }
        watcher.start(paths: Array(Set(paths)))
        watchLog.info("監看 \(paths.joined(separator: ", "), privacy: .public)")
    }

    static func isScreenshot(_ url: URL) -> Bool {
        if XAttr.has(url, XAttr.screenCapture) { return true }
        let name = url.lastPathComponent
        return screenshotPrefixes.contains { name.hasPrefix($0) }
    }

    private func event(_ url: URL) {
        watchLog.info("檔案事件 \(url.path, privacy: .public)")
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !pending.contains(url.path) else { return }
        guard FileManager.default.fileExists(atPath: url.path), url.mediaKind != .other else { return }
        guard !XAttr.has(url, XAttr.marker) else { return }
        if let t = recent[url.path], Date().timeIntervalSince(t) < 30 { return }
        pending.insert(url.path)
        Task { @MainActor in
            await waitUntilStable(url)
            pending.remove(url.path)
            dispatch(url)
        }
    }

    /// 等檔案大小連續兩次相同（螢幕錄影寫檔需要時間）
    private func waitUntilStable(_ url: URL) async {
        var last: Int64 = -1
        for _ in 0..<600 {
            try? await Task.sleep(nanoseconds: 800_000_000)
            let size = url.fileSize
            if size > 0 && size == last { return }
            last = size
        }
    }

    private func dispatch(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !XAttr.has(url, XAttr.marker) else { return }
        let s = AppSettings.shared.data
        let kind = url.mediaKind
        recent[url.path] = Date()
        recent = recent.filter { Date().timeIntervalSince($0.value) < 120 }

        watchLog.info("處理 \(url.path, privacy: .public) 截圖=\(Self.isScreenshot(url))")
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if parent == Paths.screenshotFolder.standardizedFileURL.path && Self.isScreenshot(url) {
            // 只處理剛建立的截圖，避免動到舊檔
            let created = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? .distantPast
            guard Date().timeIntervalSince(created) < 600 else { return }
            if kind == .image && s.autoScreenshots || kind == .video && s.autoRecordings {
                Jobs.shared.handle([url], pipeline: s.pipeline(s.screenshotPipeline))
            }
            return
        }
        for folder in s.watchedFolders where folder.enabled && folder.kinds.contains(kind) {
            let root = URL(fileURLWithPath: (folder.path as NSString).expandingTildeInPath).standardizedFileURL.path
            if url.standardizedFileURL.path.hasPrefix(root + "/") {
                Jobs.shared.handle([url], pipeline: s.pipeline(folder.pipelineID))
                return
            }
        }
    }
}

// MARK: - 剪貼簿

@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    static let marker = NSPasteboard.PasteboardType("com.zilong.smallimg.optimised")
    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")

    var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            Task { @MainActor in ClipboardWatcher.shared.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard AppSettings.shared.data.autoClipboard else { return }
        optimiseCurrent(manual: false)
    }

    static func isImageType(_ t: NSPasteboard.PasteboardType) -> Bool {
        let legacy = ["Apple PNG pasteboard type", "NeXT TIFF v4.0 pasteboard type", "com.apple.pict", "Apple PICT pasteboard type"]
        if legacy.contains(t.rawValue) { return true }
        return UTType(t.rawValue)?.conforms(to: .image) ?? false
    }

    func optimiseCurrent(manual: Bool) {
        let pb = NSPasteboard.general
        lastChange = pb.changeCount
        let types = pb.types ?? []
        if types.contains(Self.marker) { return }
        let skip = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        if types.contains(where: { skip.contains($0.rawValue) }) { return }
        if types.contains(.fileURL) {
            guard manual else { return }
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            Jobs.shared.handle(urls)
            return
        }
        var data: Data?
        var ext = "png"
        if let d = pb.data(forType: .png) {
            data = d
        } else if let d = pb.data(forType: Self.jpeg) {
            data = d; ext = "jpg"
        } else if let d = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: d) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let data, data.count > 4096 || manual else { return }
        // 保留所有型別（文字、HTML、網址等），寫回時只換掉圖片
        var original: [(NSPasteboard.PasteboardType, Data)] = []
        for t in types where t != Self.marker {
            if let d = pb.data(forType: t) { original.append((t, d)) }
        }
        Jobs.shared.handleClipboard(data: data, ext: ext, original: original, changeCount: pb.changeCount)
    }
}

// MARK: - 全域快捷鍵

final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        install()
        unregister(id)
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x534D_4C49), id: id)
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hk, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        }
    }

    func unregister(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        handlers[id] = nil
    }

    func isRegistered(_ id: UInt32) -> Bool { refs[id] != nil }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Finder

enum Finder {
    static func selection() -> [URL] {
        let source = """
        tell application "Finder"
            set out to ""
            repeat with f in (selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue else { return [] }
        return result.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}
