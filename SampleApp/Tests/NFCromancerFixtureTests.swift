import XCTest
import CoreNFC
import NFCromancer

/// End-to-end headless proof of the client-fixture flow: upload a tag, start a
/// real NFCNDEFReaderSession, present the tag programmatically, and assert the
/// delegate receives its NDEF — no menu-bar interaction, no physical card.
///
/// Requires the NFCromancer provider running in Mock mode on the host.
final class NFCromancerFixtureTests: XCTestCase {

    func testClientFixtureDeliversNDEF() throws {
        try XCTSkipUnless(NFCromancerIsProviderConnected(),
                          "NFCromancer provider not running in Mock mode")

        let fixture = """
        {"name": "QR login", "tags": [
          {"id": "login", "kind": "uri", "value": "https://example.test/login"}
        ]}
        """.data(using: .utf8)!
        XCTAssertTrue(NFCromancerSetMockConfiguration(fixture))
        addTeardownBlock { NFCromancerClearMockConfiguration() }

        let scanned = expectation(description: "NDEF delivered")
        let delegate = Delegate { messages in
            let uris = messages.flatMap { $0.records }.compactMap { $0.wellKnownTypeURIPayload()?.absoluteString }
            XCTAssertEqual(uris, ["https://example.test/login"])
            scanned.fulfill()
        }

        let session = NFCNDEFReaderSession(delegate: delegate, queue: nil, invalidateAfterFirstRead: true)
        session.begin()
        // Give the session a moment to reach the provider, then present.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertTrue(NFCromancerPresentTag("login"))
        }

        wait(for: [scanned], timeout: 5)
        session.invalidate()
    }
}

private final class Delegate: NSObject, NFCNDEFReaderSessionDelegate {
    let onDetect: ([NFCNDEFMessage]) -> Void
    init(onDetect: @escaping ([NFCNDEFMessage]) -> Void) { self.onDetect = onDetect }
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) { onDetect(messages) }
    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {}
    func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {}
}
