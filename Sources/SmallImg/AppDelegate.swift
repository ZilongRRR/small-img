import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var lastWatchKey = ""

    private enum HotKeyID: UInt32 { case clipboard = 1, finder = 2 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure(Paths.support)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left.circle", accessibilityDescription: "SmallImg")
            img?.isTemplate = true
            button.image = img
        }
        menu.delegate = self
        statusItem.menu = menu

        _ = ResultsPanelController.shared
        AutoWatch.shared.restart()
        lastWatchKey = watchKey()
        ClipboardWatcher.shared.start()
        DropZoneController.shared.start()

        HotKeys.shared.register(id: HotKeyID.clipboard.rawValue, keyCode: kVK_ANSI_C, modifiers: controlKey | shiftKey) {
            Task { @MainActor in ClipboardWatcher.shared.optimiseCurrent(manual: true) }
        }
        // Control-O 只在 Finder 在前景時註冊，避免搶走其他 App 的快捷鍵
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self.updateFinderHotKey(frontmost: app?.bundleIdentifier) }
        }
        updateFinderHotKey(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let key = self.watchKey()
                if key != self.lastWatchKey {
                    self.lastWatchKey = key
                    AutoWatch.shared.restart()
                }
            }
        }

        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()

        let days = AppSettings.shared.data.backupDays
        DispatchQueue.global(qos: .background).async { Backups.shared.prune(olderThanDays: days) }

        if !Tools.missing.isEmpty {
            let names = Tools.missing.map(\.brewPackage)
            Notifier.error("缺少壓縮工具，請在終端機執行：\nbrew install \(Array(Set(names)).sorted().joined(separator: " "))")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMain()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Jobs.shared.handle(urls)
    }

    private func watchKey() -> String {
        let s = AppSettings.shared.data
        let folders = s.watchedFolders.filter(\.enabled).map(\.path).sorted().joined(separator: "|")
        return "\(Paths.screenshotFolder.path)#\(folders)"
    }

    private func updateFinderHotKey(frontmost: String?) {
        let id = HotKeyID.finder.rawValue
        if frontmost == "com.apple.finder" {
            if !HotKeys.shared.isRegistered(id) {
                HotKeys.shared.register(id: id, keyCode: kVK_ANSI_O, modifiers: controlKey) {
                    let files = Finder.selection()
                    Task { @MainActor in Jobs.shared.handle(files) }
                }
            }
        } else {
            HotKeys.shared.unregister(id)
        }
    }

    // MARK: - 選單

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = AppSettings.shared.data

        menu.addItem(item("開啟壓縮視窗", #selector(openMain), key: "o"))
        let clip = item("最佳化剪貼簿", #selector(optimiseClipboard), key: "c")
        clip.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(clip)
        menu.addItem(item("選擇檔案並最佳化…", #selector(chooseFiles)))
        menu.addItem(.separator())

        menu.addItem(toggle("自動壓縮截圖", s.autoScreenshots, #selector(toggleScreenshots)))
        menu.addItem(toggle("自動壓縮螢幕錄影", s.autoRecordings, #selector(toggleRecordings)))
        menu.addItem(toggle("自動壓縮剪貼簿圖片", s.autoClipboard, #selector(toggleClipboard)))
        menu.addItem(toggle("強力壓縮", s.aggressive, #selector(toggleAggressive)))
        menu.addItem(.separator())

        let pipelines = NSMenuItem(title: "執行流程", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in s.pipelines {
            let i = item(p.name, #selector(runPipeline(_:)))
            i.representedObject = p.id
            sub.addItem(i)
        }
        pipelines.submenu = sub
        menu.addItem(pipelines)

        let recent = Jobs.shared.history.suffix(5).reversed()
        if !recent.isEmpty {
            let r = NSMenuItem(title: "最近處理", action: nil, keyEquivalent: "")
            let rs = NSMenu()
            for job in recent {
                var title = job.displayName
                if let pct = job.savedPercent, job.status == .done { title += "  -\(pct)%" }
                let i = item(title, #selector(revealRecent(_:)))
                i.representedObject = job.id
                rs.addItem(i)
            }
            r.submenu = rs
            menu.addItem(r)
        }
        menu.addItem(item("打開備份資料夾", #selector(openBackups)))
        menu.addItem(.separator())
        menu.addItem(item("設定…", #selector(openSettings), key: ","))
        menu.addItem(item("結束 SmallImg", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    @objc private func openMain() { WindowManager.shared.showMain() }
    @objc private func openSettings() { WindowManager.shared.showSettings() }
    @objc private func optimiseClipboard() { ClipboardWatcher.shared.optimiseCurrent(manual: true) }
    @objc private func openBackups() { NSWorkspace.shared.open(Paths.backups) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleScreenshots() { AppSettings.shared.data.autoScreenshots.toggle() }
    @objc private func toggleRecordings() { AppSettings.shared.data.autoRecordings.toggle() }
    @objc private func toggleClipboard() { AppSettings.shared.data.autoClipboard.toggle() }
    @objc private func toggleAggressive() { AppSettings.shared.data.aggressive.toggle() }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { Jobs.shared.handle(panel.urls) }
    }

    @objc private func runPipeline(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let p = AppSettings.shared.data.pipeline(id) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "選擇要執行「\(p.name)」的檔案"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { Jobs.shared.handle(panel.urls, pipeline: p) }
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let job = Jobs.shared.history.first(where: { $0.id == id }) else { return }
        if job.isClipboard { WindowManager.shared.showMain() } else { Jobs.shared.reveal(job) }
    }
}

/// Finder 右鍵「服務」選單
final class ServiceProvider: NSObject {
    private func files(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func optimiseFiles(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = files(pb)
        Task { @MainActor in Jobs.shared.handle(urls) }
    }

    @objc func optimiseFilesAggressive(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = files(pb)
        Task { @MainActor in Jobs.shared.handle(urls, aggressive: true) }
    }

    @objc func runPipelineOnFiles(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = files(pb)
        Task { @MainActor in
            let menu = NSMenu()
            for p in AppSettings.shared.data.pipelines {
                let i = NSMenuItem(title: p.name, action: #selector(PipelinePicker.pick(_:)), keyEquivalent: "")
                i.target = PipelinePicker.shared
                i.representedObject = (p, urls)
                menu.addItem(i)
            }
            NSApp.activate(ignoringOtherApps: true)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

@MainActor
final class PipelinePicker: NSObject {
    static let shared = PipelinePicker()
    @objc func pick(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? (Pipeline, [URL]) else { return }
        Jobs.shared.handle(pair.1, pipeline: pair.0)
    }
}
