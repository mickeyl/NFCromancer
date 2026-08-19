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
- Sibling projects: `~/Documents/late/ImpossiBLE` and
  `~/Documents/late/CAMouflage` — when in doubt about a pattern, look there.
  The off-body icon rules (pre-scaled via `sbkScaled`, `drawingGroup` over
  the shadow) exist because the Simsalabim splitter resizes sections at
  mouse-event rate.

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
