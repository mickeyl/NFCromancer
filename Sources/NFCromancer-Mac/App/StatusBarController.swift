import AppKit
import Combine
import SwiftUI
import NFCromancerProviderKit
import SimBridgeServer
import SimBridgeShell

/// Owns the app's menu bar presence. The status item and control panel
/// machinery come from SimBridgeShell's `StatusItemPanelController`; this
/// class contributes the icon, the panel content, and the mode transitions.
@MainActor
final class StatusBarController: NSObject, ObservableObject {
    private let server: TagServer
    let modeController: ModeTransitionController<ProviderMode>
    private var panel: StatusItemPanelController!
    private var cancellables: Set<AnyCancellable> = []
    private static let controlWindowContentSize = NSSize(width: 400, height: 560)
    private static let modeDefaultsKey = "ProviderMode"

    init(server: TagServer) {
        self.server = server
        // Creating the controller restores the persisted provider mode. Mode
        // switches bounce through a stop so a connected client observes a
        // disconnect instead of silently changing provider behavior.
        self.modeController = ModeTransitionController(
            initial: ProviderMode.persisted(key: Self.modeDefaultsKey),
            persist: { $0.persist(key: Self.modeDefaultsKey) }
        ) { mode, completion in
            switch mode {
                case .off:
                    server.stop(completion: completion)
                case .mock:
                    server.stop {
                        server.start(mode: .mock, completion: completion)
                    }
                case .passthrough:
                    server.stop {
                        server.start(mode: .passthrough, completion: completion)
                    }
            }
        }
        super.init()
        panel = StatusItemPanelController(
            title: "NFCromancer",
            toolTip: "NFCromancer",
            contentSize: Self.controlWindowContentSize
        ) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(MenuContent(
                server: self.server,
                transport: self.server.transport,
                controller: self.modeController,
                onDismiss: { [weak self] in self?.panel.hidePanel() }
            ))
        }
        observeIconState()
        updateIcon()
    }

    private func observeIconState() {
        // @Published emits in willSet; hop through the main queue so
        // updateIcon() runs after didSet.
        server.transport.$status.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        server.transport.$trafficActive.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
    }

    private func updateIcon() {
        let name: String =
            switch server.transport.status {
                case .stopped, .blocked:
                    "wave.3.right"
                case .listening, .clientConnected:
                    server.transport.trafficActive ? "wave.3.right.circle.fill" : "wave.3.right.circle"
            }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "NFCromancer")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        panel.setIcon(image)
    }
}
