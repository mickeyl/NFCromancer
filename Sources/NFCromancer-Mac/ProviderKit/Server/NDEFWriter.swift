import Foundation

/// Writes an NDEF message onto a tag through the reader's card session — the
/// mirror of `NDEFReader`. v1 targets Type 2 (NTAG / Ultralight): the data area
/// is written page by page with the reader's `FF D6` update command. The tag
/// must already be NDEF-formatted (factory NTAGs are: their capability
/// container in page 3 is preset), so we only touch the data pages from 4 up.
/// Every page write is verified; a locked, read-only, or too-small tag surfaces
/// as a precise failure rather than a silent partial write.
enum NDEFWriter {
    typealias Transmit = NDEFReader.Transmit

    enum WriteError: LocalizedError {
        case writeFailed(page: Int, sw1: UInt8, sw2: UInt8)
        case tooLarge
        case locked

        var errorDescription: String? {
            switch self {
                case let .writeFailed(page, sw1, sw2):
                    "Write failed at page \(page) (SW \(String(format: "%02X%02X", sw1, sw2))) — the tag may be locked, read-only, or too small."
                case .tooLarge:
                    "The message is too large for a Type 2 tag."
                case .locked:
                    "This tag is write-protected (its capability container marks it read-only)."
            }
        }
    }

    /// Encode `message` into a Type 2 NDEF-message TLV, cap it with the
    /// terminator TLV, pad to the 4-byte page size, and write it from page 4.
    static func writeType2(
        message: Data,
        transmit: @escaping Transmit,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Page 3 is the Capability Container: [magic, version, MLEN, access].
        // The access byte's low nibble is the write-access condition — 0x0 is
        // open, anything else means the tag refuses every write. Checking it
        // first turns a guaranteed page-4 failure into one precise error
        // instead of a generic "may be locked" guess after the fact.
        transmit(Data([0xFF, 0xB0, 0x00, 0x03, 0x04])) { cc, sw1, sw2 in
            guard sw1 == 0x90, sw2 == 0x00, cc.count == 4 else {
                completion(.failure(WriteError.writeFailed(page: 3, sw1: sw1, sw2: sw2)))
                return
            }
            guard cc[cc.startIndex + 3] & 0x0F == 0x00 else {
                completion(.failure(WriteError.locked))
                return
            }
            writePages(message: message, transmit: transmit, completion: completion)
        }
    }

    private static func writePages(
        message: Data,
        transmit: @escaping Transmit,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var payload = Data([0x03])                  // NDEF-message TLV tag
        if message.count < 0xFF {
            payload.append(UInt8(message.count))
        } else {
            payload.append(0xFF)                    // 3-byte length form
            payload.append(UInt8(message.count >> 8))
            payload.append(UInt8(message.count & 0xFF))
        }
        payload.append(message)
        payload.append(0xFE)                        // terminator TLV
        while payload.count % 4 != 0 { payload.append(0x00) }

        let pages = stride(from: 0, to: payload.count, by: 4).map { payload.subdata(in: $0..<($0 + 4)) }
        func writeNext(_ index: Int) {
            guard index < pages.count else { completion(.success(())); return }
            let page = 4 + index
            guard page < 0x100 else { completion(.failure(WriteError.tooLarge)); return }
            let apdu = Data([0xFF, 0xD6, 0x00, UInt8(page), 0x04]) + pages[index]
            transmit(apdu) { _, sw1, sw2 in
                guard sw1 == 0x90, sw2 == 0x00 else {
                    completion(.failure(WriteError.writeFailed(page: page, sw1: sw1, sw2: sw2)))
                    return
                }
                writeNext(index + 1)
            }
        }
        writeNext(0)
    }
}
