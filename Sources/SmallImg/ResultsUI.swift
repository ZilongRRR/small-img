import AppKit
import Combine
import SwiftUI

// MARK: - 結果卡片

struct ResultCard: View {
    @ObservedObject var item: ResultItem
    @EnvironmentObject var jobs: Jobs
    @ObservedObject var settings = AppSettings.shared
    var wide = false
    /// 游標停在按鈕上時，標題列暫時改成按鈕說明。浮動視窗不會啟用 App，系統 tooltip 出不來，所以自己畫。
    @State private var hint: String?

    init(item: ResultItem, wide: Bool = false, hint: String? = nil) {
        _item = ObservedObject(wrappedValue: item)
        self.wide = wide
        _hint = State(initialValue: hint)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let hint {
                        Text(hint)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    } else {
                        Text(item.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if !wide {
                        IconButton(symbol: "xmark", help: L("關閉")) { jobs.dismiss(item) }
                    }
                }
                statusLine
                if !chips.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(chips, id: \.self) { Chip(text: $0) }
                    }
                }
                if let note = item.note {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                toolbar
                formatBar
            }
        }
        .environment(\.setHint) { text, inside in
            if inside { hint = text } else if hint == text { hint = nil }
        }
        .padding(10)
        .frame(width: wide ? nil : 360)
        .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .onHover { inside in
            item.lastTouch = Date()
            if inside {
                jobs.hoveredID = item.id
                if !wide { ResultsPanelController.shared.makeKey() }
            } else if jobs.hoveredID == item.id {
                jobs.hoveredID = nil
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
            if let img = item.thumbnail {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbol(for: item.kind)).font(.system(size: 22)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .onTapGesture(count: 2) { jobs.open(item) }
        .hint(L("拖出檔案，或點兩下打開"))
    }

    @ViewBuilder private var statusLine: some View {
        switch item.status {
        case .queued:
            Text(L("排隊中")).font(.system(size: 11)).foregroundStyle(.secondary)
        case .working:
            HStack(spacing: 6) {
                if let p = item.progress {
                    ProgressView(value: p).progressViewStyle(.linear).frame(maxWidth: 180)
                    Text("\(Int(p * 100))%").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(L("壓縮中")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                IconButton(symbol: "stop.circle", help: L("停止")) { jobs.cancel(item) }
            }
        case .done:
            HStack(spacing: 6) {
                Text("\(formatBytes(item.originalSize)) → \(formatBytes(item.newSize ?? 0))")
                    .font(.system(size: 11).monospacedDigit())
                if let pct = item.savedPercent {
                    Text(pct >= 0 ? "-\(pct)%" : "+\(-pct)%")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((pct >= 0 ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                        .foregroundStyle(pct >= 0 ? Color.green : Color.orange)
                }
            }
        case .skipped:
            Text(L("已經是最佳大小 · %@", formatBytes(item.newSize ?? item.originalSize)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .restored:
            Text(L("已還原原檔 · %@", formatBytes(item.newSize ?? item.originalSize)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var chips: [String] {
        let o = item.options
        var c: [String] = []
        if o.aggressive { c.append(L("強力")) }
        if o.scale < 0.999 { c.append("\(Int((o.scale * 100).rounded()))%") }
        if let cr = o.crop { c.append(L("裁切 %@", cr.label)) }
        if let f = o.fitUnder { c.append("< \(formatBytes(f))") }
        if o.speed != 1 { c.append("\(o.speed.clean)x") }
        if o.mute { c.append(L("靜音")) }
        if let l = o.loudness { c.append("\(Int(l)) LUFS") }
        if o.watermark != nil { c.append(L("浮水印")) }
        return c
    }

    private var busy: Bool { item.status == .working }

    private var toolbar: some View {
        HStack(spacing: 2) {
            if item.status == .restored {
                Button(L("改回壓縮")) { jobs.start(item) }
                    .buttonStyle(FormatButtonStyle())
                    .fixedSize()
                    .hint(L("重新壓縮這個檔案"))
                    .padding(.trailing, 4)
            } else if item.canRestore || item.isClipboard {
                Button(L("保留原檔")) { jobs.restore(item) }
                    .buttonStyle(FormatButtonStyle())
                    .fixedSize()
                    .hint(L("不要壓縮，換回原本的檔案（快捷鍵 z）"))
                    .padding(.trailing, 4)
                    .disabled(busy)
            }
            if !item.isClipboard {
                IconButton(symbol: "folder", help: L("在 Finder 顯示")) { jobs.reveal(item) }
            }
            IconButton(symbol: "doc.on.doc", help: L("複製")) { jobs.copy(item) }

            if item.kind == .image || item.kind == .video {
                Menu {
                    ForEach([90, 80, 75, 70, 60, 50, 40, 30, 25, 20, 10], id: \.self) { p in
                        Button("\(p)%") { jobs.setScale(item, Double(p) / 100) }
                    }
                    Divider()
                    Button(L("原始大小")) { jobs.setScale(item, 1) }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                } primaryAction: {
                    jobs.downscaleStep(item)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .hint(L("縮小尺寸（快捷鍵 -，1 到 9 為 10% 到 90%）"))
                .disabled(busy)

                Menu {
                    ForEach(CropSpec.presets, id: \.self) { c in
                        Button(c.label) { jobs.setCrop(item, c) }
                    }
                    Divider()
                    Button(L("自訂比例或尺寸…")) {
                        if let s = Notifier.ask(L("裁切"), L("輸入比例（例如 16:9）或像素尺寸（例如 1200x630）")), let c = CropSpec.parse(s) {
                            jobs.setCrop(item, c)
                        }
                    }
                    if item.options.crop != nil { Button(L("取消裁切")) { jobs.setCrop(item, nil) } }
                } label: { Image(systemName: "crop") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .hint(L("裁切比例或尺寸"))
                .disabled(busy)
            }

            Menu {
                Button(L("8 MB（Discord）")) { jobs.setFit(item, 8_000_000) }
                Button("10 MB") { jobs.setFit(item, 10_000_000) }
                Button(L("25 MB（Gmail）")) { jobs.setFit(item, 25_000_000) }
                Button("50 MB") { jobs.setFit(item, 50_000_000) }
                Button("1 MB") { jobs.setFit(item, 1_000_000) }
                Button("500 KB") { jobs.setFit(item, 500_000) }
                Divider()
                Button(L("自訂大小…")) {
                    if let s = Notifier.ask(L("壓到指定大小以下"), L("例如 5MB、800KB")), let b = parseBytes(s) { jobs.setFit(item, b) }
                }
                if item.options.fitUnder != nil { Button(L("取消大小限制")) { jobs.setFit(item, nil) } }
            } label: { Image(systemName: "scalemass") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .hint(L("壓到指定大小以下"))
            .disabled(busy)

            moreMenu
        }
        .font(.system(size: 12))
    }

    private var moreMenu: some View {
        Menu {
            Toggle(L("強力壓縮"), isOn: Binding(get: { item.options.aggressive }, set: { _ in jobs.toggleAggressive(item) }))
            if item.kind == .video || item.kind == .audio {
                Menu(L("速度")) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { v in
                        Button("\(v.clean)x") { jobs.setSpeed(item, v) }
                    }
                }
            }
            if item.kind == .video {
                Button(item.options.mute ? L("保留音訊") : L("移除音訊")) { jobs.toggleMute(item) }
            }
            if item.kind == .video || item.kind == .audio {
                Menu(L("響度標準化")) {
                    Button(L("-14 LUFS（串流平台）")) { jobs.setLoudness(item, -14) }
                    Button(L("-16 LUFS（Apple Music）")) { jobs.setLoudness(item, -16) }
                    if item.options.loudness != nil { Button(L("不調整")) { jobs.setLoudness(item, nil) } }
                }
            }
            if item.kind == .image {
                Button(L("加浮水印…")) {
                    if let t = Notifier.ask(L("浮水印"), L("輸入文字，或標誌圖片的路徑"), item.options.watermark ?? "") { jobs.setWatermark(item, t) }
                }
                if item.options.watermark != nil { Button(L("移除浮水印")) { jobs.setWatermark(item, nil) } }
            }
            if item.kind == .pdf {
                Menu(L("裁切頁邊對齊裝置")) {
                    ForEach(PDFCropper.devices, id: \.0) { d in
                        Button(d.0) { jobs.cropPDF(item, aspect: d.1 / d.2, name: d.0) }
                    }
                }
            }
            Menu(L("執行流程")) {
                ForEach(settings.data.pipelines) { p in
                    Button(p.name) { jobs.runPipeline(item, p) }
                }
            }
            Divider()
            Button(L("打開")) { jobs.open(item) }
            if item.lastConversion != nil {
                Button(L("在 Finder 顯示轉檔結果")) { NSWorkspace.shared.activateFileViewerSelecting([item.lastConversion!]) }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .hint(L("更多：強力壓縮、浮水印、執行流程"))
        .disabled(busy)
    }

    @ViewBuilder private var formatBar: some View {
        let targets = Target.targets(for: item.kind).filter { $0.ext != item.url.pathExtension.lowercased() || $0 == .hevc || $0 == .av1 }
        if !targets.isEmpty {
            HStack(spacing: 4) {
                Text(L("轉成")).font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(targets) { t in
                    Button(t.label) {
                        let keep = NSEvent.modifierFlags.contains(.option)
                        jobs.convert(item, to: t, keepPrevious: keep)
                    }
                    .buttonStyle(FormatButtonStyle())
                    .hint(L("另存成 %@（按住 Option 保留上次轉檔）", t.label))
                }
            }
            .disabled(busy)
        }
    }
}

func symbol(for kind: MediaKind) -> String {
    switch kind {
    case .image: return "photo"
    case .video: return "film"
    case .pdf: return "doc.richtext"
    case .audio: return "waveform"
    case .other: return "doc"
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .hint(help)
    }
}

// MARK: - 說明提示

private struct SetHintKey: EnvironmentKey {
    static let defaultValue: (String, Bool) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var setHint: (String, Bool) -> Void {
        get { self[SetHintKey.self] }
        set { self[SetHintKey.self] = newValue }
    }
}

private struct HintModifier: ViewModifier {
    let text: String
    @Environment(\.setHint) private var setHint

    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { setHint(text, $0) }
    }
}

extension View {
    /// 系統 tooltip 加上卡片內的說明文字
    func hint(_ text: String) -> some View { modifier(HintModifier(text: text)) }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

struct FormatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(configuration.isPressed ? 0.2 : 0.08), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 浮動結果視窗

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect = .zero) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }
}

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct FloatingStack: View {
    @EnvironmentObject var jobs: Jobs
    var onSize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(jobs.floating) { item in
                ResultCard(item: item)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .animation(.easeOut(duration: 0.2), value: jobs.floating.map(\.id))
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
        .onPreferenceChange(SizeKey.self) { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

@MainActor
final class ResultsPanelController {
    static let shared = ResultsPanelController()

    let panel = FloatingPanel()
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    private init() {
        let view = FloatingStack(onSize: { size in
            Task { @MainActor in ResultsPanelController.shared.resize(size) }
        }).environmentObject(Jobs.shared)
        panel.contentView = NSHostingView(rootView: view)
        Jobs.shared.$floating
            .receive(on: RunLoop.main)
            .sink { [weak self] items in self?.update(visible: !items.isEmpty) }
            .store(in: &cancellables)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    func makeKey() {
        if panel.isVisible && !panel.isKeyWindow { panel.makeKey() }
    }

    private func update(visible: Bool) {
        if visible {
            if !panel.isVisible {
                position(size: panel.frame.size == .zero ? CGSize(width: 384, height: 140) : panel.frame.size)
                panel.orderFrontRegardless()
            }
        } else {
            panel.orderOut(nil)
        }
    }

    private func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        position(size: size)
    }

    private func position(size: CGSize) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let h = min(size.height, vf.height)
        panel.setFrame(NSRect(x: vf.maxX - size.width, y: vf.minY, width: size.width, height: h), display: true)
    }

    /// 浮動結果的快捷鍵：- 縮小、1 到 9 指定比例、x 關閉、z 還原、c 複製
    private func handleKey(_ e: NSEvent) -> Bool {
        let jobs = Jobs.shared
        guard let id = jobs.hoveredID ?? jobs.floating.last?.id,
              let item = jobs.floating.first(where: { $0.id == id }),
              item.status != .working
        else { return false }
        guard let ch = e.charactersIgnoringModifiers else { return false }
        switch ch {
        case "-": jobs.downscaleStep(item)
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if item.kind == .image || item.kind == .video { jobs.setScale(item, Double(Int(ch)!) / 10) }
        case "x": jobs.dismiss(item)
        case "z": jobs.restore(item)
        case "c": jobs.copy(item)
        case " ": jobs.open(item)
        default:
            if e.keyCode == 53 { jobs.dismiss(item); return true }
            return false
        }
        return true
    }
}
