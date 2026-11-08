// BallKey Overlay — injected into SpringBoard.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOKit/hid/IOHIDEventTypes.h>
#import "BKConfig.h"

typedef const void *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;
typedef void (*BKHIDEventCB)(void *target, void *refcon, void *queue, BKIOHIDEventRef event);

BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator, int type, CFDictionaryRef props);
void IOHIDEventSystemClientRegisterEventCallback(BKIOHIDEventSystemClientRef client, BKHIDEventCB callback, void *target, void *refcon);
void IOHIDEventSystemClientScheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
void IOHIDEventSystemClientUnscheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
int IOHIDEventGetType(BKIOHIDEventRef event);
int IOHIDEventGetIntegerValue(BKIOHIDEventRef event, IOHIDEventField field);

static dispatch_queue_t gIOQ;
static NSString *gFrontBundle = nil;
static BOOL gEnabledFlag = YES;

static UIWindow *gBallWindow = nil;
static UIWindow *gEditorWindow = nil;
static UIView *gMenuView = nil;

static NSMutableArray<UIView *> *gMarkers = nil;
static UIView *gPendingBind = nil;
static BKIOHIDEventSystemClientRef gBindClient = NULL;
static UIView *gBindBanner = nil;

static void BKStartBindCapture(void);

#pragma mark - Scene helpers

static UIWindowScene *BKScene(void)
{
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)s;
    }
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

@interface BKPassWindow : UIWindow
@end

@implementation BKPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    if (!v) return nil;
    if (v == self.rootViewController.view) return nil;
    return v;
}
@end

static UIWindow *BKMakeWindow(CGFloat level, BOOL passthrough)
{
    UIWindowScene *sc = BKScene();
    if (!sc) return nil;
    UIWindow *w = passthrough ? [[BKPassWindow alloc] initWithWindowScene:sc]
                              : [[UIWindow alloc] initWithWindowScene:sc];
    w.frame = sc.coordinateSpace.bounds;
    w.windowLevel = level;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;
    w.hidden = YES;
    return w;
}

#pragma mark - Plist IO

static NSDictionary *BKReadCfg(void)
{
    __block NSDictionary *cfg = nil;
    dispatch_sync(gIOQ, ^{ cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath]; });
    return cfg ?: @{};
}

static void BKWriteCfg(void (^mutate)(NSMutableDictionary *cfg))
{
    dispatch_async(gIOQ, ^{
        NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath] ?: [NSMutableDictionary dictionary];
        mutate(cfg);
        [cfg writeToFile:kBKConfigPath atomically:YES];
        notify_post(kBKNotifyReload);
    });
}

#pragma mark - Orientation transforms

static UIInterfaceOrientation BKCurrentOrientation(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].statusBarOrientation;
#pragma clang diagnostic pop
}

static CGPoint BKNormFromUIKit(CGPoint p)
{
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat Wp = MIN(s.width, s.height);
    CGFloat Hp = MAX(s.width, s.height);
    UIInterfaceOrientation o = BKCurrentOrientation();
    CGPoint q = p;
    switch (o) {
        case UIInterfaceOrientationPortrait: break;
        case UIInterfaceOrientationPortraitUpsideDown:
            q = CGPointMake(s.width - p.x, s.height - p.y); break;
        case UIInterfaceOrientationLandscapeLeft:
            q = CGPointMake(p.y, s.height - p.x); break;
        case UIInterfaceOrientationLandscapeRight:
            q = CGPointMake(s.width - p.y, p.x); break;
        default: break;
    }
    return CGPointMake(q.x / Wp, q.y / Hp);
}

static CGPoint BKUIKitFromNorm(CGPoint n)
{
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat Wp = MIN(s.width, s.height);
    CGFloat Hp = MAX(s.width, s.height);
    UIInterfaceOrientation o = BKCurrentOrientation();
    switch (o) {
        case UIInterfaceOrientationPortrait:
            return CGPointMake(n.x * Wp, n.y * Hp);
        case UIInterfaceOrientationPortraitUpsideDown:
            return CGPointMake(Wp - n.x * Wp, Hp - n.y * Hp);
        case UIInterfaceOrientationLandscapeLeft:
            return CGPointMake(Hp - n.y * Hp, n.x * Wp);
        case UIInterfaceOrientationLandscapeRight:
            return CGPointMake(n.y * Hp, Wp - n.x * Wp);
        default:
            return CGPointMake(n.x * Wp, n.y * Hp);
    }
}

#pragma mark - Marker view

@interface BKMarkerView : UIView
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *keyEnc;
@property (nonatomic, assign) NSInteger holdMs;
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, assign) CGFloat sens;
@property (nonatomic, strong) UILabel *label;
- (void)bk_pan:(UIPanGestureRecognizer *)pan;
- (void)bk_tap:(UITapGestureRecognizer *)tap;
- (void)bk_long:(UILongPressGestureRecognizer *)lp;
@end

static NSString *BKKeyDisplayName(NSString *enc)
{
    if (!enc) return @"?";
    NSArray *parts = [enc componentsSeparatedByString:@":"];
    if (parts.count != 2) return enc;
    NSString *kind = parts[0];
    int code = [parts[1] intValue];
    if ([kind isEqualToString:@"m"]) {
        static NSArray *names;
        names = @[@"左键", @"右键", @"中键"];
        return names[MIN(code, 2)];
    }
    if (code == 44) return @"空格";
    if (code == 40) return @"回车";
    if (code == 41) return @"Esc";
    if (code == 42) return @"退格";
    if (code == 43) return @"Tab";
    if (code >= 4 && code <= 29) {
        return [NSString stringWithFormat:@"%c", (char)('A' + (code - 4))];
    }
    if (code >= 58 && code <= 63) return [NSString stringWithFormat:@"F%d", code - 57];
    return [NSString stringWithFormat:@"K%d", code];
}

static UIColor *BKTypeColor(NSString *type)
{
    if ([type isEqualToString:@"Tap"]) return [UIColor systemBlueColor];
    if ([type isEqualToString:@"Press"]) return [UIColor systemGreenColor];
    if ([type isEqualToString:@"Hold"]) return [UIColor systemOrangeColor];
    return [UIColor systemPurpleColor];
}

static NSString *BKTypeLabel(NSString *type)
{
    if ([type isEqualToString:@"Tap"]) return @"单击";
    if ([type isEqualToString:@"Press"]) return @"按下";
    if ([type isEqualToString:@"Hold"]) return @"长按";
    return @"方向";
}

@implementation BKMarkerView

- (void)bk_pan:(UIPanGestureRecognizer *)pan
{
    UIView *canvas = self.superview;
    CGPoint t = [pan translationInView:canvas];
    CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    c.x = MAX(0, MIN(canvas.bounds.size.width, c.x));
    c.y = MAX(0, MIN(canvas.bounds.size.height, c.y));
    self.center = c;
    [pan setTranslation:CGPointZero inView:canvas];
}
- (void)bk_tap:(UITapGestureRecognizer *)tap
{
    gPendingBind = self;
    gBindBanner.hidden = NO;
    [self.superview bringSubviewToFront:self];
    BKStartBindCapture();
}
- (void)bk_long:(UILongPressGestureRecognizer *)lp
{
    if (lp.state != UIGestureRecognizerStateBegan) return;
    if (gPendingBind == self) { gPendingBind = nil; gBindBanner.hidden = YES; }
    [self removeFromSuperview];
    [gMarkers removeObject:self];
}
@end

static BKMarkerView *BKMakeMarker(NSString *type, CGPoint center)
{
    BKMarkerView *m = [[BKMarkerView alloc] initWithFrame:CGRectMake(center.x - 26, center.y - 26, 52, 52)];
    m.backgroundColor = [BKTypeColor(type) colorWithAlphaComponent:0.45];
    m.layer.cornerRadius = 26;
    m.layer.borderColor = BKTypeColor(type).CGColor;
    m.layer.borderWidth = 2;
    m.type = type;
    m.holdMs = 400;
    m.radius = 0.12;
    m.sens = 1.0;

    UILabel *l = [[UILabel alloc] initWithFrame:m.bounds];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont boldSystemFontOfSize:11];
    l.textColor = UIColor.whiteColor;
    l.numberOfLines = 2;
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    l.text = [NSString stringWithFormat:@"%@\n?", BKTypeLabel(type)];
    [m addSubview:l];
    m.label = l;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:m action:@selector(bk_pan:)];
    [m addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:m action:@selector(bk_tap:)];
    [m addGestureRecognizer:tap];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:m action:@selector(bk_long:)];
    [m addGestureRecognizer:lp];
    return m;
}

#pragma mark - Bind HID capture

static void BKStopBindClient(void)
{
    if (gBindClient) {
        IOHIDEventSystemClientUnscheduleWithRunLoop(gBindClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(gBindClient);
        gBindClient = NULL;
    }
}

static void BKBindCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    if (!ev || !gPendingBind) return;
    int type = IOHIDEventGetType(ev);
    NSString *enc = nil;
    if (type == kIOHIDEventTypeKeyboard) {
        int page = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = IOHIDEventGetIntegerValue(ev, kIOHIDEvent
