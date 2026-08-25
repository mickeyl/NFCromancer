import Foundation

/// Parses a raw NDEF message back into its records, so the panel can show a
/// tag's actual content instead of just "NDEF present". Counterpart to
/// `MockTag`'s encoders and `NDEFReader`'s raw-bytes fetch.
enum NDEFDecoder {
    struct Record {
        let tnf: UInt8
        let type: Data
        let payload: Data
    }

    /// Chunked records (CF flag) stop parsing at that point rather than being
    /// reassembled: every record this app writes itself is single-part, and
    /// this is a display nicety, not a general-purpose NDEF library.
    static func decode(_ message: Data) -> [Record] {
        var records: [Record] = []
        var i = message.startIndex
        while i < message.endIndex {
            let header = message[i]; i += 1
            guard header & 0x20 == 0 else { break }   // CF: chunked, unsupported
            let sr = header & 0x10 != 0
            let il = header & 0x08 != 0
            let tnf = header & 0x07

            guard i < message.endIndex else { break }
            let typeLength = Int(message[i]); i += 1

            let payloadLength: Int
            if sr {
                guard i < message.endIndex else { break }
                payloadLength = Int(message[i]); i += 1
            } else {
                guard i + 4 <= message.endIndex else { break }
                payloadLength = message[i..<i+4].reduce(0) { ($0 << 8) | Int($1) }
                i += 4
            }

            var idLength = 0
            if il {
                guard i < message.endIndex else { break }
                idLength = Int(message[i]); i += 1
            }

            guard i + typeLength <= message.endIndex else { break }
            let type = message.subdata(in: i..<(i+typeLength)); i += typeLength
            guard i + idLength <= message.endIndex else { break }
            i += idLength   // id itself isn't shown, only skipped over
            guard i + payloadLength <= message.endIndex else { break }
            let payload = message.subdata(in: i..<(i+payloadLength)); i += payloadLength

            records.append(Record(tnf: tnf, type: type, payload: payload))
        }
        return records
    }

    /// The text of the first Well-Known "T" record, if any.
    static func firstText(in message: Data) -> String? {
        for record in decode(message) {
            guard record.tnf == 0x01, record.type == Data("T".utf8),
                  let status = record.payload.first else { continue }
            let isUTF16 = status & 0x80 != 0
            let headerLength = 1 + Int(status & 0x3F)   // status byte + language code
            guard record.payload.count > headerLength else { continue }
            let textData = record.payload.dropFirst(headerLength)
            let text = isUTF16
                ? String(data: textData, encoding: .utf16)
                : String(data: textData, encoding: .utf8)
            if let text, !text.isEmpty { return text }
        }
        return nil
    }

    /// The payload of the first Media-type record whose MIME type is an image.
    static func firstImage(in message: Data) -> Data? {
        for record in decode(message) {
            guard record.tnf == 0x02,
                  let mime = String(data: record.type, encoding: .ascii),
                  mime.hasPrefix("image/"), !record.payload.isEmpty else { continue }
            return record.payload
        }
        return nil
    }
}
