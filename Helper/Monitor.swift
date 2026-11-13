import AppKit
import Foundation

let players: Set<String> = ["com.netease.163music", "com.tencent.QQMusicMac", "com.apple.Music"]
let flowflowID = "local.flowflow.desktop"
guard CommandLine.arguments.count > 1 else { exit(1) }
let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let workspace = NSWorkspace.shared
func supportedRunning() -> Bool {
    workspace.runningApplications.contains { app in
        guard let id = app.bundleIdentifier else { return false }
        return players.contains(id) && !app.isTerminated
    }
}
func startIfNeeded() {
    guard supportedRunning(), NSRunningApplication.runningApplications(withBundleIdentifier: flowflowID).isEmpty else { return }
    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
    workspace.openApplication(at: appURL, configuration: configuration) { _, _ in }
}
let nc = workspace.notificationCenter
let launched = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let id = app.bundleIdentifier, players.contains(id) else { return }
    startIfNeeded()
}
let terminated = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let id = app.bundleIdentifier, players.contains(id) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        guard !supportedRunning() else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: flowflowID).forEach { $0.terminate() }
    }
}
startIfNeeded()
RunLoop.main.run()
withExtendedLifetime((launched, terminated)) {}
