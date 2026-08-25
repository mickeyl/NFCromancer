import Foundation
import CryptoTokenKit
import CornucopiaCore

/// The reader lost its card between an operation being requested and run.
struct NoCard: LocalizedError {
    var errorDescription: String? { "No card on the reader." }
}

/// A tag seen on the reader, resolved far enough to hand to a session.
struct ReaderTag {
    enum Tech {
        case type2      // ISO14443-3 storage (NTAG / Ultralight): FF pseudo-APDUs only
        case iso7816    // ISO14443-4 (ISO-DEP): real APDUs reach the card
    }
    let uid: Data
    let tech: Tech
    let atr: Data
    /// NDEF message bytes, if one could be read on arrival.
    var ndef: Data?
    /// Historical bytes / application data for the ISO7816 tag shim.
    var historicalBytes: Data
}

/// Wraps a USB NFC reader (ACR122U first) behind CryptoTokenKit. Slot state is
/// the RF field: `.validCard` means a tag entered the field, `.empty` means it
/// left. All work runs on a private serial queue; callbacks fire there.
///
/// Requires the `com.apple.security.smartcard` entitlement — without it
/// `TKSmartCardSlotManager.default` is nil (verified prerequisite, PLAN §0).
final class ReaderSource {
    private let logger = Cornucopia.Core.Logger()
    /// A tag arrived in the field and was resolved.
    var onTagDetected: ((ReaderTag) -> Void)?
    /// The tag left the field.
    var onTagRemoved: (() -> Void)?
    /// Reader availability changed (unplugged / re-enumerated).
    var onReaderAvailability: ((Bool) -> Void)?

    private let manager = TKSmartCardSlotManager.default
    private let queue = DispatchQueue(label: "nfcromancer.reader")
    private var slot: TKSmartCardSlot?
    private var slotObservation: NSKeyValueObservation?
    private var managerObservation: NSKeyValueObservation?
    private var card: TKSmartCard?
    private var present = false
    /// Set only once `beginSession` has actually succeeded. `endSession` on a
    /// card whose session never began (e.g. torn down mid-`beginSession`, as
    /// happens when the slot flickers through states while a reader
    /// enumerates) trips an internal CryptoTokenKit assert and aborts the
    /// process — so `endCard()` must gate on this rather than on `card`
    /// being non-nil.
    private var sessionActive = false
    /// Bumped on every `resolveCard`/`endCard`; callbacks capture the
    /// generation they started under and discard themselves if it has since
    /// moved on, so a stale `beginSession`/`transmit` reply for a card we've
    /// already torn down can't act on it.
    private var generation = 0

    /// Pseudo-APDU understood by PC/SC readers: read the tag UID.
    private static let getUID = Data([0xFF, 0xCA, 0x00, 0x00, 0x00])

    var isReaderAvailable: Bool { slot != nil }

    func start() {
        queue.async { [self] in
            logger.info("Reader source starting")
            guard let manager else {
                logger.error("No smartcard slot manager — is the com.apple.security.smartcard entitlement present?")
                return
            }
            // Re-observe the slot list: readers disappear/reappear across sleep
            // and hub re-enumeration, so we never cache a slot name for long.
            managerObservation = manager.observe(\.slotNames, options: [.initial]) { [weak self] mgr, _ in
                self?.queue.async { self?.bindPreferredSlot(from: mgr) }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            slotObservation = nil
            managerObservation = nil
            endCard()
            slot = nil
            present = false
        }
    }

    // MARK: - Slot binding (queue)

    private func bindPreferredSlot(from manager: TKSmartCardSlotManager) {
        let names = manager.slotNames
        let wanted = names.first { $0.localizedCaseInsensitiveContains("ACR122") }
            ?? names.first { $0.localizedCaseInsensitiveContains("PICC") }
            ?? names.first
        guard let wanted else {
            if slot != nil {
                slot = nil
                slotObservation = nil
                notifyAvailability(false)
            }
            return
        }
        manager.getSlot(withName: wanted) { [weak self] resolved in
            self?.queue.async {
                guard let self else { return }
                guard let resolved else {
                    self.notifyAvailability(false)
                    return
                }
                let firstBind = self.slot == nil
                self.slot = resolved
                self.observe(resolved)
                if firstBind { self.notifyAvailability(true) }
            }
        }
    }

    private func observe(_ slot: TKSmartCardSlot) {
        slotObservation = slot.observe(\.state, options: [.initial]) { [weak self] slot, _ in
            self?.queue.async { self?.handleState(slot.state, slot: slot) }
        }
    }

    private func handleState(_ state: TKSmartCardSlot.State, slot: TKSmartCardSlot) {
        let hasCard = (state == .validCard)
        guard hasCard != present else { return }
        present = hasCard
        if hasCard {
            resolveCard(in: slot)
        } else {
            endCard()
            notifyRemoved()
        }
    }

    // MARK: - Card resolution (queue)

    private func resolveCard(in slot: TKSmartCardSlot) {
        guard let card = slot.makeSmartCard() else {
            logger.error("makeSmartCard failed")
            return
        }
        self.card = card
        generation += 1
        let myGeneration = generation
        let atr = slot.atr?.bytes ?? Data()
        let tech = Self.classify(atr: slot.atr)
        logger.debug("Card ATR=\(atr.map { String(format: "%02X", $0) }.joined()) hist=\((slot.atr?.historicalBytes ?? Data()).map { String(format: "%02X", $0) }.joined()) → \(tech == .iso7816 ? "ISO7816" : "Type2")")

        card.beginSession { [weak self] success, error in
            self?.queue.async {
                guard let self, self.generation == myGeneration else { return }
                guard success else {
                    self.logger.error("Card beginSession failed: \(error?.localizedDescription ?? "?")")
                    return
                }
                self.sessionActive = true
                self.readUID(card: card) { uid in
                    var tag = ReaderTag(
                        uid: uid,
                        tech: tech,
                        atr: atr,
                        ndef: nil,
                        historicalBytes: slot.atr?.historicalBytes ?? Data()
                    )
                    // Best-effort NDEF read on arrival; a card that refuses
                    // simply yields no NDEF (raw APDUs still work afterwards).
                    NDEFReader.read(
                        tech: tech,
                        transmit: { apdu, done in self.transmit(card: card, apdu: apdu, completion: done) }
                    ) { ndef in
                        self.queue.async {
                            guard self.generation == myGeneration else { return }
                            tag.ndef = ndef
                            self.notifyDetected(tag)
                        }
                    }
                }
            }
        }
    }

    private func readUID(card: TKSmartCard, completion: @escaping (Data) -> Void) {
        transmit(card: card, apdu: Self.getUID) { data, sw1, sw2 in
            completion((sw1 == 0x90 && sw2 == 0x00) ? data : Data())
        }
    }

    /// Writes an NDEF message onto the Type 2 card currently in the field.
    /// Callback on the queue.
    func writeType2NDEF(_ message: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard let card else {
                completion(.failure(NoCard()))
                return
            }
            NDEFWriter.writeType2(
                message: message,
                transmit: { apdu, done in self.transmit(card: card, apdu: apdu, completion: done) }
            ) { result in
                self.queue.async { completion(result) }
            }
        }
    }

    /// Sends one APDU on the reader's card session. Callback on the queue.
    func sendAPDU(_ apdu: Data, completion: @escaping (Data, UInt8, UInt8, String?) -> Void) {
        queue.async { [self] in
            guard let card else {
                completion(Data(), 0, 0, "no card present")
                return
            }
            transmit(card: card, apdu: apdu) { data, sw1, sw2 in
                completion(data, sw1, sw2, nil)
            }
        }
    }

    private func transmit(card: TKSmartCard, apdu: Data, completion: @escaping (Data, UInt8, UInt8) -> Void) {
        card.transmit(apdu) { response, error in
            self.queue.async {
                guard let response, response.count >= 2 else {
                    completion(Data(), 0x6F, 0x00)
                    return
                }
                let sw1 = response[response.count - 2]
                let sw2 = response[response.count - 1]
                let data = response.prefix(response.count - 2)
                completion(Data(data), sw1, sw2)
            }
        }
    }

    private func endCard() {
        generation += 1
        if sessionActive {
            card?.endSession()
        }
        sessionActive = false
        card = nil
    }

    // MARK: - ATR classification

    /// PC/SC contactless storage cards (MIFARE Classic/Ultralight, NTAG,
    /// Topaz…) carry the template `A0 00 00 03 06 SS NN NN …` in their ATR —
    /// those are Type 2/3 storage that answer only the reader's FF pseudo-APDUs.
    /// Anything without that template exposes a real ATS and is ISO-DEP /
    /// ISO7816, taking real APDUs.
    ///
    /// Classified from the *full* ATR bytes, not `historicalBytes`:
    /// CryptoTokenKit does not reliably parse the historical-byte field out of
    /// these PICC ATRs (verified against a live NTAG, ATR
    /// `3B8F8001804F0CA0000003060300030000000068`), so we locate the template
    /// directly. `NN NN` is the card name — 0003 = Ultralight/NTAG,
    /// 0001/0002 = MIFARE Classic (readable only after sector auth, out of
    /// v1 scope), etc.; all are Type 2 for our purposes.
    private static func classify(atr: TKSmartCardATR?) -> ReaderTag.Tech {
        guard let atr else { return .iso7816 }
        let bytes = [UInt8](atr.bytes)
        let template: [UInt8] = [0xA0, 0x00, 0x00, 0x03, 0x06]
        let found = bytes.indices.contains { i in
            i + template.count <= bytes.count && Array(bytes[i..<i+template.count]) == template
        }
        return found ? .type2 : .iso7816
    }

    // MARK: - Callbacks (queue → caller)

    private func notifyDetected(_ tag: ReaderTag) { onTagDetected?(tag) }
    private func notifyRemoved() { onTagRemoved?() }
    private func notifyAvailability(_ available: Bool) { onReaderAvailability?(available) }
}
