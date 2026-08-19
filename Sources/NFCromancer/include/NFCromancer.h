#import <Foundation/Foundation.h>

//! NFCromancer — use real NFC hardware from the iOS Simulator.
//!
//! Linking this library is all an app needs: on simulator builds the CoreNFC
//! surface is swizzled at +load and served by the NFCromancer provider on the
//! host Mac; on device builds everything compiles to no-ops and CoreNFC works
//! as usual.

NS_ASSUME_NONNULL_BEGIN

/// Waits briefly for the provider socket, so it is safe to call at start-up.
/// On device builds this always returns NO.
FOUNDATION_EXPORT BOOL NFCromancerIsProviderConnected(void);

/// Upload an ephemeral tag fixture so a test owns its own tags instead of
/// depending on the menu-bar library. The JSON has the shape
/// `{"tags": [{"id": "login", "kind": "uri", "value": "https://…"}]}`
/// (kinds: uri, text, raw). Returns NO on device builds.
FOUNDATION_EXPORT BOOL NFCromancerSetMockConfiguration(NSData *json);

/// Present an uploaded fixture tag into the active reader session by its wire
/// id — the programmatic equivalent of tapping the tag. Returns NO on device.
FOUNDATION_EXPORT BOOL NFCromancerPresentTag(NSString *tagId);

/// Hand tag control back to the menu-bar selection.
FOUNDATION_EXPORT void NFCromancerClearMockConfiguration(void);

NS_ASSUME_NONNULL_END
