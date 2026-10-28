import AppKit

if CLI.shouldHandle(CommandLine.arguments) {
    exit(await CLI.run(CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
