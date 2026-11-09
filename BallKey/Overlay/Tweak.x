#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <stdarg.h>

#define kBKConfigPath @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"

static UIWindow *gBallWindow = nil;
static UIWindow *gMenuWindow = nil;
static UIView *gBall = nil;
static NSString *gFrontBundle = nil;
static BOOL gEnabled = NO;
static int gOrientOverride = 0;
static CGPoint gBallPos = {0.06, 0.85};

static CGRect BKSpace(void);
static UIWindowScene *BKMainScene(void);

@interface BKPassWindow : UIWindow
@end

@implementation BKPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e
{
    UIView *v = [super hitTest:p withEvent:e];
    if (!v || v == self.rootViewController.view) return nil;
    return v;
}
@end

static void BKMark(NSString *name)
{
    [name writeToFile:[@"/var/mobile/bk_" stringByAppendingString:name]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BKLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSData *d = [[NSString stringWithFormat:@"ov %@\n", s] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/bk_debug.log"];
    if (!fh) {
        [d writeToFile:@"/var/mobile/bk_debug.log" atomically:YES];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (NSException *e) {
    }
}

static UIWindowScene *BKMainScene(void)
{
    UIWindowScene *fallback = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (!fallback) fallback = ws;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
    }
    if (!fallback) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        if (kw.windowScene) fallback = kw.windowScene;
    }
    return fallback;
}

static UIWindow *BKMakeWindow(CGFloat level)
{
    UIWindowScene *scene = BKMainScene();
    if (!scene) return nil;

    UIWindow *w = [[BKPassWindow alloc] initWithWindowScene:scene];
    w.frame = BKSpace();
    w.windowLevel = level;
    w.backgroundColor = [UIColor clearColor];
    w.alpha = 1.0;
    w.hidden = YES;

    UIViewController *vc = [UIViewController new];
    w.rootViewController = vc;
    vc.view.frame = w.bounds;
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return w;
}

static int BKFrontMostOrientation(void)
{
    Class sbCls = objc_getClass("SpringBoard");
    if (!sbCls) return 0;
    id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
    if (!sb) return 0;
    SEL sel = @selector(_accessibilityFrontMostApplication);
    if (![sb respondsToSelector:sel]) return 0;
    id app = ((id (*)(id, SEL))objc_msgSend)(sb, sel);
    if (!app) return 0;
    SEL s2 = @selector(_frontMostAppOrientation);
    if (![app respondsToSelector:s2]) return 0;
    return (int)((int (*)(id, SEL))objc_msgSend)(app, s2);
}

static CGRect BKSpace(void)
{
    UIScreen *s = [UIScreen mainScreen];
    int o = gOrientOverride ? gOrientOverride : BKFrontMostOrientation();
    if (o == 3 || o == 4) return s.coordinateSpace.bounds;
    return s.bounds;
}

static void BKRelayout(void)
{
    if (!gBallWindow || !gBallWindow.windowScene) return;
    CGRect sp = BKSpace();
    if (sp.size.width < 1.0 || sp.size.height < 1.0) return;
    gBallWindow.frame = sp;
    if (gMenuWindow) gMenuWindow.frame = sp;
    if (!gBall) return;
    CGFloat side = 44.0;
    gBall.frame = CGRectMake(gBallPos.x * sp.size.width - side / 2,
                             gBallPos.y * sp.size.height - side / 2, side, side);
    gBall.layer.cornerRadius = side / 2;
}

static void BKPost(const char *name)
{
    notify_post(name);
}

static void BKSetEnabled(BOOL on)
{
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath]
        ?: [NSMutableDictionary dictionary];
    cfg[@"Enabled"] = @(on);
    [cfg writeToFile:kBKConfigPath atomically:YES];
    gEnabled = on;
    BKPost("com.wjf.ballkey.reload");
    BKLog(@"toggle en=%d", (int)on);
}

static void BKToggleMenu(void)
{
    if (gMenuWindow && !gMenuWindow.hidden) {
        gMenuWindow.hidden = YES;
        return;
    }
    if (!gMenuWindow) {
        gMenuWindow = BKMakeWindow(UIWindowLevelAlert + 1001);
        if (!gMenuWindow) {
            BKLog(@"menu: sem scene");
            return;
        }
    }

    UIView *root = gMenuWindow.rootViewController.view;
    [[root viewWithTag:77] removeFromSuperview];

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 240, 260)];
    box.tag = 77;
    box.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    box.layer.cornerRadius = 14;
    box.center = CGPointMake(gMenuWindow.bounds.size.width / 2,
                             gMenuWindow.bounds.size.height / 2);

    NSArray *titles = @[gEnabled ? @"Desativar" : @"Ativar", @"Testar centro", @"Dump de toque",
                        @"Recarregar", @"Fechar"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(12, 14 + (CGFloat)i * 46, 216, 40);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:(i == 0 && gEnabled ? [UIColor systemGreenColor] : [UIColor whiteColor])
                forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
        b.layer.cornerRadius = 8;
        b.tag = 100 + (NSInteger)i;
        [b addTarget:gMenuWindow.rootViewController
              action:@selector(bkMenuTap:)
    forControlEvents:UIControlEventTouchUpInside];
        [box addSubview:b];
    }
    [root addSubview:box];
    gMenuWindow.hidden = NO;
}

static void BKSetupBall(void)
{
    if (gBallWindow) return;

    gBallWindow = BKMakeWindow(UIWindowLevelAlert + 1000);
    if (!gBallWindow) {
        BKLog(@"ball: sem scene, retry");
        return;
    }
    BKLog(@"ball: scene ok bounds=%.0fx%.0f",
          BKSpace().size.width, BKSpace().size.height);

    gBall = [[UIView alloc] initWithFrame:CGRectZero];
    gBall.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.5 alpha:0.85];
    gBall.layer.borderWidth = 2;
    gBall.layer.borderColor = [UIColor whiteColor].CGColor;
    gBall.userInteractionEnabled = YES;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    l.text = @"BK";
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont boldSystemFontOfSize:14];
    l.textAlignment = NSTextAlignmentCenter;
    [gBall addSubview:l];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:gBallWindow.rootViewController action:@selector(bkPan:)];
    [gBall addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:gBallWindow.rootViewController action:@selector(bkTap:)];
    [gBall addGestureRecognizer:tap];

    [gBallWindow.rootViewController.view addSubview:gBall];
    BKRelayout();
    gBallWindow.hidden = NO;
    BKMark(@"ball_shown.txt");
    BKLog(@"ball: hidden=%d level=%.0f", (int)gBallWindow.hidden, gBallWindow.windowLevel);
}

static void BKPollFrontmost(void)
{
    Class sbCls = objc_getClass("SpringBoard");
    if (!sbCls) return;
    id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
    if (!sb) return;
    SEL sel = @selector(_accessibilityFrontMostApplication);
    if (![sb respondsToSelector:sel]) return;
    id app = ((id (*)(id, SEL))objc_msgSend)(sb, sel);
    NSString *bid = app ? ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier)) : nil;
    if (![bid isKindOfClass:[NSString class]]) return;
    if ([bid isEqualToString:gFrontBundle]) return;
    if ([bid isEqualToString:@"com.apple.springboard"]) return;
    gFrontBundle = bid;

    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath]
        ?: [NSMutableDictionary dictionary];
    cfg[@"ActiveBundle"] = bid;
    [cfg writeToFile:kBKConfigPath atomically:YES];
    BKLog(@"front=%@", bid);
    BKPost("com.wjf.ballkey.reload");
}

@interface UIViewController (BKMenu)
- (void)bkMenuTap:(UIButton *)b;
- (void)bkPan:(UIPanGestureRecognizer *)g;
- (void)bkTap:(UITapGestureRecognizer *)g;
@end

@implementation UIViewController (BKMenu)

- (void)bkMenuTap:(UIButton *)b
{
    NSInteger i = b.tag - 100;
    if (i == 0) {
        BKSetEnabled(!gEnabled);
        BKToggleMenu();
        BKToggleMenu();
    } else if (i == 1) {
        BKPost("com.wjf.ballkey.test");
    } else if (i == 2) {
        NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath]
            ?: [NSMutableDictionary dictionary];
        cfg[@"Dump"] = @(![cfg[@"Dump"] boolValue]);
        [cfg writeToFile:kBKConfigPath atomically:YES];
        BKPost("com.wjf.ballkey.reload");
    } else if (i == 3) {
        BKPost("com.wjf.ballkey.reload");
    } else {
        gMenuWindow.hidden = YES;
    }
}

- (void)bkPan:(UIPanGestureRecognizer *)g
{
    UIView *v = g.view;
    UIView *host = v.window ?: v.superview;
    CGRect sp = BKSpace();
    if (sp.size.width < 1.0 || sp.size.height < 1.0) return;
    CGPoint p = [g locationInView:host];
    v.center = p;
    gBallPos = CGPointMake(p.x / sp.size.width, p.y / sp.size.height);
}

- (void)bkTap:(UITapGestureRecognizer *)g
{
    (void)g;
    BKToggleMenu();
}

@end

static void BKOverlayInit(void)
{
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
    gEnabled = [cfg[@"Enabled"] boolValue];
    gFrontBundle = cfg[@"ActiveBundle"];
    gOrientOverride = cfg[@"OrientOverride"] ? [cfg[@"OrientOverride"] intValue] : 0;
    BKMark(@"overlay_loaded.txt");

    __block int tries = 0;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (gBallWindow || ++tries > 30) {
            [t invalidate];
            if (!gBallWindow) BKLog(@"ball: desisti sem scene");
            return;
        }
        BKSetupBall();
    }];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        (void)t;
        if (gBallWindow && gBallWindow.hidden) gBallWindow.hidden = NO;
        BKRelayout();
        BKPollFrontmost();
    }];
}

%ctor {
    @autoreleasepool {
        BKMark(@"overlay_ctor.txt");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BKOverlayInit();
        });
    }
}
