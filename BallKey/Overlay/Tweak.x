#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <dlfcn.h>

#define kBKBuildTag    @"b36"
#define kBKConfigPath  @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKNotifyLoad  "com.wjf.ballkey.reload"
#define kBKNotifyTest  "com.wjf.ballkey.test"
#define kBKNotifyCap   "com.wjf.ballkey.capture"
#define kBKOffFile     @"/var/mobile/bk_off.txt"
#define kBKOSafeFile   @"/var/mobile/bk_overlay_safe.txt"
#define kBKOTryFile    @"/var/mobile/bk_ot.txt"

#define kBKNeon  [UIColor colorWithRed:0.15 green:0.98 blue:0.85 alpha:1.0]
#define kBKNeon2 [UIColor colorWithRed:0.45 green:0.35 blue:1.00 alpha:1.0]
#define kBKHot   [UIColor colorWithRed:1.00 green:0.22 blue:0.55 alpha:1.0]
#define kBKRed   [UIColor colorWithRed:1.00 green:0.30 blue:0.30 alpha:1.0]
#define kBKDim   [UIColor colorWithRed:0.70 green:0.80 blue:0.85 alpha:1.0]

@interface BKRootView : UIView
@end

@implementation BKRootView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e
{
    UIView *v = [super hitTest:p withEvent:e];
    if (!v || v == self) return nil;
    return v;
}
@end

@interface BKRootVC : UIViewController
@end

@implementation BKRootVC
- (void)loadView
{
    self.view = [[BKRootView alloc] initWithFrame:[UIScreen mainScreen].bounds];
}
@end

@interface BKUI : NSObject
- (void)dragMarker:(UIPanGestureRecognizer *)g;
- (void)killMarker:(UILongPressGestureRecognizer *)g;
- (void)dragBall:(UIPanGestureRecognizer *)g;
- (void)tapBall:(UITapGestureRecognizer *)g;
- (void)toggle:(UIButton *)b;
- (void)cursor:(UIButton *)b;
- (void)fps:(UIButton *)b;
- (void)map:(UIButton *)b;
- (void)test:(UIButton *)b;
- (void)capture:(UIButton *)b;
- (void)save:(UIButton *)b;
- (void)done:(UIButton *)b;
@end

static UIWindow *gBallWin = nil;
static UIWindow *gMenuWin = nil;
static UIWindow *gEditWin = nil;
static UIWindow *gCursorWin = nil;
static UIView *gBall = nil;
static UIView *gCursor = nil;
static UILabel *gStatusLabel = nil;
static UILabel *gEditTitle = nil;
static UIView *gEditCanvas = nil;
static BKUI *gUI = nil;
static BOOL gMenuOpen = NO;
static BOOL gEngineLoaded = NO;
static BOOL gBallDone = NO, gCursorDone = NO, gTimerDone = NO;
static int gLoadTries = 0;
static double gCurX = 0.0, gCurY = 0.0;
static double gSpanW = 414.0, gSpanH = 736.0;
static BOOL gCurValid = NO;
static int gCapState = 0;
static NSString *gBaseDir = nil;
static NSString *gEditKind = @"key";
static int gEditCode = 0;

static NSString *BKBase(void);
static NSString *BKPath(NSString *name);
static void BKMark(NSString *name);
static void BKAppend(NSString *fmt, ...);
static BOOL BKExists(NSString *p);
static int BKReadInt(NSString *p);
static void BKWriteInt(NSString *p, int n);
static void BKLoadEngine(void);
static void BKPost(const char *name);
static NSMutableDictionary *BKConfig(void);
static void BKSaveConfig(NSDictionary *cfg);
static NSMutableArray *BKProfile(NSMutableDictionary *cfg);
static void BKRefreshStatus(void);
static void BKRefreshCursor(void);
static void BKOpenMenu(void);
static void BKCloseMenu(void);
static void BKOpenEditor(NSString *kind, int code);
static void BKCloseEditor(void);
static void BKRedrawMarkers(void);
static void BKCaptureRequest(void);
static void BKCapturePoll(void);
static void BKAddMarker(NSString *kind, int code, double nx, double ny);
static void BKRemoveMarkerAt(int idx);
static void BKSaveMarkers(void);
static UIWindow *BKMakeWindow(CGFloat level);
static void BKBuildBall(void);
static void BKBuildCursor(void);
static void BKStartTimer(void);
static void BKOverlayBuild(void);

static NSString *BKBase(void)
{
    if (gBaseDir) return gBaseDir;
    @try {
        NSString *probe = @"/var/mobile/.bk_ow";
        if ([@"x" writeToFile:probe atomically:NO encoding:NSUTF8StringEncoding error:nil]) {
            [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
            gBaseDir = @"/var/mobile";
        } else {
            gBaseDir = @"/tmp";
        }
    } @catch (NSException *e) { gBaseDir = @"/tmp"; }
    return gBaseDir;
}

static NSString *BKPath(NSString *name) { return [BKBase() stringByAppendingPathComponent:name]; }

static void BKMark(NSString *name)
{
    @try {
        [@"" writeToFile:BKPath([@"bk_" stringByAppendingString:name])
              atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void BKAppend(NSString *fmt, ...)
{
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        @try {
            NSString *p = BKPath(@"bk_overlay.log");
            NSString *old = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            if (!old) old = @"";
            if (old.length > 40000) old = [old substringFromIndex:old.length - 26000];
            [([old stringByAppendingFormat:@"%@\n", msg]) writeToFile:p atomically:NO
                        encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) { }
    }
}

static BOOL BKExists(NSString *p)
{
    @try { return [[NSFileManager defaultManager] fileExistsAtPath:p]; }
    @catch (NSException *e) { return NO; }
}

static int BKReadInt(NSString *p)
{
    @try {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        return s ? [s intValue] : 0;
    } @catch (NSException *e) { return 0; }
}

static void BKWriteInt(NSString *p, int n)
{
    @try {
        [[NSString stringWithFormat:@"%d", n] writeToFile:p atomically:NO
                    encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void BKPost(const char *name) { notify_post(name); }

static NSMutableDictionary *BKConfig(void)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath];
    if (!d) d = [NSMutableDictionary dictionary];
    if (![d objectForKey:@"Profiles"]) [d setObject:[NSMutableDictionary dictionary] forKey:@"Profiles"];
    if (![d objectForKey:@"Enabled"]) [d setObject:[NSNumber numberWithBool:YES] forKey:@"Enabled"];
    if (![d objectForKey:@"CursorSpeed"]) [d setObject:[NSNumber numberWithDouble:1.6] forKey:@"CursorSpeed"];
    return d;
}

static void BKSaveConfig(NSDictionary *cfg)
{
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/Preferences"
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        [cfg writeToFile:kBKConfigPath atomically:YES];
        BKPost(kBKNotifyLoad);
    } @catch (NSException *e) { }
}

static NSMutableArray *BKProfile(NSMutableDictionary *cfg)
{
    NSMutableDictionary *profiles = [cfg objectForKey:@"Profiles"];
    NSString *ab = [cfg objectForKey:@"ActiveBundle"];
    if (![ab isKindOfClass:[NSString class]] || !ab.length) ab = @"*";
    NSMutableArray *arr = [profiles objectForKey:ab];
    if (![arr isKindOfClass:[NSMutableArray class]]) {
        arr = [NSMutableArray array];
        [profiles setObject:arr forKey:ab];
    }
    return arr;
}

static void BKLoadEngine(void)
{
    if (gEngineLoaded) return;
    if (gLoadTries > 20) return;
    gLoadTries++;
    @try {
        if (BKExists(kBKOffFile)) return;
        NSString *cand = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/BallKeyEngine.dylib";
        if (!BKExists(cand)) return;
        void *h = dlopen([cand UTF8String], RTLD_LAZY);
        if (h) { gEngineLoaded = YES; BKAppend(@"E dlopen ok"); }
    } @catch (NSException *e) { }
}

static void BKRefreshCursor(void)
{
    if (!gCursorWin || !gCursor) return;
    NSString *s = [NSString stringWithContentsOfFile:BKPath(@"bk_ptr.txt")
                                            encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return;
    NSArray *p = [s componentsSeparatedByString:@" "];
    if (p.count < 3) return;

    if ([[p objectAtIndex:0] isEqualToString:@"A"] && p.count >= 5) {
        gSpanW = [[p objectAtIndex:3] doubleValue];
        gSpanH = [[p objectAtIndex:4] doubleValue];
        gCurX = [[p objectAtIndex:1] doubleValue];
        gCurY = [[p objectAtIndex:2] doubleValue];
        gCurValid = YES;
    } else if ([[p objectAtIndex:0] isEqualToString:@"R"]) {
        double sp = 1.0;
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
        if (cfg) {
            double v = [[cfg objectForKey:@"CursorSpeed"] doubleValue];
            if (v > 0.2 && v < 8.0) sp = v;
        }
        if (!gCurValid) { gCurX = gSpanW * 0.5; gCurY = gSpanH * 0.5; gCurValid = YES; }
        gCurX += [[p objectAtIndex:1] doubleValue] * sp;
        gCurY += [[p objectAtIndex:2] doubleValue] * sp;
    } else {
        return;
    }

    if (gCurX < 0.0) gCurX = 0.0;
    if (gCurY < 0.0) gCurY = 0.0;
    if (gCurX > gSpanW) gCurX = gSpanW;
    if (gCurY > gSpanH) gCurY = gSpanH;
    [UIView performWithoutAnimation:^{ gCursor.center = CGPointMake(gCurX, gCurY); }];
}

static uint64_t BKAgeOf(NSString *file)
{
    @try {
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:BKPath(file) error:nil];
        if (!a) return 0;
        NSDate *d = [a objectForKey:NSFileModificationDate];
        if (!d) return 0;
        double age = -[d timeIntervalSinceNow];
        if (age < 0.0) age = 0.0;
        return (uint64_t)age;
    } @catch (NSException *e) { return 0; }
}

static void BKRefreshStatus(void)
{
    if (!gStatusLabel) return;
    @try {
        NSString *eng = [NSString stringWithContentsOfFile:BKPath(@"bk_engine_status.txt")
                                                  encoding:NSUTF8StringEncoding error:nil];
        if (!eng) eng = @"e0 k0 p0 m0 a=- o0 ct=0/0 plf=N sf=0";
        uint64_t age = BKAgeOf(@"bk_engine_status.txt");
        uint64_t engAge = BKAgeOf(@"bk_engine_ready.txt");
        BOOL safe = BKExists(kBKOSafeFile);

        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
        BOOL on = cfg ? [[cfg objectForKey:@"Enabled"] boolValue] : YES;

        NSString *head = [NSString stringWithFormat:
            @"v %@  at %@  lib:%@  eng:%llus  age:%llus  osf:%@",
            kBKBuildTag, on ? @"1" : @"0", gEngineLoaded ? @"S" : @"N",
            (unsigned long long)engAge, (unsigned long long)age, safe ? @"1" : @"0"];

        gStatusLabel.text = [NSString stringWithFormat:@"%@\n%@", head, eng];
        gStatusLabel.textColor = (engAge > 8 || age > 8) ? kBKRed : kBKDim;
    } @catch (NSException *e) { }
}

static NSMutableArray *BKMarkersFor(NSMutableDictionary *cfg, NSString *kind)
{
    NSMutableArray *arr = BKProfile(cfg);
    NSMutableArray *out = [NSMutableArray array];
    int want = [kind isEqualToString:@"key"] ? 0 : 1;
    for (NSDictionary *d in arr) {
        if ([[d objectForKey:@"Kind"] intValue] == want) [out addObject:d];
    }
    return out;
}

static void BKAddMarker(NSString *kind, int code, double nx, double ny)
{
    if (nx < 0.0 || nx > 1.0 || ny < 0.0 || ny > 1.0) return;
    NSMutableDictionary *cfg = BKConfig();
    NSMutableArray *arr = BKProfile(cfg);
    int k = [kind isEqualToString:@"key"] ? 0 : 1;
    for (NSDictionary *d in arr) {
        if ([[d objectForKey:@"Kind"] intValue] == k &&
            [[d objectForKey:@"Code"] intValue] == code) return;
    }
    [arr addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInt:k], @"Kind",
        [NSNumber numberWithInt:code], @"Code",
        [NSNumber numberWithDouble:nx], @"X",
        [NSNumber numberWithDouble:ny], @"Y",
        [NSNumber numberWithDouble:0.06], @"W",
        [NSNumber numberWithDouble:0.06], @"H", nil]];
    BKSaveConfig(cfg);
}

static void BKRemoveMarkerAt(int idx)
{
    NSMutableDictionary *cfg = BKConfig();
    NSMutableArray *arr = BKProfile(cfg);
    int k = [gEditKind isEqualToString:@"key"] ? 0 : 1;
    int seen = 0;
    for (int i = 0; i < (int)arr.count; i++) {
        NSDictionary *d = [arr objectAtIndex:i];
        if ([[d objectForKey:@"Kind"] intValue] != k) continue;
        if (seen == idx) { [arr removeObjectAtIndex:i]; BKSaveConfig(cfg); return; }
        seen++;
    }
}

static void BKSaveMarkers(void)
{
    if (!gEditCanvas) return;
    NSMutableDictionary *cfg = BKConfig();
    NSMutableArray *arr = BKProfile(cfg);
    int k = [gEditKind isEqualToString:@"key"] ? 0 : 1;

    for (UIView *v in gEditCanvas.subviews) {
        if (v.tag < 1000) continue;
        int idx = (int)v.tag - 1000;
        double nx = v.center.x / gEditCanvas.bounds.size.width;
        double ny = v.center.y / gEditCanvas.bounds.size.height;
        if (nx < 0.0) nx = 0.0;
        if (ny < 0.0) ny = 0.0;
        if (nx > 1.0) nx = 1.0;
        if (ny > 1.0) ny = 1.0;
        int seen = 0;
        for (int i = 0; i < (int)arr.count; i++) {
            NSMutableDictionary *d = [arr objectAtIndex:i];
            if ([[d objectForKey:@"Kind"] intValue] != k) continue;
            if (seen == idx) {
                [d setObject:[NSNumber numberWithDouble:nx] forKey:@"X"];
                [d setObject:[NSNumber numberWithDouble:ny] forKey:@"Y"];
                break;
            }
            seen++;
        }
    }
    BKSaveConfig(cfg);
}

static void BKRedrawMarkers(void)
{
    if (!gEditCanvas) return;
    for (UIView *v in gEditCanvas.subviews) {
        if (v.tag >= 1000) [v removeFromSuperview];
    }
    NSMutableDictionary *cfg = BKConfig();
    NSArray *arr = BKMarkersFor(cfg, gEditKind);
    CGSize cs = gEditCanvas.bounds.size;

    for (int i = 0; i < (int)arr.count; i++) {
        NSDictionary *d = [arr objectAtIndex:i];
        double nx = [[d objectForKey:@"X"] doubleValue];
        double ny = [[d objectForKey:@"Y"] doubleValue];
        UIView *m = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 46, 46)];
        m.center = CGPointMake(nx * cs.width, ny * cs.height);
        m.backgroundColor = [kBKNeon2 colorWithAlphaComponent:0.20];
        m.layer.borderColor = kBKNeon.CGColor;
        m.layer.borderWidth = 1.5;
        m.layer.cornerRadius = 10;
        m.tag = 1000 + i;

        UILabel *l = [[UILabel alloc] initWithFrame:m.bounds];
        l.text = [NSString stringWithFormat:@"%d", [[d objectForKey:@"Code"] intValue]];
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont boldSystemFontOfSize:13];
        l.textColor = kBKNeon;
        l.userInteractionEnabled = NO;
        [m addSubview:l];

        [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gUI
            action:@selector(dragMarker:)]];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gUI
            action:@selector(killMarker:)];
        lp.minimumPressDuration = 0.7;
        [m addGestureRecognizer:lp];
        [gEditCanvas addSubview:m];
    }
}

static void BKCaptureRequest(void)
{
    @try {
        [@"" writeToFile:BKPath(@"bk_capture_result.txt") atomically:NO
                encoding:NSUTF8StringEncoding error:nil];
        gCapState = 1;
        BKPost(kBKNotifyCap);
        if (gEditTitle) gEditTitle.text = @"Aperte a tecla ou o botao";
    } @catch (NSException *e) { }
}

static void BKCapturePoll(void)
{
    if (gCapState != 1) return;
    NSString *s = [NSString stringWithContentsOfFile:BKPath(@"bk_capture_result.txt")
                                            encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return;
    NSArray *p = [s componentsSeparatedByString:@"|"];
    if (p.count < 2) return;

    int kind = [[p objectAtIndex:0] intValue];
    int code = [[p objectAtIndex:1] intValue];
    gCapState = 0;
    gEditKind = kind == 0 ? @"key" : @"btn";
    gEditCode = code;

    BKAddMarker(gEditKind, code, 0.5, 0.5);
    if (gEditTitle) {
        gEditTitle.text = [NSString stringWithFormat:@"%@ %d  arraste e salve",
                           kind == 0 ? @"tecla" : @"botao", code];
    }
    BKRedrawMarkers();
}

static UIButton *BKButton(NSString *title, SEL sel, UIColor *color)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.backgroundColor = [color colorWithAlphaComponent:0.12];
    b.layer.borderColor = color.CGColor;
    b.layer.borderWidth = 1.5;
    b.layer.cornerRadius = 12;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:gUI action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UIWindow *BKMakeWindow(CGFloat level)
{
    UIWindowScene *scene = nil;
    @try {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
        }
    } @catch (NSException *e) { }
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = level;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [[BKRootVC alloc] init];
    return w;
}

static void BKOpenMenu(void)
{
    if (gMenuOpen) return;
    gMenuOpen = YES;
    @try {
        if (!gMenuWin) gMenuWin = BKMakeWindow(UIWindowLevelAlert + 2002);
        UIViewController *vc = gMenuWin.rootViewController;
        for (UIView *v in vc.view.subviews) [v removeFromSuperview];
        vc.view.backgroundColor = [UIColor colorWithRed:0.02 green:0.04 blue:0.07 alpha:0.94];

        UILabel *title = [[UILabel alloc] init];
        title.text = @"BALLKEY";
        title.font = [UIFont boldSystemFontOfSize:22];
        title.textColor = kBKNeon;
        title.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:title];

        gStatusLabel = [[UILabel alloc] init];
        gStatusLabel.numberOfLines = 4;
        gStatusLabel.font = [UIFont systemFontOfSize:10];
        gStatusLabel.textColor = kBKDim;
        gStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:gStatusLabel];

        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
        BOOL on = cfg ? [[cfg objectForKey:@"Enabled"] boolValue] : YES;
        BOOL cur = cfg ? [[cfg objectForKey:@"CursorOn"] boolValue] : NO;
        BOOL fps = cfg ? [[cfg objectForKey:@"FpsMode"] boolValue] : NO;

        UIButton *bOn = BKButton(on ? @"DESATIVAR" : @"ATIVAR", @selector(toggle:), kBKNeon);
        UIButton *bCur = BKButton(cur ? @"CURSOR OFF" : @"CURSOR ON", @selector(cursor:), kBKNeon2);
        UIButton *bFps = BKButton(fps ? @"FPS OFF" : @"FPS ON", @selector(fps:), kBKHot);
        UIButton *bMap = BKButton(@"MAPA", @selector(map:), kBKNeon);
        UIButton *bTst = BKButton(@"TESTE", @selector(test:), kBKDim);

        UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[bOn, bCur, bFps]];
        left.axis = UILayoutConstraintAxisVertical;
        left.spacing = 12;
        left.distribution = UIStackViewDistributionFillEqually;

        UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:@[bMap, bTst]];
        right.axis = UILayoutConstraintAxisVertical;
        right.spacing = 12;
        right.distribution = UIStackViewDistributionFillEqually;

        UIStackView *cols = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
        cols.axis = UILayoutConstraintAxisHorizontal;
        cols.spacing = 12;
        cols.distribution = UIStackViewDistributionFillEqually;
        cols.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:cols];

        UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:18],
            [title.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
            [gStatusLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
            [gStatusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
            [gStatusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
            [cols.topAnchor constraintEqualToAnchor:gStatusLabel.bottomAnchor constant:16],
            [cols.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
            [cols.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
            [cols.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18]
        ]];

        gMenuWin.hidden = NO;
        BKRefreshStatus();
    } @catch (NSException *e) {
        BKAppend(@"! menu %@", e.reason);
    }
}

static void BKCloseMenu(void)
{
    gMenuOpen = NO;
    @try {
        if (gMenuWin) {
            gMenuWin.hidden = YES;
            for (UIView *v in gMenuWin.rootViewController.view.subviews) [v removeFromSuperview];
        }
    } @catch (NSException *e) { }
    gStatusLabel = nil;
}

static void BKOpenEditor(NSString *kind, int code)
{
    gEditKind = kind;
    gEditCode = code;
    gMenuOpen = NO;
    if (gMenuWin) gMenuWin.hidden = YES;
    @try {
        if (!gEditWin) {
            gEditWin = BKMakeWindow(UIWindowLevelAlert + 2003);
            gEditWin.rootViewController.view.backgroundColor = [UIColor clearColor];
        }
        UIViewController *vc = gEditWin.rootViewController;
        for (UIView *v in vc.view.subviews) [v removeFromSuperview];
        vc.view.backgroundColor = [UIColor clearColor];

        UIView *bg = [[UIView alloc] initWithFrame:vc.view.bounds];
        bg.backgroundColor = [UIColor colorWithRed:0.02 green:0.04 blue:0.07 alpha:0.28];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view addSubview:bg];

        gEditCanvas = [[UIView alloc] initWithFrame:vc.view.bounds];
        gEditCanvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view addSubview:gEditCanvas];

        gEditTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, vc.view.bounds.size.width - 32, 24)];
        gEditTitle.text = @"Toque em CAPTURAR e aperte a tecla";
        gEditTitle.font = [UIFont boldSystemFontOfSize:13];
        gEditTitle.textColor = kBKNeon;
        gEditTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [vc.view addSubview:gEditTitle];

        UIButton *cap = BKButton(@"CAPTURAR", @selector(capture:), kBKNeon);
        cap.frame = CGRectMake(16, vc.view.bounds.size.height - 110, 130, 46);
        [vc.view addSubview:cap];

        UIButton *save = BKButton(@"SALVAR", @selector(save:), kBKNeon2);
        save.frame = CGRectMake(156, vc.view.bounds.size.height - 110, 130, 46);
        [vc.view addSubview:save];

        UIButton *done = BKButton(@"FECHAR", @selector(done:), kBKHot);
        done.frame = CGRectMake(296, vc.view.bounds.size.height - 110, 130, 46);
        [vc.view addSubview:done];

        gEditWin.hidden = NO;
        BKRedrawMarkers();
    } @catch (NSException *e) {
        BKAppend(@"! editor %@", e.reason);
    }
}

static void BKCloseEditor(void)
{
    BKSaveMarkers();
    @try {
        if (gEditWin) {
            gEditWin.hidden = YES;
            for (UIView *v in gEditWin.rootViewController.view.subviews) [v removeFromSuperview];
        }
    } @catch (NSException *e) { }
    gEditCanvas = nil;
    gEditTitle = nil;
}

@implementation BKUI

- (void)dragMarker:(UIPanGestureRecognizer *)g
{
    if (!gEditCanvas) return;
    UIView *v = g.view;
    CGPoint t = [g translationInView:gEditCanvas];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:gEditCanvas];
}

- (void)killMarker:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    BKRemoveMarkerAt((int)g.view.tag - 1000);
    BKRedrawMarkers();
}

- (void)dragBall:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:gBallWin];
    gBall.center = CGPointMake(gBall.center.x + t.x, gBall.center.y + t.y);
    [g setTranslation:CGPointZero inView:gBallWin];
}

- (void)tapBall:(UITapGestureRecognizer *)g
{
    (void)g;
    if (gMenuOpen) BKCloseMenu();
    else BKOpenMenu();
}

- (void)toggle:(UIButton *)b
{
    NSMutableDictionary *cfg = BKConfig();
    BOOL on = [[cfg objectForKey:@"Enabled"] boolValue];
    [cfg setObject:[NSNumber numberWithBool:!on] forKey:@"Enabled"];
    BKSaveConfig(cfg);
    [b setTitle:on ? @"ATIVAR" : @"DESATIVAR" forState:UIControlStateNormal];
}

- (void)cursor:(UIButton *)b
{
    NSMutableDictionary *cfg = BKConfig();
    BOOL on = [[cfg objectForKey:@"CursorOn"] boolValue];
    [cfg setObject:[NSNumber numberWithBool:!on] forKey:@"CursorOn"];
    BKSaveConfig(cfg);
    [b setTitle:on ? @"CURSOR OFF" : @"CURSOR ON" forState:UIControlStateNormal];
    if (gCursorWin) gCursorWin.hidden = on;
}

- (void)fps:(UIButton *)b
{
    NSMutableDictionary *cfg = BKConfig();
    BOOL on = [[cfg objectForKey:@"FpsMode"] boolValue];
    [cfg setObject:[NSNumber numberWithBool:!on] forKey:@"FpsMode"];
    BKSaveConfig(cfg);
    [b setTitle:on ? @"FPS OFF" : @"FPS ON" forState:UIControlStateNormal];
}

- (void)map:(UIButton *)b { (void)b; BKCloseMenu(); BKOpenEditor(@"key", 0); }
- (void)test:(UIButton *)b { (void)b; BKPost(kBKNotifyTest); BKAppend(@"autoteste"); }
- (void)capture:(UIButton *)b { (void)b; BKCaptureRequest(); }

- (void)save:(UIButton *)b
{
    (void)b;
    BKSaveMarkers();
    BKRedrawMarkers();
    if (gEditTitle) gEditTitle.text = @"salvo";
}

- (void)done:(UIButton *)b { (void)b; BKCloseEditor(); }

@end

static void BKBuildBall(void)
{
    gBallWin = BKMakeWindow(UIWindowLevelAlert + 2000);

    gBall = [[UIView alloc] initWithFrame:CGRectMake(20, 120, 44, 44)];
    gBall.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.10 alpha:0.85];
    gBall.layer.cornerRadius = 22;
    gBall.layer.borderColor = kBKNeon.CGColor;
    gBall.layer.borderWidth = 2.0;

    UILabel *bl = [[UILabel alloc] initWithFrame:gBall.bounds];
    bl.text = @"BK";
    bl.textAlignment = NSTextAlignmentCenter;
    bl.font = [UIFont boldSystemFontOfSize:15];
    bl.textColor = kBKNeon;
    bl.userInteractionEnabled = NO;
    [gBall addSubview:bl];

    [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gUI
        action:@selector(dragBall:)]];
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gUI
        action:@selector(tapBall:)]];

    [gBallWin.rootViewController.view addSubview:gBall];
    gBallWin.hidden = NO;
}

static void BKBuildCursor(void)
{
    gCursorWin = BKMakeWindow(UIWindowLevelAlert + 2001);

    gCursor = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    gCursor.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    gCursor.layer.cornerRadius = 9;
    gCursor.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    gCursor.layer.borderWidth = 1.5;
    [gCursorWin.rootViewController.view addSubview:gCursor];
    gCursorWin.hidden = YES;

    CGRect sb = [UIScreen mainScreen].bounds;
    gSpanW = sb.size.width;
    gSpanH = sb.size.height;
    gCurX = gSpanW * 0.5;
    gCurY = gSpanH * 0.5;
    gCurValid = YES;
}

static void BKStartTimer(void)
{
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 500ull * NSEC_PER_MSEC),
                              500ull * NSEC_PER_MSEC, 80ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        @try {
            static int tick = 0;
            tick++;
            if (tick == 40) {
                BKWriteInt(kBKOTryFile, 0);
                if (BKExists(kBKOSafeFile)) {
                    [[NSFileManager defaultManager] removeItemAtPath:kBKOSafeFile error:nil];
                }
                BKMark(@"overlay_ok.txt");
            }
            if (gMenuOpen) BKRefreshStatus();
            BKRefreshCursor();
            BKCapturePoll();
            NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
            BOOL cur = cfg ? [[cfg objectForKey:@"CursorOn"] boolValue] : NO;
            if (gCursorWin) gCursorWin.hidden = !cur;
            if (!gEngineLoaded) BKLoadEngine();
        } @catch (NSException *e) { }
    });
    dispatch_resume(t);
}

static void BKOverlayBuild(void)
{
    @try { if (!gUI) gUI = [[BKUI alloc] init]; } @catch (NSException *e) { return; }

    if (!gBallDone) {
        @try { BKBuildBall(); gBallDone = YES; }
        @catch (NSException *e) { BKAppend(@"! ball %@", e.reason); }
    }
    if (!gCursorDone) {
        @try { BKBuildCursor(); gCursorDone = YES; }
        @catch (NSException *e) { BKAppend(@"! cursor %@", e.reason); }
    }
    @try { BKLoadEngine(); } @catch (NSException *e) { }
    if (!gTimerDone) {
        @try { BKStartTimer(); gTimerDone = YES; }
        @catch (NSException *e) { BKAppend(@"! timer %@", e.reason); }
    }
    BKMark(@"overlay_loaded.txt");
}

__attribute__((constructor)) static void BKOverlayInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try {
                BKMark(@"overlay_ctor.txt");
                int n = BKReadInt(kBKOTryFile) + 1;
                BKWriteInt(kBKOTryFile, n);
                BOOL off = BKExists(kBKOffFile);
                if (n > 3) {
                    [@"" writeToFile:kBKOSafeFile atomically:NO encoding:NSUTF8StringEncoding error:nil];
                }
                BOOL safe = BKExists(kBKOSafeFile);
                BKAppend(@"O boot n=%d off=%d osf=%d", n, off, safe);

                if (off || (safe && n > 3)) {
                    BKMark(@"overlay_safe.txt");
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(900 * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    @try { BKOverlayBuild(); }
                    @catch (NSException *e) { BKAppend(@"! build %@", e.reason); }
                });
            } @catch (NSException *e) {
                BKAppend(@"! ctor %@", e.reason);
            }
        }
    });
}
