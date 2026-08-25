import Foundation

/// Reads/writes NDEF data on a MIFARE Classic tag that's already formatted
/// per NXP AN1304 ("NFC Type MIFARE Classic Tag Operation") and AN10787
/// ("MIFARE Application Directory"): a MAD in sector 0 points at one or more
/// contiguous "NFC sectors" holding the actual NDEF TLV, keyed with public
/// keys anyone may authenticate with by design — no secret key material or
/// MIFARE crypto implementation needed on our side; the reader's own PN532
/// handles the Crypto-1 handshake once we hand it the (public) key.
///
/// v1 scope, matching Type 2's own "must already be NDEF-formatted" stance:
/// only MAD1 (sectors 1–15) is scanned, and a tag without a MAD — or whose
/// NFC sector doesn't accept the public write key — simply isn't supported.
/// Formatting a blank card (writing a MAD from scratch) is out of scope: a
/// bad sector-trailer write can permanently brick a sector.
enum MifareClassicNDEF {
    typealias Transmit = NDEFReader.Transmit

    /// Public key A that grants read access to the MAD in sector 0 — anyone
    /// may read it by design (NXP AN10787 §2.5.1, Table 3).
    private static let madKeyA = Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5])
    /// Public key A for NFC (NDEF) sectors — grants read, and write too when
    /// the sector was formatted with read/write access (NXP AN1304 §2.5.2,
    /// Table 6/7).
    private static let ndefKeyA = Data([0xD3, 0xF7, 0xD3, 0xF7, 0xD3, 0xF7])
    /// The NFC AID: function cluster 0xE1, application code 0x03 (AN1304
    /// §6.1). MAD AIDs are exchanged application-code-byte-first (AN10787
    /// §3.10.1: "the lowest significant byte is exchanged first").
    private static let ndefAIDLow: UInt8 = 0x03
    private static let ndefAIDHigh: UInt8 = 0xE1

    enum ClassicError: LocalizedError {
        case authFailed(sector: Int)
        case readFailed(block: Int)
        case writeFailed(block: Int)
        case noNDEFSector
        case tooLarge

        var errorDescription: String? {
            switch self {
                case let .authFailed(sector):
                    "Couldn't authenticate sector \(sector) with the public NDEF key — this tag isn't formatted the standard way (or is read-only)."
                case let .readFailed(block):
                    "Read failed at block \(block)."
                case let .writeFailed(block):
                    "Write failed at block \(block) — the sector may be read-only."
                case .noNDEFSector:
                    "This tag has no MIFARE Application Directory entry pointing at an NDEF sector — it was never formatted for NDEF."
                case .tooLarge:
                    "The message is too large for this tag's NDEF sector(s)."
            }
        }
    }

    // MARK: - Low-level PC/SC MIFARE commands

    private static func loadKey(_ key: Data, slot: UInt8, transmit: @escaping Transmit, completion: @escaping (Bool) -> Void) {
        let apdu = Data([0xFF, 0x82, 0x00, slot, 0x06]) + key
        transmit(apdu) { _, sw1, sw2 in completion(sw1 == 0x90 && sw2 == 0x00) }
    }

    private static func authenticate(block: Int, slot: UInt8, transmit: @escaping Transmit, completion: @escaping (Bool) -> Void) {
        // ACR122U "Authentication": FF 86 00 00 05 <version(2)> <block> <keyType 0x60=A> <slot>
        let apdu = Data([0xFF, 0x86, 0x00, 0x00, 0x05, 0x01, 0x00, UInt8(block), 0x60, slot])
        transmit(apdu) { _, sw1, sw2 in completion(sw1 == 0x90 && sw2 == 0x00) }
    }

    /// Loads `key` into slot 0 and authenticates `block` with it (Key A).
    private static func auth(block: Int, key: Data, transmit: @escaping Transmit, completion: @escaping (Bool) -> Void) {
        loadKey(key, slot: 0x00, transmit: transmit) { loaded in
            guard loaded else { completion(false); return }
            authenticate(block: block, slot: 0x00, transmit: transmit, completion: completion)
        }
    }

    private static func readBlock(_ block: Int, transmit: @escaping Transmit, completion: @escaping (Data?) -> Void) {
        let apdu = Data([0xFF, 0xB0, 0x00, UInt8(block), 0x10])
        transmit(apdu) { data, sw1, sw2 in
            completion((sw1 == 0x90 && sw2 == 0x00 && data.count == 16) ? data : nil)
        }
    }

    private static func writeBlock(_ block: Int, data: Data, transmit: @escaping Transmit, completion: @escaping (Bool) -> Void) {
        let apdu = Data([0xFF, 0xD6, 0x00, UInt8(block), 0x10]) + data
        transmit(apdu) { _, sw1, sw2 in completion(sw1 == 0x90 && sw2 == 0x00) }
    }

    /// A sector's first data block (0-indexed, 4-block sectors — MAD1's
    /// range covers all of a 1k card and the first 32 sectors of a 4k card).
    private static func firstBlock(ofSector sector: Int) -> Int { sector * 4 }

    // MARK: - MAD (sector 0)

    /// Reads the MAD (sector 0, blocks 1 & 2) and returns every sector
    /// number (1...15) whose AID marks it as an NFC/NDEF sector, in order.
    private static func ndefSectors(transmit: @escaping Transmit, completion: @escaping (Result<[Int], Error>) -> Void) {
        auth(block: 0, key: madKeyA, transmit: transmit) { ok in
            guard ok else { completion(.failure(ClassicError.authFailed(sector: 0))); return }
            readBlock(1, transmit: transmit) { block1 in
                guard let block1 else { completion(.failure(ClassicError.readFailed(block: 1))); return }
                readBlock(2, transmit: transmit) { block2 in
                    guard let block2 else { completion(.failure(ClassicError.readFailed(block: 2))); return }
                    // 32 bytes: [CRC, info, AID(1), AID(2), … AID(7)] + [AID(8), … AID(15)].
                    // AID(sector n) sits at byte offset 2*n — verified against
                    // AN10787 Table 11's worked CRC example (sector 1's AID
                    // lands at bytes 2-3, sector 8's at bytes 16-17, i.e. the
                    // same 2*n formula carries straight across the block1/
                    // block2 boundary with no extra offset).
                    let mad = block1 + block2
                    var sectors: [Int] = []
                    for sector in 1...15 {
                        let lo = 2 * sector
                        guard lo + 1 < mad.count else { break }
                        if mad[mad.startIndex + lo] == ndefAIDLow, mad[mad.startIndex + lo + 1] == ndefAIDHigh {
                            sectors.append(sector)
                        }
                    }
                    completion(.success(sectors))
                }
            }
        }
    }

    /// The longest run of consecutive sector numbers starting from the
    /// smallest — "NFC Sectors SHALL be contiguous" (AN1304 §6.1); a
    /// discontiguous remainder is ignored rather than guessed at.
    private static func contiguousRun(_ sectors: [Int]) -> [Int] {
        guard var prev = sectors.sorted().first else { return [] }
        var run = [prev]
        for s in sectors.sorted().dropFirst() {
            guard s == prev + 1 else { break }
            run.append(s); prev = s
        }
        return run
    }

    // MARK: - Read / write

    static func read(transmit: @escaping Transmit, completion: @escaping (Data?) -> Void) {
        ndefSectors(transmit: transmit) { result in
            guard case .success(let found) = result else { completion(nil); return }
            let sectors = contiguousRun(found)
            guard !sectors.isEmpty else { completion(nil); return }
            readSectors(sectors, transmit: transmit) { data in
                completion(data.flatMap(NDEFTLV.firstNDEFMessage))
            }
        }
    }

    static func write(message: Data, transmit: @escaping Transmit, completion: @escaping (Result<Void, Error>) -> Void) {
        ndefSectors(transmit: transmit) { result in
            switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let found):
                    let sectors = contiguousRun(found)
                    guard !sectors.isEmpty else { completion(.failure(ClassicError.noNDEFSector)); return }
                    let wrapped = NDEFTLV.wrap(message, blockSize: 16)
                    guard wrapped.count <= sectors.count * 3 * 16 else {
                        completion(.failure(ClassicError.tooLarge)); return
                    }
                    writeSectors(sectors, data: wrapped, transmit: transmit, completion: completion)
            }
        }
    }

    /// Reads the 3 data blocks of each sector in order (block 3, the sector
    /// trailer, is never touched). Authentication is per-sector — it does
    /// not carry over from one sector to the next.
    private static func readSectors(_ sectors: [Int], transmit: @escaping Transmit, completion: @escaping (Data?) -> Void) {
        var acc = Data()
        func nextSector(_ si: Int) {
            guard si < sectors.count else { completion(acc); return }
            let base = firstBlock(ofSector: sectors[si])
            auth(block: base, key: ndefKeyA, transmit: transmit) { ok in
                guard ok else { completion(nil); return }
                func nextBlock(_ bi: Int) {
                    guard bi < 3 else { nextSector(si + 1); return }
                    readBlock(base + bi, transmit: transmit) { data in
                        guard let data else { completion(nil); return }
                        acc.append(data)
                        nextBlock(bi + 1)
                    }
                }
                nextBlock(0)
            }
        }
        nextSector(0)
    }

    /// Writes `data` (already a multiple of 16 bytes) across `sectors`' data
    /// blocks in order, stopping once every byte has landed — a sector run
    /// longer than the message is left untouched past that point.
    private static func writeSectors(_ sectors: [Int], data: Data, transmit: @escaping Transmit, completion: @escaping (Result<Void, Error>) -> Void) {
        func nextSector(_ si: Int) {
            guard si < sectors.count else { completion(.success(())); return }
            let sector = sectors[si]
            let base = firstBlock(ofSector: sector)
            auth(block: base, key: ndefKeyA, transmit: transmit) { ok in
                guard ok else { completion(.failure(ClassicError.authFailed(sector: sector))); return }
                func nextBlock(_ bi: Int) {
                    guard bi < 3 else { nextSector(si + 1); return }
                    let offset = (si * 3 + bi) * 16
                    guard offset + 16 <= data.count else { nextSector(si + 1); return }
                    let chunk = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + 16)
                    writeBlock(base + bi, data: chunk, transmit: transmit) { ok in
                        guard ok else { completion(.failure(ClassicError.writeFailed(block: base + bi))); return }
                        nextBlock(bi + 1)
                    }
                }
                nextBlock(0)
            }
        }
        nextSector(0)
    }
}
