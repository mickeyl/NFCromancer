import Foundation
import SimBridgeServer

private let kSocketPath = "/tmp/nfcromancer.sock"

/// The domain layer behind `/tmp/nfcromancer.sock`, serving the NFCromancer
/// wire protocol in one of two modes: presenting mock tags, or forwarding to
/// a real USB NFC reader (ACR122U via CryptoTokenKit).
///
/// The transport — socket lifecycle, NDJSON framing, hello handshake,
/// last-connection-wins takeover, client-socket hardening, and the
/// socket-ownership guard — is SimBridgeKit's `ProtocolServer`. Every handler
/// here runs on the transport's I/O queue, which also guards all mutable
/// state; UI-facing state is published on the main thread.
public final class TagServer: ObservableObject {
    public enum ServeMode: Sendable {
        case mock
        case passthrough
    }

    /// Socket lifecycle, connection status, client identity, and the activity
    /// line are published by the transport; observe it directly.
    public let transport: ProtocolServer

    // Guarded by the transport's I/O queue
    private var serveMode: ServeMode = .mock

    private static let serverEnabledKey = "ServerEnabled"

    public init() {
        transport = ProtocolServer(
            socketPath: kSocketPath,
            name: "NFCromancer-Mock",
            appVersion: AppVersion.current
        )
        transport.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
        transport.onClientTeardown = { [weak self] _ in
            self?.tearDownClientState()
        }
    }

    public func start(mode: ServeMode, completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(true, forKey: Self.serverEnabledKey)
        transport.performOnIOQueue { [self] in
            serveMode = mode
        }
        transport.start(completion: completion)
    }

    public func stop(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(false, forKey: Self.serverEnabledKey)
        transport.stop(completion: completion)
    }

    // MARK: - Connection lifecycle (transport I/O queue)

    private func tearDownClientState() {
        // Sessions and presented tags will be dropped here from phase 1 on.
    }

    // MARK: - Protocol handling (transport I/O queue)

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
            case "beginSession":
                // Phase 1 brings the real session plumbing; failing loudly
                // beats a session that silently never begins.
                let sessionId = message["sessionId"] ?? NSNull()
                transport.send([
                    "type": "didBeginSession",
                    "sessionId": sessionId,
                    "ok": false,
                    "error": "NFCromancer provider: sessions are not implemented yet (phase 1)",
                ])
                transport.note("Rejected beginSession — phase 1 pending")
            default:
                transport.note("Ignoring unknown message type \(type)")
        }
    }
}
