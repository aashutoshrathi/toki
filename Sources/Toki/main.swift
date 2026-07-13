import AppKit

if UpdateInstaller.runHelperIfRequested(arguments: CommandLine.arguments) {
    exit(EXIT_SUCCESS)
}

if let exitCode = StatusCommand.runIfRequested(arguments: CommandLine.arguments) {
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
