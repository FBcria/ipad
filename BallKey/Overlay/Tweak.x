#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <stdarg.h>
#define kBKConfigPath @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKStatusPath @"/var/mobile/bk_status.txt"
#define kBKPtrPath @"/var/mobile/bk_ptr.txt"
#define kBKCaptureReqPath @"/var/mobile/bk_capture.txt"
#define kBKCaptureResPath @"/var/mobile/bk_capture_result.txt"
#define kBKEdgePt 30.0
static UIWindow *gBallWindow = nil, *gMenuWindow = nil, *gEditWindow = nil;
static UIView *gBall = nil, *gCanvas = nil, *gBanner = nil, *gCursorView = nil;
static NSTimer *gCursorTimer = nil;
static NSMutableArray *gMarkers = nil;
static NSString *gFrontBundle = nil;
static BOOL gEnabled = NO;
static int gCloseTok = 0, gLastOrient = 0, gAppliedOrient = 0;
static CGPoint gBallPos = {0.06, 0.85};
static CGRect BKSpace(void);
static UIWindowScene *BKMainScene(void);
static void BKLayoutEditor(void);
static NSMutableDictionary *BKReadCfg(void);
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
@property (nonatomic, strong) UIView *box;
@end
static BKMarkerView *gPending = nil;
static NSTimer *gCapTimer = nil;
static double BKClamp01(double v) { if (v < 0.02) return 0.02; if (v > 0.98) return 0.98; return v; }
static void BKMark(NSString *name)
{
    [name writeToFile:[@"/var/mobile/bk_" stringByAppendingString:name]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void BKLog(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSData *d = [[NSString stringWithFormat:@"ov %@\n", s] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/bk_debug.log"];
    if (!fh) { [d writeToFile:@"/var/mobile/bk_debug.log" atomically:YES]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; } @catch (NSException *e) { }
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
    id app = nil;
    SEL sa = @selector(_accessibilityFrontMostApplication);
    SEL sb2 = @selector(_frontMostApplication);
    if ([sb respondsToSelector:sa]) app = ((id (*)(id, SEL))objc_msgSend)(sb, sa);
    if (!app && [sb respondsToSelector:sb2]) app = ((id (*)(id, SEL))objc_msgSend)(sb, sb2);
    if (!app) return 0;
    SEL s2 = @selector(_frontMostAppOrientation);
    if ([app respondsToSelector:s2]) {
        int o = (int)((int (*)(id, SEL))objc_msgSend)(app, s2);
        if (o >= 1 && o <= 4) return o;
    }
    SEL s3 = @selector(interfaceOrientation);
    if ([app respondsToSelector:s3]) {
        int o = (int)((int (*)(id, SEL))objc_msgSend)(app, s3);
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
    if (o < 1 || o > 4) o = (gFrontBundle && ![gFrontBundle isEqualToString:@"com.apple.springboard"]) ? 3 : 1;
    gLastOrient = o;
    return o;
}
static CGRect BKPortraitBase(void)
{
    UIScreen *s = [UIScreen mainScreen];
    CGFloat scale = s.nativeScale > 0 ? s.nativeScale : s.scale;
    CGRect nb = s.nativeBounds;
    if (nb.size.width > 1.0 && nb.size.height > 1.0 && scale > 0.0) {
        CGFloat w = nb.size.width / scale, h = nb.size.height / scale;
        if (w > h) { CGFloat t = w; w = h; h = t; }
        if (w > 1.0 && h > 1.0) return CGRectMake(0, 0, w, h);
    }
    CGRect b = s.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) b = CGRectMake(0, 0, 414, 736);
    if (b.size.width > b.size.height) { CGFloat t = b.size.width; b.size.width = b.size.height; b.size.height = t; }
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
static void BKPlaceMarker(BKMarkerView *m)
{
    if (!gCanvas || !m) return;
    CGSize sz = gCanvas.bounds.size;
    if (sz.width < 1.0 || sz.height < 1.0) return;
    m.nx = BKClamp01(m.nx);
    m.ny = BKClamp01(m.ny);
    CGFloat side = 56;
    m.frame = CGRectMake(m.nx * sz.width - side / 2, m.ny * sz.height - side / 2, side, side);
    if (m.box) m.box.frame = CGRectInset(gCanvas.bounds, kBKEdgePt, kBKEdgePt);
}
static void BKRelayout(void)
{
    if (!gBallWindow || !gBallWindow.windowScene) return;
    int o = BKReadOrient();
    CGRect sp = BKSpaceFor(o);
    if (sp.size.width < 1.0 || sp.size.height < 1.0) return;
    if (o != gAppliedOrient) { gAppliedOrient = o; BKLog(@"orient=%d espaco=%.0fx%.0f", o, sp.size.width, sp.size.height); }
    if (!CGRectEqualToRect(gBallWindow.frame, sp)) gBallWindow.frame = sp;
    if (gMenuWindow) {
        if (!CGRectEqualToRect(gMenuWindow.frame, sp)) gMenuWindow.frame = sp;
        UIView *box = [gMenuWindow.rootViewController.view viewWithTag:77];
        if (box) box.center = CGPointMake(sp.size.width / 2, sp.size.height / 2);
    }
    if (gBall) {
        CGFloat side = 44.0;
        gBallPos.x = MAX(0.02, MIN(0.98, gBallPos.x));
        gBallPos.y = MAX(0.02, MIN(0.98, gBallPos.y));
        gBall.frame = CGRectMake(gBallPos.x * sp.size.width - side / 2, gBallPos.y * sp.size.height - side / 2, side, side);
        gBall.layer.cornerRadius = side / 2;
    }
    if (gEditWindow) {
        if (!CGRectEqualToRect(gEditWindow.frame, sp)) gEditWindow.frame = sp;
        BKLayoutEditor();
    }
}
static void BKPost(const char *name) { notify_post(name); }
static NSMutableDictionary *BKReadCfg(void)
{
    return [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath] ?: [NSMutableDictionary dictionary];
}
static void BKWriteCfg(NSMutableDictionary *cfg)
{
    [cfg writeToFile:kBKConfigPath atomically:YES];
    BKPost("com.wjf.ballkey.reload");
}
static BOOL BKGetDump(void) { NSNumber *n = BKReadCfg()[@"Dump"]; return n ? [n boolValue] : NO; }
static BOOL BKGetCursor(void) { NSNumber *n = BKReadCfg()[@"Cursor"]; return n ? [n boolValue] : NO; }
static NSString *BKStatusText(void)
{
    NSString *s = [NSString stringWithContentsOfFile:kBKStatusPath encoding:NSUTF8StringEncoding error:nil];
    return s.length ? s : @"ativo=? marcadores=? app=?";
}
static void BKCursorTick(void)
{
    if (!gCursorView) return;
    if (!BKGetCursor()) { gCursorView.hidden = YES; return; }
    NSString *s = [NSString stringWithContentsOfFile:kBKPtrPath encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) { gCursorView.hidden = YES; return; }
    NSArray *p = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                  componentsSeparatedByString:@" "];
    if (p.count < 3) { gCursorView.hidden = YES; return; }
    double x = [p[0] doubleValue], y = [p[1] doubleValue];
    BOOL fps = [p[2] intValue] != 0;
    CGSize sz = gCursorView.superview.bounds.size;
    if (sz.width < 1.0 || sz.height < 1.0) return;
    gCursorView.center = CGPointMake(x * sz.width, y * sz.height);
    gCursorView.hidden = fps;
}
static void BKCursorSetup(void)
{
    if (gCursorView || !gBallWindow) return;
    gCursorView = [[UIView alloc] initWithFrame:CGRectMake(-100, -100, 22, 22)];
    gCursorView.userInteractionEnabled = NO;
    gCursorView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    gCursorView.layer.cornerRadius = 11;
    gCursorView.layer.borderWidth = 1.5;
    gCursorView.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
    gCursorView.layer.shadowColor = [UIColor blackColor].CGColor;
    gCursorView.layer.shadowOpacity = 0.3;
    gCursorView.layer.shadowRadius = 3;
    gCursorView.layer.shadowOffset = CGSizeMake(0, 1);
    gCursorView.hidden = YES;
    [gBallWindow.rootViewController.view addSubview:gCursorView];
    if (!gCursorTimer) {
        gCursorTimer = [NSTimer scheduledTimerWithTimeInterval:0.04 repeats:YES block:^(NSTimer *t) {
            (void)t;
            BKCursorTick();
        }];
    }
}
static NSString *BKNewNonce(void) { return [[NSUUID UUID] UUIDString]; }
static void BKStopCapture(void)
{
    [gCapTimer invalidate];
    gCapTimer = nil;
    gPending = nil;
    if (gBanner) gBanner.hidden = YES;
    [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureReqPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureResPath error:nil];
}
static void BKArmCapture(BKMarkerView *m)
{
    if (!m || gPending != m) return;
    NSString *nonce = BKNewNonce();
    [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureResPath error:nil];
    [nonce writeToFile:kBKCaptureReqPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    notify_post("com.wjf.ballkey.capture");
    __block int ticks = 0;
    gCapTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        @try {
            BKMarkerView *mm = gPending;
            if (!mm) { [t invalidate]; gCapTimer = nil; return; }
            if (++ticks > 400) {
                BKLog(@"cap timeout");
                mm.label.text = [NSString stringWithFormat:@"%@\nsem resp",
                                 [mm.label.text componentsSeparatedByString:@"\n"].firstObject];
                BKStopCapture();
                return;
            }
            NSString *r = [NSString stringWithContentsOfFile:kBKCaptureResPath encoding:NSUTF8StringEncoding error:nil];
            if (r.length) r = [r stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!r.length) return;
            NSArray *parts = [r componentsSeparatedByString:@" "];
            if (parts.count < 2) return;
            if (![parts[0] isEqualToString:nonce]) return;
            NSString *key = parts[1];
            if (!key.length) return;
            gPending = nil;
            [t invalidate];
            gCapTimer = nil;
            mm.keyEnc = key;
            mm.label.text = [NSString stringWithFormat:@"%@\n%@",
                             [mm.label.text componentsSeparatedByString:@"\n"].firstObject, key];
            if (gBanner) gBanner.hidden = YES;
            [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureReqPath error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureResPath error:nil];
            BKLog(@"cap ok %@", key);
        } @catch (NSException *e) { BKLog(@"cap erro: %@", e.reason); }
    }];
}
static void BKStartCapture(BKMarkerView *m)
{
    if (!m) return;
    [gCapTimer invalidate];
    gCapTimer = nil;
    gPending = m;
    if (gBanner) gBanner.hidden = NO;
    __block BKMarkerView *alvo = m;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(450 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ BKArmCapture(alvo); });
}
@implementation BKMarkerView
- (void)bkPan:(UIPanGestureRecognizer *)g
{
    if (!gCanvas) return;
    CGPoint t = [g translationInView:gCanvas];
    CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    CGSize sz = gCanvas.bounds.size;
    c.x = MAX(20, MIN(sz.width - 20, c.x));
    c.y = MAX(20, MIN(sz.height - 20, c.y));
    self.center = c;
    self.nx = c.x / sz.width;
    self.ny = c.y / sz.height;
    [g setTranslation:CGPointZero inView:gCanvas];
}
- (void)bkTap:(UITapGestureRecognizer *)g
{
    (void)g;
    @try {
        if ([self.type isEqualToString:@"Fogo"] || [self.type isEqualToString:@"Mirar"]) return;
        if (gPending == self) return;
        BKStartCapture(self);
    } @catch (NSException *e) { BKLog(@"tap erro: %@", e.reason); }
}
- (void)bkLong:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (gPending == self) BKStopCapture();
    [self.box removeFromSuperview];
    [gMarkers removeObject:self];
    [self removeFromSuperview];
}
@end
static NSString *BKTypeName(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return @"Toque";
    if ([t isEqualToString:@"Press"]) return @"Pressionar";
    if ([t isEqualToString:@"Hold"]) return @"Segurar";
    if ([t isEqualToString:@"Dir"]) return @"Direção";
    if ([t isEqualToString:@"Fps"]) return @"Trava FPS";
    if ([t isEqualToString:@"Fogo"]) return @"Atirar";
    if ([t isEqualToString:@"Mirar"]) return @"Mirar";
    return t;
}
static UIColor *BKTypeColor(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return [UIColor systemBlueColor];
    if ([t isEqualToString:@"Press"]) return [UIColor systemGreenColor];
    if ([t isEqualToString:@"Hold"]) return [UIColor systemOrangeColor];
    if ([t isEqualToString:@"Dir"]) return [UIColor systemPurpleColor];
    if ([t isEqualToString:@"Fps"]) return [UIColor systemIndigoColor];
    if ([t isEqualToString:@"Fogo"]) return [UIColor systemRedColor];
    if ([t isEqualToString:@"Mirar"]) return [UIColor systemTealColor];
    return [UIColor systemRedColor];
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
    if (!enc) {
        if ([type isEqualToString:@"Fogo"]) enc = @"m:0";
        else if ([type isEqualToString:@"Mirar"]) enc = @"m:1";
    }
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
    l.text = [NSString stringWithFormat:@"%@\n%@", BKTypeName(type), enc ?: @"…"];
    [m addSubview:l];
    m.label = l;
    if ([type isEqualToString:@"Fps"]) {
        UIView *bx = [[UIView alloc] initWithFrame:CGRectZero];
        bx.userInteractionEnabled = NO;
        bx.backgroundColor = [UIColor clearColor];
        bx.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        bx.layer.borderWidth = 1.5;
        bx.layer.cornerRadius = 6;
        [gCanvas insertSubview:bx atIndex:0];
        m.box = bx;
    }
    [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:m action:@selector(bkPan:)]];
    [m addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:m action:@selector(bkTap:)]];
    [m addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:m action:@selector(bkLong:)]];
    return m;
}
static void BKLayoutEditor(void)
{
    if (!gEditWindow || !gCanvas) return;
    CGRect b = gEditWindow.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) return;
    UIView *root = gEditWindow.rootViewController.view;
    root.frame = b;
    gCanvas.frame = b;
    UIView *bar = [root viewWithTag:88];
    if (bar) {
        bar.frame = CGRectMake(0, 0, b.size.width, 92);
        CGFloat gap = 6, x = 8;
        CGFloat bw = (b.size.width - 16 - gap * 4) / 5.0;
        if (bw < 40) bw = 40;
        for (int i = 0; i < 5; i++) {
            UIView *v = [bar viewWithTag:200 + i];
            v.frame = CGRectMake(x, 6, bw, 32);
            x += bw + gap;
        }
        CGFloat x2 = 8;
        for (int i = 5; i < 7; i++) {
            UIView *v = [bar viewWithTag:200 + i];
            v.frame = CGRectMake(x2, 44, bw, 32);
            x2 += bw + gap;
        }
        UIView *sv = [bar viewWithTag:210];
        sv.frame = CGRectMake(b.size.width - 158, 44, 70, 32);
        UIView *ex = [bar viewWithTag:211];
        ex.frame = CGRectMake(b.size.width - 82, 44, 74, 32);
    }
    if (gBanner) gBanner.frame = CGRectMake(b.size.width / 2 - 155, b.size.height - 54, 310, 34);
    for (BKMarkerView *m in gMarkers) BKPlaceMarker(m);
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
            cfg[@"FpsKey"] = d[@"Key"];
            [pts addObject:d];
            continue;
        }
        if ([m.type isEqualToString:@"Fogo"]) {
            d[@"Key"] = @"m:0";
            cfg[@"FireX"] = d[@"X"];
            cfg[@"FireY"] = d[@"Y"];
            [pts addObject:d];
            continue;
        }
        if ([m.type isEqualToString:@"Mirar"]) {
            d[@"Key"] = @"m:1";
            cfg[@"AdsX"] = d[@"X"];
            cfg[@"AdsY"] = d[@"Y"];
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
        } else {
            d[@"Key"] = m.keyEnc ?: @"";
            if ([m.type isEqualToString:@"Hold"]) d[@"HoldMs"] = @(400);
        }
        [pts addObject:d];
    }
    NSString *bundle = gFrontBundle ?: cfg[@"ActiveBundle"];
    if (![bundle isKindOfClass:[NSString class]] || !bundle.length) { BKLog(@"save: bundle ausente"); return; }
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
static void BKOpenEditor(void)
{
    if (gEditWindow) return;
    gEditWindow = BKMakeWindow(UIWindowLevelAlert + 1005, NO);
    if (!gEditWindow) { BKLog(@"editor: sem scene"); return; }
    gMarkers = [NSMutableArray array];
    UIView *root = gEditWindow.rootViewController.view;
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];
    gCanvas = [[UIView alloc] initWithFrame:root.bounds];
    gCanvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:gCanvas];
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.tag = 88;
    bar.backgroundColor = [UIColor clearColor];
    [root addSubview:bar];
    NSArray *row1 = @[@[@"+ Toque", @"Tap"], @[@"+ Pressionar", @"Press"],
                      @[@"+ Segurar", @"Hold"], @[@"+ Direção", @"Dir"], @[@"+ Trava", @"Fps"],
                      @[@"+ Atirar", @"Fogo"], @[@"+ Mirar", @"Mirar"]];
    for (NSUInteger i = 0; i < row1.count; i++) {
        NSArray *pair = row1[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:pair[0] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.backgroundColor = [BKTypeColor(pair[1]) colorWithAlphaComponent:0.85];
        b.layer.cornerRadius = 8;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        [b addTarget:gEditWindow.rootViewController action:@selector(bkAdd:) forControlEvents:UIControlEventTouchUpInside];
        b.tag = 200 + (NSInteger)i;
        [bar addSubview:b];
    }
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"Salvar" forState:UIControlStateNormal];
    [save setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    save.backgroundColor = [UIColor systemGreenColor];
    save.layer.cornerRadius = 8;
    save.tag = 210;
    [save addTarget:gEditWindow.rootViewController action:@selector(bkSave:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:save];
    UIButton *sair = [UIButton buttonWithType:UIButtonTypeSystem];
    [sair setTitle:@"Sair" forState:UIControlStateNormal];
    [sair setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    sair.backgroundColor = [UIColor systemGrayColor];
    sair.layer.cornerRadius = 8;
    sair.tag = 211;
    [sair addTarget:gEditWindow.rootViewController action:@selector(bkClose:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:sair];
    gBanner = [[UIView alloc] initWithFrame:CGRectZero];
    gBanner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    gBanner.layer.cornerRadius = 8;
    gBanner.hidden = YES;
    UILabel *bl = [[UILabel alloc] initWithFrame:CGRectZero];
    bl.tag = 1;
    bl.textAlignment = NSTextAlignmentCenter;
    bl.textColor = UIColor.whiteColor;
    bl.font = [UIFont systemFontOfSize:12];
    bl.text = @"Aperte a tecla ou o botão do mouse…";
    bl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gBanner addSubview:bl];
    [root addSubview:gBanner];
    NSString *bundle = gFrontBundle ?: BKReadCfg()[@"ActiveBundle"];
    NSArray *pts = BKReadCfg()[@"Profiles"][bundle ?: @""];
    if ([pts isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in pts) {
            BKMarkerView *m = BKMakeMarker(d[@"Type"] ?: @"Tap", [d[@"X"] doubleValue], [d[@"Y"] doubleValue], d[@"Key"]);
            if (d[@"Radius"]) m.radius = [d[@"Radius"] doubleValue];
            [gCanvas addSubview:m];
            [gMarkers addObject:m];
        }
    }
    [gEditWindow setHidden:NO];
    BKLayoutEditor();
}
static void BKLimpar(BOOL tudo)
{
    NSMutableDictionary *cfg = BKReadCfg();
    NSString *bundle = gFrontBundle ?: cfg[@"ActiveBundle"];
    if (![bundle isKindOfClass:[NSString class]] || !bundle.length) { BKLog(@"limpar: bundle ausente"); return; }
    NSMutableDictionary *profiles = [cfg[@"Profiles"] isKindOfClass:[NSDictionary class]]
        ? [cfg[@"Profiles"] mutableCopy] : [NSMutableDictionary dictionary];
    NSArray *pts = profiles[bundle];
    if (![pts isKindOfClass:[NSArray class]]) { BKLog(@"limpar: perfil vazio"); return; }
    if (tudo) { profiles[bundle] = @[]; BKLog(@"limpar: tudo"); }
    else {
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
static double BKGetSens(void) { NSNumber *n = BKReadCfg()[@"FpsSens"]; return n ? [n doubleValue] : 1.0; }
static void BKToggleMenu(void)
{
    if (gMenuWindow && !gMenuWindow.hidden) { gMenuWindow.hidden = YES; return; }
    if (!gMenuWindow) {
        gMenuWindow = BKMakeWindow(UIWindowLevelAlert + 1001, YES);
        if (!gMenuWindow) { BKLog(@"menu: sem scene"); return; }
    }
    gMenuWindow.frame = BKSpace();
    UIView *root = gMenuWindow.rootViewController.view;
    [[root viewWithTag:77] removeFromSuperview];
    const CGFloat boxW = 210.0, boxH = 422.0, pad = 12.0, rowH = 30.0, rowPitch = 34.0, topY = 26.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, boxW, boxH)];
    box.tag = 77;
    box.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    box.layer.cornerRadius = 18;
    box.layer.masksToBounds = YES;
    box.layer.borderWidth = 1.0;
    box.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    box.center = CGPointMake(gMenuWindow.bounds.size.width / 2, gMenuWindow.bounds.size.height / 2);
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.frame = box.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [box addSubview:blur];
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(pad, 6, boxW - pad * 2, 16)];
    st.font = [UIFont monospacedSystemFontOfSize:8.5 weight:UIFontWeightRegular];
    st.textColor = [UIColor systemYellowColor];
    st.textAlignment = NSTextAlignmentCenter;
    st.text = BKStatusText();
    [box addSubview:st];
    BOOL dump = BKGetDump();
    BOOL cur = BKGetCursor();
    NSArray *titles = @[@"Editar teclas",
                        [NSString stringWithFormat:@"Sensi FPS %.2f  (-)", BKGetSens()],
                        @"Sensi FPS  (+)",
                        gEnabled ? @"Desativar" : @"Ativar",
                        @"Testar centro",
                        cur ? @"Cursor: LIGADO" : @"Ativar cursor",
                        dump ? @"Dump: LIGADO" : @"Dump: desligado",
                        @"Reler config",
                        @"Limpar direção",
                        @"Limpar tudo",
                        @"Fechar"];
    NSArray *cols = @[ [UIColor systemBlueColor], [UIColor systemPurpleColor], [UIColor systemPurpleColor],
                       gEnabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor],
                       [UIColor systemTealColor],
                       cur ? [UIColor systemGreenColor] : [UIColor systemGrayColor],
                       dump ? [UIColor systemOrangeColor] : [UIColor systemGrayColor],
                       [UIColor systemGrayColor], [UIColor systemPinkColor], [UIColor systemPinkColor],
                       [UIColor systemGrayColor] ];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        CGFloat y = topY + (CGFloat)i * rowPitch + (i == 10 ? 8.0 : 0.0);
        b.frame = CGRectMake(pad, y, boxW - pad * 2, rowH);
        UIColor *col = cols[i];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = [col colorWithAlphaComponent:0.45];
        b.layer.cornerRadius = rowH / 2.0;
        b.layer.masksToBounds = YES;
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [col colorWithAlphaComponent:0.9].CGColor;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.titleLabel.minimumScaleFactor = 0.8;
        b.tag = 100 + (NSInteger)i;
        [b addTarget:gMenuWindow.rootViewController action:@selector(bkMenuTap:) forControlEvents:UIControlEventTouchUpInside];
        [box addSubview:b];
    }
    box.transform = CGAffineTransformMakeScale(0.94, 0.94);
    box.alpha = 0.0;
    [root addSubview:box];
    gMenuWindow.hidden = NO;
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        box.transform = CGAffineTransformIdentity;
        box.alpha = 1.0;
    } completion:nil];
}
@interface UIViewController (BKUI)
- (void)bkAdd:(UIButton *)b;
- (void)bkSave:(UIButton *)b;
- (void)bkClose:(UIButton *)b;
- (void)bkMenuTap:(UIButton *)b;
- (void)bkPan:(UIPanGestureRecognizer *)g;
- (void)bkTap:(UITapGestureRecognizer *)g;
@end
@implementation UIViewController (BKUI)
- (void)bkAdd:(UIButton *)b
{
    @try {
        NSArray *types = @[@"Tap", @"Press", @"Hold", @"Dir", @"Fps", @"Fogo", @"Mirar"];
        NSInteger i = b.tag - 200;
        if (i < 0 || i >= (NSInteger)types.count) return;
        NSString *t = types[i];
        BOOL cap = !([t isEqualToString:@"Fogo"] || [t isEqualToString:@"Mirar"]);
        BKAddMarker(t, cap);
    } @catch (NSException *e) { BKLog(@"add erro: %@", e.reason); }
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            BKPost("com.wjf.ballkey.test");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!gMenuWindow || gMenuWindow.hidden) BKToggleMenu();
        });
        return;
    }
    if (i == 10) { gMenuWindow.hidden = YES; return; }
    if (i == 5) {
        NSMutableDictionary *cfg = BKReadCfg();
        BOOL on = ![cfg[@"Cursor"] boolValue];
        cfg[@"Cursor"] = @(on);
        BKWriteCfg(cfg);
        BKLog(@"cursor=%d", (int)on);
    } else if (i == 6) {
        NSMutableDictionary *cfg = BKReadCfg();
        BOOL on = ![cfg[@"Dump"] boolValue];
        cfg[@"Dump"] = @(on);
        BKWriteCfg(cfg);
        BKLog(@"dump=%d", (int)on);
    } else if (i == 7) BKPost("com.wjf.ballkey.reload");
    else if (i == 1) BKSetSens(BKGetSens() - 0.05);
    else if (i == 2) BKSetSens(BKGetSens() + 0.05);
    else if (i == 3) BKSetEnabled(!gEnabled);
    else if (i == 8) BKLimpar(NO);
    else if (i == 9) BKLimpar(YES);
    dispatch_async(dispatch_get_main_queue(), ^{ BKToggleMenu(); BKToggleMenu(); });
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
- (void)bkTap:(UITapGestureRecognizer *)g { (void)g; BKToggleMenu(); }
@end
static UIView *BKMakeInputGlyph(CGFloat s)
{
    UIView *g = [[UIView alloc] initWithFrame:CGRectMake(0, 0, s, s)];
    g.userInteractionEnabled = NO;
    g.backgroundColor = [UIColor clearColor];
    g.layer.masksToBounds = YES;
    g.layer.cornerRadius = s / 2.0;
    UIColor *ink = [UIColor colorWithWhite:0.07 alpha:1.0];
    CGFloat kbW = s * 0.66, kbH = s * 0.25, kbX = (s - kbW) / 2.0, kbY = s * 0.185;
    CALayer *kb = [CALayer layer];
    kb.frame = CGRectMake(kbX, kbY, kbW, kbH);
    kb.backgroundColor = ink.CGColor;
    kb.cornerRadius = s * 0.055;
    [g.layer addSublayer:kb];
    for (int row = 0; row < 2; row++) {
        int n = (row == 0) ? 4 : 3;
        CGFloat dy = kbY + kbH * (row == 0 ? 0.33 : 0.67);
        for (int i = 0; i < n; i++) {
            CGFloat dr = s * 0.024;
            CGFloat dx = s * 0.5 + ((CGFloat)i - (n - 1) / 2.0) * s * 0.125;
            CALayer *dot = [CALayer layer];
            dot.frame = CGRectMake(dx - dr, dy - dr, dr * 2, dr * 2);
            dot.backgroundColor = [UIColor whiteColor].CGColor;
            dot.cornerRadius = dr;
            [g.layer addSublayer:dot];
        }
    }
    CGFloat mW = s * 0.26, mH = s * 0.33, mX = (s - mW) / 2.0, mY = s * 0.515;
    CALayer *mouse = [CALayer layer];
    mouse.frame = CGRectMake(mX, mY, mW, mH);
    mouse.backgroundColor = ink.CGColor;
    mouse.cornerRadius = mW / 2.0;
    [g.layer addSublayer:mouse];
    CGFloat wW = s * 0.042, wH = s * 0.085;
    CALayer *wheel = [CALayer layer];
    wheel.frame = CGRectMake(s * 0.5 - wW / 2.0, mY + s * 0.055, wW, wH);
    wheel.backgroundColor = [UIColor whiteColor].CGColor;
    wheel.cornerRadius = wW / 2.0;
    [g.layer addSublayer:wheel];
    return g;
}
static void BKSetupBall(void)
{
    if (gBallWindow) return;
    gBallWindow = BKMakeWindow(UIWindowLevelAlert + 1000, YES);
    if (!gBallWindow) { BKLog(@"ball: sem scene, retry"); return; }
    gBall = [[UIView alloc] initWithFrame:CGRectZero];
    gBall.backgroundColor = [UIColor whiteColor];
    gBall.layer.borderWidth = 1.5;
    gBall.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.18].CGColor;
    gBall.layer.shadowColor = [UIColor blackColor].CGColor;
    gBall.layer.shadowOpacity = 0.22;
    gBall.layer.shadowRadius = 6;
    gBall.layer.shadowOffset = CGSizeMake(0, 2);
    gBall.userInteractionEnabled = YES;
    UIView *glyph = BKMakeInputGlyph(44.0);
    glyph.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gBall addSubview:glyph];
    [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:gBallWindow.rootViewController action:@selector(bkPan:)]];
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:gBallWindow.rootViewController action:@selector(bkTap:)]];
    [gBallWindow.rootViewController.view addSubview:gBall];
    BKRelayout();
    gBallWindow.hidden = NO;
    BKCursorSetup();
    BKMark(@"ball_shown.txt");
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
    NSMutableDictionary *cfg = BKReadCfg();
    cfg[@"ActiveBundle"] = bid;
    BKWriteCfg(cfg);
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
                       dispatch_get_main_queue(), ^{ BKOverlayInit(); });
    }
}
