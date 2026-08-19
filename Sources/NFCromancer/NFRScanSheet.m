#import "NFRScanSheet.h"

#if TARGET_OS_SIMULATOR

#import <UIKit/UIKit.h>

// Imitates the iOS system "Ready to Scan" sheet: a bottom sheet anchored to the
// screen edge (top corners rounded), a large left-aligned title with a close
// button top-right, a phone-in-a-ring glyph, the app's alertMessage, and a
// filled blue Cancel pill — over a dimmed backdrop. Matched against a real
// device screenshot (2026-08-19), not pixel-perfect but faithful.
@interface NFRScanSheetWindow : UIWindow
@property(nonatomic, copy) void (^onCancel)(void);
@property(nonatomic, strong) UILabel *messageLabel;
@property(nonatomic, strong) UIView *sheet;
@property(nonatomic, strong) UIView *iconContainer;
@property(nonatomic, strong) CAShapeLayer *ring;
@property(nonatomic, strong) UIImageView *phone;
@property(nonatomic, strong) UIImageView *successMark;
@property(nonatomic, assign) CGFloat sheetHeight;
@end

@implementation NFRScanSheetWindow

- (instancetype)initWithScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor clearColor];
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
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    [root addSubview:dim];

    CGFloat screenW = root.bounds.size.width;
    CGFloat screenH = root.bounds.size.height;
    self.sheetHeight = 430;
    // Anchored to the bottom, a little overshoot below so the bottom corners
    // never show. Only the top corners are rounded.
    self.sheet = [[UIView alloc] initWithFrame:CGRectMake(0, screenH - self.sheetHeight, screenW, self.sheetHeight + 60)];
    self.sheet.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.sheet.backgroundColor = [UIColor systemBackgroundColor];
    self.sheet.layer.cornerRadius = 40;
    self.sheet.layer.cornerCurve = kCACornerCurveContinuous;
    self.sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [root addSubview:self.sheet];

    CGFloat pad = 24;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, 28, screenW - pad * 2 - 44, 42)];
    title.text = @"Ready to Scan";
    title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    title.textColor = [UIColor labelColor];
    title.textAlignment = NSTextAlignmentLeft;
    [self.sheet addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(screenW - pad - 34, 30, 34, 34);
    UIImageSymbolConfiguration *xcfg = [UIImageSymbolConfiguration configurationWithPointSize:32 weight:UIImageSymbolWeightRegular];
    UIImage *x = [UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:xcfg];
    [close setImage:x forState:UIControlStateNormal];
    close.tintColor = [UIColor tertiaryLabelColor];
    [close addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.sheet addSubview:close];

    // Phone-in-a-ring glyph, centered.
    CGFloat ringSize = 170;
    self.iconContainer = [[UIView alloc] initWithFrame:CGRectMake((screenW - ringSize) / 2, 108, ringSize, ringSize)];
    [self.sheet addSubview:self.iconContainer];

    self.ring = [CAShapeLayer layer];
    CGFloat inset = 4;
    self.ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.iconContainer.bounds, inset, inset)].CGPath;
    self.ring.strokeColor = [UIColor systemBlueColor].CGColor;
    self.ring.fillColor = [UIColor clearColor].CGColor;
    self.ring.lineWidth = 8;
    [self.iconContainer.layer addSublayer:self.ring];

    UIImageSymbolConfiguration *pcfg = [UIImageSymbolConfiguration configurationWithPointSize:84 weight:UIImageSymbolWeightRegular];
    self.phone = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"iphone.gen3" withConfiguration:pcfg]];
    if (!self.phone.image) {
        self.phone.image = [UIImage systemImageNamed:@"iphone" withConfiguration:pcfg];
    }
    self.phone.tintColor = [UIColor colorWithRed:0.79 green:0.87 blue:0.99 alpha:1.0];
    self.phone.contentMode = UIViewContentModeScaleAspectFit;
    self.phone.frame = CGRectMake((ringSize - 84) / 2, (ringSize - 104) / 2, 84, 104);
    [self.iconContainer addSubview:self.phone];
    [self startPulse];

    // Success checkmark, hidden until a tag is read.
    UIImageSymbolConfiguration *scfg = [UIImageSymbolConfiguration configurationWithPointSize:120 weight:UIImageSymbolWeightRegular];
    self.successMark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:scfg]];
    self.successMark.tintColor = [UIColor systemGreenColor];
    self.successMark.contentMode = UIViewContentModeScaleAspectFit;
    self.successMark.frame = self.iconContainer.bounds;
    self.successMark.hidden = YES;
    [self.iconContainer addSubview:self.successMark];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 292, screenW - pad * 2, 44)];
    self.messageLabel.font = [UIFont systemFontOfSize:16];
    self.messageLabel.textColor = [UIColor secondaryLabelColor];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 2;
    [self.sheet addSubview:self.messageLabel];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(20, self.sheetHeight - 54 - 34, screenW - 40, 54);
    cancel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    cancel.backgroundColor = [UIColor systemBlueColor];
    cancel.layer.cornerRadius = 27;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.sheet addSubview:cancel];
}

- (void)startPulse {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.4;
    pulse.duration = 0.9;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.phone.layer addAnimation:pulse forKey:@"pulse"];
}

- (void)cancelTapped {
    void (^handler)(void) = self.onCancel;
    if (handler) handler();
}

- (void)showSuccessWithMessage:(NSString *)message {
    [self.phone.layer removeAllAnimations];
    self.phone.hidden = YES;
    self.ring.hidden = YES;
    self.successMark.hidden = NO;
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
    window.messageLabel.text = message ?: @"";
    window.hidden = NO;

    CGRect finalFrame = window.sheet.frame;
    window.sheet.frame = CGRectOffset(finalFrame, 0, window.sheetHeight + 60);
    UIView *dim = window.rootViewController.view.subviews.firstObject;
    dim.alpha = 0;
    [UIView animateWithDuration:0.30 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        dim.alpha = 1;
        window.sheet.frame = finalFrame;
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dismiss];
    });
}

+ (void)dismiss {
    NFRScanSheetWindow *window = gWindow;
    if (!window) return;
    gWindow = nil;
    UIView *dim = window.rootViewController.view.subviews.firstObject;
    [UIView animateWithDuration:0.25 animations:^{
        dim.alpha = 0;
        window.sheet.frame = CGRectOffset(window.sheet.frame, 0, window.sheetHeight + 60);
    } completion:^(BOOL finished) {
        window.hidden = YES;
    }];
}

@end

#endif
