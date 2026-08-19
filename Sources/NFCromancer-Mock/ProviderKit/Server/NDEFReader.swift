import Foundation

/// Reads the NDEF message off a tag through the reader's card session, one
/// procedure per tag technology. Every APDU is fallible: a card that mutes or
/// refuses simply yields no NDEF, never a crash.
enum NDEFReader {
    /// Completion delivers the raw NDEF message bytes, or nil if none could be
    /// read. `send` transmits one APDU and calls back with (data, sw1, sw2).
    typealias Transmit = (_ apdu: Data, _ completion: @escaping (Data, UInt8, UInt8) -> Void) -> Void

    static func read(tech: ReaderTag.Tech, transmit: @escaping Transmit, completion: @escaping (Data?) -> Void) {
        switch tech {
            case .type2:   readType2(transmit: transmit, completion: completion)
            case .iso7816: readType4(transmit: transmit, completion: completion)
        }
    }

    // MARK: - Type 2 (NTAG / Ultralight): FF B0 page reads, parse the TLV area

    private static func readType2(transmit: @escaping Transmit, completion: @escaping (Data?) -> Void) {
        // The data area starts at page 4. Read a run of pages, then parse the
        // TLV blocks for the NDEF-message TLV (tag 0x03).
        readPages(transmit: transmit, start: 4, count: 24) { data in
            guard let data, !data.isEmpty else { completion(nil); return }
            completion(parseTLV(data))
        }
    }

    /// Reads `count` 4-byte pages starting at `start` via `FF B0 00 <page> 04`,
    /// accumulating until a read fails (end of readable memory).
    private static func readPages(
        transmit: @escaping Transmit,
        start: Int,
        count: Int,
        completion: @escaping (Data?) -> Void
    ) {
        var acc = Data()
        func readNext(_ page: Int, _ remaining: Int) {
            guard remaining > 0, page < 0x100 else { completion(acc.isEmpty ? nil : acc); return }
            let apdu = Data([0xFF, 0xB0, 0x00, UInt8(page), 0x04])
            transmit(apdu) { resp, sw1, sw2 in
                guard sw1 == 0x90, sw2 == 0x00, resp.count >= 4 else {
                    completion(acc.isEmpty ? nil : acc)
                    return
                }
                acc.append(resp.prefix(4))
                readNext(page + 1, remaining - 1)
            }
        }
        readNext(start, count)
    }

    /// NDEF-message TLV in a Type 2 data area: `03 <len> <ndef…>` (len 0xFF ⇒
    /// 3-byte length). Skips lock/memory-control TLVs (0x00, 0x01, 0x02).
    private static func parseTLV(_ data: Data) -> Data? {
        var i = data.startIndex
        while i < data.endIndex {
            let tag = data[i]; i += 1
            if tag == 0x00 { continue }        // NULL TLV, no length
            if tag == 0xFE { return nil }       // Terminator
            guard i < data.endIndex else { return nil }
            var len = Int(data[i]); i += 1
            if len == 0xFF {                    // 3-byte length
                guard i + 1 < data.endIndex else { return nil }
                len = Int(data[i]) << 8 | Int(data[i+1]); i += 2
            }
            if tag == 0x03 {                    // NDEF message TLV
                guard i + len <= data.endIndex else { return nil }
                return data.subdata(in: i..<(i+len))
            }
            i += len                            // skip other TLVs
        }
        return nil
    }

    // MARK: - Type 4 (ISO-DEP): SELECT NDEF app → CC → NDEF file

    private static let selectNDEFApp = Data([
        0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00,
    ])
    private static let selectCC = Data([0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x03])

    private static func readType4(transmit: @escaping Transmit, completion: @escaping (Data?) -> Void) {
        transmit(selectNDEFApp) { _, sw1, sw2 in
            guard sw1 == 0x90 else { completion(nil); return }
            transmit(selectCC) { _, sw1, sw2 in
                guard sw1 == 0x90 else { completion(nil); return }
                // Read the Capability Container (15 bytes) to learn the NDEF
                // file id and its maximum read size.
                readBinary(transmit: transmit, offset: 0, length: 15) { cc in
                    guard let cc, cc.count >= 15 else { completion(nil); return }
                    let fileId = Data([cc[9], cc[10]])
                    let maxRead = min(Int(cc[3]) << 8 | Int(cc[4]), 0xFF)  // MLe, short APDU cap
                    let selectFile = Data([0x00, 0xA4, 0x00, 0x0C, 0x02]) + fileId
                    transmit(selectFile) { _, sw1, _ in
                        guard sw1 == 0x90 else { completion(nil); return }
                        // First two bytes are NLEN (NDEF length).
                        readBinary(transmit: transmit, offset: 0, length: 2) { header in
                            guard let header, header.count == 2 else { completion(nil); return }
                            let nlen = Int(header[0]) << 8 | Int(header[1])
                            guard nlen > 0 else { completion(Data()); return }
                            readBinaryChunked(transmit: transmit, offset: 2, length: nlen, maxRead: max(maxRead, 1), completion: completion)
                        }
                    }
                }
            }
        }
    }

    private static func readBinary(
        transmit: @escaping Transmit,
        offset: Int,
        length: Int,
        completion: @escaping (Data?) -> Void
    ) {
        let apdu = Data([0x00, 0xB0, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(length)])
        transmit(apdu) { resp, sw1, sw2 in
            completion(sw1 == 0x90 ? resp : nil)
        }
    }

    private static func readBinaryChunked(
        transmit: @escaping Transmit,
        offset: Int,
        length: Int,
        maxRead: Int,
        completion: @escaping (Data?) -> Void
    ) {
        var acc = Data()
        func readNext(_ off: Int, _ remaining: Int) {
            guard remaining > 0 else { completion(acc); return }
            let chunk = min(remaining, maxRead)
            readBinary(transmit: transmit, offset: off, length: chunk) { resp in
                guard let resp, !resp.isEmpty else { completion(acc.isEmpty ? nil : acc); return }
                acc.append(resp)
                readNext(off + resp.count, remaining - resp.count)
            }
        }
        readNext(offset, length)
    }
}
