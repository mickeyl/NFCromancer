import Foundation

/// Shared TLV framing for a linear NDEF data area. A Type 2 tag's paged data
/// area and a MIFARE Classic NFC sector's contiguous data blocks are both
/// just a byte blob wrapped the same way (NFC Forum Type 2 Tag / NXP AN1304)
/// — only the physical write granularity (page vs. block size) and the
/// read/write primitives differ, which callers supply separately.
enum NDEFTLV {
    /// Wraps `message` in an NDEF-message TLV (tag 0x03) plus a terminator
    /// TLV (0xFE), then pads to a multiple of `blockSize`.
    static func wrap(_ message: Data, blockSize: Int) -> Data {
        var payload = Data([0x03])
        if message.count < 0xFF {
            payload.append(UInt8(message.count))
        } else {
            payload.append(0xFF)                    // 3-byte length form
            payload.append(UInt8(message.count >> 8))
            payload.append(UInt8(message.count & 0xFF))
        }
        payload.append(message)
        payload.append(0xFE)
        while payload.count % blockSize != 0 { payload.append(0x00) }
        return payload
    }

    /// Locates the NDEF-message TLV (tag 0x03) in a linear data area, skipping
    /// NULL TLVs (0x00) and stopping at the terminator (0xFE) or a truncated
    /// block rather than reading past the end.
    static func firstNDEFMessage(in data: Data) -> Data? {
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
}
