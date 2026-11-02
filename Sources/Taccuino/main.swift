import AppKit

FontLoader.registerBundledFonts()

let application = NSApplication.shared

if CommandLine.arguments.contains("--selftest") {
    application.setActivationPolicy(.prohibited)
    let passed = SelfTest.run()
    exit(passed ? 0 : 1)
}

let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
