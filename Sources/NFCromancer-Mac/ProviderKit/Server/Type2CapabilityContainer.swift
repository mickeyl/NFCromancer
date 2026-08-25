import Foundation

/// A Type 2 tag's Capability Container (page 3): `[magic, version, MLEN,
/// access]`. `MLEN * 8` is the usable NDEF area size — also the one thing
/// that reliably tells NTAG213/215/216 apart, since they otherwise share the
/// same ATR card-name code and command set.
struct Type2CapabilityContainer {
    let mlen: UInt8
    let access: UInt8

    var capacityBytes: Int { Int(mlen) * 8 }
    /// The write-access condition (low nibble of the access byte) — 0x0 is
    /// open, anything else means the tag refuses every write.
    var isWriteLocked: Bool { access & 0x0F != 0x00 }

    /// Best-effort identification from the well-known NXP NTAG MLEN values.
    /// Any other Type 2 chip (a different vendor, or a future NTAG size)
    /// simply reports no variant name — the capacity is still accurate.
    var ntagVariant: String? {
        switch mlen {
            case 0x12: "NTAG213"
            case 0x3F: "NTAG215"
            case 0x6D: "NTAG216"
            default:   nil
        }
    }

    static func read(transmit: @escaping NDEFReader.Transmit, completion: @escaping (Type2CapabilityContainer?) -> Void) {
        transmit(Data([0xFF, 0xB0, 0x00, 0x03, 0x04])) { data, sw1, sw2 in
            guard sw1 == 0x90, sw2 == 0x00, data.count == 4 else { completion(nil); return }
            completion(Type2CapabilityContainer(mlen: data[data.startIndex + 2], access: data[data.startIndex + 3]))
        }
    }
}
