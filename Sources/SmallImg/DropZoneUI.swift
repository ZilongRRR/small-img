import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum DropHelper {
    /// 從拖放內容取出檔案與網址，並依按鍵決定是否強力壓縮
    static func perform(_ providers: [NSItemProvider], aggressive forced: Bool? = nil, pipeline: Pipeline? = nil) -> Bool {
        let command = NSEvent.modifierFlags.contains(.command)
        let aggressive: Bool? = forced ?? (command ? true : nil)
        let group = DispatchGroup()
        let lock = NSLock()
        var files: [URL] = []
        var remotes: [URL] = []
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    if url.isFileURL { files.append(url) } else if ["http", "https"].contains(url.scheme?.lowercased()) { remotes.append(url) }
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                if !files.isEmpty { Jobs.shared.handle(files, aggressive: aggressive, pipeline: pipeline) }
                if !remotes.isEmpty { Jobs.shared.handleRemote(remotes, aggressive: aggressive, pipeline: pipeline) }
            }
        }
        return !providers.isEmpty
    }

    static let types: [UTType] = [.fileURL, .url]
}

/// 一個放置區格子
struct DropTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    var height: CGFloat = 64
    var aggressive: Bool? = nil
    var pipeline: Pipeline? = nil
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: height > 100 ? 30 : 18)).foregroundStyle(targeted ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: height > 100 ? 15 : 12, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: DropHelper.types, isTargeted: $targeted) { providers in
            DropZoneController.shared.dropped()
            return DropHelper.perform(providers, aggressive: aggressive, pipeline: pipeline)
        }
    }
}

// MARK: - 拖曳時出現的浮動放置區

struct FloatingDropZone: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 6) {
            DropTile(title: "最佳化", subtitle: "按住 Command 放開為強力壓縮", symbol: "arrow.down.right.and.arrow.up.left", height: 70)
            DropTile(title: "強力最佳化", subtitle: "更小的檔案，畫質稍降", symbol: "bolt", height: 44, aggressive: true)
            ForEach(settings.data.pipelines.filter(\.showInDropZone)) { p in
                DropTile(title: p.name, subtitle: p.steps.map(\.label).joined(separator: " → "), symbol: "square.stack.3d.down.right", height: 44, pipeline: p)
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .padding(8)
    }
}

@MainActor
final class DropZoneController {
    static let shared = DropZoneController()

    private let panel = FloatingPanel()
    private var timer: Timer?
    private var lastDragCount = NSPasteboard(name: .drag).changeCount
    private var dragging = false
    private var atCursor = false
    private var hideWork: DispatchWorkItem?

    private init() {
        let host = NSHostingView(rootView: FloatingDropZone())
        panel.contentView = host
        panel.becomesKeyOnlyIfNeeded = true
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor in DropZoneController.shared.tick() }
        }
    }

    func dropped() {
        hideWork?.cancel()
        panel.orderOut(nil)
        dragging = false
    }

    private func tick() {
        let s = AppSettings.shared.data
        let mouseDown = NSEvent.pressedMouseButtons & 1 == 1
        let pb = NSPasteboard(name: .drag)
        if mouseDown && pb.changeCount != lastDragCount {
            lastDragCount = pb.changeCount
            let types = pb.types ?? []
            if s.dropZoneOnDrag && (types.contains(.fileURL) || types.contains(.URL)) && hasMedia(pb) {
                dragging = true
                atCursor = false
                if !s.dropZoneOptionOnly { show(atCursor: false) }
            }
        }
        guard dragging else { return }
        if mouseDown {
            if NSEvent.modifierFlags.contains(.option) && !atCursor {
                atCursor = true
                show(atCursor: true)
            }
        } else {
            dragging = false
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    private func hasMedia(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            return urls.contains { !$0.isFileURL || $0.mediaKind != .other || $0.hasDirectoryPath }
        }
        return false
    }

    private func show(atCursor: Bool) {
        hideWork?.cancel()
        let size = panel.contentView?.fittingSize ?? CGSize(width: 296, height: 200)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var origin: CGPoint
        if atCursor {
            let m = NSEvent.mouseLocation
            origin = CGPoint(x: m.x - size.width / 2, y: m.y - size.height / 2)
            origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)
        } else {
            origin = CGPoint(x: vf.maxX - size.width - 8, y: vf.minY + 8)
            if ResultsPanelController.shared.panel.isVisible {
                origin.y = ResultsPanelController.shared.panel.frame.maxY
            }
            origin.y = min(origin.y, vf.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

// MARK: - 主視窗

struct MainView: View {
    @EnvironmentObject var jobs: Jobs
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropTile(
                title: "拖曳圖片、影片、PDF 或音訊到這裡",
                subtitle: "就地壓縮並保留備份。按住 Command 放開為強力壓縮，也可以拖網址或整個資料夾。",
                symbol: "arrow.down.doc", height: 140
            )
            .overlay(alignment: .bottomTrailing) {
                Button("選擇檔案…") { chooseFiles() }.padding(10)
            }
            let presets = settings.data.pipelines.filter(\.showInDropZone)
            if !presets.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    DropTile(title: "強力最佳化", subtitle: "更小的檔案", symbol: "bolt", height: 50, aggressive: true)
                    ForEach(presets) { p in
                        DropTile(title: p.name, subtitle: p.steps.map(\.label).joined(separator: " → "), symbol: "square.stack.3d.down.right", height: 50, pipeline: p)
                    }
                }
            }
            HStack {
                Text("最近處理").font(.headline)
                Spacer()
                Toggle("強力壓縮", isOn: $settings.data.aggressive).toggleStyle(.switch).controlSize(.mini)
                Button("清除") { jobs.clearHistory() }.disabled(jobs.history.isEmpty)
            }
            if jobs.history.isEmpty {
                Text("還沒有處理過的檔案。截圖、複製圖片或拖檔案進來都會出現在這裡。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(jobs.history.reversed()) { item in
                            ResultCard(item: item, wide: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 520)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .movie, .pdf, .audio, .folder]
        if panel.runModal() == .OK { jobs.handle(panel.urls) }
    }
}

@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, size: CGSize, @ViewBuilder content: () -> V) {
        if let w = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content().environmentObject(Jobs.shared))
        w.center()
        w.setFrameAutosaveName("SmallImg.\(id)")
        windows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) { windows[id]?.close() }

    func showMain() {
        show("main", title: "SmallImg", size: CGSize(width: 520, height: 640)) { MainView() }
    }

    func showSettings() {
        show("settings", title: "SmallImg 設定", size: CGSize(width: 680, height: 520)) { SettingsView() }
    }
}
