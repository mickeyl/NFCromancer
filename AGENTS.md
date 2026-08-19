# Agent Notes

## Project Shape

- `Sources/NFCromancer` is the simulator-side Swift package library
  (Objective-C, `NFR` prefix, `#if TARGET_OS_SIMULATOR`). `NFRConnection` is
  the `CBSConnection` port (lazy connect, 2 s auto-reconnect, `hello
  {clientVersion, bundleId, pid}` handshake — bump `kNFRLibraryVersion` on
  release). `NFRActivator` swizzles at `+load`; as of phase 0 only
  `readingAvailable` on both session classes, answering with provider
  connectivity (the connection opens lazily on the first query). Device
  builds compile to no-ops.
- `Sources/NFCromancer-Mock` is the nested provider package —
  **product-specific directory name** (SPM identity comes from the basename;
  two `MockApp` directories cannot coexist in the suite's graph). Two
  targets: `NFCromancerProviderKit` (library: `TagServer` domain layer,
  `NFCromancerSection`/`MenuContent` views) and the thin `NFCromancer-Mock`
  executable (app lifecycle + shell wiring). Transport and menu bar shell
  come from SimBridgeKit (`ProtocolServer`, `StatusItemPanelController`,
  `ModeTransitionController`); see that repo's AGENTS.md for the socket
  discipline, takeover semantics, and ownership guard.
- Socket: `/tmp/nfcromancer.sock`. Persisted mode key: `ProviderMode` in
  `de.vanille.nfcromancer-mock`.
- Wire protocol beyond the kit's hello/takeover: see PLAN.md §2 —
  `beginSession`/`endSession`/`connectTag`/`sendAPDU` client→provider,
  `tagDetected`/`tagRemoved`/`apduResponse`/`sessionInvalidated`
  provider→client. Phase 0 answers `beginSession` with
  `didBeginSession {ok: false}` — failing loudly beats a session that
  silently never begins.

## Invariants and Gotchas

- **The smartcard entitlement is load-bearing.**
  `TKSmartCardSlotManager.default` is nil without
  `com.apple.security.smartcard` — even unsandboxed, even in debug. The
  entitlements file carries it from phase 0 so nobody debugs a nil manager.
  Unlike TCC there is no user prompt; the entitlement alone gates access.
- **`readingAvailable` models provider connectivity**, mirroring
  `CBManagerState` in ImpossiBLE: true only while the socket is up.
- CoreNFC exists in the simulator SDK (verified 2026-08-19); the plan's §0
  records the hardware facts (ACR122U slot name
  `"ACS ACR122U PICC Interface"`, 261-byte APDU ceiling).
- NDEF needs almost no proxy shims: `NFCNDEFPayload`/`NFCNDEFMessage` have
  public initializers. Only the `NFCTagReaderSession` tags are shim objects
  (protocol conformances, no private-class alloc).
## Passthrough (phase 1, verified against live cards 2026-08-19)

- `ReaderSource` wraps the reader via CryptoTokenKit. Slot `.validCard`/`.empty`
  transitions are the RF field (tag arrival/removal), observed by KVO — no poll
  loop. `TKSmartCardSlotManager.default` is nil without
  `com.apple.security.smartcard` (in the entitlements from phase 0).
- **Tag classification is from the FULL ATR bytes, not `historicalBytes`.**
  CryptoTokenKit does not parse the historical-byte field out of these PICC
  ATRs, so `classify()` locates the PC/SC storage template `A0 00 00 03 06`
  anywhere in `atr.bytes`: present means Type 2 storage (FF pseudo-APDUs only),
  absent means ISO-DEP / ISO7816 (real APDUs). The naive "long historical bytes
  = ISO-DEP" guess is exactly backwards and cost an afternoon.
- **Verified card ATRs** (`3B 8F 80 01 80 4F 0C A0 00 00 03 06 03 <NN NN> ...`),
  card name `NN NN`: `0003` = NTAG/Ultralight (Type 2, FF B0 NDEF read works —
  read a real 2-record NDEF end to end), `0001`/`0002` = MIFARE Classic (needs
  sector key auth before reads, out of v1 scope — FF B0 returns 6300).
- NDEF: `NDEFReader` reads Type 2 via `FF B0` page reads + TLV parse, Type 4
  via SELECT NDEF app then CC then file. Every APDU is fallible; a card that
  mutes or refuses yields no NDEF, never a crash.
- ISO7816 raw APDU passthrough: `NFRISO7816Tag` (library shim) then
  `sendAPDU`/`apduResponse` then `ReaderSource.sendAPDU` then
  `TKSmartCard.transmit`. Verified `FF CA 00 00` returns a UID with SW 9000
  through the whole stack.
- Logging goes through `Cornucopia.Core.Logger` (LOGLEVEL/LOGSINK
  configurable); the dependency-free ObjC simulator library keeps its gated
  NSLog on purpose (blast-radius: no dependencies in the swizzle library).

- Sibling projects: `~/Documents/late/ImpossiBLE` and
  `~/Documents/late/CAMouflage` — when in doubt about a pattern, look there.
  The off-body icon rules (pre-scaled via `sbkScaled`, `drawingGroup` over
  the shadow) exist because the Simsalabim splitter resizes sections at
  mouse-event rate.

## Mock mode (phase 2)

- `TagStore` persists the virtual tag library (`~/Library/Application
  Support/NFCromancer/tags.json`), `MockTag` encodes NDEF (well-known URI/Text
  records, or raw hex) with public-initializer-free byte building.
- An NFC tag is an *event*: `TagServer.present(_:)` is the panel's "tap" — it
  delivers `tagDetected` into the waiting session, `retract()` sends
  `tagRemoved`. `sessionWaiting` gates the panel's Present buttons (enabled
  only while a simulator session is open). One tag in the field at a time.
- A **Text record's payload is not a plain string**: it prefixes a status byte
  + language code. Consumers must use `wellKnownTypeTextPayload()` /
  `wellKnownTypeURIPayload()` (see SampleApp), not `String(data: payload)` —
  the naive read surfaces the "en" language prefix. The provider's encoding is
  correct; CoreNFC hands over the structured raw payload by design.

## Logging

Provider logging is `Cornucopia.Core.Logger` (see the logging directive). To
see output from a **release** build (`make mock` is release), pass both env
vars: `LOGLEVEL=TRACE LOGSINK=print://`. `LOGLEVEL` alone is not enough — the
logger's default sink is nil in release (PrintLogger only in DEBUG builds), so
`make mock-debug` shows logs without a LOGSINK but `make mock` does not.
Output goes to stderr as `[subsystem:category] <thread> (LEVEL) message`.

## Build And Verification

```bash
xcodebuild -scheme NFCromancer -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme NFCromancer -destination 'generic/platform=iOS' build
cd Sources/NFCromancer-Mock && swift build   # standalone SPM check
make mock-clean mock
plutil -lint Sources/NFCromancer-Mock/Resources/Info.plist Sources/NFCromancer-Mock/Resources/entitlements.plist
```

## Release Checklist

Bump the version in **three** places and keep them identical:
`kNFRLibraryVersion` in `Sources/NFCromancer/NFRConnection.m`,
`AppVersion.current` in
`Sources/NFCromancer-Mock/ProviderKit/Models/AppVersion.swift`, and
`CFBundleShortVersionString` in `Sources/NFCromancer-Mock/Resources/Info.plist`.
