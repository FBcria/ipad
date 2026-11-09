#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <mach/mach_time.h>

#define kBKConfigPath @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKStatusPath @"/var/mobile/bk_status.txt"

static UIWindow *gBallWindow = nil;
static UIWindow *gMenuWindow = nil;
static UIWindow *gEditWindow = nil;
static UIView *gBall = nil;
static UIView *gCanvas = nil;
static UIView *gBanner = nil;
static NSMutableArray *gMarkers = nil;
static NSString *gFrontBundle = nil;
static BOOL gEnabled = NO;
static int gOrientOverride = 0;
static CGPoint gBallPos = {0.06, 0.85};

static void *gIOKit = NULL;
static void *gCapClient = NULL;
static int gCapSeen = 0;
static struct {
    void *(*Create)(CFAllocatorRef);
    void *(*CreateWithType)(CFAllocatorRef, int, void *);
    void (*RegisterCB)(void *, void *, void *, void *);
    void (*SetQueue)(void *, dispatch_queue_t);
    void (*Activate)(void *);
    int (*GetType)(void *);
    int64_t (*GetInt)(void *, int32_t);
} gCap;

static uint64_t gCapIgnoreUntil = 0;

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

@interface BKMarkerView : UIView
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *keyEnc;
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, strong) UILabel *label;
@end

static BKMarkerView *gPending = nil;

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

static NSMutableDictionary *BKReadCfg(void)
{
    return [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath]
        ?: [NSMutableDictionary dictionary];
}

static void BKWriteCfg(NSMutableDictionary *cfg)
{
    [cfg writeToFile:kBKConfigPath atomically:YES];
    BKPost("com.wjf.ballkey.reload");
}

static NSString *BKStatusText(void)
{
    NSString *s = [NSString stringWithContentsOfFile:kBKStatusPath
                                            encoding:NSUTF8StringEncoding error:nil];
    return s.length ? s : @"ativo=? marcadores=? app=?";
}

#pragma mark - Captura de tecla

static void BKStopCapture(void)
{
    gPending = nil;
    gBanner.hidden = YES;
}

static void BKFreeCapture(void)
{
    gPending = nil;
    if (!gCapClient) return;
    @try {
        if (gCap.SetQueue) gCap.SetQueue(gCapClient, NULL);
    } @catch (NSException *e) {
    }
    CFRelease(gCapClient);
    gCapClient = NULL;
}

static void BKCapCB(void *target, void *refcon, void *queue, void *ev)
{
    (void)target; (void)refcon; (void)queue;
    if (!ev) return;
    @try {
        int type = gCap.GetType(ev);
        if (gCapSeen < 25) {
            gCapSeen++;
            BKLog(@"cap t=%d", type);
        }
        if (!gPending) return;
        if (mach_absolute_time() < gCapIgnoreUntil) return;

        NSString *enc = nil;
        if (type == 3) {
            int page = (int)gCap.GetInt(ev, (3 << 16 | 0));
            int usage = (int)gCap.GetInt(ev, (3 << 16 | 1));
            int down = (int)gCap.GetInt(ev, (3 << 16 | 2));
            if ((page == 0 || page == 7) && down && usage >= 4 && usage <= 231) {
                enc = [NSString stringWithFormat:@"k:%d", usage];
            }
        } else if (type == 17) {
            int mask = (int)gCap.GetInt(ev, (17 << 16 | 3));
            if (mask & 1) enc = @"m:0";
            else if (mask & 2) enc = @"m:1";
            else if (mask & 4) enc = @"m:2";
        }
        if (!enc) return;

        BKMarkerView *m = gPending;
        gPending = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            m.keyEnc = enc;
            m.label.text = [NSString stringWithFormat:@"%@\n%@",
                            [m.label.text componentsSeparatedByString:@"\n"].firstObject, enc];
            gBanner.hidden = YES;
            BKLog(@"cap ok %@", enc);
        });
    } @catch (NSException *e) {
        BKLog(@"cap erro: %@", e.reason);
    }
}

static void BKStartCapture(BKMarkerView *m)
{
    if (!gIOKit) {
        gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (gIOKit) {
            gCap.Create = dlsym(gIOKit, "IOHIDEventSystemClientCreate");
            gCap.CreateWithType = dlsym(gIOKit, "IOHIDEventSystemClientCreateWithType");
            gCap.RegisterCB = dlsym(gIOKit, "IOHIDEventSystemClientRegisterEventCallback");
            gCap.SetQueue = dlsym(gIOKit, "IOHIDEventSystemClientSetDispatchQueue");
            gCap.Activate = dlsym(gIOKit, "IOHIDEventSystemClientActivate");
            gCap.GetType = dlsym(gIOKit, "IOHIDEventGetType");
            gCap.GetInt = dlsym(gIOKit, "IOHIDEventGetIntegerValue");
        }
    }
    if (!gIOKit || !gCap.Create || !gCap.RegisterCB) return;

    gPending = m;
    gBanner.hidden = NO;
    gCapIgnoreUntil = mach_absolute_time() + 250000000ull;

    if (gCapClient) return;

    @try {
        gCapClient = gCap.CreateWithType ? gCap.CreateWithType(kCFAllocatorDefault, 2, NULL)
                                         : gCap.Create(kCFAllocatorDefault);
        if (!gCapClient) {
            BKLog(@"cap: cliente nulo");
            return;
        }
        gCap.RegisterCB(gCapClient, BKCapCB, NULL, NULL);
        dispatch_queue_t q = dispatch_get_main_queue();
        if (gCap.SetQueue) gCap.SetQueue(gCapClient, q);
        if (gCap.Activate) gCap.Activate(gCapClient);
        BKLog(@"cap: cliente criado");
    } @catch (NSException *e) {
        BKLog(@"cap falhou: %@", e.reason);
    }
}

#pragma mark - Marcador

@implementation BKMarkerView

- (void)bkPan:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:self.superview];
    CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    c.x = MAX(20, MIN(self.superview.bounds.size.width - 20, c.x));
    c.y = MAX(20, MIN(self.superview.bounds.size.height - 20, c.y));
    self.center = c;
    [g setTranslation:CGPointZero inView:self.superview];
}

- (void)bkTap:(UITapGestureRecognizer *)g
{
    (void)g;
    if (gPending == self) return;
    BKStartCapture(self);
}

- (void)bkLong:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (gPending == self) BKStopCapture();
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

static BKMarkerView *BKMakeMarker(NSString *type, CGPoint c, NSString *enc)
{
    CGFloat side = 56;
    BKMarkerView *m = [[BKMarkerView alloc] initWithFrame:
        CGRectMake(c.x - side / 2, c.y - side / 2, side, side)];
    UIColor *col = BKTypeColor(type);
    m.backgroundColor = [col colorWithAlphaComponent:0.45];
    m.layer.cornerRadius = side / 2;
    m.layer.borderColor = col.CGColor;
    m.layer.borderWidth = 2;
    m.type = type;
    m.keyEnc = enc;
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

    [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:m action:@selector(bkPan:)]];
    [m addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:m action:@selector(bkTap:)]];
    [m addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:m action:@selector(bkLong:)]];
    return m;
}

#pragma mark - Editor

static void BKAddMarker(NSString *type, BOOL capture)
{
    if (!gCanvas) return;
    CGPoint c = CGPointMake(gCanvas.bounds.size.width / 2, gCanvas.bounds.size.height / 2);
    BKMarkerView *m = BKMakeMarker(type, c, nil);
    [gCanvas addSubview:m];
    [gMarkers addObject:m];
    if (capture) BKStartCapture(m);
}

static void BKSaveEditor(void)
{
    NSMutableArray *pts = [NSMutableArray array];
    CGSize sz = gCanvas.bounds.size;

    for (BKMarkerView *m in gMarkers) {
        double x = m.center.x / sz.width;
        double y = m.center.y / sz.height;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"X"] = @(x);
        d[@"Y"] = @(y);
        d[@"Type"] = m.type;
        if ([m.type isEqualToString:@"Fps"]) {
            d[@"Key"] = m.keyEnc ?: @"k:224";
            continue;
        }
        if ([m.type isEqualToString:@"Dir"]) {
            double r = m.radius;
            d[@"Key"] = m.keyEnc ?: @"m:0";
            d[@"Radius"] = @(r);
            d[@"Sens"] = @(1.0);
            d[@"Center"] = [NSString stringWithFormat:@"%.5f,%.5f", x, y];
            d[@"Up"] = [NSString stringWithFormat:@"%.5f,%.5f", x, y - r];
            d[@"Down"] = [NSString stringWithFormat:@"%.5f,%.5f", x, y + r];
            d[@"Left"] = [NSString stringWithFormat:@"%.5f,%.5f", x - r, y];
            d[@"Right"] = [NSString stringWithFormat:@"%.5f,%.5f", x + r, y];
        } else {
            d[@"Key"] = m.keyEnc ?: @"";
            if ([m.type isEqualToString:@"Hold"]) d[@"HoldMs"] = @(400);
        }
        [pts addObject:d];
    }

    NSMutableDictionary *cfg = BKReadCfg();
    NSString *bundle = gFrontBundle ?: cfg[@"ActiveBundle"];
    if (![bundle isKindOfClass:[NSString class]] || !bundle.length) {
        BKLog(@"save: bundle ausente");
        return;
    }

    NSMutableDictionary *profiles = [cfg[@"Profiles"] isKindOfClass:[NSDictionary class]]
        ? [cfg[@"Profiles"] mutableCopy] : [NSMutableDictionary dictionary];

    NSMutableArray *keep = [NSMutableArray array];
    for (NSDictionary *d in pts) {
        if ([d[@"Type"] isEqualToString:@"Fps"]) {
            cfg[@"FpsX"] = d[@"X"];
            cfg[@"FpsY"] = d[@"Y"];
            cfg[@"FpsKey"] = d[@"Key"];
        } else {
            [keep addObject:d];
        }
    }
    profiles[bundle] = keep;
    cfg[@"Profiles"] = profiles;
    cfg[@"ActiveBundle"] = bundle;
    BKWriteCfg(cfg);
    BKLog(@"save: %lu marcadores em %@", (unsigned long)keep.count, bundle);
}

static void BKCloseEditor(void)
{
    BKFreeCapture();
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

    NSArray *row1 = @[@[@"+ Toque", @"Tap"], @[@"+ Pressionar", @"Press"],
                      @[@"+ Segurar", @"Hold"], @[@"+ Direção", @"Dir"], @[@"+ Trava", @"Fps"]];
    CGFloat bx = 8;
    for (NSArray *pair in row1) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(bx, 8, 76, 34);
        [b setTitle:pair[0] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.backgroundColor = [BKTypeColor(pair[1]) colorWithAlphaComponent:0.85];
        b.layer.cornerRadius = 8;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [b addTarget:gEditWindow.rootViewController
              action:@selector(bkAdd:)
    forControlEvents:UIControlEventTouchUpInside];
        b.tag = 200 + [row1 indexOfObject:pair];
        [root addSubview:b];
        bx += 82;
    }

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(root.bounds.size.width - 158, 8, 70, 34);
    [save setTitle:@"Salvar" forState:UIControlStateNormal];
    [save setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    save.backgroundColor = [UIColor systemGreenColor];
    save.layer.cornerRadius = 8;
    [save addTarget:gEditWindow.rootViewController
             action:@selector(bkSave:)
   forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:save];

    UIButton *sair = [UIButton buttonWithType:UIButtonTypeSystem];
    sair.frame = CGRectMake(root.bounds.size.width - 82, 8, 74, 34);
    [sair setTitle:@"Sair" forState:UIControlStateNormal];
    [sair setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    sair.backgroundColor = [UIColor systemGrayColor];
    sair.layer.cornerRadius = 8;
    [sair addTarget:gEditWindow.rootViewController
             action:@selector(bkClose:)
   forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:sair];

    gBanner = [[UIView alloc] initWithFrame:CGRectMake(root.bounds.size.width / 2 - 155,
                                                      root.bounds.size.height - 54, 310, 34)];
    gBanner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    gBanner.layer.cornerRadius = 8;
    gBanner.hidden = YES;
    UILabel *bl = [[UILabel alloc] initWithFrame:gBanner.bounds];
    bl.textAlignment = NSTextAlignmentCenter;
    bl.textColor = UIColor.whiteColor;
    bl.font = [UIFont systemFontOfSize:12];
    bl.text = @"Aperte a tecla ou o botão do mouse…";
    [gBanner addSubview:bl];
    [root addSubview:gBanner];

    NSString *bundle = gFrontBundle ?: BKReadCfg()[@"ActiveBundle"];
    NSArray *pts = BKReadCfg()[@"Profiles"][bundle ?: @""];
    CGSize sz = gCanvas.bounds.size;
    if ([pts isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in pts) {
            CGPoint c = CGPointMake([d[@"X"] doubleValue] * sz.width,
                                    [d[@"Y"] doubleValue] * sz.height);
            BKMarkerView *m = BKMakeMarker(d[@"Type"] ?: @"Tap", c, d[@"Key"]);
            if (d[@"Radius"]) m.radius = [d[@"Radius"] doubleValue];
            [gCanvas addSubview:m];
            [gMarkers addObject:m];
        }
    }

    [gEditWindow setHidden:NO];
}

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

    UIView *root = gMenuWindow.rootViewController.view;
    [[root viewWithTag:77] removeFromSuperview];

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 486)];
    box.tag = 77;
    box.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    box.layer.cornerRadius = 14;
    box.center = CGPointMake(gMenuWindow.bounds.size.width / 2,
                             gMenuWindow.bounds.size.height / 2);

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 226, 26)];
    st.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    st.textColor = [UIColor systemYellowColor];
    st.text = BKStatusText();
    [box addSubview:st];

    NSArray *titles = @[@"Editar teclas",
                        [NSString stringWithFormat:@"Sensi FPS %.2f  (-)", BKGetSens()],
                        @"Sensi FPS  (+)",
                        gEnabled ? @"Desativar" : @"Ativar",
                        @"Testar centro",
                        @"Dump de toque",
                        @"Recarregar",
                        @"Fechar"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(12, 40 + (CGFloat)i * 46, 226, 40);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:(i == 3 && gEnabled ? [UIColor systemGreenColor] : [UIColor whiteColor])
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
    NSArray *types = @[@"Tap", @"Press", @"Hold", @"Dir", @"Fps"];
    NSInteger i = b.tag - 200;
    if (i < 0 || i >= (NSInteger)types.count) return;
    BKAddMarker(types[i], YES);
}

- (void)bkSave:(UIButton *)b
{
    (void)b;
    BKSaveEditor();
    BKCloseEditor();
}

- (void)bkClose:(UIButton *)b
{
    (void)b;
    BKCloseEditor();
}

- (void)bkMenuTap:(UIButton *)b
{
    NSInteger i = b.tag - 100;
    if (i == 0) {
        gMenuWindow.hidden = YES;
        BKOpenEditor();
    } else if (i == 1) {
        BKSetSens(BKGetSens() - 0.05);
        BKToggleMenu();
        BKToggleMenu();
    } else if (i == 2) {
        BKSetSens(BKGetSens() + 0.05);
        BKToggleMenu();
        BKToggleMenu();
    } else if (i == 3) {
        BKSetEnabled(!gEnabled);
        BKToggleMenu();
        BKToggleMenu();
    } else if (i == 4) {
        BKPost("com.wjf.ballkey.test");
    } else if (i == 5) {
        NSMutableDictionary *cfg = BKReadCfg();
        cfg[@"Dump"] = @(![cfg[@"Dump"] boolValue]);
        BKWriteCfg(cfg);
    } else if (i == 6) {
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

    [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:gBallWindow.rootViewController action:@selector(bkPan:)]];
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:gBallWindow.rootViewController action:@selector(bkTap:)]];

    [gBallWindow.rootViewController.view addSubview:gBall];
    BKRelayout();
    gBallWindow.hidden = NO;
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
