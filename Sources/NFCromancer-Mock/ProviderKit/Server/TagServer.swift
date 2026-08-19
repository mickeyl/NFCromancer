import Foundation
import SimBridgeServer

private let kSocketPath = "/tmp/nfcromancer.sock"

/// The domain layer behind `/tmp/nfcromancer.sock`, serving the NFCromancer
/// wire protocol in one of two modes: presenting mock tags, or forwarding to
/// a real USB NFC reader (ACR122U via `ReaderSource`).
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

    /// The tag currently in the field, for the panel to show.
    @Published public private(set) var presentedTag: PresentedTag?
    @Published public private(set) var readerAvailable = false

    // Guarded by the transport's I/O queue
    private var serveMode: ServeMode = .mock
    private var sessionId: Int?
    private var sessionKind: String?          // "ndef" | "tag"
    private var currentTagId: String?
    private var tagGeneration = 0             // bumped on every arrival/removal
    private let reader = ReaderSource()

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
        reader.onReaderAvailability = { [weak self] available in
            guard let self else { return }
            self.transport.performOnIOQueue {
                DispatchQueue.main.async { self.readerAvailable = available }
                self.transport.note(available ? "Reader connected" : "Reader disconnected")
            }
        }
        reader.onTagDetected = { [weak self] tag in
            self?.transport.performOnIOQueue { self?.handleReaderTag(tag) }
        }
        reader.onTagRemoved = { [weak self] in
            self?.transport.performOnIOQueue { self?.handleReaderTagRemoved() }
        }
    }

    public func start(mode: ServeMode, completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(true, forKey: Self.serverEnabledKey)
        transport.performOnIOQueue { [self] in
            serveMode = mode
            if mode == .passthrough {
                reader.start()
            } else {
                reader.stop()
            }
        }
        transport.start(completion: completion)
    }

    public func stop(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(false, forKey: Self.serverEnabledKey)
        reader.stop()
        transport.stop(completion: completion)
    }

    // MARK: - Connection lifecycle (transport I/O queue)

    private func tearDownClientState() {
        sessionId = nil
        sessionKind = nil
        currentTagId = nil
        tagGeneration += 1
        clearPresentedTag()
    }

    // MARK: - Protocol handling (transport I/O queue)

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
            case "beginSession":  handleBeginSession(message)
            case "endSession":    handleEndSession(message)
            case "connectTag":    handleConnectTag(message)
            case "sendAPDU":      handleSendAPDU(message)
            case "restartPolling": break   // the field is always polling in passthrough
            default:
                transport.note("Ignoring unknown message type \(type)")
        }
    }

    private func handleBeginSession(_ message: [String: Any]) {
        guard let sid = (message["sessionId"] as? NSNumber)?.intValue else { return }
        guard sessionId == nil else {
            transport.send(["type": "didBeginSession", "sessionId": sid, "ok": false,
                            "error": "a session is already active"])
            return
        }
        sessionId = sid
        sessionKind = (message["kind"] as? String) ?? "ndef"
        transport.send(["type": "didBeginSession", "sessionId": sid, "ok": true])
        transport.note("Session \(sid) began (\(sessionKind ?? "ndef"))")

        // A tag already resting on the reader when the session starts should be
        // delivered immediately, mirroring how iOS reports a present tag.
        if serveMode == .passthrough, let tag = pendingReaderTag {
            deliver(tag)
        }
    }

    private func handleEndSession(_ message: [String: Any]) {
        guard let sid = (message["sessionId"] as? NSNumber)?.intValue, sid == sessionId else { return }
        sessionId = nil
        sessionKind = nil
        currentTagId = nil
        transport.note("Session \(sid) ended")
    }

    private func handleConnectTag(_ message: [String: Any]) {
        guard let sid = sessionId,
              let tagId = message["tagId"] as? String else { return }
        let ok = (tagId == currentTagId)
        transport.send(["type": "didConnectTag", "sessionId": sid, "tagId": tagId, "ok": ok])
    }

    private func handleSendAPDU(_ message: [String: Any]) {
        guard let requestId = (message["requestId"] as? NSNumber)?.intValue,
              let apduB64 = message["apdu"] as? String,
              let apdu = Data(base64Encoded: apduB64) else { return }
        guard message["tagId"] as? String == currentTagId, currentTagId != nil else {
            transport.send(["type": "apduResponse", "requestId": requestId, "ok": false,
                            "error": "no connected tag"])
            return
        }
        transport.note("APDU → \(apdu.prefix(4).map { String(format: "%02X", $0) }.joined())")
        reader.sendAPDU(apdu) { [weak self] data, sw1, sw2, error in
            guard let self else { return }
            self.transport.performOnIOQueue {
                if let error {
                    self.transport.send(["type": "apduResponse", "requestId": requestId, "ok": false, "error": error])
                } else {
                    self.transport.send([
                        "type": "apduResponse", "requestId": requestId, "ok": true,
                        "data": data.base64EncodedString(), "sw1": Int(sw1), "sw2": Int(sw2),
                    ])
                }
            }
        }
    }

    // MARK: - Reader tag lifecycle (transport I/O queue)

    private var pendingReaderTag: ReaderTag?

    private func handleReaderTag(_ tag: ReaderTag) {
        pendingReaderTag = tag
        publishPresentedTag(tag)
        // Deliver into a waiting session; otherwise it waits for beginSession.
        if sessionId != nil {
            deliver(tag)
        } else {
            transport.note("Tag on reader — \(tag.tech == .iso7816 ? "ISO7816" : "Type 2"), no session yet")
        }
    }

    private func deliver(_ tag: ReaderTag) {
        guard let sid = sessionId else { return }
        tagGeneration += 1
        let tagId = "\(tagGeneration)"
        currentTagId = tagId

        var payload: [String: Any] = [
            "type": "tagDetected",
            "sessionId": sid,
            "tagId": tagId,
            "tech": tag.tech == .iso7816 ? "iso7816" : "type2",
            "uid": tag.uid.map { String(format: "%02x", $0) }.joined(),
        ]
        if let ndef = tag.ndef {
            payload["ndef"] = ndef.base64EncodedString()
        }
        if tag.tech == .iso7816 {
            payload["iso7816"] = ["historicalBytes": tag.historicalBytes.base64EncodedString()]
        }
        transport.send(payload)
        transport.note("Delivered tag \(tagId) to session \(sid)")
    }

    private func handleReaderTagRemoved() {
        pendingReaderTag = nil
        clearPresentedTag()
        guard let sid = sessionId, let tagId = currentTagId else { return }
        currentTagId = nil
        transport.send(["type": "tagRemoved", "sessionId": sid, "tagId": tagId])
        transport.note("Tag removed from reader")
    }

    // MARK: - Publishing

    private func publishPresentedTag(_ tag: ReaderTag) {
        let presented = PresentedTag(
            uid: tag.uid.map { String(format: "%02X", $0) }.joined(separator: " "),
            tech: tag.tech == .iso7816 ? "ISO7816 (ISO-DEP)" : "Type 2 (NTAG/Ultralight)",
            hasNDEF: tag.ndef != nil && !(tag.ndef?.isEmpty ?? true)
        )
        DispatchQueue.main.async { self.presentedTag = presented }
    }

    private func clearPresentedTag() {
        DispatchQueue.main.async { self.presentedTag = nil }
    }
}

/// A tag in the field, for the panel.
public struct PresentedTag: Equatable {
    public let uid: String
    public let tech: String
    public let hasNDEF: Bool
}
