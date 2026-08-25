import Foundation

/// A virtual tag in the mock library. A tag is an *event* (it is tapped, not
/// streamed), so the panel presents it into a waiting session on demand.
public struct MockTag: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: Kind
    /// For `.uri`/`.text`: the payload string. For `.raw`: hex NDEF bytes.
    /// For `.image`: the image bytes, base64-encoded.
    public var value: String
    /// Synthetic UID reported to the app (hex); random if empty.
    public var uid: String
    /// For `.image`: the record's Media-type MIME string (e.g. "image/png").
    /// Unused otherwise; optional so older persisted libraries still decode.
    public var mimeType: String?

    public enum Kind: String, Codable, CaseIterable {
        case uri
        case text
        case image
        case raw    // raw NDEF message bytes, entered as hex

        public var title: String {
            switch self {
                case .uri:   "URI"
                case .text:  "Text"
                case .image: "Image"
                case .raw:   "Raw NDEF"
            }
        }

        /// SF Symbol for list rows.
        public var iconName: String {
            switch self {
                case .uri:   "link"
                case .text:  "text.alignleft"
                case .image: "photo"
                case .raw:   "number"
            }
        }
    }

    public init(id: UUID = UUID(), name: String, kind: Kind, value: String, uid: String = "", mimeType: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.value = value
        self.uid = uid
        self.mimeType = mimeType
    }

    /// `value` for a list row: the base64 blob a `.image` tag carries would be
    /// unreadable, so summarize it as MIME type and byte count instead.
    public var displayValue: String {
        guard kind == .image else { return value }
        let bytes = Data(base64Encoded: value)?.count ?? 0
        return "\(mimeType ?? "image") · \(bytes) bytes"
    }

    /// Snapshot a real card seen in passthrough into a persistent mock. The
    /// NDEF message is kept verbatim as raw bytes so re-presenting reproduces
    /// the card exactly; a card without NDEF yields a blank tag carrying only
    /// its UID (secured cards can't be reproduced beyond that — no keys, no
    /// challenge/response).
    public static func captured(uidHex: String, ndef: Data?) -> MockTag {
        let shortUID = hexData(uidHex)?.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
        let name = shortUID.map { "Captured \($0)" } ?? "Captured card"
        let value = ndef.map { $0.map { String(format: "%02X", $0) }.joined() } ?? ""
        return MockTag(name: name, kind: .raw, value: value, uid: uidHex)
    }

    /// The 7-byte UID bytes to report, deriving a stable synthetic one from the
    /// id when none was set (NXP-style `04` prefix, like a real NTAG).
    public var uidBytes: Data {
        if let explicit = Self.hexData(uid), !explicit.isEmpty {
            return explicit
        }
        var bytes = [UInt8]([0x04])
        withUnsafeBytes(of: id.uuid) { raw in
            bytes.append(contentsOf: raw.prefix(6))
        }
        return Data(bytes)
    }

    /// The NDEF message bytes this tag presents, or nil if it encodes none.
    public var ndefMessage: Data? {
        switch kind {
            case .uri:   return Self.encodeURI(value)
            case .text:  return Self.encodeText(value)
            case .image: return Data(base64Encoded: value).map { Self.encodeImage($0, mime: mimeType ?? "image/png") }
            case .raw:   return Self.hexData(value)
        }
    }

    // MARK: - NDEF encoding

    /// Well-known URI record with the standard abbreviation prefixes.
    static func encodeURI(_ uri: String) -> Data {
        let prefixes = ["", "http://www.", "https://www.", "http://", "https://"]
        var code: UInt8 = 0
        var rest = uri
        // Longest matching prefix wins, so "https://" beats "http://".
        for (i, p) in prefixes.enumerated().dropFirst().sorted(by: { $0.1.count > $1.1.count }) {
            if uri.hasPrefix(p) {
                code = UInt8(i)
                rest = String(uri.dropFirst(p.count))
                break
            }
        }
        var payload = Data([code])
        payload.append(rest.data(using: .utf8) ?? Data())
        return ndefRecord(tnf: 0x01, type: Data("U".utf8), payload: payload)
    }

    /// Well-known Text record, UTF-8, language "en".
    static func encodeText(_ text: String) -> Data {
        let lang = Data("en".utf8)
        var payload = Data([UInt8(lang.count)])   // status byte: UTF-8, lang length
        payload.append(lang)
        payload.append(text.data(using: .utf8) ?? Data())
        return ndefRecord(tnf: 0x01, type: Data("T".utf8), payload: payload)
    }

    /// Media-type record carrying raw bytes under a MIME type, e.g. an image.
    static func encodeImage(_ data: Data, mime: String) -> Data {
        ndefRecord(tnf: 0x02, type: Data(mime.utf8), payload: data)
    }

    /// A single short-record NDEF message (MB+ME set, SR set).
    static func ndefRecord(tnf: UInt8, type: Data, payload: Data) -> Data {
        var header: UInt8 = 0xC0 | (tnf & 0x07)   // MB=1, ME=1
        if payload.count < 256 { header |= 0x10 } // SR
        var data = Data([header, UInt8(type.count)])
        if payload.count < 256 {
            data.append(UInt8(payload.count))
        } else {
            var len = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        }
        data.append(type)
        data.append(payload)
        return data
    }

    static func hexData(_ hex: String) -> Data? {
        let cleaned = hex.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var bytes = Data()
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return bytes
    }
}
