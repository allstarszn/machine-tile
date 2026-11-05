import AppKit

// Proof mode: print every number the tile would show, once, then exit. It runs
// before the one-copy check on purpose, so it works while the app is already open.
if CommandLine.arguments.contains("--machine-dump") {
    MachineDump.run()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--machine-states"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { MachineSnapshotWriter.runStates(into: CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--machine-snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { MachineSnapshotWriter.run(into: CommandLine.arguments[i + 1]) }
    exit(0)
}

// One copy at a time: a second launch steps aside rather than adding a second icon.
let bundleID = Bundle.main.bundleIdentifier ?? "com.machinetile.app"
let mine = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != mine }
if !others.isEmpty {
    others.first?.activate()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
