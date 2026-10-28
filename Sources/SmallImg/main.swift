import AppKit

#if DEBUG
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "render-docs" {
    await DocShots.render(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
#endif

if CLI.shouldHandle(CommandLine.arguments) {
    exit(await CLI.run(CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
