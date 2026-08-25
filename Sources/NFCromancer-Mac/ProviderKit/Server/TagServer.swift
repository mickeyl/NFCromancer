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

    /// The mock tag library, exposed so the panel can present tags.
    public let store = TagStore()
    /// A mock tag the panel has presented into the active session, so it can
    /// show which one is "on the reader" and offer to remove it.
    @Published public private(set) var presentedMockTagId: UUID?
    /// True while a simulator session is waiting for a tag — the panel enables
    /// its Present buttons only then.
    @Published public private(set) var sessionWaiting = false
    /// Fixtures uploaded by the connected client, shown read-only in the panel.
    @Published public private(set) var clientConfiguration: ClientTagConfiguration?

    /// Client-uploaded fixtures, keyed by their wire id. Deliberately in-memory
    /// only: never persisted to the user's library, cleared with the connection.
    private var clientSuppliedTags: [String: MockTag]?

    // Guarded by the transport's I/O queue
    private var serveMode: ServeMode = .mock
    private var sessionId: Int?
    private var sessionKind: String?          // "ndef" | "tag"
    private var currentTagId: String?
    private var tagGeneration = 0             // bumped on every arrival/removal
    private var currentMockTag: MockTag?
    private let reader = ReaderSource()

    private static let serverEnabledKey = "ServerEnabled"

    public init() {
        transport = ProtocolServer(
            socketPath: kSocketPath,
            name: "NFCromancer-Mac",
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

    // MARK: - Mock tag presentation

    /// Deliver a mock tag into the waiting session (the panel's "tap").
    public func present(_ tag: MockTag) {
        transport.performOnIOQueue { [weak self] in self?.deliverMockTag(tag) }
    }

    /// Shared delivery for panel-presented and client-fixture tags.
    private func deliverMockTag(_ tag: MockTag) {
        guard sessionId != nil else { return }
        if currentMockTag != nil { retractMockTag() }
        currentMockTag = tag
        DispatchQueue.main.async { self.presentedMockTagId = tag.id }

        tagGeneration += 1
        let tagId = "\(tagGeneration)"
        currentTagId = tagId

        var payload: [String: Any] = [
            "type": "tagDetected",
            "sessionId": sessionId!,
            "tagId": tagId,
            "tech": "type2",
            "uid": tag.uidBytes.map { String(format: "%02x", $0) }.joined(),
        ]
        if let ndef = tag.ndefMessage {
            payload["ndef"] = ndef.base64EncodedString()
        }
        transport.send(payload)
        transport.note("Presented '\(tag.name)'")
    }

    /// Reasons a host-side write can't proceed, surfaced to the panel.
    public enum WriteRefused: LocalizedError {
        case noWritableCard
        case noNDEF

        public var errorDescription: String? {
            switch self {
                case .noWritableCard: "Place a writable Type 2 tag (NTAG/Ultralight) on the reader first."
                case .noNDEF:         "This mock tag carries no NDEF message to write."
            }
        }
    }

    /// Write a mock tag's NDEF onto the Type 2 card resting on the reader — the
    /// write-out counterpart to copying a card in. Completion is delivered on
    /// the main thread for the panel.
    public func writeToReader(_ tag: MockTag, completion: @escaping (Result<Void, Error>) -> Void) {
        transport.performOnIOQueue { [weak self] in
            guard let self else { return }
            let finish: (Result<Void, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            guard let reading = self.pendingReaderTag, reading.tech == .type2 else {
                finish(.failure(WriteRefused.noWritableCard))
                return
            }
            guard let message = tag.ndefMessage, !message.isEmpty else {
                finish(.failure(WriteRefused.noNDEF))
                return
            }
            self.transport.note("Writing '\(tag.name)' to card…")
            self.reader.writeType2NDEF(message) { [weak self] result in
                finish(result)
                self?.transport.performOnIOQueue {
                    guard let self else { return }
                    switch result {
                        case .success:
                            self.transport.note("Wrote '\(tag.name)' to card")
                            // Reflect the freshly written content in the panel so
                            // the card now reads back what was just burned in.
                            self.pendingReaderTag?.ndef = message
                            if let updated = self.pendingReaderTag { self.publishPresentedTag(updated) }
                        case .failure(let error):
                            self.transport.note("Write failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Remove the presented mock tag from the field.
    public func retract() {
        transport.performOnIOQueue { [weak self] in self?.retractMockTag() }
    }

    private func retractMockTag() {
        guard let sid = sessionId, let tagId = currentTagId, currentMockTag != nil else { return }
        currentMockTag = nil
        currentTagId = nil
        DispatchQueue.main.async { self.presentedMockTagId = nil }
        transport.send(["type": "tagRemoved", "sessionId": sid, "tagId": tagId])
        transport.note("Retracted mock tag")
    }

    // MARK: - Connection lifecycle (transport I/O queue)

    private func tearDownClientState() {
        sessionId = nil
        sessionKind = nil
        currentTagId = nil
        currentMockTag = nil
        clientSuppliedTags = nil
        tagGeneration += 1
        publishSessionWaiting(false)
        publishClientConfiguration(nil)
        DispatchQueue.main.async { self.presentedMockTagId = nil }
        clearPresentedTag()
    }

    private func publishSessionWaiting(_ waiting: Bool) {
        DispatchQueue.main.async { self.sessionWaiting = waiting }
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
            case "setMockConfiguration":   handleSetMockConfiguration(message)
            case "clearMockConfiguration": clearClientConfiguration()
            case "presentTag":    handlePresentTag(message)
            default:
                transport.note("Ignoring unknown message type \(type)")
        }
    }

    // MARK: - Client-supplied fixtures (transport I/O queue)

    private func handleSetMockConfiguration(_ message: [String: Any]) {
        guard let raw = message["configuration"] ?? message["tags"].map({ ["tags": $0] }) else {
            sendConfigurationResult(ok: false, error: "missing configuration")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw)
            let config = try JSONDecoder().decode(ClientTagConfiguration.self, from: data)
            var byId: [String: MockTag] = [:]
            for t in config.tags {
                byId[t.id] = t.asMockTag
            }
            clientSuppliedTags = byId
            publishClientConfiguration(config)
            sendConfigurationResult(ok: true, error: nil)
            transport.note("Client supplied \(byId.count) fixture tag(s)")
        } catch {
            // Fail loudly: a malformed fixture is otherwise indistinguishable
            // from an empty environment.
            transport.note("Rejected client fixtures: \(error.localizedDescription)")
            sendConfigurationResult(ok: false, error: error.localizedDescription)
        }
    }

    private func clearClientConfiguration() {
        guard clientSuppliedTags != nil else { return }
        clientSuppliedTags = nil
        publishClientConfiguration(nil)
        transport.note("Client fixtures cleared")
    }

    private func handlePresentTag(_ message: [String: Any]) {
        guard let tagKey = message["tagId"] as? String else { return }
        guard let tag = clientSuppliedTags?[tagKey] else {
            transport.send(["type": "didPresentTag", "tagId": tagKey, "ok": false,
                            "error": "no fixture tag '\(tagKey)'"])
            return
        }
        deliverMockTag(tag)
        transport.send(["type": "didPresentTag", "tagId": tagKey, "ok": true])
    }

    private func sendConfigurationResult(ok: Bool, error: String?) {
        var msg: [String: Any] = ["type": "didSetMockConfiguration", "ok": ok]
        if let error { msg["error"] = error }
        transport.send(msg)
    }

    private func publishClientConfiguration(_ config: ClientTagConfiguration?) {
        DispatchQueue.main.async { self.clientConfiguration = config }
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
        publishSessionWaiting(true)

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
        currentMockTag = nil
        publishSessionWaiting(false)
        DispatchQueue.main.async { self.presentedMockTagId = nil }
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
        let ndef = (tag.ndef?.isEmpty ?? true) ? nil : tag.ndef
        let presented = PresentedTag(
            uid: tag.uid.map { String(format: "%02X", $0) }.joined(separator: " "),
            uidHex: tag.uid.map { String(format: "%02x", $0) }.joined(),
            tech: tag.tech == .iso7816 ? "ISO7816 (ISO-DEP)" : "Type 2 (NTAG/Ultralight)",
            isType2: tag.tech == .type2,
            hasNDEF: ndef != nil,
            ndef: ndef,
            ndefText: ndef.flatMap(NDEFDecoder.firstText),
            ndefImage: ndef.flatMap(NDEFDecoder.firstImage)
        )
        DispatchQueue.main.async { self.presentedTag = presented }
    }

    private func clearPresentedTag() {
        DispatchQueue.main.async { self.presentedTag = nil }
    }
}

/// A tag in the field, for the panel.
public struct PresentedTag: Equatable {
    /// UID as spaced uppercase hex, for display.
    public let uid: String
    /// UID as compact lowercase hex, the form a captured mock stores.
    public let uidHex: String
    public let tech: String
    /// True for Type 2 (NTAG/Ultralight) — the technology v1 can write.
    public let isType2: Bool
    public let hasNDEF: Bool
    /// The NDEF message read on arrival, for snapshotting into the library.
    public let ndef: Data?
    /// The first Well-Known Text record's text, if the NDEF carries one.
    public let ndefText: String?
    /// The first image Media-type record's bytes, if the NDEF carries one.
    public let ndefImage: Data?
}
