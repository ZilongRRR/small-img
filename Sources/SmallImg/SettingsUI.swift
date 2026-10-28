import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("一般", systemImage: "gearshape") }
            ConversionTab().tabItem { Label("轉檔", systemImage: "arrow.triangle.2.circlepath") }
            PipelinesTab().tabItem { Label("流程", systemImage: "square.stack.3d.down.right") }
            FoldersTab().tabItem { Label("監看資料夾", systemImage: "folder.badge.gearshape") }
            BackupTab().tabItem { Label("備份與工具", systemImage: "externaldrive") }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
    }
}

struct GeneralTab: View {
    @ObservedObject var s = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("自動") {
                Toggle("自動壓縮新截圖", isOn: $s.data.autoScreenshots)
                Toggle("自動壓縮螢幕錄影", isOn: $s.data.autoRecordings)
                Toggle("自動壓縮複製到剪貼簿的圖片（快捷鍵 Control-Shift-C 手動壓縮）", isOn: $s.data.autoClipboard)
                Picker("截圖完成後執行流程", selection: $s.data.screenshotPipeline) {
                    Text("只做最佳化").tag(UUID?.none)
                    ForEach(s.data.pipelines) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("剪貼簿圖片執行流程", selection: $s.data.clipboardPipeline) {
                    Text("只做最佳化").tag(UUID?.none)
                    ForEach(s.data.pipelines) { Text($0.name).tag(Optional($0.id)) }
                }
                LabeledContent("截圖資料夾") {
                    HStack {
                        Text(Paths.screenshotFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("更改…") {
                            if let u = pickFolder() { s.data.screenshotFolder = u.path }
                        }
                        if s.data.screenshotFolder != nil {
                            Button("用系統設定") { s.data.screenshotFolder = nil }
                        }
                    }
                }
            }
            Section("壓縮") {
                Toggle("預設使用強力壓縮", isOn: $s.data.aggressive)
                Toggle("影片用 Apple 媒體引擎編碼（省電、速度快，檔案稍大）", isOn: $s.data.mediaEngine)
            }
            Section("放置區與結果") {
                Toggle("拖曳檔案時顯示放置區", isOn: $s.data.dropZoneOnDrag)
                Toggle("只在拖曳中按 Option 時才顯示（顯示在游標位置）", isOn: $s.data.dropZoneOptionOnly)
                    .disabled(!s.data.dropZoneOnDrag)
                Stepper("結果視窗停留 \(Int(s.data.resultSeconds)) 秒", value: $s.data.resultSeconds, in: 2...60, step: 1)
                Stepper("超過 \(s.data.batchThreshold) 個檔案時開批次視窗", value: $s.data.batchThreshold, in: 5...500, step: 5)
            }
            Section("系統") {
                Toggle("登入時自動啟動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

struct ConversionTab: View {
    @ObservedObject var s = AppSettings.shared

    var body: some View {
        Form {
            Section("最佳化時自動轉成相容格式") {
                Toggle("HEIC 轉 JPEG", isOn: $s.data.convertHEIC)
                Toggle("TIFF、BMP 轉 JPEG", isOn: $s.data.convertTIFF)
                Toggle("MOV 轉 MP4", isOn: $s.data.convertMOV)
                Toggle("WAV 轉 MP3，AIFF、FLAC 轉 AAC", isOn: $s.data.convertAudio)
            }
            Section("GIF") {
                Stepper("影片轉 GIF 的最大寬度 \(s.data.gifMaxWidth) px", value: $s.data.gifMaxWidth, in: 240...1920, step: 40)
            }
            Section("依資料夾自動轉檔") {
                Text("到「監看資料夾」加入資料夾，並指定含有「轉檔」步驟的流程，例如「轉成 WebP」。放進那個資料夾的檔案都會自動轉檔。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PipelinesTab: View {
    @ObservedObject var s = AppSettings.shared
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(s.data.pipelines) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            if p.showInDropZone { Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary).help("顯示在放置區") }
                        }
                        .tag(p.id)
                    }
                }
                HStack(spacing: 4) {
                    Button { addPipeline() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 180, maxWidth: 220)

            if let idx = s.data.pipelines.firstIndex(where: { $0.id == selection }) {
                PipelineEditor(pipeline: $s.data.pipelines[idx])
            } else {
                Text("選擇或新增一個流程。\n流程可以掛在放置區、截圖、剪貼簿、監看資料夾，也可以用 Finder 右鍵「服務」或命令列執行。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func addPipeline() {
        let p = Pipeline(name: "新流程", steps: [.optimise(aggressive: false)])
        s.data.pipelines.append(p)
        selection = p.id
    }

    private func removeSelected() {
        s.data.pipelines.removeAll { $0.id == selection }
        selection = nil
    }
}

struct PipelineEditor: View {
    @Binding var pipeline: Pipeline

    var body: some View {
        Form {
            TextField("名稱", text: $pipeline.name)
            Toggle("顯示在放置區（預設區）", isOn: $pipeline.showInDropZone)
            Section("步驟（依序執行）") {
                ForEach(pipeline.steps.indices, id: \.self) { i in
                    HStack {
                        Text("\(i + 1).").foregroundStyle(.secondary).frame(width: 20)
                        StepRow(step: $pipeline.steps[i])
                        Spacer()
                        Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == pipeline.steps.count - 1)
                        Button { pipeline.steps.remove(at: i) } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                }
                Menu("新增步驟") {
                    ForEach(Step.templates, id: \.0) { t in
                        Button(t.0) { pipeline.steps.append(t.1) }
                    }
                }
                .fixedSize()
            }
            Section {
                Text("命令列：smallimg pipeline \"\(pipeline.name)\" 檔案…").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard pipeline.steps.indices.contains(j) else { return }
        pipeline.steps.swapAt(i, j)
    }
}

struct StepRow: View {
    @Binding var step: Step

    var body: some View {
        switch step {
        case .optimise(let a):
            Toggle("最佳化（強力）", isOn: Binding(get: { a }, set: { step = .optimise(aggressive: $0) }))
        case .scale(let p):
            Stepper("縮放到 \(p)%", value: Binding(get: { p }, set: { step = .scale(percent: $0) }), in: 5...100, step: 5)
        case .maxWidth(let px):
            HStack {
                Text("寬度上限")
                TextField("", value: Binding(get: { px }, set: { step = .maxWidth(px: max(16, $0)) }), format: .number).frame(width: 70)
                Text("px")
            }
        case .crop(let c):
            HStack {
                Text("裁切")
                TextField("16:9 或 1200x630", text: Binding(get: { c.label }, set: { if let n = CropSpec.parse($0) { step = .crop(n) } }))
                    .frame(width: 110)
            }
        case .convert(let t):
            Picker("轉成", selection: Binding(get: { t }, set: { step = .convert($0) })) {
                ForEach(Target.allCases.filter { $0 != .keep }) { Text($0.label).tag($0) }
            }
            .frame(width: 180)
        case .fitUnder(let mb):
            HStack {
                Text("壓到")
                TextField("", value: Binding(get: { mb }, set: { step = .fitUnder(mb: max(0.05, $0)) }), format: .number).frame(width: 60)
                Text("MB 以下")
            }
        case .watermark(let t):
            HStack {
                Text("浮水印")
                TextField("文字或圖片路徑", text: Binding(get: { t }, set: { step = .watermark(text: $0) }))
            }
        case .mute:
            Text("移除音訊")
        case .speed(let v):
            Stepper("速度 \(v.clean)x", value: Binding(get: { v }, set: { step = .speed($0) }), in: 0.25...8, step: 0.25)
        case .loudness(let l):
            Picker("響度", selection: Binding(get: { l }, set: { step = .loudness($0) })) {
                Text("-14 LUFS").tag(-14.0)
                Text("-16 LUFS").tag(-16.0)
            }
            .frame(width: 160)
        case .moveTo(let p):
            HStack {
                Text("移到")
                TextField("~/Pictures/{yyyy}-{MM}", text: Binding(get: { p }, set: { step = .moveTo(path: $0) }))
            }
            .help("可用 {yyyy} {MM} {dd} {name}")
        case .copyFile:
            Text("複製檔案到剪貼簿")
        case .copyPath:
            Text("複製路徑")
        case .copyMarkdown:
            Text("複製成 Markdown 連結")
        case .shell(let c):
            HStack {
                Text("指令")
                TextField("$FILE 是檔案路徑", text: Binding(get: { c }, set: { step = .shell(command: $0) })).font(.system(.body, design: .monospaced))
            }
        }
    }
}

struct FoldersTab: View {
    @ObservedObject var s = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("放進這些資料夾（含子資料夾）的新檔案會自動處理。").foregroundStyle(.secondary)
            List {
                ForEach($s.data.watchedFolders) { $f in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle("", isOn: $f.enabled).labelsHidden()
                            Text(f.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { s.data.watchedFolders.removeAll { $0.id == f.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        HStack {
                            Picker("流程", selection: $f.pipelineID) {
                                Text("只做最佳化").tag(UUID?.none)
                                ForEach(s.data.pipelines) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .frame(width: 240)
                            ForEach([MediaKind.image, .video, .pdf, .audio], id: \.self) { k in
                                Toggle(k.label, isOn: Binding(
                                    get: { f.kinds.contains(k) },
                                    set: { on in if on { f.kinds.append(k) } else { f.kinds.removeAll { $0 == k } } }
                                ))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Button("加入資料夾…") {
                if let u = pickFolder() { s.data.watchedFolders.append(WatchedFolder(path: u.path)) }
            }
        }
    }
}

struct BackupTab: View {
    @ObservedObject var s = AppSettings.shared
    @State private var size = Backups.shared.totalSize
    @State private var cliInstalled = FileManager.default.fileExists(atPath: CLIInstaller.linkPath)

    var body: some View {
        Form {
            Section("備份") {
                LabeledContent("位置") {
                    HStack {
                        Text(Paths.backups.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("打開") { NSWorkspace.shared.open(Paths.backups) }
                    }
                }
                LabeledContent("目前使用", value: formatBytes(size))
                Stepper("保留 \(s.data.backupDays) 天", value: $s.data.backupDays, in: 1...365)
                Button("清除全部備份") {
                    Backups.shared.clearAll()
                    size = Backups.shared.totalSize
                }
            }
            Section("命令列工具") {
                LabeledContent("smallimg") {
                    HStack {
                        Text(cliInstalled ? CLIInstaller.linkPath : "尚未安裝").foregroundStyle(.secondary)
                        Button(cliInstalled ? "重新安裝" : "安裝") {
                            CLIInstaller.install()
                            cliInstalled = FileManager.default.fileExists(atPath: CLIInstaller.linkPath)
                        }
                    }
                }
            }
            Section("壓縮工具") {
                ForEach(Tool.allCases, id: \.self) { t in
                    LabeledContent(t.rawValue) {
                        if let p = Tools.path(t) {
                            Text(p).foregroundStyle(.secondary)
                        } else {
                            Text("缺少：brew install \(t.brewPackage)").foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
func pickFolder() -> URL? {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.allowsMultipleSelection = false
    NSApp.activate(ignoringOtherApps: true)
    return p.runModal() == .OK ? p.url : nil
}

enum CLIInstaller {
    static var linkPath: String {
        FileManager.default.isWritableFile(atPath: "/opt/homebrew/bin") ? "/opt/homebrew/bin/smallimg" : "/usr/local/bin/smallimg"
    }

    @MainActor
    static func install() {
        guard let exe = Bundle.main.executablePath else { return }
        let fm = FileManager.default
        try? fm.removeItem(atPath: linkPath)
        do {
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: exe)
        } catch {
            Notifier.error("無法建立 \(linkPath)：\(error.localizedDescription)")
        }
    }
}
