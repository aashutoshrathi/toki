import AppKit

if UpdateInstaller.runHelperIfRequested(arguments: CommandLine.arguments) {
    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
