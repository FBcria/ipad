#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <stdarg.h>

#define kBKConfigPath @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKStatusPath @"/var/mobile/bk_status.txt"
#define kBKPtrPath    @"/var/mobile/bk_ptr.txt"
#define kBKCaptureReqPath @"/var/mobile/bk_capture.txt"
#define kBKCaptureResPath @"/var/mobile/bk_capture_result.txt"

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
static BOOL gEnabled = NO;
static int gCloseTok = 0;
static int gFpsTokOn = 0;
static int gFpsTokOff = 0;
static CGPoint gBallPos = {0.06, 0.85};

static int gLastOrient = 0;
static int gAppliedOrient = 0;
static BOOL gFpsNow = NO;

static CGRect BKSpace(void);
static UIWindowScene *BKMainScene(void);
static void BKLayoutEditor(void);
static NSMutableDictionary *BKReadCfg(void);
static void BKToggleMenu(void);
static void BKSetEnabled(BOOL on);
static void BKSetSens(double v);
static double BKGetSens(void);
static void BKLimpar(BOOL tudo);
static void BKStopCapture(void);

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
    if (!fh) { [d writeToFile:@"/var/mobile/bk_debug.log" atomically:NO]; return; }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (NSException *e) { }
}

static void BKPost(const char *n) { notify_post(n); }

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
    return [[NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath]
        ?: [NSMutableDictionary dictionary] mutableCopy];
}

static void BKWriteCfg(NSMutableDictionary *cfg)
{
    [cfg writeToFile:kBKConfigPath atomically:YES];
    BKPost("com.wjf.ballkey.reload");
}

static BOOL BKGetDump(void)
{
    NSNumber *n = BKReadCfg()[@"Dump"];
    return n ? [n boolValue] : NO;
}

static BOOL BKFile(NSString *n)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:
        [@"/var/mobile/" stringByAppendingString:n]];
}

static NSString *BKStatusText(void)
{
    NSString *st = [NSString stringWithContentsOfFile:kBKStatusPath
                                            encoding:NSUTF8StringEncoding error:nil];
    st = [st stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *motor = BKFile(@"bk_engine_ready.txt") ? @"mot:ok" : @"mot:NAO";
    return [NSString stringWithFormat:@"%@ %@", motor, st.length ? st : @"-"];
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
    if (o < 1 || o > 4) o = BKFrontMostOrientation();
    if (o < 1 || o > 4) o = gLastOrient;
    if (o < 1 || o > 4) o = BKDeviceOrientation();
    if (o < 1 || o > 4) {
        o = (gFrontBundle && ![gFrontBundle isEqualToString:@"com.apple.springboard"]) ? 3 : 1;
    }
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

// Converte coordenada nativa (retrato) para o espaco da orientacao atual.
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
    NSString *s = [NSString stringWithContentsOfFile:kBKPtrPath
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
    if ([t isEqualToString:@"Tap"]) return [UIColor systemBlueColor];
    if ([t isEqualToString:@"Press"]) return [UIColor systemGreenColor];
    if ([t isEqualToString:@"Hold"]) return [UIColor systemOrangeColor];
    if ([t isEqualToString:@"Dir"]) return [UIColor systemPurpleColor];
    return [UIColor systemRedColor];
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
    [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureReqPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureResPath error:nil];
}

static void BKStartCapture(BKMarkerView *m)
{
    if (!m) return;
    [gCapTimer invalidate];
    gCapTimer = nil;
    gPending = m;
    if (gBanner) gBanner.hidden = NO;

    [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureResPath error:nil];

    NSString *nonce = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970] * 1000.0];
    [nonce writeToFile:kBKCaptureReqPath atomically:YES
              encoding:NSUTF8StringEncoding error:nil];
    BKPost("com.wjf.ballkey.capture");

    gCapTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer *t) {
        @try {
            if (!gPending) { [t invalidate]; return; }
            NSString *r = [NSString stringWithContentsOfFile:kBKCaptureResPath
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
            if (![[NSFileManager defaultManager] fileExistsAtPath:kBKCaptureReqPath]) {
                [nonce writeToFile:kBKCaptureReqPath atomically:YES
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
    m.backgroundColor = [col colorWithAlphaComponent:0.45];
    m.layer.cornerRadius = side / 2;
    m.layer.borderColor = col.CGColor;
    m.layer.borderWidth = 2;
    m.type = type;
    m.keyEnc = enc;
    m.nx = BKClamp01(nx);
    m.ny = BKClamp01(ny);
    m.radius = 0.09;

    UILabel *l = [[UILabel alloc] initWithFrame:m.bounds];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont boldSystemFontOfSize:10];
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

// Se o app não é detectável (SpringBoard), usa o perfil coringa.
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
        CGFloat gap = 6;
        CGFloat x = 8;
        CGFloat bw = (b.size.width - 16 - gap * 4) / 5.0;
        if (bw < 40) bw = 40;
        for (int i = 0; i < 5; i++) {
            UIView *v = [bar viewWithTag:200 + i];
            v.frame = CGRectMake(x, 8, bw, 34);
            x += bw + gap;
        }
        UIView *sv = [bar viewWithTag:210];
        sv.frame = CGRectMake(b.size.width - 158, 50, 70, 34);
        UIView *ex = [bar viewWithTag:211];
        ex.frame = CGRectMake(b.size.width - 82, 50, 74, 34);
    }
    if (gBanner) gBanner.frame = CGRectMake(b.size.width / 2 - 155, b.size.height - 54, 310, 34);
    for (BKMarkerView *m in gMarkers) BKPlaceMarker(m);
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
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];

    gCanvas = [[UIView alloc] initWithFrame:root.bounds];
    gCanvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:gCanvas];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.tag = 88;
    bar.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    [root addSubview:bar];

    NSArray *row1 = @[@[@"+ Toque", @"Tap"], @[@"+ Pressionar", @"Press"],
                      @[@"+ Segurar", @"Hold"], @[@"+ Direção", @"Dir"], @[@"+ Trava", @"Fps"]];
    for (NSUInteger i = 0; i < row1.count; i++) {
        NSArray *pair = row1[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = 200 + (NSInteger)i;
        [b setTitle:pair[0] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.backgroundColor = [BKTypeColor(pair[1]) colorWithAlphaComponent:0.30];
        b.layer.cornerRadius = 8;
        b.layer.borderWidth = 1;
        b.layer.borderColor = BKTypeColor(pair[1]).CGColor;
        [b addTarget:gEditWindow.rootViewController
              action:@selector(bkAdd:)
    forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
    }

    UIButton *sv = [UIButton buttonWithType:UIButtonTypeSystem];
    sv.tag = 210;
    [sv setTitle:@"Salvar" forState:UIControlStateNormal];
    sv.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    sv.backgroundColor = [UIColor systemGreenColor];
    sv.layer.cornerRadius = 8;
    [sv addTarget:gEditWindow.rootViewController
          action:@selector(bkSave:)
forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:sv];

    UIButton *ex = [UIButton buttonWithType:UIButtonTypeSystem];
    ex.tag = 211;
    [ex setTitle:@"Fechar" forState:UIControlStateNormal];
    ex.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    ex.backgroundColor = [UIColor systemRedColor];
    ex.layer.cornerRadius = 8;
    [ex addTarget:gEditWindow.rootViewController
          action:@selector(bkClose:)
forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:ex];

    gBanner = [[UILabel alloc] initWithFrame:CGRectZero];
    gBanner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    gBanner.textColor = UIColor.whiteColor;
    gBanner.font = [UIFont boldSystemFontOfSize:11];
    gBanner.textAlignment = NSTextAlignmentCenter;
    gBanner.layer.cornerRadius = 8;
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

static UIButton *BKMenuButton(UIView *box, NSString *title, NSInteger idx, UIColor *col)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [col colorWithAlphaComponent:0.22];
    b.layer.cornerRadius = 7;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [col colorWithAlphaComponent:0.75].CGColor;
    b.tag = 100 + idx;
    [b addTarget:gMenuWindow.rootViewController
          action:@selector(bkMenuTap:)
forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:b];
    return b;
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
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    box.tag = 77;
    box.frame = CGRectMake(0, 0, 200, 372);
    box.layer.cornerRadius = 14;
    box.clipsToBounds = YES;
    box.center = CGPointMake(gMenuWindow.bounds.size.width / 2,
                             gMenuWindow.bounds.size.height / 2);

    UIView *host = box.contentView;

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, 180, 34)];
    st.font = [UIFont monospacedSystemFontOfSize:8 weight:UIFontWeightRegular];
    st.textColor = [UIColor systemYellowColor];
    st.numberOfLines = 3;
    st.text = BKStatusText();
    [host addSubview:st];

    NSArray *titles = @[@"Editor", @"Sens -", @"Sens +", @"Ligar/Desligar", @"Testar",
                        @"Dump", @"Recarregar", @"Limpar teclas", @"Limpar tudo",
                        @"Cursor", @"Fechar"];
    NSArray *cols = @[[UIColor systemTealColor], [UIColor systemBlueColor],
                      [UIColor systemBlueColor], [UIColor systemGreenColor],
                      [UIColor systemPurpleColor], [UIColor systemGrayColor],
                      [UIColor systemGrayColor], [UIColor systemOrangeColor],
                      [UIColor systemRedColor], [UIColor systemIndigoColor],
                      [UIColor systemRedColor]];

    CGFloat y = 42;
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSString *t = titles[i];
        UIColor *c = cols[i];
        if (i == 3) t = gEnabled ? @"Desligar" : @"Ligar";
        if (i == 5 && BKGetDump()) t = @"Dump: ON";
        if (i == 9) t = [BKReadCfg()[@"CursorOn"] boolValue] ? @"Cursor: ON" : @"Cursor: OFF";
        if (i == 1) t = [NSString stringWithFormat:@"Sens -  (%.2f)", BKGetSens()];
        if (i == 2) t = [NSString stringWithFormat:@"Sens +  (%.2f)", BKGetSens()];
        UIButton *b = BKMenuButton(host, t, i, c);
        b.frame = CGRectMake(10, y, 180, 26);
        y += 30;
    }

    [root addSubview:box];
    gMenuWindow.hidden = NO;
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
    gBall.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:0.62];
    gBall.layer.cornerRadius = 22;
    gBall.layer.borderWidth = 1.5;
    gBall.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
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

static void BKPollFrontmost(void)
{
    Class sbCls = objc_getClass("SpringBoard");
    if (!sbCls) return;
    id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
    if (!sb) return;

    id app = nil;
    SEL s1 = @selector(_accessibilityFrontMostApplication);
    SEL s2 = @selector(_frontMostApplication);
    if ([sb respondsToSelector:s1]) app = ((id (*)(id, SEL))objc_msgSend)(sb, s1);
    if (!app && [sb respondsToSelector:s2]) app = ((id (*)(id, SEL))objc_msgSend)(sb, s2);

    if (!app) {
        Class lsw = objc_getClass("LSApplicationWorkspace");
        if (lsw) {
            id ws = ((id (*)(id, SEL))objc_msgSend)(lsw, @selector(defaultWorkspace));
            SEL s3 = @selector(frontmostApplication);
            if (ws && [ws respondsToSelector:s3]) app = ((id (*)(id, SEL))objc_msgSend)(ws, s3);
        }
    }
    if (!app) {
        Class ctrl = objc_getClass("SBApplicationController");
        if (ctrl) {
            id c = ((id (*)(id, SEL))objc_msgSend)(ctrl, @selector(sharedInstance));
            SEL s4 = @selector(allApplications);
            if (c && [c respondsToSelector:s4]) {
                NSArray *all = ((id (*)(id, SEL))objc_msgSend)(c, s4);
                for (id a in all) {
                    SEL s5 = @selector(isFrontmost);
                    if ([a respondsToSelector:s5]
                        && ((BOOL (*)(id, SEL))objc_msgSend)(a, s5)) { app = a; break; }
                }
            }
        }
    }
    if (!app) return;

    NSString *bid = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
    if (![bid isKindOfClass:[NSString class]] || !bid.length) return;
    if ([bid isEqualToString:gFrontBundle]) return;
    if ([bid isEqualToString:@"com.apple.springboard"]) return;
    gFrontBundle = bid;

    NSMutableDictionary *cfg = BKReadCfg();
    cfg[@"ActiveBundle"] = bid;
    BKWriteCfg(cfg);
    BKLog(@"app=%@", bid);
}

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
        UIView *box = [gMenuWindow.rootViewController.view viewWithTag:77];
        if (box) box.center = CGPointMake(sp.size.width / 2, sp.size.height / 2);
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
