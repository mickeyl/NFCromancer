#import "include/NFCromancer.h"
#import "NFRConnection.h"
#import <CoreNFC/CoreNFC.h>
#import <objc/runtime.h>

#if TARGET_OS_SIMULATOR

// Phase 0 surface: availability only. `readingAvailable` reflects provider
// connectivity (the connection opens lazily on the first query), so an app's
// "is NFC available?" gate answers truthfully. Session swizzles land in
// phase 1.

static BOOL nfr_reading_available(id self, SEL _cmd) {
    NFRConnectionOpen();
    return NFRConnectionIsConnected();
}

static void nfr_swizzle_reading_available(Class cls) {
    if (!cls) {
        return;
    }
    Class meta = object_getClass(cls);
    SEL selector = @selector(readingAvailable);
    Method original = class_getClassMethod(cls, selector);
    if (!original) {
        return;
    }
    class_replaceMethod(meta, selector, (IMP)nfr_reading_available, method_getTypeEncoding(original));
}

@interface NFRActivator : NSObject
@end

@implementation NFRActivator

+ (void)load {
    NSLog(@"NFCromancer: loaded");
    nfr_swizzle_reading_available(NSClassFromString(@"NFCNDEFReaderSession"));
    nfr_swizzle_reading_available(NSClassFromString(@"NFCTagReaderSession"));
    NSLog(@"NFCromancer: availability swizzles installed");
}

@end

BOOL NFCromancerIsProviderConnected(void) {
    NFRConnectionOpen();
    // The socket opens asynchronously; an immediate check would nearly always
    // report "not connected" during app start-up.
    for (int i = 0; i < 20; i++) {
        if (NFRConnectionIsConnected()) {
            return YES;
        }
        usleep(50000);
    }
    return NFRConnectionIsConnected();
}

#else

BOOL NFCromancerIsProviderConnected(void) { return NO; }

#endif
