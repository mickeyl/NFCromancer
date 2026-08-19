#import "NFRTagShim.h"
#import "NFRConnection.h"

#if TARGET_OS_SIMULATOR

// APDU round-trips block the caller's thread until the response arrives, which
// matches the synchronous feel apps expect from a tag; the completion is
// dispatched on the tag's own serial queue by the session layer.
@interface NFRISO7816Tag ()
@property(nonatomic, copy) NSString *tagId;
@property(nonatomic, copy) NSData *uid;
@property(nonatomic, copy) NSData *historical;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, void (^)(NSData *, uint8_t, uint8_t, NSError *)> *pending;
@property(nonatomic, assign) NSInteger nextRequestId;
@property(nonatomic, strong) dispatch_queue_t lock;
@end

@implementation NFRISO7816Tag

// The session layer routes apduResponse messages here by tagId.
static NSMutableDictionary<NSString *, NFRISO7816Tag *> *gTagsById;

+ (void)initialize {
    if (self == [NFRISO7816Tag class]) {
        gTagsById = [NSMutableDictionary dictionary];
    }
}

+ (void)routeAPDUResponse:(NSDictionary *)msg {
    NSString *reqId = [msg[@"requestId"] stringValue];
    (void)reqId;
    // Responses carry requestId only; find the tag holding that request.
    NSNumber *requestId = msg[@"requestId"];
    if (![requestId isKindOfClass:[NSNumber class]]) {
        return;
    }
    @synchronized (gTagsById) {
        for (NFRISO7816Tag *tag in gTagsById.allValues) {
            void (^handler)(NSData *, uint8_t, uint8_t, NSError *) = tag.pending[requestId];
            if (handler) {
                [tag.pending removeObjectForKey:requestId];
                BOOL ok = [msg[@"ok"] boolValue];
                if (ok) {
                    NSData *data = [[NSData alloc] initWithBase64EncodedString:(msg[@"data"] ?: @"") options:0] ?: [NSData data];
                    handler(data, (uint8_t)[msg[@"sw1"] intValue], (uint8_t)[msg[@"sw2"] intValue], nil);
                } else {
                    NSError *error = [NSError errorWithDomain:NFCErrorDomain code:NFCReaderTransceiveErrorTagResponseError
                                                     userInfo:@{NSLocalizedDescriptionKey: msg[@"error"] ?: @"APDU failed"}];
                    handler([NSData data], 0, 0, error);
                }
                return;
            }
        }
    }
}

- (instancetype)initWithTagId:(NSString *)tagId uid:(NSData *)uid historicalBytes:(NSData *)historicalBytes {
    self = [super init];
    if (self) {
        _tagId = [tagId copy];
        _uid = [uid copy];
        _historical = [historicalBytes copy];
        _pending = [NSMutableDictionary dictionary];
        _lock = dispatch_queue_create("nfcromancer.tag", DISPATCH_QUEUE_SERIAL);
        @synchronized (gTagsById) {
            gTagsById[tagId] = self;
        }
    }
    return self;
}

- (void)invalidate {
    @synchronized (gTagsById) {
        [gTagsById removeObjectForKey:self.tagId];
    }
}

#pragma mark - NFCISO7816Tag

@synthesize identifier = _identifier;

- (NSData *)identifier { return self.uid; }
- (NSString *)initialSelectedAID { return @""; }
- (NSData *)historicalBytes { return self.historical; }
- (NSData *)applicationData { return nil; }
- (BOOL)proprietaryApplicationDataCoding { return NO; }

#pragma mark - NFCTag stubs

- (NFCTagType)type { return NFCTagTypeISO7816Compatible; }
- (BOOL)isAvailable { return YES; }
- (id<NFCISO7816Tag>)asNFCISO7816Tag { return self; }
- (id)asNFCISO15693Tag { return nil; }
- (id)asNFCMiFareTag { return nil; }
- (id)asNFCFeliCaTag { return nil; }

- (void)sendCommandAPDU:(NFCISO7816APDU *)apdu
      completionHandler:(void (^)(NSData *responseData, uint8_t sw1, uint8_t sw2, NSError *_Nullable error))completionHandler {
    NSData *raw = [self encodeAPDU:apdu];
    __block NSNumber *requestId;
    dispatch_sync(self.lock, ^{
        requestId = @(self.nextRequestId++);
        self.pending[requestId] = [completionHandler copy];
    });
    NFRConnectionSend(@{
        @"type": @"sendAPDU",
        @"tagId": self.tagId,
        @"requestId": requestId,
        @"apdu": [raw base64EncodedStringWithOptions:0],
    });
}

/// Reconstructs the wire APDU from the CoreNFC command object.
- (NSData *)encodeAPDU:(NFCISO7816APDU *)apdu {
    NSMutableData *data = [NSMutableData data];
    uint8_t header[4] = { apdu.instructionClass, apdu.instructionCode,
                          apdu.p1Parameter, apdu.p2Parameter };
    [data appendBytes:header length:4];
    NSData *field = apdu.data;
    if (field.length > 0) {
        uint8_t lc = (uint8_t)field.length;
        [data appendBytes:&lc length:1];
        [data appendData:field];
    }
    NSInteger le = apdu.expectedResponseLength;
    if (le >= 0) {
        uint8_t leByte = (le > 255 || le == 0) ? 0x00 : (uint8_t)le;
        [data appendBytes:&leByte length:1];
    }
    return data;
}

@end

#endif
