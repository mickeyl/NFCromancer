#import "NFRScanSheet.h"

#if TARGET_OS_SIMULATOR

#import <UIKit/UIKit.h>

// A bottom card echoing the iOS "Ready to Scan" sheet: a pulsing NFC glyph, a
// message line, and a Cancel button, over a dimmed backdrop. Deliberately not
// pixel-identical to any one iOS version — recognizable, not a forgery.
@interface NFRScanSheetWindow : UIWindow
@property(nonatomic, copy) void (^onCancel)(void);
@property(nonatomic, strong) UILabel *messageLabel;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIImageView *glyph;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation NFRScanSheetWindow

- (instancetype)initWithScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.0];
        self.rootViewController = [UIViewController new];
        [self buildContent];
    }
    return self;
}

- (void)buildContent {
    UIView *root = self.rootViewController.view;
    root.backgroundColor = [UIColor clearColor];

    UIView *dim = [[UIView alloc] initWithFrame:root.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    [root addSubview:dim];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancelTapped)];
    [dim addGestureRecognizer:tap];

    CGFloat width = MIN(root.bounds.size.width - 32, 380);
    CGFloat height = 220;
    self.card = [[UIView alloc] initWithFrame:CGRectMake((root.bounds.size.width - width) / 2,
                                                         root.bounds.size.height - height - 40,
                                                         width, height)];
    self.card.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.card.layer.cornerRadius = 20;
    self.card.layer.cornerCurve = kCACornerCurveContinuous;
    [root addSubview:self.card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 16, width - 32, 24)];
    title.text = @"Ready to Scan";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.textAlignment = NSTextAlignmentCenter;
    [self.card addSubview:title];

    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:52 weight:UIImageSymbolWeightRegular];
    self.glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wave.3.right" withConfiguration:cfg]];
    self.glyph.tintColor = [UIColor systemBlueColor];
    self.glyph.contentMode = UIViewContentModeScaleAspectFit;
    self.glyph.frame = CGRectMake((width - 90) / 2, 52, 90, 66);
    [self.card addSubview:self.glyph];
    [self startPulse];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 126, width - 32, 36)];
    self.messageLabel.font = [UIFont systemFontOfSize:14];
    self.messageLabel.textColor = [UIColor secondaryLabelColor];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 2;
    [self.card addSubview:self.messageLabel];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(16, height - 52, width - 32, 40);
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:cancel];
}

- (void)startPulse {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.35;
    pulse.duration = 0.8;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.glyph.layer addAnimation:pulse forKey:@"pulse"];
}

- (void)cancelTapped {
    void (^handler)(void) = self.onCancel;
    if (handler) handler();
}

- (void)showSuccessWithMessage:(NSString *)message {
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:52 weight:UIImageSymbolWeightRegular];
    [self.glyph.layer removeAllAnimations];
    self.glyph.image = [UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:cfg];
    self.glyph.tintColor = [UIColor systemGreenColor];
    if (message) self.messageLabel.text = message;
}

@end

@implementation NFRScanSheet

static NFRScanSheetWindow *gWindow;

+ (UIWindowScene *)activeScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    // Fall back to any window scene if none is foreground-active yet.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

+ (void)presentWithMessage:(NSString *)message onCancel:(void (^)(void))onCancel {
    if (gWindow) {
        [self updateMessage:message];
        return;
    }
    UIWindowScene *scene = [self activeScene];
    if (!scene) return;

    NFRScanSheetWindow *window = [[NFRScanSheetWindow alloc] initWithScene:scene];
    window.onCancel = onCancel;
    window.messageLabel.text = message ?: @"Hold your device near an NFC tag.";
    window.hidden = NO;

    // Slide the card up from below.
    CGRect finalFrame = window.card.frame;
    window.card.frame = CGRectOffset(finalFrame, 0, finalFrame.size.height + 60);
    window.alpha = 0;
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        window.alpha = 1;
        window.card.frame = finalFrame;
    } completion:nil];

    gWindow = window;
}

+ (void)updateMessage:(NSString *)message {
    if (!gWindow || !message) return;
    gWindow.messageLabel.text = message;
}

+ (void)dismissWithSuccess:(NSString *)message {
    if (!gWindow) return;
    [gWindow showSuccessWithMessage:message];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dismiss];
    });
}

+ (void)dismiss {
    NFRScanSheetWindow *window = gWindow;
    if (!window) return;
    gWindow = nil;
    [UIView animateWithDuration:0.22 animations:^{
        window.alpha = 0;
        window.card.frame = CGRectOffset(window.card.frame, 0, window.card.frame.size.height + 60);
    } completion:^(BOOL finished) {
        window.hidden = YES;
    }];
}

@end

#endif
