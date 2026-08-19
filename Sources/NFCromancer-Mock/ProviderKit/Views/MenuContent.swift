import SwiftUI
import SimBridgeServer
import SimBridgeShell

/// The standalone app's control panel: a title header and an app footer
/// wrapped around `NFCromancerSection`, which carries the actual provider UI.
public struct MenuContent: View {
    @ObservedObject var server: TagServer
    @ObservedObject var transport: ProtocolServer
    @ObservedObject var controller: ModeTransitionController<ProviderMode>
    let onDismiss: () -> Void

    @State private var dismissOnDeactivate = ShellPreferences.dismissControlWindowOnDeactivate
    @State private var launchAtLogin = MenuContent.launchAgent.isEnabled
    private static let launchAgent = LaunchAtLogin(label: "de.vanille.nfcromancer-mock")

    public init(
        server: TagServer,
        transport: ProtocolServer,
        controller: ModeTransitionController<ProviderMode>,
        onDismiss: @escaping () -> Void
    ) {
        self.server = server
        self.transport = transport
        self.controller = controller
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            NFCromancerSection(
                server: server,
                transport: transport,
                controller: controller
            )
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "wave.3.right")
                .font(.title2)
            Text("NFCromancer")
                .font(.title3.weight(.semibold))
            Spacer()
            Text(AppVersion.current)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Dismiss panel on app switch", isOn: $dismissOnDeactivate)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: dismissOnDeactivate) { _, newValue in
                    ShellPreferences.dismissControlWindowOnDeactivate = newValue
                }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, newValue in
                    Self.launchAgent.setEnabled(newValue)
                }
            HStack {
                Button("Quit NFCromancer") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Button("Close") {
                    onDismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .font(.callout)
        }
        .padding(12)
    }
}
