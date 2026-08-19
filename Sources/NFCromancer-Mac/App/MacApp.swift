import SwiftUI
import AppKit
import NFCromancerProviderKit
import SimBridgeShell

@MainActor
private final class MacAppRuntime {
    let server: TagServer
    let statusBar: StatusBarController

    init() {
        server = TagServer()
        statusBar = StatusBarController(server: server)
    }
}

/// Shuts the socket server down before the process exits so the socket file is
/// unlinked cleanly. Handles every quit path (footer button and ⌘Q).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let server = MacApp.retainedRuntime?.server else {
            return .terminateNow
        }

        server.stop {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MacApp: App {
    fileprivate static var retainedRuntime: MacAppRuntime?

    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    init() {
        if Self.retainedRuntime == nil {
            Self.retainedRuntime = MacAppRuntime()
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
