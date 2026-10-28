import Foundation

/// 原始檔備份：第一次替換檔案前把原檔複製到備份資料夾，之後所有調整都從原檔重新開始。
final class Backups {
    static let shared = Backups()

    struct Entry: Codable {
        var backupPath: String
        var originalPath: String
        var date: Date
    }

    private let lock = NSLock()
    private var index: [String: Entry] = [:]
    private var indexURL: URL { Paths.backups.appendingPathComponent("index.json") }

    private init() {
        Paths.ensure(Paths.backups)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    /// 重新從磁碟讀取（命令列與 App 共用索引）
    func reload() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded
        }
    }

    func original(for url: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let e = index[url.path], FileManager.default.fileExists(atPath: e.backupPath) else { return nil }
        return URL(fileURLWithPath: e.backupPath)
    }

    func entry(for url: URL) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return index[url.path]
    }

    @discardableResult
    func backupIfNeeded(_ url: URL) throws -> URL {
        if let existing = original(for: url) { return existing }
        let day = DateFormatter.backupDay.string(from: Date())
        let dir = Paths.backups.appendingPathComponent(day).appendingPathComponent(UUID().uuidString.prefix(8).description)
        Paths.ensure(dir)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        lock.lock()
        index[url.path] = Entry(backupPath: dest.path, originalPath: url.path, date: Date())
        save()
        lock.unlock()
        return dest
    }

    func moved(from old: URL, to new: URL) {
        lock.lock(); defer { lock.unlock() }
        guard old.path != new.path, let e = index.removeValue(forKey: old.path) else { return }
        index[new.path] = e
        save()
    }

    /// 還原原檔，回傳還原後的路徑。
    func restore(_ url: URL) throws -> URL {
        guard let e = entry(for: url) else { throw ToolError.message("沒有這個檔案的備份") }
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: e.backupPath)
        let original = URL(fileURLWithPath: e.originalPath)
        guard fm.fileExists(atPath: backup.path) else { throw ToolError.message("備份檔已被刪除") }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        if original.path != url.path, fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
        try fm.copyItem(at: backup, to: original)
        XAttr.set(original)
        lock.lock()
        index.removeValue(forKey: url.path)
        save()
        lock.unlock()
        return original
    }

    var totalSize: Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: Paths.backups, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var sum: Int64 = 0
        for case let u as URL in en {
            sum += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return sum
    }

    func prune(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        lock.lock()
        let old = index.filter { $0.value.date < cutoff }
        for (k, e) in old {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: e.backupPath).deletingLastPathComponent())
            index.removeValue(forKey: k)
        }
        save()
        lock.unlock()
        // 剪貼簿暫存圖也一起清
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: Paths.clipboard, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: f) }
        }
    }

    func clearAll() {
        lock.lock()
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: nil) {
            items.forEach { try? fm.removeItem(at: $0) }
        }
        index = [:]
        save()
        lock.unlock()
    }
}

extension DateFormatter {
    static let backupDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
