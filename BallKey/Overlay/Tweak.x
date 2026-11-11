#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdarg.h>

#define kBKBuildTag    @"b29"
#define kBKPrefDomain  CFSTR("com.wjf.ballkey")
#define kBKConfigPath  @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"

static UIWindow *gBallWindow = nil;
static UIWindow *gMenuWindow = nil;
static UIWindow *gEditWindow = nil;
static UIWindow *gCursorWindow = nil;
static UIView *gBall = nil;
static UIView *gCanvas = nil;
static UILabel *gBanner = nil;
static UIView *gCursorView = nil;
static NSMutableArray *gMarkers = nil;
static NSString *gFrontBundle = nil;
static NSString *gBaseDir = nil;
static NSString *gLoadRes = @"-";
static BOOL gEnabled = NO;
static int gCloseTok = 0;
static int gFpsTokOn = 0;
static int gFpsTokOff = 0;
static int gDirTok = 0;
static CGPoint gBallPos = {0.06, 0.85};

static int gLastOrient = 0;
static int gAppliedOrient = 0;
static BOOL gFpsNow = NO;

static CGRect BKSpace(void);
static UIWindowScene *BKMainScene(void);
static void BKLayoutEditor(void);
static void BKMenuLayout(void);
static void BKRefreshStatus(void);
static NSMutableDictionary *BKReadCfg(void);
static void BKToggleMenu(void);
static void BKSetEnabled(BOOL on);
static void BKSetSens(double v);
static double BKGetSens(void);
static void BKLimpar(BOOL tudo);
static void BKStopCapture(void);
static NSString *BKPath(NSString *name);
static void BKSyncApp(void);
static long BKStatusAge(void);
static NSString *BKAppText(void);
static NSString *BKOwnDir(void);
static long BKFileAge(NSString *name);
static NSString *BKSibling(NSString *name);
static NSString *BKFfApps(void);
static void BKLoadEngine(void);

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

@interface BKMarkerView : UIView
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *keyEnc;
@property (nonatomic, assign) double nx;
@property (nonatomic, assign) double ny;
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, strong) UILabel *label;
@end

static BKMarkerView *gPending = nil;
static NSTimer *gCapTimer = nil;
static NSTimer *gCursorTimer = nil;

static void BKPlaceMarker(BKMarkerView *m);

static double BKClamp01(double v)
{
    if (v < 0.02) return 0.02;
    if (v > 0.98) return 0.98;
    return v;
}

static NSString *BKBase(void)
{
    if (gBaseDir) return gBaseDir;
    CFStringRef v = CFPreferencesCopyAppValue(CFSTR("AppDir"), kBKPrefDomain);
    NSString *d = (__bridge_transfer NSString *)v;
    if ([d isKindOfClass:[NSString class]] && d.length) {
        gBaseDir = [d hasSuffix:@"/"] ? d : [d stringByAppendingString:@"/"];
    } else {
        gBaseDir = @"/var/mobile/";
    }
    return gBaseDir;
}

static NSString *BKPath(NSString *name) { return [BKBase() stringByAppendingString:name]; }

static NSString *BKOwnDir(void)
{
    static NSString *dir = nil;
    if (dir) return dir;
    Dl_info info;
    if (dladdr((void *)BKOwnDir, &info) && info.dli_fname) {
        dir = [@(info.dli_fname) stringByDeletingLastPathComponent];
    }
    return dir;
}

static void BKMark(NSString *name)
{
    [[NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]]
        writeToFile:BKPath([@"bk_" stringByAppendingString:name])
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BKLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSData *d = [[NSString stringWithFormat:@"ov %@\n", s] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:BKPath(@"bk_debug.log")];
    if (!fh) { [d writeToFile:BKPath(@"bk_debug.log") atomically:NO]; return; }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (NSException *e) { }
}

static void BKPost(const char *n) { notify_post(n); }

static void BKLoadEngine(void)
{
    NSString *d = BKOwnDir();
    if (!d) { gLoadRes = @"E0"; return; }
    NSString *p = [d stringByAppendingPathComponent:@"BallKeyEngine.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) { gLoadRes = @"NAO"; return; }

    void *h = dlopen(p.fileSystemRepresentation, RTLD_NOLOAD);
    if (h) { gLoadRes = @"ja"; return; }

    dlerror();
    h = dlopen(p.fileSystemRepresentation, RTLD_NOW);
    if (h) { gLoadRes = @"ok"; }
    else {
        const char *e = dlerror();
        NSString *es = e ? @(e) : @"?";
        if (es.length > 40) es = [es substringToIndex:40];
        gLoadRes = [NSString stringWithFormat:@"E:%@", es];
    }
    BKLog(@"load=%@", gLoadRes);
}

static UIWindowScene *BKMainScene(void)
{
    Class appCls = objc_getClass("UIApplication");
    if (!appCls) return nil;
    id app = ((id (*)(id, SEL))objc_msgSend)(appCls, @selector(sharedApplication));
    if (!app) return nil;

    SEL sel = @selector(connectedScenes);
    if ([app respondsToSelector:sel]) {
        NSSet *scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel);
        for (id sc in scenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (((NSInteger (*)(id, SEL))objc_msgSend)(sc, @selector(activationState)) == 0) return sc;
        }
        for (id sc in scenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) return sc;
        }
    }
    return nil;
}

static NSMutableDictionary *BKReadCfg(void)
{
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("Config"), kBKPrefDomain);
    if (v) {
        NSDictionary *d = (__bridge_transfer NSDictionary *)v;
        if ([d isKindOfClass:[NSDictionary class]]) return [d mutableCopy];
    }
    return [[NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath]
        ?: [NSMutableDictionary dictionary] mutableCopy];
}

static void BKWriteCfg(NSMutableDictionary *cfg)
{
    [cfg writeToFile:kBKConfigPath atomically:YES];
    CFPreferencesSetAppValue(CFSTR("Config"), (__bridge CFDictionaryRef)cfg, kBKPrefDomain);
    CFPreferencesAppSynchronize(kBKPrefDomain);
    BKPost("com.wjf.ballkey.reload");
}

static BOOL BKGetDump(void)
{
    NSNumber *n = BKReadCfg()[@"Dump"];
    return n ? [n boolValue] : NO;
}

static long BKFileAge(NSString *name)
{
    NSDictionary *at = [[NSFileManager defaultManager]
        attributesOfItemAtPath:BKPath(name) error:nil];
    NSDate *mt = at[NSFileModificationDate];
    if (!mt) return -1;
    return (long)[[NSDate date] timeIntervalSinceDate:mt];
}

static NSString *BKSibling(NSString *name)
{
    NSString *d = BKOwnDir();
    if (!d) return @"?";
    return [[NSFileManager defaultManager]
        fileExistsAtPath:[d stringByAppendingPathComponent:name]] ? @"S" : @"N";
}

static NSString *BKFfApps(void)
{
    Class wsCls = objc_getClass("LSApplicationWorkspace");
    if (!wsCls) return @"?";
    id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace));
    if (!ws) return @"?";
    SEL s = @selector(allInstalledApplications);
    if (![ws respondsToSelector:s]) return @"?";
    NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, s);
    NSMutableString *out = [NSMutableString string];
    for (id a in apps) {
        NSString *b = ((id (*)(id, SEL))objc_msgSend)(a, @selector(bundleIdentifier));
        if (![b isKindOfClass:[NSString class]] || !b.length) continue;
        if ([b.lowercaseString rangeOfString:@"fire"].location == NSNotFound) continue;
        if (out.length) [out appendString:@","];
        [out appendString:b];
        if (out.length > 60) break;
    }
    return out.length ? out : @"none";
}

static long BKStatusAge(void) { return BKFileAge(@"bk_status.txt"); }

static NSString *BKAppText(void)
{
    NSString *s = [NSString stringWithContentsOfFile:BKPath(@"bk_app.txt")
                                           encoding:NSUTF8StringEncoding error:nil];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length ? s : @"-";
}

static NSString *BKStatusText(void)
{
    NSString *st = [NSString stringWithContentsOfFile:BKPath(@"bk_status.txt")
                                            encoding:NSUTF8StringEncoding error:nil];
    st = [st stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    long age = BKStatusAge();
    long eng = BKFileAge(@"bk_engine_ctor.txt");
    NSString *motor = (age >= 0 && age <= 5) ? @"mot:ok" : @"mot:NAO";
    return [NSString stringWithFormat:@"%@ v%@ ld:%@ lib:%@ pl:%@\nff:%@\neng:%lds\n%@",
            motor, kBKBuildTag, gLoadRes, BKSibling(@"BallKeyEngine.dylib"),
            BKSibling(@"BallKeyEngine.plist"), BKFfApps(), eng, st.length ? st : @"-"];
}

static void BKSyncApp(void)
{
    NSString *s = BKAppText();
    if ([s isEqualToString:@"-"]) return;
    if ([s isEqualToString:gFrontBundle]) return;
    gFrontBundle = s;
    NSMutableDictionary *cfg = BKReadCfg();
    cfg[@"ActiveBundle"] = s;
    BKWriteCfg(cfg);
    BKLog(@"app=%@", s);
}

static int BKFrontMostOrientation(void)
{
    Class sbCls = objc_getClass("SpringBoard");
    if (!sbCls) return 0;
    id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
    if (!sb) return 0;

    SEL s1 = @selector(_frontMostAppOrientation);
    if ([sb respondsToSelector:s1]) {
        int o = (int)((int (*)(id, SEL))objc_msgSend)(sb, s1);
        if (o >= 1 && o <= 4) return o;
    }
    return 0;
}

static int BKDeviceOrientation(void)
{
    Class c = objc_getClass("UIDevice");
    if (!c) return 0;
    id d = ((id (*)(id, SEL))objc_msgSend)(c, @selector(currentDevice));
    if (!d) return 0;
    int o = (int)((int (*)(id, SEL))objc_msgSend)(d, @selector(orientation));
    if (o >= 1 && o <= 4) return o;
    return 0;
}

static int BKReadOrient(void)
{
    NSNumber *ov = BKReadCfg()[@"OrientOverride"];
    int o = ov ? [ov intValue] : 0;
    if (o < 1 || o > 4) o = BKDeviceOrientation();
    if (o < 1 || o > 4) o = BKFrontMostOrientation();
    if (o < 1 || o > 4) o = gLastOrient;
    if (o < 1 || o > 4) o = 3;
    gLastOrient = o;
    return o;
}

static CGRect BKPortraitBase(void)
{
    UIScreen *s = [UIScreen mainScreen];
    CGFloat scale = s.nativeScale > 0 ? s.nativeScale : s.scale;
    CGRect nb = s.nativeBounds;
    if (nb.size.width > 1.0 && nb.size.height > 1.0 && scale > 0.0) {
        CGFloat w = nb.size.width / scale;
        CGFloat h = nb.size.height / scale;
        if (w > h) { CGFloat t = w; w = h; h = t; }
        if (w > 1.0 && h > 1.0) return CGRectMake(0, 0, w, h);
    }
    CGRect b = s.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) b = CGRectMake(0, 0, 414, 736);
    if (b.size.width > b.size.height) {
        CGFloat t = b.size.width;
        b.size.width = b.size.height;
        b.size.height = t;
    }
    return CGRectMake(0, 0, b.size.width, b.size.height);
}

static CGRect BKSpaceFor(int o)
{
    CGRect base = BKPortraitBase();
    if (o == 3 || o == 4) return CGRectMake(0, 0, base.size.height, base.size.width);
    return base;
}

static CGRect BKSpace(void) { return BKSpaceFor(BKReadOrient()); }

static UIWindow *BKMakeWindow(CGFloat level, BOOL pass)
{
    UIWindowScene *scene = BKMainScene();
    if (!scene) return nil;

    UIWindow *w = pass ? (UIWindow *)[[BKPassWindow alloc] initWithWindowScene:scene]
                       : [[UIWindow alloc] initWithWindowScene:scene];
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

#pragma mark - Cursor

static void BKNativeToSpace(double nx, double ny, int orient, double *ox, double *oy)
{
    double rx = nx, ry = ny;
    switch (orient) {
        case 2: rx = 1.0 - nx; ry = 1.0 - ny; break;
        case 3: rx = 1.0 - ny; ry = nx;       break;
        case 4: rx = ny;       ry = 1.0 - nx; break;
        default: break;
    }
    if (rx < 0) rx = 0; if (rx > 1) rx = 1;
    if (ry < 0) ry = 0; if (ry > 1) ry = 1;
    *ox = rx; *oy = ry;
}

static void BKPtrPlace(CGPoint pt)
{
    if (!gCursorView) return;
    gCursorView.layer.position = pt;
}

static void BKMakeCursor(UIView *v)
{
    v.backgroundColor = [UIColor clearColor];
    v.userInteractionEnabled = NO;
    CGFloat w = 14.0, h = 19.0;
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(0.4, 0.4)];
    [p addLineToPoint:CGPointMake(0.4, 18.0)];
    [p addLineToPoint:CGPointMake(4.6, 14.2)];
    [p addLineToPoint:CGPointMake(7.4, 18.8)];
    [p addLineToPoint:CGPointMake(9.5, 17.7)];
    [p addLineToPoint:CGPointMake(6.7, 13.0)];
    [p addLineToPoint:CGPointMake(13.2, 13.0)];
    [p closePath];

    CAShapeLayer *l = [CAShapeLayer layer];
    l.frame = CGRectMake(0, 0, w, h);
    l.path = p.CGPath;
    l.fillColor = [UIColor whiteColor].CGColor;
    l.strokeColor = [UIColor blackColor].CGColor;
    l.lineWidth = 1.0;
    l.lineJoin = kCALineJoinRound;
    l.lineCap = kCALineCapRound;
    l.shadowColor = [UIColor blackColor].CGColor;
    l.shadowOpacity = 0.45;
    l.shadowRadius = 1.0;
    l.shadowOffset = CGSizeMake(0.4, 0.6);
    [v.layer addSublayer:l];

    v.layer.anchorPoint = CGPointMake(0.0, 0.0);
    v.bounds = CGRectMake(0, 0, w, h);
}

static void BKPtrPoll(void)
{
    if (!gCursorView || !gCursorWindow || gCursorWindow.hidden) return;
    NSString *s = [NSString stringWithContentsOfFile:BKPath(@"bk_ptr.txt")
                                            encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return;
    NSArray *a = [s componentsSeparatedByString:@" "];
    if (a.count < 3) return;

    NSString *tag = a[0];
    double nx = 0.0, ny = 0.0;

    if ([tag isEqualToString:@"A"]) {
        if (a.count < 5) return;
        double rx = [a[1] doubleValue];
        double ry = [a[2] doubleValue];
        double spanX = [a[3] doubleValue];
        double spanY = [a[4] doubleValue];
        if (spanX < 1.0 || spanY < 1.0) return;
        BKNativeToSpace(rx / spanX, ry / spanY, BKReadOrient(), &nx, &ny);
    } else if ([tag isEqualToString:@"R"]) {
        BKNativeToSpace([a[1] doubleValue], [a[2] doubleValue], BKReadOrient(), &nx, &ny);
    } else {
        return;
    }

    CGSize sz = gCursorWindow.bounds.size;
    if (sz.width < 1.0 || sz.height < 1.0) return;
    BKPtrPlace(CGPointMake(nx * sz.width, ny * sz.height));
}

static void BKPtrShow(BOOL on)
{
    if (on) {
        if (!gCursorWindow) {
            gCursorWindow = BKMakeWindow(UIWindowLevelAlert + 999, YES);
            if (!gCursorWindow) return;
            gCursorView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 19)];
            BKMakeCursor(gCursorView);
            [gCursorWindow.rootViewController.view addSubview:gCursorView];
            gCursorWindow.hidden = NO;
            CGSize sz = gCursorWindow.bounds.size;
            BKPtrPlace(CGPointMake(sz.width / 2, sz.height / 2));
        }
        gCursorWindow.hidden = NO;
        BKPtrPoll();
        if (!gCursorTimer) {
            gCursorTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                            repeats:YES
                                                              block:^(NSTimer *t) {
                (void)t;
                BKPtrPoll();
            }];
        }
    } else {
        if (gCursorTimer) { [gCursorTimer invalidate]; gCursorTimer = nil; }
        if (gCursorWindow) gCursorWindow.hidden = YES;
    }
}

#pragma mark - Marcadores

static NSString *BKTypeName(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return @"Toque";
    if ([t isEqualToString:@"Press"]) return @"Pressionar";
    if ([t isEqualToString:@"Hold"]) return @"Segurar";
    if ([t isEqualToString:@"Dir"]) return @"Direção";
    if ([t isEqualToString:@"Fps"]) return @"Trava FPS";
    return t;
}

static UIColor *BKTypeColor(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return [UIColor colorWithRed:0.00 green:0.70 blue:1.00 alpha:1];
    if ([t isEqualToString:@"Press"]) return [UIColor colorWithRed:0.00 green:0.90 blue:0.45 alpha:1];
    if ([t isEqualToString:@"Hold"]) return [UIColor colorWithRed:1.00 green:0.62 blue:0.00 alpha:1];
    if ([t isEqualToString:@"Dir"]) return [UIColor colorWithRed:0.72 green:0.20 blue:1.00 alpha:1];
    return [UIColor colorWithRed:1.00 green:0.18 blue:0.30 alpha:1];
}

static void BKPlaceMarker(BKMarkerView *m)
{
    if (!gCanvas || !m) return;
    CGSize sz = gCanvas.bounds.size;
    if (sz.width < 1.0 || sz.height < 1.0) return;
    m.nx = BKClamp01(m.nx);
    m.ny = BKClamp01(m.ny);
    CGFloat side = 56;
    m.frame = CGRectMake(m.nx * sz.width - side / 2, m.ny * sz.height - side / 2, side, side);
}

@implementation BKMarkerView

- (void)bkPan:(UIPanGestureRecognizer *)g
{
    if (!gCanvas) return;
    CGPoint p = [g locationInView:gCanvas];
    CGSize sz = gCanvas.bounds.size;
    if (sz.width < 1.0 || sz.height < 1.0) return;
    self.nx = BKClamp01(p.x / sz.width);
    self.ny = BKClamp01(p.y / sz.height);
    BKPlaceMarker(self);
}

- (void)bkLong:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (gPending == self) BKStopCapture();
    [gMarkers removeObject:self];
    [self removeFromSuperview];
}

@end

static void BKStopCapture(void)
{
    [gCapTimer invalidate];
    gCapTimer = nil;
    gPending = nil;
    if (gBanner) gBanner.hidden = YES;
    [[NSFileManager defaultManager] removeItemAtPath:BKPath(@"bk_capture.txt") error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:BKPath(@"bk_capture_result.txt") error:nil];
}

static void BKStartCapture(BKMarkerView *m)
{
    if (!m) return;
    [gCapTimer invalidate];
    gCapTimer = nil;
    gPending = m;
    if (gBanner) gBanner.hidden = NO;

    [[NSFileManager defaultManager] removeItemAtPath:BKPath(@"bk_capture_result.txt") error:nil];

    NSString *nonce = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970] * 1000.0];
    [nonce writeToFile:BKPath(@"bk_capture.txt") atomically:YES
              encoding:NSUTF8StringEncoding error:nil];
    BKPost("com.wjf.ballkey.capture");

    gCapTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer *t) {
        @try {
            if (!gPending) { [t invalidate]; return; }
            NSString *r = [NSString stringWithContentsOfFile:BKPath(@"bk_capture_result.txt")
                                                    encoding:NSUTF8StringEncoding error:nil];
            r = [r stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (r.length) {
                NSArray *p = [r componentsSeparatedByString:@"|"];
                if (p.count >= 2) {
                    NSString *got = p[0];
                    NSString *key = p[1];
                    if ([got isEqualToString:nonce] && key.length) {
                        gPending.keyEnc = key;
                        gPending.label.text = [NSString stringWithFormat:@"%@\n%@",
                                               BKTypeName(gPending.type), key];
                        BKLog(@"capturado %@ em %@", key, gPending.type);
                        BKStopCapture();
                        return;
                    }
                }
            }
            if (![[NSFileManager defaultManager] fileExistsAtPath:BKPath(@"bk_capture.txt")]) {
                [nonce writeToFile:BKPath(@"bk_capture.txt") atomically:YES
                          encoding:NSUTF8StringEncoding error:nil];
                BKPost("com.wjf.ballkey.capture");
            }
        } @catch (NSException *e) { }
    }];
}

static BKMarkerView *BKMakeMarker(NSString *type, double nx, double ny, NSString *enc)
{
    CGFloat side = 56;
    BKMarkerView *m = [[BKMarkerView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    UIColor *col = BKTypeColor(type);
    m.backgroundColor = [col colorWithAlphaComponent:0.28];
    m.layer.cornerRadius = side / 2;
    m.layer.borderColor = col.CGColor;
    m.layer.borderWidth = 2.2;
    m.layer.shadowColor = col.CGColor;
    m.layer.shadowOpacity = 0.85;
    m.layer.shadowRadius = 6;
    m.layer.shadowOffset = CGSizeZero;
    m.type = type;
    m.keyEnc = enc;
    m.nx = BKClamp01(nx);
    m.ny = BKClamp01(ny);
    m.radius = 0.09;

    UILabel *l = [[UILabel alloc] initWithFrame:m.bounds];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont boldSystemFontOfSize:10.5];
    l.textColor = UIColor.whiteColor;
    l.numberOfLines = 2;
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    l.text = [NSString stringWithFormat:@"%@\n%@", BKTypeName(type), enc ?: @"?"];
    [m addSubview:l];
    m.label = l;

    [m addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:m action:@selector(bkPan:)]];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:m action:@selector(bkLong:)];
    lp.minimumPressDuration = 0.8;
    [m addGestureRecognizer:lp];
    return m;
}

static void BKAddMarker(NSString *type, BOOL capture)
{
    if (!gCanvas) return;
    BKMarkerView *m = BKMakeMarker(type, 0.5, 0.5, nil);
    [gCanvas addSubview:m];
    [gMarkers addObject:m];
    BKPlaceMarker(m);
    if (capture) BKStartCapture(m);
}

static NSString *BKBundle(void)
{
    if (gFrontBundle.length && ![gFrontBundle isEqualToString:@"com.apple.springboard"])
        return gFrontBundle;
    NSMutableDictionary *cfg = BKReadCfg();
    NSString *b = cfg[@"ActiveBundle"];
    if ([b isKindOfClass:[NSString class]] && b.length
        && ![b isEqualToString:@"com.apple.springboard"]) return b;
    return @"*";
}

static void BKSaveEditor(void)
{
    NSMutableArray *pts = [NSMutableArray array];
    NSMutableDictionary *cfg = BKReadCfg();

    for (BKMarkerView *m in gMarkers) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"X"] = @(m.nx);
        d[@"Y"] = @(m.ny);
        d[@"Type"] = m.type;
        if ([m.type isEqualToString:@"Fps"]) {
            d[@"Key"] = m.keyEnc ?: @"k:224";
            cfg[@"FpsX"] = d[@"X"];
            cfg[@"FpsY"] = d[@"Y"];
            cfg[@"FpsKey"] = @([m.keyEnc hasPrefix:@"k:"] ? [[m.keyEnc substringFromIndex:2] intValue] : 224);
            [pts addObject:d];
            continue;
        }
        if ([m.type isEqualToString:@"Dir"]) {
            double r = m.radius;
            d[@"Key"] = m.keyEnc ?: @"m:0";
            d[@"Radius"] = @(r);
            d[@"Sens"] = @(1.0);
            d[@"Center"] = [NSString stringWithFormat:@"%.5f,%.5f", m.nx, m.ny];
            d[@"Up"] = [NSString stringWithFormat:@"%.5f,%.5f", m.nx, m.ny - r];
            d[@"Down"] = [NSString stringWithFormat:@"%.5f,%.5f", m.nx, m.ny + r];
            d[@"Left"] = [NSString stringWithFormat:@"%.5f,%.5f", m.nx - r, m.ny];
            d[@"Right"] = [NSString stringWithFormat:@"%.5f,%.5f", m.nx + r, m.ny];
            [pts addObject:d];
            continue;
        }
        if (m.keyEnc.length) {
            d[@"Key"] = m.keyEnc;
            if ([m.keyEnc isEqualToString:@"m:0"]) {
                cfg[@"FireX"] = d[@"X"];
                cfg[@"FireY"] = d[@"Y"];
            } else if ([m.keyEnc isEqualToString:@"m:1"]) {
                cfg[@"AdsX"] = d[@"X"];
                cfg[@"AdsY"] = d[@"Y"];
            }
        }
        [pts addObject:d];
    }

    NSString *bundle = BKBundle();
    NSMutableDictionary *profiles = [cfg[@"Profiles"] isKindOfClass:[NSDictionary class]]
        ? [cfg[@"Profiles"] mutableCopy] : [NSMutableDictionary dictionary];
    profiles[bundle] = pts;
    cfg[@"Profiles"] = profiles;
    cfg[@"ActiveBundle"] = bundle;
    BKWriteCfg(cfg);
    BKLog(@"save: %lu marcadores em %@", (unsigned long)pts.count, bundle);
}

static void BKCloseEditor(void)
{
    BKStopCapture();
    [gEditWindow setHidden:YES];
    gEditWindow = nil;
    gCanvas = nil;
    gMarkers = nil;
    gBanner = nil;
}

#pragma mark - Editor

@interface UIViewController (BKUI)
- (void)bkAdd:(UIButton *)b;
- (void)bkSave:(UIButton *)b;
- (void)bkClose:(UIButton *)b;
- (void)bkMenuTap:(UIButton *)b;
- (void)bkPan:(UIPanGestureRecognizer *)g;
- (void)bkTap:(UITapGestureRecognizer *)g;
@end

static void BKLayoutEditor(void)
{
    if (!gEditWindow) return;
    UIView *root = gEditWindow.rootViewController.view;
    CGRect b = root.bounds;
    gCanvas.frame = b;

    UIView *bar = [root viewWithTag:88];
    if (bar) {
        bar.frame = CGRectMake(0, 0, b.size.width, 96);
        CGFloat gap = 8;
        CGFloat x = 10;
        CGFloat bw = (b.size.width - 20 - gap * 4) / 5.0;
        if (bw < 44) bw = 44;
        for (int i = 0; i < 5; i++) {
            UIView *v = [bar viewWithTag:200 + i];
            v.frame = CGRectMake(x, 10, bw, 38);
            x += bw + gap;
        }
        UIView *sv = [bar viewWithTag:210];
        sv.frame = CGRectMake(b.size.width - 170, 54, 74, 36);
        UIView *ex = [bar viewWithTag:211];
        ex.frame = CGRectMake(b.size.width - 88, 54, 78, 36);
    }
    if (gBanner) gBanner.frame = CGRectMake(b.size.width / 2 - 160, b.size.height - 58, 320, 36);
    for (BKMarkerView *m in gMarkers) BKPlaceMarker(m);
}

static void BKStyleButton(UIButton *b, UIColor *col, CGFloat size)
{
    b.titleLabel.font = [UIFont boldSystemFontOfSize:size];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.72];
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1.4;
    b.layer.borderColor = col.CGColor;
    b.layer.shadowColor = col.CGColor;
    b.layer.shadowOpacity = 0.75;
    b.layer.shadowRadius = 5;
    b.layer.shadowOffset = CGSizeZero;
}

static void BKOpenEditor(void)
{
    if (gEditWindow) return;
    gEditWindow = BKMakeWindow(UIWindowLevelAlert + 1005, NO);
    if (!gEditWindow) {
        BKLog(@"editor: sem scene");
        return;
    }
    gMarkers = [NSMutableArray array];

    UIView *root = gEditWindow.rootViewController.view;
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.34];

    gCanvas = [[UIView alloc] initWithFrame:root.bounds];
    gCanvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:gCanvas];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.tag = 88;
    bar.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.94];
    bar.layer.borderWidth = 1;
    bar.layer.borderColor = [UIColor colorWithRed:0 green:0.9 blue:1 alpha:0.55].CGColor;
    [root addSubview:bar];

    NSArray *row1 = @[@[@"+ Toque", @"Tap"], @[@"+ Pressionar", @"Press"],
                      @[@"+ Segurar", @"Hold"], @[@"+ Direção", @"Dir"], @[@"+ Trava", @"Fps"]];
    for (NSUInteger i = 0; i < row1.count; i++) {
        NSArray *pair = row1[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = 200 + (NSInteger)i;
        [b setTitle:pair[0] forState:UIControlStateNormal];
        BKStyleButton(b, BKTypeColor(pair[1]), 12.5);
        [b addTarget:gEditWindow.rootViewController
              action:@selector(bkAdd:)
    forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
    }

    UIButton *sv = [UIButton buttonWithType:UIButtonTypeSystem];
    sv.tag = 210;
    [sv setTitle:@"Salvar" forState:UIControlStateNormal];
    BKStyleButton(sv, [UIColor colorWithRed:0 green:0.95 blue:0.5 alpha:1], 13);
    [sv addTarget:gEditWindow.rootViewController
          action:@selector(bkSave:)
forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:sv];

    UIButton *ex = [UIButton buttonWithType:UIButtonTypeSystem];
    ex.tag = 211;
    [ex setTitle:@"Fechar" forState:UIControlStateNormal];
    BKStyleButton(ex, [UIColor colorWithRed:1 green:0.2 blue:0.25 alpha:1], 13);
    [ex addTarget:gEditWindow.rootViewController
          action:@selector(bkClose:)
forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:ex];

    gBanner = [[UILabel alloc] initWithFrame:CGRectZero];
    gBanner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    gBanner.textColor = UIColor.whiteColor;
    gBanner.font = [UIFont boldSystemFontOfSize:12];
    gBanner.textAlignment = NSTextAlignmentCenter;
    gBanner.layer.cornerRadius = 10;
    gBanner.layer.borderWidth = 1.2;
    gBanner.layer.borderColor = [UIColor colorWithRed:0 green:0.95 blue:1 alpha:0.9].CGColor;
    gBanner.clipsToBounds = YES;
    gBanner.text = @"Aperte a tecla ou o botão do mouse agora";
    gBanner.hidden = YES;
    [root addSubview:gBanner];

    NSMutableDictionary *cfg = BKReadCfg();
    NSString *bundle = BKBundle();
    NSDictionary *profiles = cfg[@"Profiles"];
    if ([profiles isKindOfClass:[NSDictionary class]] && bundle) {
        NSArray *saved = profiles[bundle];
        if ([saved isKindOfClass:[NSArray class]]) {
            for (NSDictionary *d in saved) {
                if (![d isKindOfClass:[NSDictionary class]]) continue;
                NSString *t = d[@"Type"];
                if (![t isKindOfClass:[NSString class]]) continue;
                BKMarkerView *m = BKMakeMarker(t, [d[@"X"] doubleValue], [d[@"Y"] doubleValue], d[@"Key"]);
                [gCanvas addSubview:m];
                [gMarkers addObject:m];
                BKPlaceMarker(m);
            }
        }
    }

    [gEditWindow setHidden:NO];
    BKLayoutEditor();
}

@implementation UIViewController (BKUI)

- (void)bkAdd:(UIButton *)b
{
    @try {
        NSArray *types = @[@"Tap", @"Press", @"Hold", @"Dir", @"Fps"];
        NSInteger i = b.tag - 200;
        if (i < 0 || i >= (NSInteger)types.count) return;
        BKAddMarker(types[i], YES);
    } @catch (NSException *e) {
        BKLog(@"add erro: %@", e.reason);
    }
}

- (void)bkSave:(UIButton *)b
{
    (void)b;
    BKSaveEditor();
    dispatch_async(dispatch_get_main_queue(), ^{ BKCloseEditor(); });
}

- (void)bkClose:(UIButton *)b
{
    (void)b;
    dispatch_async(dispatch_get_main_queue(), ^{ BKCloseEditor(); });
}

- (void)bkMenuTap:(UIButton *)b
{
    NSInteger i = b.tag - 100;
    if (i == 0) {
        gMenuWindow.hidden = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ BKOpenEditor(); });
        return;
    }
    if (i == 4) {
        gMenuWindow.hidden = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ BKPost("com.wjf.ballkey.test"); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3400 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (!gMenuWindow || gMenuWindow.hidden) BKToggleMenu();
        });
        return;
    }
    if (i == 10) {
        gMenuWindow.hidden = YES;
        return;
    }
    if (i == 9) {
        NSMutableDictionary *cfg = BKReadCfg();
        BOOL on = ![cfg[@"CursorOn"] boolValue];
        cfg[@"CursorOn"] = @(on);
        BKWriteCfg(cfg);
        BKPtrShow(on && !gFpsNow);
        BKLog(@"cursor=%d", (int)on);
    } else if (i == 5) {
        NSMutableDictionary *cfg = BKReadCfg();
        BOOL on = ![cfg[@"Dump"] boolValue];
        cfg[@"Dump"] = @(on);
        BKWriteCfg(cfg);
        BKLog(@"dump=%d", (int)on);
    } else if (i == 6) {
        BKPost("com.wjf.ballkey.reload");
    } else if (i == 1) {
        BKSetSens(BKGetSens() - 0.05);
    } else if (i == 2) {
        BKSetSens(BKGetSens() + 0.05);
    } else if (i == 3) {
        BKSetEnabled(!gEnabled);
    } else if (i == 7) {
        BKLimpar(NO);
    } else if (i == 8) {
        BKLimpar(YES);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        BKToggleMenu();
        BKToggleMenu();
    });
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

#pragma mark - Menu

static void BKSetEnabled(BOOL on)
{
    NSMutableDictionary *cfg = BKReadCfg();
    cfg[@"Enabled"] = @(on);
    BKWriteCfg(cfg);
    gEnabled = on;
}

static void BKSetSens(double v)
{
    if (v < 0.1) v = 0.1;
    if (v > 5.0) v = 5.0;
    NSMutableDictionary *cfg = BKReadCfg();
    cfg[@"FpsSens"] = @(v);
    BKWriteCfg(cfg);
}

static double BKGetSens(void)
{
    NSNumber *n = BKReadCfg()[@"FpsSens"];
    return n ? [n doubleValue] : 1.0;
}

static void BKLimpar(BOOL tudo)
{
    NSMutableDictionary *cfg = BKReadCfg();
    NSString *bundle = BKBundle();
    NSMutableDictionary *profiles = [cfg[@"Profiles"] isKindOfClass:[NSDictionary class]]
        ? [cfg[@"Profiles"] mutableCopy] : [NSMutableDictionary dictionary];
    NSArray *pts = profiles[bundle];
    if (![pts isKindOfClass:[NSArray class]]) return;

    if (tudo) {
        [profiles removeObjectForKey:bundle];
        BKLog(@"limpar: tudo");
    } else {
        NSMutableArray *keep = [NSMutableArray array];
        NSUInteger n = 0;
        for (NSDictionary *d in pts) {
            if ([d[@"Type"] isEqualToString:@"Dir"]) { n++; continue; }
            [keep addObject:d];
        }
        profiles[bundle] = keep;
        BKLog(@"limpar: %lu direcao, sobrou %lu", (unsigned long)n, (unsigned long)keep.count);
    }
    cfg[@"Profiles"] = profiles;
    BKWriteCfg(cfg);
}

static UIColor *BKNeon(NSInteger i)
{
    switch (i) {
        case 0:  return [UIColor colorWithRed:0.00 green:0.95 blue:1.00 alpha:1];
        case 1:  return [UIColor colorWithRed:0.20 green:0.55 blue:1.00 alpha:1];
        case 2:  return [UIColor colorWithRed:0.55 green:0.30 blue:1.00 alpha:1];
        case 3:  return [UIColor colorWithRed:0.00 green:0.95 blue:0.50 alpha:1];
        case 4:  return [UIColor colorWithRed:0.90 green:0.20 blue:1.00 alpha:1];
        case 5:  return [UIColor colorWithRed:0.65 green:0.70 blue:0.78 alpha:1];
        case 6:  return [UIColor colorWithRed:0.00 green:0.72 blue:1.00 alpha:1];
        case 7:  return [UIColor colorWithRed:1.00 green:0.70 blue:0.00 alpha:1];
        case 8:  return [UIColor colorWithRed:1.00 green:0.15 blue:0.30 alpha:1];
        case 9:  return [UIColor colorWithRed:0.10 green:1.00 blue:0.85 alpha:1];
        default: return [UIColor colorWithRed:1.00 green:0.35 blue:0.10 alpha:1];
    }
}

static UIButton *BKMenuButton(UIView *box, NSString *title, NSInteger idx)
{
    UIColor *col = BKNeon(idx);
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    BKStyleButton(b, col, 13.5);
    b.tag = 100 + idx;
    [b addTarget:gMenuWindow.rootViewController
          action:@selector(bkMenuTap:)
forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:b];
    return b;
}

static void BKMenuLayout(void)
{
    if (!gMenuWindow || gMenuWindow.hidden) return;
    UIView *root = gMenuWindow.rootViewController.view;
    UIVisualEffectView *box = (UIVisualEffectView *)[root viewWithTag:77];
    if (!box) return;

    CGSize sz = root.bounds.size;
    if (sz.width < 1.0 || sz.height < 1.0) return;

    BOOL duas = (sz.height < 580.0);
    CGFloat bw = duas ? MIN(540.0, sz.width * 0.76) : MIN(320.0, sz.width * 0.74);
    CGFloat headerH = 104.0;
    CGFloat rowH = duas ? 38.0 : 42.0;
    CGFloat gap = 10.0;
    int linhas = duas ? 6 : 11;
    CGFloat bh = headerH + 16.0 + linhas * (rowH + gap) + 6.0;
    if (bh > sz.height - 16.0) bh = sz.height - 16.0;

    box.frame = CGRectMake((sz.width - bw) / 2.0, (sz.height - bh) / 2.0, bw, bh);

    CAGradientLayer *g = (CAGradientLayer *)[box.contentView.layer valueForKey:@"bkGrad"];
    if (!g) {
        g = [CAGradientLayer layer];
        g.colors = @[(id)[UIColor colorWithRed:0 green:0.95 blue:1 alpha:1].CGColor,
                     (id)[UIColor colorWithRed:0.85 green:0.15 blue:1 alpha:1].CGColor];
        g.startPoint = CGPointMake(0, 0);
        g.endPoint = CGPointMake(1, 1);
        g.opacity = 0.16;
        [box.contentView.layer insertSublayer:g atIndex:0];
        [box.contentView.layer setValue:g forKey:@"bkGrad"];
    }
    g.frame = box.contentView.bounds;

    UIView *head = [box.contentView viewWithTag:78];
    if (head) head.frame = CGRectMake(12, 10, bw - 24, headerH - 8);

    int cols = duas ? 2 : 1;
    CGFloat pad = 12.0;
    CGFloat colW = (bw - pad * 2.0 - gap * (cols - 1)) / cols;
    CGFloat y = headerH + 10.0;
    for (int i = 0; i < 11; i++) {
        UIView *b = [box.contentView viewWithTag:100 + i];
        if (!b) continue;
        int c = i % cols, r = i / cols;
        b.frame = CGRectMake(pad + c * (colW + gap), y + r * (rowH + gap), colW, rowH);
    }
}

static void BKToggleMenu(void)
{
    if (gMenuWindow && !gMenuWindow.hidden) {
        gMenuWindow.hidden = YES;
        return;
    }
    if (!gMenuWindow) {
        gMenuWindow = BKMakeWindow(UIWindowLevelAlert + 1001, YES);
        if (!gMenuWindow) {
            BKLog(@"menu: sem scene");
            return;
        }
    }
    gMenuWindow.frame = BKSpace();

    UIView *root = gMenuWindow.rootViewController.view;
    [[root viewWithTag:77] removeFromSuperview];

    UIVisualEffectView *box = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    box.tag = 77;
    box.layer.cornerRadius = 18;
    box.layer.borderWidth = 1.6;
    box.layer.borderColor = [UIColor colorWithRed:0 green:0.95 blue:1 alpha:0.85].CGColor;
    box.layer.shadowColor = [UIColor colorWithRed:0.55 green:0.1 blue:1 alpha:1].CGColor;
    box.layer.shadowOpacity = 0.9;
    box.layer.shadowRadius = 14;
    box.layer.shadowOffset = CGSizeZero;
    box.clipsToBounds = NO;

    UIView *host = box.contentView;
    host.clipsToBounds = YES;
    host.layer.cornerRadius = 18;

    UIView *head = [[UIView alloc] initWithFrame:CGRectZero];
    head.tag = 78;
    head.backgroundColor = [UIColor clearColor];
    [host addSubview:head];

    UILabel *tt = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 300, 18)];
    tt.font = [UIFont boldSystemFontOfSize:13];
    tt.textColor = [UIColor colorWithRed:0.25 green:1 blue:1 alpha:1];
    tt.text = @"TECLADO E MOUSE MAPEADOR";
    tt.adjustsFontSizeToFitWidth = YES;
    tt.minimumScaleFactor = 0.6;
    tt.textAlignment = NSTextAlignmentCenter;
    tt.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [head addSubview:tt];

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(0, 22, 300, 68)];
    st.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightSemibold];
    st.numberOfLines = 5;
    st.textAlignment = NSTextAlignmentCenter;
    st.backgroundColor = [UIColor colorWithWhite:0 alpha:0.60];
    st.layer.cornerRadius = 8;
    st.clipsToBounds = YES;
    st.adjustsFontSizeToFitWidth = YES;
    st.minimumScaleFactor = 0.38;
    st.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    st.tag = 79;
    [head addSubview:st];

    NSArray *titles = @[@"Editor", @"Sens -", @"Sens +", @"Ligar", @"Testar",
                        @"Dump", @"Recarregar", @"Limpar teclas", @"Limpar tudo",
                        @"Cursor: OFF", @"Fechar"];

    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSString *t = titles[i];
        if (i == 3) t = gEnabled ? @"Desligar" : @"Ligar";
        if (i == 5 && BKGetDump()) t = @"Dump: ON";
        if (i == 9) t = [BKReadCfg()[@"CursorOn"] boolValue] ? @"Cursor: ON" : @"Cursor: OFF";
        if (i == 1) t = [NSString stringWithFormat:@"Sens -  %.2f", BKGetSens()];
        if (i == 2) t = [NSString stringWithFormat:@"Sens +  %.2f", BKGetSens()];
        BKMenuButton(host, t, i);
    }

    [root addSubview:box];
    gMenuWindow.hidden = NO;
    BKMenuLayout();
    BKRefreshStatus();
}

static void BKRefreshStatus(void)
{
    if (!gMenuWindow || gMenuWindow.hidden) return;
    UILabel *st = (UILabel *)[gMenuWindow.rootViewController.view viewWithTag:79];
    if (!st) return;
    long age = BKStatusAge();
    st.text = [NSString stringWithFormat:@"%@\na=%@", BKStatusText(), BKAppText()];
    st.textColor = (age >= 0 && age <= 5) ? UIColor.whiteColor
                                          : [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:1];
}

#pragma mark - Bolinha

static void BKSetupBall(void)
{
    if (gBallWindow) return;

    gBallWindow = BKMakeWindow(UIWindowLevelAlert + 1000, YES);
    if (!gBallWindow) {
        BKLog(@"ball: sem scene, retry");
        return;
    }

    gBall = [[UIView alloc] initWithFrame:CGRectZero];
    gBall.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.09 alpha:0.80];
    gBall.layer.cornerRadius = 22;
    gBall.layer.borderWidth = 1.6;
    gBall.layer.borderColor = [UIColor colorWithRed:0 green:0.95 blue:1 alpha:0.95].CGColor;
    gBall.layer.shadowColor = [UIColor colorWithRed:0 green:0.95 blue:1 alpha:1].CGColor;
    gBall.layer.shadowOpacity = 0.8;
    gBall.layer.shadowRadius = 8;
    gBall.layer.shadowOffset = CGSizeZero;
    gBall.userInteractionEnabled = YES;

    CAShapeLayer *kb = [CAShapeLayer layer];
    UIBezierPath *kp = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(8, 13, 28, 18)
                                                 cornerRadius:3];
    kb.path = kp.CGPath;
    kb.fillColor = [UIColor clearColor].CGColor;
    kb.strokeColor = [UIColor whiteColor].CGColor;
    kb.lineWidth = 1.6;
    [gBall.layer addSublayer:kb];

    for (int r = 0; r < 2; r++) {
        for (int c = 0; c < 4; c++) {
            CAShapeLayer *d = [CAShapeLayer layer];
            d.path = [UIBezierPath bezierPathWithRect:
                CGRectMake(11.0 + c * 6.0, 16.5 + r * 5.0, 3.6, 2.6)].CGPath;
            d.fillColor = [UIColor whiteColor].CGColor;
            [gBall.layer addSublayer:d];
        }
    }
    CAShapeLayer *sp = [CAShapeLayer layer];
    sp.path = [UIBezierPath bezierPathWithRect:CGRectMake(15, 26.5, 14, 2.4)].CGPath;
    sp.fillColor = [UIColor whiteColor].CGColor;
    [gBall.layer addSublayer:sp];

    CAShapeLayer *ms = [CAShapeLayer layer];
    UIBezierPath *mp = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(31, 9, 11, 16)
                                                 cornerRadius:5.5];
    ms.path = mp.CGPath;
    ms.fillColor = [UIColor clearColor].CGColor;
    ms.strokeColor = [UIColor whiteColor].CGColor;
    ms.lineWidth = 1.6;
    [gBall.layer addSublayer:ms];
    CAShapeLayer *ml = [CAShapeLayer layer];
    ml.path = [UIBezierPath bezierPathWithRect:CGRectMake(36.2, 12, 1.4, 4)].CGPath;
    ml.fillColor = [UIColor whiteColor].CGColor;
    [gBall.layer addSublayer:ml];

    [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:gBallWindow.rootViewController action:@selector(bkPan:)]];
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:gBallWindow.rootViewController action:@selector(bkTap:)]];

    [gBallWindow.rootViewController.view addSubview:gBall];
    gBallWindow.hidden = NO;
}

#pragma mark - Estado

static void BKRelayout(void)
{
    if (!gBallWindow || !gBallWindow.windowScene) return;
    int o = BKReadOrient();
    CGRect sp = BKSpaceFor(o);
    if (sp.size.width < 1.0 || sp.size.height < 1.0) return;

    if (o != gAppliedOrient) {
        gAppliedOrient = o;
        BKLog(@"orient=%d espaco=%.0fx%.0f", o, sp.size.width, sp.size.height);
    }

    if (!CGRectEqualToRect(gBallWindow.frame, sp)) gBallWindow.frame = sp;
    if (gCursorWindow && !CGRectEqualToRect(gCursorWindow.frame, sp)) {
        gCursorWindow.frame = sp;
        BKPtrPoll();
    }
    if (gMenuWindow) {
        if (!CGRectEqualToRect(gMenuWindow.frame, sp)) gMenuWindow.frame = sp;
        BKMenuLayout();
    }
    if (gBall) {
        CGFloat side = 44.0;
        gBallPos.x = MAX(0.02, MIN(0.98, gBallPos.x));
        gBallPos.y = MAX(0.02, MIN(0.98, gBallPos.y));
        gBall.frame = CGRectMake(gBallPos.x * sp.size.width - side / 2,
                                 gBallPos.y * sp.size.height - side / 2,
                                 side, side);
        gBall.layer.cornerRadius = side / 2;
    }
    if (gEditWindow) {
        if (!CGRectEqualToRect(gEditWindow.frame, sp)) {
            gEditWindow.frame = sp;
            BKLayoutEditor();
        }
    }
}

static void BKOverlayInit(void)
{
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
    gEnabled = [cfg[@"Enabled"] boolValue];
    gFrontBundle = cfg[@"ActiveBundle"];
    BKMark(@"overlay_loaded.txt");

    BKLoadEngine();

    notify_register_dispatch("com.wjf.ballkey.close", &gCloseTok, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        if (gMenuWindow) gMenuWindow.hidden = YES;
    });

    notify_register_dispatch("com.wjf.ballkey.fps_on", &gFpsTokOn, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        gFpsNow = YES;
        BKPtrShow(NO);
    });

    notify_register_dispatch("com.wjf.ballkey.fps_off", &gFpsTokOff, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        gFpsNow = NO;
        BOOL on = [BKReadCfg()[@"CursorOn"] boolValue];
        if (on) {
            BKPtrShow(YES);
            CGSize sz = gCursorWindow.bounds.size;
            BKPtrPlace(CGPointMake(sz.width / 2, sz.height / 2));
        }
    });

    notify_register_dispatch("com.wjf.ballkey.appdir", &gDirTok, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        gBaseDir = nil;
        BKBase();
    });

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
        BKSyncApp();
        BKRefreshStatus();
        if (!gFpsNow && [BKReadCfg()[@"CursorOn"] boolValue]) {
            if (!gCursorWindow) BKPtrShow(YES);
        }
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
