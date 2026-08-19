# NFCromancer — Implementation Plan

> **Status (2026-08-19): phases 0 and 1 done, validated against live hardware.**
> The scaffold serves the socket on SimBridgeKit; the ACR122U passthrough
> reads Type 2 NDEF (a real 2-record NTAG end to end) and round-trips raw
> APDUs to ISO7816/storage cards. Card classification is fixed (full-ATR
> template match). Logging goes through CornucopiaCore. Mock mode (phase 2, a virtual tag library presented on demand) is done
> too; client fixtures (phase 3) are next.

**Use real NFC hardware from the iOS Simulator.**

The iOS Simulator has no NFC: `NFCNDEFReaderSession.readingAvailable` is
false, sessions never begin, and every tap/scan/provisioning flow is
untestable without a device. NFCromancer conjures the dead framework back to
life — transparently bridging CoreNFC from a simulated app to a real USB NFC
reader on the host Mac, or to configurable mock tags.

Third member of the Simsalabim family, after
[ImpossiBLE](https://github.com/mickeyl/ImpossiBLE) (CoreBluetooth) and
[CAMouflage](https://github.com/mickeyl/CAMouflage) (AVFoundation capture).
Same philosophy, same integration story: add a local Swift package, build,
run. No `DYLD_INSERT_LIBRARIES`, no system extension, no code changes in the
app under test. Unlike its older siblings it is born on the shared foundation:
[SimBridgeKit](https://github.com/mickeyl/SimBridgeKit) provides the socket
transport (hello handshake, last-connection-wins takeover, hardened client
sockets, socket-ownership guard) and the menu bar shell from day one.

---

## 0. Verified facts (2026-08-19, this machine)

These were checked before writing the plan, not assumed:

- **CoreNFC exists in the iOS Simulator SDK** (`CoreNFC.framework` plus
  `_CoreNFC_UIKit.framework`): the classes are present and swizzlable;
  `readingAvailable` merely answers false.
- **The ACR122U is reachable via CryptoTokenKit** once the process carries the
  `com.apple.security.smartcard` entitlement (without it,
  `TKSmartCardSlotManager.default` is nil — the same "works unsigned, dies
  entitled" class of trap as CAMouflage's camera and ImpossiBLE's Bluetooth
  entitlements, only inverted). Verified with an ad-hoc-signed probe:
  slot `"ACS ACR122U PICC Interface"`, state `.empty` without a tag,
  `maxInputLength` 261 bytes (short APDUs plus CCID overhead — extended APDUs
  need chunking or are out of scope).

## 1. Product Definition

### What it does

- **Passthrough mode** — a tag laid on the Mac's USB NFC reader (ACR122U
  first; any CCID/PC-SC reader in principle) appears to the simulator app as
  a real CoreNFC tag: NDEF payloads arrive in `NFCNDEFReaderSession`, and
  ISO7816 tags answer raw APDUs through `NFCTagReaderSession`.
- **Mock mode** — a library of virtual tags (URI, text, WiFi credentials,
  vCard, APDU-scripted ISO7816) presented to the waiting session at the
  click of a **Present tag** button. Unlike BLE and camera, an NFC tag is an
  *event*, not a stream — the panel button is the tap.
- **Client-supplied fixtures** — a UI test uploads its own tag ("present
  this NDEF when the session starts") and asserts the scan flow end-to-end.

### v1 scope

In scope:

- `NFCNDEFReaderSession`: availability, begin/invalidate, delegate replay
  (`didDetectNDEFs`, `didInvalidateWithError`), single-tag detection
- `NFCTagReaderSession` for ISO14443: `connect(to:)`, `NFCISO7816Tag` shim
  with `sendCommand(apdu:)` round-trips against the real card
- NDEF read for Type 2 (NTAG/Ultralight, via the reader's `FF` pseudo-APDUs)
  and Type 4 (ISO-DEP, via standard SELECT/READ BINARY)
- Tag arrival/removal driven by the reader's slot state

Out of scope for v1 (documented as limitations, tracked on the roadmap):

- NDEF **writing** (v1.x; straightforward on both tag types)
- MIFARE Classic sector auth, FeliCa, ISO15693
- Tag emulation / P2P (the ACR122U's PN532 could, via escape commands —
  explicitly a non-goal for now)
- VAS, background tag reading, `NFCNDEFReaderSession.alertMessage` UI
  fidelity (accepted, ignored)

## 2. Architecture

The established two-process shape, third edition:

```
┌──────────────────────────────┐          ┌──────────────────────────────────┐
│ iOS Simulator app            │  NDJSON  │ macOS host                       │
│  CoreNFC surface             │ control  │  NFCromancer-Mock.app            │
│  ── swizzled at +load ──►    ◄──────────►  ProtocolServer (SimBridgeKit)   │
│  NFRActivator                │ /tmp/    │  Mock: virtual tag library       │
│  NFRConnection (CBS port)    │ nfcroman │  Passthrough: ACR122U via        │
│  NFRTagShims (ISO7816 shim)  │ cer.sock │  CryptoTokenKit (TKSmartCard)    │
└──────────────────────────────┘          └──────────────────────────────────┘
```

- **Library** (`Sources/NFCromancer`, ObjC, `NFR` prefix,
  `#if TARGET_OS_SIMULATOR`): swizzles the CoreNFC surface at `+load`, talks
  NDJSON over `/tmp/nfcromancer.sock`, lazy connect on first session
  creation, device builds compile to no-ops. `NFRConnection` is the
  `CBSConnection` port (hello handshake included).
- **Provider** (`Sources/NFCromancer-Mock`, nested package): the directory
  name is product-specific from day one (SPM identity lesson), with
  `NFCromancerProviderKit` (library) + thin `NFCromancer-Mock` executable —
  the Step-3 shape the suite consumes. Transport and shell from SimBridgeKit.

### The pleasant surprise: almost no proxy shims

`NFCNDEFPayload` and `NFCNDEFMessage` have **public initializers**
(`init(format:type:identifier:payload:)`, `init(records:)`) — the provider
sends raw NDEF bytes and the library builds *real* CoreNFC objects. The
alloc-without-init immortalization circus that CoreBluetooth and AVFoundation
forced is needed only for the tag objects handed to
`NFCTagReaderSession` delegates (`NFCISO7816Tag` is a protocol → a plain
`NFRISO7816Tag: NSObject` conforming to it suffices; no private-class alloc
at all).

### Swizzle surface

| API | Strategy |
|---|---|
| `NFCNDEFReaderSession.readingAvailable`, `NFCTagReaderSession.readingAvailable` | true while the provider connection is up (provider connectivity models reality, as with `CBManagerState`) |
| `NFCNDEFReaderSession init(delegate:queue:invalidateAfterFirstRead:)` | bookkeep session, store delegate/queue/invalidateAfterFirstRead |
| `-beginSession` / `-invalidateSession` | `beginSession` / `endSession` on the wire; queue delegate callbacks onto the stored queue |
| `NFCTagReaderSession init(pollingOption:delegate:queue:)`, `begin`, `restartPolling`, `connect(to:)` | same bookkeeping; `connect` acknowledges via `connectTag` |
| `alertMessage` setters | accepted, stored, ignored (no system sheet in the simulator) |
| tag delivery | provider `tagDetected` → build `NFCNDEFMessage` from raw bytes / `NFRISO7816Tag` shim → `didDetectNDEFs:` / `didDetect(tags:)` |
| `NFCISO7816Tag.sendCommand(apdu:)` | `sendAPDU` round-trip; completion with `(data, sw1, sw2)` |
| session invalidation on disconnect | provider drop ⇒ `didInvalidateWithError(.readerSessionInvalidationErrorSystemIsBusy)` — mirrors ImpossiBLE's disconnect fidelity |

### Wire protocol (on top of SimBridgeKit's hello/takeover)

```
client → provider
  beginSession       {sessionId, kind: "ndef"|"tag", pollingOptions, invalidateAfterFirstRead}
  endSession         {sessionId}
  connectTag         {sessionId, tagId}
  sendAPDU           {sessionId, tagId, requestId, apdu: base64}
  restartPolling     {sessionId}

provider → client
  didBeginSession    {sessionId, ok, error?}
  tagDetected        {sessionId, tagId, tech: "type2"|"iso7816", uid: hex,
                      ndef?: base64, iso7816?: {historicalBytes: base64}}
  tagRemoved         {sessionId, tagId}
  didConnectTag      {sessionId, tagId, ok}
  apduResponse       {requestId, ok, data: base64, sw1, sw2, error?}
  sessionInvalidated {sessionId, reason}
```

One session at a time per client (CoreNFC's own model); the provider rejects
a second `beginSession` with `didBeginSession {ok: false}`.

## 3. ACR122U passthrough (Phase 1 — first, the reader itches)

- **Slot monitoring is the field.** `TKSmartCardSlot.state` transitions to
  `.validCard` when a tag enters the RF field and back when it leaves —
  observed via KVO, these are exactly `tagDetected` / `tagRemoved`. No
  polling loop of our own.
- **Session plumbing**: `slot.makeSmartCard()` → `beginSession`, then APDUs
  via `transmit`. One card session per presented tag, torn down on removal.
- **Identify**: UID via the reader pseudo-APDU `FF CA 00 00 00`; the ATR
  distinguishes ISO14443-4 (Type 4 / ISO-DEP → real APDUs reach the card)
  from ISO14443-3 storage cards (Type 2 → only `FF` pseudo-APDUs work).
- **NDEF Type 4**: SELECT NDEF app `D2 76 00 00 85 01 01` → SELECT CC `E103`,
  READ BINARY → file id + max sizes → SELECT NDEF file, read NLEN + payload.
- **NDEF Type 2** (NTAG21x/Ultralight): `FF B0 00 <page> 04` reads 4-byte
  pages; parse the TLV area from page 4 for the NDEF TLV (`03 len …`).
- **Entitlement**: the provider app adds `com.apple.security.smartcard` to
  its entitlements (verified prerequisite, see §0). Ad-hoc dev builds work —
  unlike TCC there is no user prompt; the entitlement alone gates access.
- **APDU length**: `maxInputLength` 261 → short APDUs only; `sendCommand`
  with extended APDUs returns an error rather than corrupting.
- **Quality-of-life**: the ACR122U beeper (`FF 00 52 00 00`-family escape)
  is deliberately left alone in v1 — no surprise beeps.
- **Robustness notes**: reader re-enumeration after sleep (slot name
  disappears/reappears — re-observe the manager's `slotNames`), and cards
  that mute mid-APDU (map to `apduResponse {ok: false}`, invalidate the tag,
  not the session).

## 4. Mock mode (Phase 2)

- Virtual tag library in the panel: NDEF presets (URI, text, WiFi, vCard,
  raw hex) and APDU-scripted ISO7816 tags (request/response table, wildcard
  fallback `6A 82`).
- **Present tag** button per tag — enabled while a client session waits;
  presenting delivers `tagDetected`, a second click (or auto-remove after n
  seconds) sends `tagRemoved`.
- Stock configurations ("URL badge", "WiFi handover", "Transit card"
  APDU script); persistence via the store pattern from ImpossiBLE.

## 5. Client-supplied fixtures (Phase 3)

The established three invariants (ephemeral, visible, verified) over the same
wire shape: `setMockConfiguration {tags: […]}` + `presentTag {tagId}` so an
XCTest can upload an NDEF fixture, present it programmatically, and assert
`didDetectNDEFs` — fully headless.

## 6. Repository layout & phases

```
NFCromancer/
├── Package.swift               # simulator library, iOS 14+, links CoreNFC
├── Makefile                    # ImpossiBLE Makefile ported (mock-* targets)
├── PLAN.md / README.md / AGENTS.md / LICENSE (MIT)
├── Sources/
│   ├── NFCromancer/            # simulator-side ObjC library (NFR prefix)
│   └── NFCromancer-Mock/       # nested package: ProviderKit/ + App/
└── SampleApp/                  # xcodegen; NDEF scanner + APDU console
```

- **Phase 0 — Scaffold** (½ day): repo layout, empty-but-linking library
  with `+load` log, provider app with SimBridgeKit shell + transport bound
  to `/tmp/nfcromancer.sock`, Makefile, SampleApp shell.
  *Validate*: library builds for simulator + device destinations; panel
  opens; socket probe answers hello.
- **Phase 1 — ACR122U passthrough** (2–3 days): §3 complete; swizzle surface
  for `NFCNDEFReaderSession` + `NFCTagReaderSession`/ISO7816.
  *Validate*: SampleApp in the simulator reads an NTAG URI and a Type-4 NDEF
  from real tags on the reader; APDU console SELECTs an applet on a real
  ISO7816 card; pulling the tag mid-session invalidates cleanly.
- **Phase 2 — Mock** (1–2 days): §4. *Validate*: Present-tag delivers into a
  waiting SampleApp session; panel parity with the sibling products.
- **Phase 3 — Client fixtures** (1 day): §5 + headless XCTest.
- **Phase 4 — Polish & release** (1 day): README/logo, notarize targets,
  0.1.0 tag, then the Simsalabim four-step integration (submodule, path dep,
  runtime + panel section + composite icon glyph `wave.3.right`?, entitlement
  union — the suite adds `com.apple.security.smartcard`).

## 7. Risks

| Risk | Mitigation |
|---|---|
| CoreNFC simulator stubs behave unexpectedly when swizzled (sessions may assert internally) | Phase 0 smoke test instantiates every swizzled class on the simulator before deeper work |
| `TKSmartCardSlotManager` under the Hardened Runtime | entitlement verified unsigned+ad-hoc (§0); release build assessed via `make mock-assess` before tagging |
| ACR122U firmware quirks (mute cards, sleep re-enumeration) | robustness notes in §3; treat every transmit as fallible; re-observe slot names |
| Session/tag lifetime races (tag pulled during APDU) | tag generation counter, the ImpossiBLE takeover/teardown discipline via SimBridgeKit |
| Apps gate on `NFCReaderUsageDescription` / entitlement checks client-side | none needed in the simulator; document that device builds keep their real requirements |
