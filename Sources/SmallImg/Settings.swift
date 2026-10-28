import Foundation

struct WatchedFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    /// nil 代表只做一般最佳化
    var pipelineID: UUID?
    var kinds: [MediaKind] = [.image, .video, .pdf, .audio]
    var enabled = true
}

struct SettingsData: Codable {
    var autoScreenshots = true
    var autoRecordings = true
    var autoClipboard = true
    var dropZoneOnDrag = true
    var dropZoneOptionOnly = false
    var resultSeconds: Double = 6
    var aggressive = false
    var mediaEngine = false
    var convertHEIC = true
    var convertTIFF = true
    var convertMOV = true
    var convertAudio = true
    var gifMaxWidth = 800
    var backupDays = 14
    var batchThreshold = 30
    var screenshotFolder: String?
    var screenshotPipeline: UUID?
    var clipboardPipeline: UUID?
    var watchedFolders: [WatchedFolder] = []
    var pipelines: [Pipeline] = Pipeline.builtins

    init() {}

    /// 舊版設定檔缺欄位時沿用預設值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsData()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        autoScreenshots = v(.autoScreenshots, d.autoScreenshots)
        autoRecordings = v(.autoRecordings, d.autoRecordings)
        autoClipboard = v(.autoClipboard, d.autoClipboard)
        dropZoneOnDrag = v(.dropZoneOnDrag, d.dropZoneOnDrag)
        dropZoneOptionOnly = v(.dropZoneOptionOnly, d.dropZoneOptionOnly)
        resultSeconds = v(.resultSeconds, d.resultSeconds)
        aggressive = v(.aggressive, d.aggressive)
        mediaEngine = v(.mediaEngine, d.mediaEngine)
        convertHEIC = v(.convertHEIC, d.convertHEIC)
        convertTIFF = v(.convertTIFF, d.convertTIFF)
        convertMOV = v(.convertMOV, d.convertMOV)
        convertAudio = v(.convertAudio, d.convertAudio)
        gifMaxWidth = v(.gifMaxWidth, d.gifMaxWidth)
        backupDays = v(.backupDays, d.backupDays)
        batchThreshold = v(.batchThreshold, d.batchThreshold)
        screenshotFolder = v(.screenshotFolder, d.screenshotFolder)
        screenshotPipeline = v(.screenshotPipeline, d.screenshotPipeline)
        clipboardPipeline = v(.clipboardPipeline, d.clipboardPipeline)
        watchedFolders = v(.watchedFolders, d.watchedFolders)
        pipelines = v(.pipelines, d.pipelines)
    }

    func pipeline(_ id: UUID?) -> Pipeline? {
        guard let id else { return nil }
        return pipelines.first { $0.id == id }
    }
}

enum SettingsStore {
    static var url: URL { Paths.support.appendingPathComponent("settings.json") }

    static func load() -> SettingsData {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SettingsData.self, from: data)
        else { return SettingsData() }
        return s
    }

    static func save(_ s: SettingsData) {
        Paths.ensure(Paths.support)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: url, options: .atomic) }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var data: SettingsData {
        didSet {
            SettingsStore.save(data)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    private init() { data = SettingsStore.load() }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("SmallImgSettingsChanged")
}
