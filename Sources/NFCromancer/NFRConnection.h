#import <Foundation/Foundation.h>

typedef void (^NFRMessageHandler)(NSDictionary *message);
typedef void (^NFRStateHandler)(BOOL connected);

void NFRConnectionSetMessageHandler(NFRMessageHandler handler);
void NFRConnectionSetStateHandler(NFRStateHandler handler);
void NFRConnectionSend(NSDictionary *message);
void NFRConnectionOpen(void);
BOOL NFRConnectionIsConnected(void);
