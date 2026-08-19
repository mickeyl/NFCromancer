#import <Foundation/Foundation.h>

#if TARGET_OS_SIMULATOR

NS_ASSUME_NONNULL_BEGIN

/// An imitation of the iOS system NFC scan sheet, shown automatically while a
/// reader session is active. CoreNFC presents this sheet on real devices; the
/// Simulator shows nothing, so apps that rely on the visual "Ready to Scan"
/// affordance behave differently. NFRScanSheet closes that gap — no app change
/// needed. All methods must be called on the main thread.
@interface NFRScanSheet : NSObject

/// Present the sheet with an initial message and a cancel handler (invoked when
/// the user taps Cancel — the session layer wires this to invalidate).
+ (void)presentWithMessage:(nullable NSString *)message onCancel:(void (^)(void))onCancel;

/// Update the message text (an app setting `session.alertMessage`).
+ (void)updateMessage:(nullable NSString *)message;

/// Dismiss after a successful read, briefly showing a success state.
+ (void)dismissWithSuccess:(nullable NSString *)message;

/// Dismiss immediately (session invalidated / cancelled).
+ (void)dismiss;

NS_ASSUME_NONNULL_END

@end

#endif
