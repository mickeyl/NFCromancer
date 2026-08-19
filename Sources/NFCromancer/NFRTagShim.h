#import <Foundation/Foundation.h>
#import <CoreNFC/CoreNFC.h>

#if TARGET_OS_SIMULATOR

NS_ASSUME_NONNULL_BEGIN

/// A stand-in for an ISO7816 tag handed to `NFCTagReaderSession` delegates.
/// `NFCISO7816Tag` is a protocol, so a plain NSObject conforming to it is
/// enough — no private-class allocation, unlike the CoreBluetooth/AVFoundation
/// proxies. `sendCommandAPDU:` round-trips over the socket to the real card.
@interface NFRISO7816Tag : NSObject <NFCISO7816Tag>
- (instancetype)initWithTagId:(NSString *)tagId
                          uid:(NSData *)uid
              historicalBytes:(NSData *)historicalBytes;
@end

NS_ASSUME_NONNULL_END

#endif
