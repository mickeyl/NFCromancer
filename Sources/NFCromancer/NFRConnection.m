#import "NFRConnection.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#if TARGET_OS_SIMULATOR

static const char *kNFRSocketPath = "/tmp/nfcromancer.sock";
// Reported to the provider in the hello handshake so version skew between the
// linked library and the installed provider is diagnosable instead of silent.
// Keep in sync with the release version (see the release checklist in AGENTS.md).
static NSString *const kNFRLibraryVersion = @"0.1.0";
static int gSockFd = -1;
static dispatch_queue_t gReadQueue;
static dispatch_queue_t gWriteQueue;
static NFRMessageHandler gMessageHandler;
static NFRStateHandler gStateHandler;
static BOOL gConnected = NO;
static BOOL gReconnectDisabled = NO;
static NSString *gPendingDisconnectReason;
static dispatch_source_t gReconnectTimer;

static void nfr_cancel_reconnect_timer(void);
static void nfr_schedule_reconnect(void);
static void nfr_handle_disconnect(int fd);
static void nfr_start_reader(int fd);

static int nfr_find_newline(NSData *data) {
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        if (bytes[i] == '\n') {
            return (int)i;
        }
    }
    return -1;
}

static void nfr_handle_line(NSData *line) {
    if (line.length == 0) {
        return;
    }
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *msg = (NSDictionary *)obj;
        NSLog(@"NFCromancer: recv type=%@", msg[@"type"]);
        if ([msg[@"type"] isEqualToString:@"connectionRejected"] &&
            [msg[@"code"] isEqualToString:@"clientBusy"]) {
            gReconnectDisabled = YES;
            gPendingDisconnectReason = msg[@"message"] ?: @"provider rejected this process as an additional client";
            nfr_cancel_reconnect_timer();
            NSLog(@"NFCromancer: superseded — %@; auto-reconnect disabled", gPendingDisconnectReason);
        }
        if (gMessageHandler) {
            gMessageHandler(msg);
        }
    }
}

static void nfr_set_connected(BOOL connected) {
    if (gConnected == connected) return;
    gConnected = connected;
    if (connected) {
        NSLog(@"NFCromancer: socket connected");
    }
    NFRStateHandler handler = gStateHandler;
    if (handler) {
        handler(connected);
    }
}

static BOOL nfr_write_all(int fd, const void *bytes, size_t length) {
    const uint8_t *ptr = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, ptr, remaining);
        if (written <= 0) {
            return NO;
        }
        ptr += (size_t)written;
        remaining -= (size_t)written;
    }
    return YES;
}

static void nfr_start_reader(int fd) {
    if (gReadQueue) {
        return;
    }
    gReadQueue = dispatch_queue_create("nfcromancer.reader", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gReadQueue, ^{
        NSMutableData *buffer = [NSMutableData data];
        while (1) {
            uint8_t tmp[2048];
            ssize_t n = read(fd, tmp, sizeof(tmp));
            if (n <= 0) {
                break;
            }
            [buffer appendBytes:tmp length:(NSUInteger)n];
            while (1) {
                int idx = nfr_find_newline(buffer);
                if (idx < 0) {
                    break;
                }
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, (NSUInteger)idx)];
                [buffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)idx + 1) withBytes:NULL length:0];
                nfr_handle_line(line);
            }
        }
        nfr_handle_disconnect(fd);
    });
}

static void nfr_send_hello(int fd) {
    NSDictionary *msg = @{
        @"type": @"hello",
        @"clientVersion": kNFRLibraryVersion,
        @"bundleId": [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
        @"pid": @(getpid()),
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:NULL];
    if (!data) {
        return;
    }
    nfr_write_all(fd, data.bytes, data.length);
    nfr_write_all(fd, "\n", 1);
}

static int nfr_try_connect(void) {
    if (gSockFd >= 0) {
        return gSockFd;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, kNFRSocketPath, sizeof(addr.sun_path) - 1);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        gSockFd = fd;
        nfr_send_hello(fd);
        nfr_start_reader(fd);
        nfr_set_connected(YES);
        return fd;
    }
    close(fd);
    return -1;
}

static int nfr_connect(void) {
    if (gReconnectDisabled) {
        return -1;
    }
    if (gSockFd >= 0) {
        return gSockFd;
    }
    // Retry a few times in case the provider is still starting up.
    for (int attempt = 0; attempt < 5; attempt++) {
        int fd = nfr_try_connect();
        if (fd >= 0) return fd;
        if (attempt < 4) {
            usleep(200000);
        }
    }
    NSLog(@"NFCromancer: connect(%s) failed after retries", kNFRSocketPath);
    nfr_schedule_reconnect();
    return -1;
}

static void nfr_handle_disconnect(int fd) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("nfcromancer.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        if (gSockFd != fd) {
            return;
        }
        close(gSockFd);
        gSockFd = -1;
        gReadQueue = nil;
        NSString *reason = gPendingDisconnectReason;
        gPendingDisconnectReason = nil;
        if (reason.length > 0) {
            NSLog(@"NFCromancer: socket disconnected (%@)", reason);
        } else {
            NSLog(@"NFCromancer: socket disconnected (provider closed connection)");
        }
        nfr_set_connected(NO);
        if (!gReconnectDisabled) {
            nfr_schedule_reconnect();
        }
    });
}

static void nfr_cancel_reconnect_timer(void) {
    if (!gReconnectTimer) return;
    dispatch_source_cancel(gReconnectTimer);
    gReconnectTimer = nil;
}

static void nfr_schedule_reconnect(void) {
    if (gReconnectDisabled) return;
    if (gReconnectTimer) return;
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("nfcromancer.writer", DISPATCH_QUEUE_SERIAL);
    }
    gReconnectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gWriteQueue);
    dispatch_source_set_timer(gReconnectTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(gReconnectTimer, ^{
        if (gReconnectDisabled) {
            nfr_cancel_reconnect_timer();
            return;
        }
        if (gSockFd >= 0) {
            nfr_cancel_reconnect_timer();
            return;
        }
        int fd = nfr_try_connect();
        if (fd >= 0) {
            nfr_cancel_reconnect_timer();
        }
    });
    dispatch_resume(gReconnectTimer);
}

void NFRConnectionSetMessageHandler(NFRMessageHandler handler) {
    gMessageHandler = [handler copy];
}

void NFRConnectionSetStateHandler(NFRStateHandler handler) {
    gStateHandler = [handler copy];
}

BOOL NFRConnectionIsConnected(void) {
    return gConnected;
}

void NFRConnectionOpen(void) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("nfcromancer.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        if (gReconnectDisabled) return;
        if (gSockFd >= 0) return;
        if (nfr_try_connect() < 0) {
            nfr_schedule_reconnect();
        }
    });
}

void NFRConnectionSend(NSDictionary *msg) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("nfcromancer.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        int fd = nfr_connect();
        if (fd < 0) {
            NSLog(@"NFCromancer: send failed — not connected");
            return;
        }
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:&error];
        if (!data) {
            NSLog(@"NFCromancer: send failed — JSON error: %@", error);
            return;
        }
        if (!nfr_write_all(fd, data.bytes, data.length) || !nfr_write_all(fd, "\n", 1)) {
            NSLog(@"NFCromancer: send failed — socket write error");
            nfr_handle_disconnect(fd);
            return;
        }
    });
}

#else

void NFRConnectionSetMessageHandler(NFRMessageHandler handler) {}
void NFRConnectionSetStateHandler(NFRStateHandler handler) {}
void NFRConnectionSend(NSDictionary *msg) {}
void NFRConnectionOpen(void) {}
BOOL NFRConnectionIsConnected(void) { return NO; }

#endif
