import AppKit
import SwiftUI

@MainActor
final class BatchRow: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published var status: JobStatus = .queued
    @Published var progress: Double?
    let originalSize: Int64
    @Published var newSize: Int64?

    init(url: URL) {
        self.url = url
        originalSize = url.fileSize
    }
}

struct KindSettings {
    var target: Target = .keep
    var aggressive = false
    var scale = 100
}

@MainActor
final class BatchModel: ObservableObject {
    @Published var rows: [BatchRow]
    @Published var kindSettings: [MediaKind: KindSettings] = [:]
    @Published var running = false
    private var tasks: [Task<Void, Never>] = []

    init(files: [URL]) {
        rows = files.map(BatchRow.init)
        for k in [MediaKind.image, .video, .pdf, .audio] {
            var ks = KindSettings()
            ks.aggressive = AppSettings.shared.data.aggressive
            kindSettings[k] = ks
        }
    }

    var kinds: [MediaKind] {
        [MediaKind.image, .video, .pdf, .audio].filter { k in rows.contains { $0.url.mediaKind == k } }
    }

    func count(_ k: MediaKind) -> Int { rows.filter { $0.url.mediaKind == k }.count }

    var totalBefore: Int64 { rows.reduce(0) { $0 + $1.originalSize } }
    var totalAfter: Int64 { rows.reduce(0) { $0 + ($1.newSize ?? $1.originalSize) } }
    var doneCount: Int { rows.filter { $0.status.isFinal }.count }

    func binding(_ k: MediaKind) -> Binding<KindSettings> {
        Binding(get: { self.kindSettings[k] ?? KindSettings() }, set: { self.kindSettings[k] = $0 })
    }

    func start() {
        running = true
        let settings = AppSettings.shared.data
        for row in rows where !row.status.isFinal || row.status == .restored {
            let ks = kindSettings[row.url.mediaKind] ?? KindSettings()
            var o = Options()
            o.aggressive = ks.aggressive
            o.scale = Double(ks.scale) / 100
            o.format = ks.target == .keep ? nil : ks.target
            row.status = .working
            let url = row.url
            let progress: ProgressHandler = { [weak row] v in Task { @MainActor in row?.progress = v } }
            tasks.append(Task {
                do {
                    let r = try await Optimizer.optimise(url, o, settings: settings, progress: progress)
                    row.url = r.url
                    row.newSize = r.newSize
                    row.status = r.skipped ? .skipped : .done
                } catch is CancellationError {
                    row.status = .failed("已取消")
                } catch {
                    row.status = .failed(error.localizedDescription)
                }
                row.progress = nil
                if self.rows.allSatisfy({ $0.status.isFinal }) { self.running = false }
            })
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        running = false
    }

    func restoreAll() {
        for row in rows where Backups.shared.entry(for: row.url) != nil {
            if let out = try? Backups.shared.restore(row.url) {
                row.url = out
                row.newSize = out.fileSize
                row.status = .restored
            }
        }
    }
}

struct BatchView: View {
    @ObservedObject var model: BatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批次處理 \(model.rows.count) 個檔案").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("類型").foregroundStyle(.secondary)
                    Text("格式").foregroundStyle(.secondary)
                    Text("解析度").foregroundStyle(.secondary)
                    Text("強力").foregroundStyle(.secondary)
                }
                ForEach(model.kinds, id: \.self) { k in
                    GridRow {
                        Text("\(k.label)（\(model.count(k))）")
                        if k == .pdf {
                            Text("PDF").foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: model.binding(k).target) {
                                Text("保持原格式").tag(Target.keep)
                                ForEach(Target.targets(for: k)) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().frame(width: 130)
                        }
                        if k == .image || k == .video {
                            Picker("", selection: model.binding(k).scale) {
                                ForEach([100, 75, 50, 25], id: \.self) { Text("\($0)%").tag($0) }
                            }
                            .labelsHidden().frame(width: 80)
                        } else {
                            Text("-").foregroundStyle(.secondary)
                        }
                        Toggle("", isOn: model.binding(k).aggressive).labelsHidden()
                    }
                }
            }
            .disabled(model.running)

            HStack {
                if model.running {
                    Button("停止") { model.stop() }
                } else {
                    Button("開始") { model.start() }.keyboardShortcut(.defaultAction)
                }
                Button("全部還原") { model.restoreAll() }.disabled(model.running)
                Spacer()
                Text("\(model.doneCount)/\(model.rows.count) · \(formatBytes(model.totalBefore)) → \(formatBytes(model.totalAfter))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }

            List(model.rows) { row in BatchRowView(row: row) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 480)
    }
}

struct BatchRowView: View {
    @ObservedObject var row: BatchRow

    var body: some View {
        HStack {
            Image(systemName: symbol(for: row.url.mediaKind)).foregroundStyle(.secondary).frame(width: 18)
            Text(row.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            switch row.status {
            case .working:
                if let p = row.progress { ProgressView(value: p).frame(width: 80) } else { ProgressView().controlSize(.small) }
            case .done:
                Text("\(formatBytes(row.originalSize)) → \(formatBytes(row.newSize ?? 0))").monospacedDigit()
            case .skipped:
                Text("已是最佳").foregroundStyle(.secondary)
            case .restored:
                Text("已還原").foregroundStyle(.secondary)
            case .failed(let m):
                Text(m).foregroundStyle(.red).lineLimit(1).help(m)
            case .queued:
                Text(formatBytes(row.originalSize)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.system(size: 12))
    }
}

@MainActor
final class BatchController {
    static let shared = BatchController()
    private var window: NSWindow?
    private var model: BatchModel?

    func open(_ files: [URL]) {
        if let model, model.running {
            model.rows += files.map(BatchRow.init)
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let m = BatchModel(files: files)
        model = m
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "SmallImg 批次處理"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: BatchView(model: m))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
