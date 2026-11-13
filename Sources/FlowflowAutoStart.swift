import AppKit
import Foundation

@MainActor enum FlowflowAutoStart {
    static func install() {
        let app = Bundle.main.bundleURL.standardizedFileURL
        // Disk-image paths disappear on eject. Register only an installed copy.
        guard !app.path.hasPrefix("/Volumes/"), app.pathExtension == "app" else { return }
        let monitor = app.appendingPathComponent("Contents/MacOS/FlowflowMonitor")
        guard FileManager.default.isExecutableFile(atPath: monitor.path) else { return }
        let label = "local.flowflow.monitor"
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plist = folder.appendingPathComponent(label + ".plist")
        let payload: [String: Any] = ["Label": label, "ProgramArguments": [monitor.path, app.path],
                                      "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background"]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
            let domain = "gui/\(getuid())"
            func launchctl(_ arguments: [String]) {
                let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                task.arguments = arguments; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
                if (try? task.run()) != nil { task.waitUntilExit() }
            }
            launchctl(["bootout", domain + "/" + label])
            launchctl(["bootstrap", domain, plist.path])
        } catch { NSLog("Flowflow automatic launch setup failed: %@", error.localizedDescription) }
    }
}
