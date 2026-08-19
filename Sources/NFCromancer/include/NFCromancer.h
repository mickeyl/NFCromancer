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

NS_ASSUME_NONNULL_END
