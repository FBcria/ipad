#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>

#define kBKConfigPath @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"

static UIWindow *gBallWindow = nil;
static UIWindow *gMenuWindow = nil;
static UIView *gBall = nil;
static NSString *gFrontBundle = nil;
static BOOL gEnabled = NO;
static int gOrientOverride = 0;
static CGPoint gBallPos = {0.06, 0.85};

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
    if (!gBallWindow) return;
    CGRect sp = BKSpace();
    gBallWindow.frame = sp;
    if (gMenuWindow) gMenuWindow.frame = sp;
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
}

static void BKToggleMenu(void)
{
    if (gMenuWindow && !gMenuWindow.hidden) {
        gMenuWindow.hidden = YES;
        return;
    }
    if (!gMenuWindow) {
        gMenuWindow = [[UIWindow alloc] initWithFrame:BKSpace()];
        gMenuWindow.windowLevel = UIWindowLevelAlert + 2;
        gMenuWindow.backgroundColor = [UIColor clearColor];
        gMenuWindow.rootViewController = [UIViewController new];
    }
    UIView *box = [gMenuWindow.rootViewController.view viewWithTag:77];
    if (!box) {
        box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 240, 260)];
        box.tag = 77;
        box.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
        box.layer.cornerRadius = 14;
        box.center = CGPointMake(gMenuWindow.bounds.size.width / 2,
                                 gMenuWindow.bounds.size.height / 2);

        NSArray *titles = @[@"Ativar / Desativar", @"Testar centro", @"Dump de toque",
                            @"Recarregar", @"Fechar"];
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            b.frame = CGRectMake(12, 14 + (CGFloat)i * 46, 216, 40);
            [b setTitle:titles[i] forState:UIControlStateNormal];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
            b.layer.cornerRadius = 8;
            b.tag = 100 + (NSInteger)i;
            [b addTarget:gMenuWindow.rootViewController
                  action:@selector(bkMenuTap:)
        forControlEvents:UIControlEventTouchUpInside];
            [box addSubview:b];
        }
        [gMenuWindow.rootViewController.view addSubview:box];
    }
    gMenuWindow.hidden = NO;
}

static void BKSetupBall(void)
{
    gBallWindow = [[UIWindow alloc] initWithFrame:BKSpace()];
    gBallWindow.windowLevel = UIWindowLevelAlert + 1;
    gBallWindow.backgroundColor = [UIColor clearColor];
    gBallWindow.rootViewController = [UIViewController new];

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
    gBallWindow.hidden = NO;
    [@"ball" writeToFile:@"/var/mobile/bk_ball_shown.txt"
              atomically:YES encoding:NSUTF8StringEncoding error:nil];
    BKRelayout();
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
    gFrontBundle = bid;

    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath]
        ?: [NSMutableDictionary dictionary];
    cfg[@"ActiveBundle"] = bid;
    [cfg writeToFile:kBKConfigPath atomically:YES];
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
    CGRect sp = BKSpace();
    CGPoint p = [g locationInView:v.superview];
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
    [@"overlay" writeToFile:@"/var/mobile/bk_overlay_loaded.txt"
                atomically:YES encoding:NSUTF8StringEncoding error:nil];

    __block int tries = 0;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (gBallWindow || ++tries > 30) { [t invalidate]; return; }
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BKOverlayInit();
        });
    }
}
