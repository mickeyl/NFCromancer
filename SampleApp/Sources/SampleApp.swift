import SwiftUI
import CoreNFC
import NFCromancer

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var scanner = NFCScanner()
    @State private var readingAvailable = false

    var body: some View {
        NavigationStack {
            List {
                Section("Availability") {
                    LabeledContent("NFC reading available") {
                        Text(readingAvailable ? "Yes" : "No")
                            .foregroundStyle(readingAvailable ? .green : .red)
                    }
                }

                Section("NDEF scan") {
                    Button("Scan NDEF tag") { scanner.scanNDEF() }
                    ForEach(scanner.ndefRecords.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scanner.ndefRecords[i].title).font(.headline)
                            Text(scanner.ndefRecords[i].detail)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("ISO7816 (raw APDU)") {
                    Button("Read tag & SELECT app") { scanner.scanTagAndSelect() }
                    if !scanner.apduLog.isEmpty {
                        ForEach(scanner.apduLog.indices, id: \.self) { i in
                            Text(scanner.apduLog[i])
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                if let status = scanner.status {
                    Section("Status") {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("NFCromancer Sample")
        }
        .task {
            while !Task.isCancelled {
                readingAvailable = NFCNDEFReaderSession.readingAvailable
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct NDEFRecord: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

@MainActor
final class NFCScanner: NSObject, ObservableObject, NFCNDEFReaderSessionDelegate, NFCTagReaderSessionDelegate {
    @Published var ndefRecords: [NDEFRecord] = []
    @Published var apduLog: [String] = []
    @Published var status: String?

    private var ndefSession: NFCNDEFReaderSession?
    private var tagSession: NFCTagReaderSession?

    // MARK: - NDEF

    func scanNDEF() {
        ndefRecords = []
        status = "Present an NDEF tag on the reader…"
        let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        ndefSession = session
        session.begin()
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let records = messages.flatMap { $0.records }.map { record -> NDEFRecord in
            let typeString = String(data: record.type, encoding: .utf8) ?? record.type.map { String(format: "%02X", $0) }.joined()
            // Well-known records carry structured payloads: a Text record
            // prefixes a status byte + language code, a URI record an
            // abbreviation byte. Use CoreNFC's decoders rather than reading the
            // raw payload as a string (which would surface the "en" prefix).
            let detail: String
            if let uri = record.wellKnownTypeURIPayload() {
                detail = uri.absoluteString
            } else if let (text, locale) = textPayload(record) {
                detail = "\(text)  [\(locale?.identifier ?? "?")]"
            } else {
                detail = String(data: record.payload, encoding: .utf8) ?? "\(record.payload.count) bytes"
            }
            return NDEFRecord(title: "TNF \(record.typeNameFormat.rawValue) · \(typeString)", detail: detail)
        }
        Task { @MainActor in
            self.ndefRecords = records
            self.status = "Read \(records.count) NDEF record(s)"
        }
    }

    private nonisolated func textPayload(_ record: NFCNDEFPayload) -> (String, Locale?)? {
        guard record.typeNameFormat == .nfcWellKnown, record.type == Data("T".utf8),
              let status = record.payload.first else { return nil }
        let langLen = Int(status & 0x3F)
        let bytes = record.payload.dropFirst(1)
        guard bytes.count >= langLen else { return nil }
        let lang = String(data: bytes.prefix(langLen), encoding: .utf8)
        let text = String(data: bytes.dropFirst(langLen), encoding: .utf8) ?? ""
        return (text, lang.map(Locale.init(identifier:)))
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in self.status = "NDEF session ended: \(error.localizedDescription)" }
    }

    nonisolated func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {}

    // MARK: - Tag / APDU

    func scanTagAndSelect() {
        apduLog = []
        status = "Present an ISO7816 tag on the reader…"
        let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
        tagSession = session
        session?.begin()
    }

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in self.status = "Tag session ended: \(error.localizedDescription)" }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard case let .iso7816(tag)? = tags.first else {
            Task { @MainActor in self.status = "Detected a non-ISO7816 tag" }
            return
        }
        session.connect(to: tags.first!) { error in
            if let error {
                Task { @MainActor in self.status = "connect failed: \(error.localizedDescription)" }
                return
            }
            // SELECT by AID (PPSE, harmless on most cards) to prove the APDU path.
            let aid = Data([0x32, 0x50, 0x41, 0x59, 0x2E, 0x53, 0x59, 0x53,
                            0x2E, 0x44, 0x44, 0x46, 0x30, 0x31])
            let select = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4,
                                        p1Parameter: 0x04, p2Parameter: 0x00,
                                        data: aid, expectedResponseLength: 256)
            tag.sendCommand(apdu: select) { response, sw1, sw2, error in
                Task { @MainActor in
                    if let error {
                        self.apduLog.append("SELECT PPSE → error: \(error.localizedDescription)")
                    } else {
                        self.apduLog.append(String(format: "SELECT PPSE → SW=%02X%02X, %d bytes", sw1, sw2, response.count))
                        if !response.isEmpty {
                            self.apduLog.append(response.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " "))
                        }
                    }
                    self.status = "APDU round-trip complete"
                    session.invalidate()
                }
            }
        }
    }
}
