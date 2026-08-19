#import "include/NFCromancer.h"
#import "NFRConnection.h"
#import "NFRTagShim.h"
#import "NFRScanSheet.h"
#import <CoreNFC/CoreNFC.h>
#import <objc/runtime.h>
#import <objc/message.h>

#if TARGET_OS_SIMULATOR

static void *kNFRSessionKindKey = &kNFRSessionKindKey;
static void *kNFRSessionIdKey = &kNFRSessionIdKey;
static void *kNFRAlertMessageKey = &kNFRAlertMessageKey;

// The one active session, tracked so socket messages can be routed back to its
// delegate on its queue. CoreNFC allows one reader session at a time.
static __weak id gActiveSession;
static NSString *gActiveKind;
static int32_t gSessionCounter;

@interface NFRISO7816Tag (Routing)
+ (void)routeAPDUResponse:(NSDictionary *)msg;
@end

#pragma mark - Delegate dispatch helpers

static dispatch_queue_t nfr_session_queue(id session) {
    dispatch_queue_t q = objc_getAssociatedObject(session, @selector(nfr_session_queue));
    return q ?: dispatch_get_main_queue();
}

static id nfr_session_delegate(id session) {
    return objc_getAssociatedObject(session, @selector(nfr_session_delegate));
}

#pragma mark - readingAvailable

static BOOL nfr_reading_available(id self, SEL _cmd) {
    NFRConnectionOpen();
    return NFRConnectionIsConnected();
}

#pragma mark - NFCNDEFReaderSession

// init(delegate:queue:invalidateAfterFirstRead:)
static id nfr_ndef_init(id self, SEL _cmd, id delegate, dispatch_queue_t queue, BOOL invalidateAfterFirstRead) {
    // Skip the real designated initializer (it asserts on the simulator);
    // initialize at NSObject level and bookkeep what the delegate replay needs.
    struct objc_super superInfo = { self, class_getSuperclass(object_getClass(self)) };
    id (*superInit)(struct objc_super *, SEL) = (void *)objc_msgSendSuper;
    self = superInit(&superInfo, @selector(init));
    if (self) {
        objc_setAssociatedObject(self, @selector(nfr_session_delegate), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, @selector(nfr_session_queue), queue ?: dispatch_get_main_queue(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kNFRSessionKindKey, @"ndef", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

// init(pollingOption:delegate:queue:)
static id nfr_tag_init(id self, SEL _cmd, NSUInteger pollingOption, id delegate, dispatch_queue_t queue) {
    struct objc_super superInfo = { self, class_getSuperclass(object_getClass(self)) };
    id (*superInit)(struct objc_super *, SEL) = (void *)objc_msgSendSuper;
    self = superInit(&superInfo, @selector(init));
    if (self) {
        objc_setAssociatedObject(self, @selector(nfr_session_delegate), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, @selector(nfr_session_queue), queue ?: dispatch_get_main_queue(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kNFRSessionKindKey, @"tag", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

static void nfr_begin(id self, SEL _cmd) {
    NSString *kind = objc_getAssociatedObject(self, kNFRSessionKindKey) ?: @"ndef";
    int32_t sid = ++gSessionCounter;
    objc_setAssociatedObject(self, kNFRSessionIdKey, @(sid), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gActiveSession = self;
    gActiveKind = kind;
    NFRConnectionOpen();
    NFRConnectionSend(@{ @"type": @"beginSession", @"sessionId": @(sid), @"kind": kind });
    NSLog(@"NFCromancer: beginSession sid=%d kind=%@", sid, kind);

    // Imitate the iOS system scan sheet the Simulator never shows. Its Cancel
    // button invalidates the session just as the real one does.
    NSString *message = objc_getAssociatedObject(self, kNFRAlertMessageKey);
    __weak id weakSession = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NFRScanSheet presentWithMessage:message onCancel:^{
            id strongSession = weakSession;
            if (strongSession) {
                ((void (*)(id, SEL))objc_msgSend)(strongSession, @selector(invalidateSession));
            } else {
                [NFRScanSheet dismiss];
            }
        }];
    });
}

static void nfr_invalidate(id self, SEL _cmd) {
    NSNumber *sid = objc_getAssociatedObject(self, kNFRSessionIdKey);
    if (sid) {
        NFRConnectionSend(@{ @"type": @"endSession", @"sessionId": sid });
    }
    if (gActiveSession == self) {
        gActiveSession = nil;
        gActiveKind = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [NFRScanSheet dismiss]; });
}

static void nfr_invalidate_message(id self, SEL _cmd, NSString *message) {
    nfr_invalidate(self, _cmd);
}

static void nfr_set_alert_message(id self, SEL _cmd, NSString *message) {
    // Stored and reflected in the imitation scan sheet, mirroring how iOS
    // shows `alertMessage` on the real system sheet.
    objc_setAssociatedObject(self, kNFRAlertMessageKey, message, OBJC_ASSOCIATION_COPY_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{ [NFRScanSheet updateMessage:message]; });
}

// connectToTag:completionHandler:
static void nfr_connect_tag(id self, SEL _cmd, id<NFCTag> tag, void (^completion)(NSError *)) {
    // The tag shim is already usable; acknowledge asynchronously on the queue.
    dispatch_async(nfr_session_queue(self), ^{
        if (completion) completion(nil);
    });
}

#pragma mark - Incoming message routing

static void nfr_deliver_ndef(id session, NSData *ndef) {
    id delegate = nfr_session_delegate(session);
    if (![delegate respondsToSelector:@selector(readerSession:didDetectNDEFs:)]) {
        return;
    }
    NSError *error = nil;
    // NFCNDEFMessage has a public initializer — build a real object, no shim.
    NFCNDEFMessage *message = [NFCNDEFMessage ndefMessageWithData:ndef];
    if (!message) {
        return;
    }
    dispatch_async(nfr_session_queue(session), ^{
        [delegate readerSession:session didDetectNDEFs:@[message]];
    });
}

static void nfr_deliver_tag(id session, NSDictionary *msg) {
    id delegate = nfr_session_delegate(session);
    NSString *tagId = msg[@"tagId"];
    NSData *uid = [[NSData alloc] initWithBase64EncodedString:@"" options:0];
    NSString *uidHex = msg[@"uid"];
    if ([uidHex isKindOfClass:[NSString class]]) {
        NSMutableData *bytes = [NSMutableData data];
        for (NSUInteger i = 0; i + 1 < uidHex.length; i += 2) {
            unsigned int b = 0;
            sscanf([[uidHex substringWithRange:NSMakeRange(i, 2)] UTF8String], "%02x", &b);
            uint8_t byte = (uint8_t)b;
            [bytes appendBytes:&byte length:1];
        }
        uid = bytes;
    }
    NSDictionary *iso = msg[@"iso7816"];
    NSData *historical = [[NSData alloc] initWithBase64EncodedString:(iso[@"historicalBytes"] ?: @"") options:0] ?: [NSData data];

    NFRISO7816Tag *shim = [[NFRISO7816Tag alloc] initWithTagId:tagId uid:uid historicalBytes:historical];
    if ([delegate respondsToSelector:@selector(tagReaderSession:didDetectTags:)]) {
        dispatch_async(nfr_session_queue(session), ^{
            [delegate tagReaderSession:session didDetectTags:@[shim]];
        });
    }
}

static void nfr_deliver_invalidation(id session, NSString *reason) {
    id delegate = nfr_session_delegate(session);
    if (![delegate respondsToSelector:@selector(readerSession:didInvalidateWithError:)]) {
        return;
    }
    NSError *error = [NSError errorWithDomain:NFCErrorDomain
                                         code:NFCReaderSessionInvalidationErrorSystemIsBusy
                                     userInfo:@{NSLocalizedDescriptionKey: reason ?: @"session invalidated"}];
    dispatch_async(nfr_session_queue(session), ^{
        [delegate readerSession:session didInvalidateWithError:error];
    });
}

static void nfr_handle_message(NSDictionary *msg) {
    NSString *type = msg[@"type"];
    id session = gActiveSession;

    if ([type isEqualToString:@"apduResponse"]) {
        [NFRISO7816Tag routeAPDUResponse:msg];
        return;
    }
    if (!session) {
        return;
    }
    if ([type isEqualToString:@"tagDetected"]) {
        // A tag arrived: flash the sheet's success state, then dismiss — the
        // same choreography as the real system sheet.
        dispatch_async(dispatch_get_main_queue(), ^{ [NFRScanSheet dismissWithSuccess:nil]; });
        NSString *ndefB64 = msg[@"ndef"];
        if ([gActiveKind isEqualToString:@"ndef"] && [ndefB64 isKindOfClass:[NSString class]]) {
            NSData *ndef = [[NSData alloc] initWithBase64EncodedString:ndefB64 options:0];
            if (ndef.length > 0) {
                nfr_deliver_ndef(session, ndef);
                return;
            }
        }
        nfr_deliver_tag(session, msg);
    } else if ([type isEqualToString:@"sessionInvalidated"]) {
        nfr_deliver_invalidation(session, msg[@"reason"]);
    } else if ([type isEqualToString:@"connectionRejected"]) {
        nfr_deliver_invalidation(session, @"provider superseded this client");
    }
}

static void nfr_handle_state(BOOL connected) {
    if (!connected && gActiveSession) {
        nfr_deliver_invalidation(gActiveSession, @"provider disconnected");
    }
}

#pragma mark - Swizzle installation

static void nfr_swizzle_class_method(Class cls, SEL selector, IMP imp) {
    if (!cls) return;
    Method original = class_getClassMethod(cls, selector);
    if (!original) return;
    class_replaceMethod(object_getClass(cls), selector, imp, method_getTypeEncoding(original));
}

static void nfr_replace(Class cls, SEL selector, IMP imp, const char *types) {
    if (!cls) return;
    Method original = class_getInstanceMethod(cls, selector);
    class_replaceMethod(cls, selector, imp, original ? method_getTypeEncoding(original) : types);
}

@interface NFRActivator : NSObject
@end

@implementation NFRActivator

+ (void)load {
    NSLog(@"NFCromancer: loaded");

    Class ndef = NSClassFromString(@"NFCNDEFReaderSession");
    Class tagReader = NSClassFromString(@"NFCTagReaderSession");

    nfr_swizzle_class_method(ndef, @selector(readingAvailable), (IMP)nfr_reading_available);
    nfr_swizzle_class_method(tagReader, @selector(readingAvailable), (IMP)nfr_reading_available);

    nfr_replace(ndef, @selector(initWithDelegate:queue:invalidateAfterFirstRead:), (IMP)nfr_ndef_init, "@@:@@B");
    nfr_replace(tagReader, @selector(initWithPollingOption:delegate:queue:), (IMP)nfr_tag_init, "@@:Q@@");

    for (Class cls in @[ndef ?: [NSNull class], tagReader ?: [NSNull class]]) {
        if (cls == [NSNull class]) continue;
        nfr_replace(cls, @selector(beginSession), (IMP)nfr_begin, "v@:");
        nfr_replace(cls, @selector(invalidateSession), (IMP)nfr_invalidate, "v@:");
        nfr_replace(cls, @selector(invalidateSessionWithErrorMessage:), (IMP)nfr_invalidate_message, "v@:@");
        nfr_replace(cls, @selector(setAlertMessage:), (IMP)nfr_set_alert_message, "v@:@");
    }
    nfr_replace(tagReader, @selector(connectToTag:completionHandler:), (IMP)nfr_connect_tag, "v@:@@?");

    NFRConnectionSetMessageHandler(^(NSDictionary *msg) { nfr_handle_message(msg); });
    NFRConnectionSetStateHandler(^(BOOL connected) { nfr_handle_state(connected); });

    NSLog(@"NFCromancer: CoreNFC swizzles installed");
}

@end

BOOL NFCromancerIsProviderConnected(void) {
    NFRConnectionOpen();
    for (int i = 0; i < 20; i++) {
        if (NFRConnectionIsConnected()) {
            return YES;
        }
        usleep(50000);
    }
    return NFRConnectionIsConnected();
}

BOOL NFCromancerSetMockConfiguration(NSData *json) {
    NFRConnectionOpen();
    id config = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![config isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NFRConnectionSend(@{ @"type": @"setMockConfiguration", @"configuration": config });
    return YES;
}

BOOL NFCromancerPresentTag(NSString *tagId) {
    if (tagId.length == 0) {
        return NO;
    }
    NFRConnectionSend(@{ @"type": @"presentTag", @"tagId": tagId });
    return YES;
}

void NFCromancerClearMockConfiguration(void) {
    NFRConnectionSend(@{ @"type": @"clearMockConfiguration" });
}

#else

BOOL NFCromancerIsProviderConnected(void) { return NO; }
BOOL NFCromancerSetMockConfiguration(NSData *json) { return NO; }
BOOL NFCromancerPresentTag(NSString *tagId) { return NO; }
void NFCromancerClearMockConfiguration(void) {}

#endif
