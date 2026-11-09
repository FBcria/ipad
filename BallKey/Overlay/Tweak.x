// BallKey Overlay — injetado no SpringBoard.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOKit/hid/IOHIDEventTypes.h>
#import "BKConfig.h"

typedef const void *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;
typedef void (*BKHIDEventCB)(void *target, void *refcon, void *queue, BKIOHIDEventRef event);

#define kBKTypeKeyExtra 15
#define kBKTagContainer 9901

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
static BOOL gBindKeyDown = NO;
static UIWindow *gBallWindow = nil;
static UIView *gBallContainer = nil;
static UIButton *gBall = nil;
static UIWindow *gEditorWindow = nil;
static UIView *gEditContainer = nil;
static UIView *gMenuView = nil;
static NSMutableArray<UIView *> *gMarkers = nil;
static UIView *gPendingBind = nil;
static BKIOHIDEventSystemClientRef gBindClient = NULL;
static UIView *gBindBanner = nil;
static double gBallNX = 0.88;
static double gBallNY = 0.30;
static int gOrientOverride = 0;
static int gLastOrient = 0;
static int gAppliedOrient = 0;

static void BKStartBindCapture(void);
static void BKToggleEnabled(void);
static void BKOpenEditor(void);
static void BKShowMenu(void);
static void BKRelayoutAll(void);

static UIWindowScene *BKScene(void)
{
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    }
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

// Tamanho do painel em coordenadas nativas: sempre retrato, independente de como
// [UIScreen bounds] esteja devolvendo agora.
static CGSize BKPanelSize(void)
{
    CGSize s = [UIScreen mainScreen].bounds.size;
    if (s.width > s.height) return CGSizeMake(s.height, s.width);
    return s;
}

static CGSize BKSquareSize(void)
{
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat side = MAX(s.width, s.height);
    return CGSizeMake(side, side);
}

#pragma mark - Orientacao

static int BKFrontMostOrientation(void)
{
    Class sbCls = objc_getClass("SpringBoard");
    if (!sbCls) return 0;
    id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
    if (!sb) return 0;
    SEL sel = @selector(_frontMostAppOrientation);
    if ([sb respondsToSelector:sel] == NO) return 0;
    int o = ((int (*)(id, SEL))objc_msgSend)(sb, sel);
    if (o < 1 || o > 4) return 0;
    return o;
}

static int BKDeviceOrientation(void)
{
    Class c = objc_getClass("UIDevice");
    if (!c) return 0;
    id d = ((id (*)(id, SEL))objc_msgSend)(c, @selector(currentDevice));
    if (!d) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(d, @selector(orientation));
}

static int BKCurrentOrient(void)
{
    if (gOrientOverride >= 1 && gOrientOverride <= 4) return gOrientOverride;
    int o = BKFrontMostOrientation();
    if (o) { gLastOrient = o; return o; }
    int d = BKDeviceOrientation();
    if (d >= 1 && d <= 4) { gLastOrient = d; return d; }
    return gLastOrient ? gLastOrient : 1;
}

@interface BKPassWindow : UIWindow
@end

@implementation BKPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    if (!v || v == self.rootViewController.view || v.tag == kBKTagContainer) return nil;
    return v;
}
@end

static UIWindow *BKMakeWindow(CGFloat level, BOOL passthrough, UIView **outContainer)
{
    UIWindowScene *sc = BKScene();
    if (!sc) return nil;
    UIWindow *w = passthrough ? [[BKPassWindow alloc] initWithWindowScene:sc] : [[UIWindow alloc] initWithWindowScene:sc];
    CGSize sq = BKSquareSize();
    CGSize p = BKPanelSize();
    w.frame = CGRectMake(-(sq.width - p.width) / 2.0, -(sq.height - p.height) / 2.0, sq.width, sq.height);
    w.windowLevel = level;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;

    UIView *c = [[UIView alloc] init];
    c.tag = kBKTagContainer;
    c.backgroundColor = UIColor.clearColor;
    [vc.view addSubview:c];
    if (outContainer) *outContainer = c;

    w.hidden = YES;
    return w;
}

// Gira o container para a orientacao atual. O container mantem bounds de painel;
// a matriz faz o resto, inclusive a conversao dos toques.
static void BKApplyTo(UIWindow *w, UIView *c, int o)
{
    if (!w || !c) return;
    CGSize p = BKPanelSize();
    c.transform = CGAffineTransformIdentity;
    c.bounds = CGRectMake(0, 0, p.width, p.height);
    c.center = CGPointMake(w.bounds.size.width / 2.0, w.bounds.size.height / 2.0);
    CGAffineTransform t = CGAffineTransformIdentity;
    if (o == 2) t = CGAffineTransformMakeRotation(M_PI);
    else if (o == 3) t = CGAffineTransformMakeRotation(-M_PI_2);
    else if (o == 4) t = CGAffineTransformMakeRotation(M_PI_2);
    c.transform = t;
}

static void BKClampBall(void)
{
    CGSize p = BKPanelSize();
    double mx = 30.0 / p.width;
    double my = 30.0 / p.height;
    if (gBallNX < mx) gBallNX = mx;
    if (gBallNX > 1.0 - mx) gBallNX = 1.0 - mx;
    if (gBallNY < my) gBallNY = my;
    if (gBallNY > 1.0 - my) gBallNY = 1.0 - my;
}

static void BKPlaceBall(void)
{
    if (!gBall || !gBallContainer) return;
    BKClampBall();
    CGSize p = gBallContainer.bounds.size;
    gBall.center = CGPointMake(gBallNX * p.width, gBallNY * p.height);
}

static void BKPlaceMenu(void)
{
    if (!gMenuView || !gBallContainer) return;
    CGSize p = gBallContainer.bounds.size;
    CGFloat mw = gMenuView.bounds.size.width;
    CGFloat mh = gMenuView.bounds.size.height;
    CGFloat x = gBall.center.x - mw + 28;
    if (gBallNX < 0.5) x = gBall.center.x - 28;
    x = MAX(4, MIN(p.width - mw - 4, x));
    CGFloat y = gBall.center.y + 34;
    if (y + mh > p.height - 4) y = gBall.center.y - mh - 34;
    y = MAX(4, MIN(p.height - mh - 4, y));
    gMenuView.frame = CGRectMake(x, y, mw, mh);
}

static void BKRelayoutAll(void)
{
    int o = BKCurrentOrient();
    if (o == gAppliedOrient) { BKPlaceBall(); BKPlaceMenu(); return; }
    gAppliedOrient = o;
    BKApplyTo(gBallWindow, gBallContainer, o);
    BKApplyTo(gEditorWindow, gEditContainer, o);
    BKPlaceBall();
    BKPlaceMenu();
    if (gBindBanner && gEditContainer) {
        CGSize p = gEditContainer.bounds.size;
        gBindBanner.frame = CGRectMake(p.width / 2.0 - 130, p.height - 90, 260, 36);
    }
}

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
    if (!enc || !enc.length) return @"?";
    NSArray *parts = [enc componentsSeparatedByString:@":"];
    if (parts.count != 2) return enc;
    int code = [parts[1] intValue];
    if ([parts[0] isEqualToString:@"m"]) return @[@"Esq.", @"Dir.", @"Meio"][MIN(code, 2)];
    if (code == 44) return @"Espaço";
    if (code == 40) return @"Enter";
    if (code == 41) return @"Esc";
    if (code == 42) return @"Backspace";
    if (code == 43) return @"Tab";
    if (code >= 4 && code <= 29) return [NSString stringWithFormat:@"%c", (char)('A' + (code - 4))];
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
    if ([type isEqualToString:@"Tap"]) return @"Toque";
    if ([type isEqualToString:@"Press"]) return @"Segurar";
    if ([type isEqualToString:@"Hold"]) return @"Longo";
    return @"Direção";
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

static void BKStopBindClient(void)
{
    if (!gBindClient) return;
    IOHIDEventSystemClientUnscheduleWithRunLoop(gBindClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFRelease(gBindClient);
    gBindClient = NULL;
}

static void BKBindCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    if (!ev || !gPendingBind) return;
    int type = IOHIDEventGetType(ev);
    NSString *enc = nil;
    if (type == kIOHIDEventTypeKeyboard) {
        int page = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsage);
        int down = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardDown);
        gBindKeyDown = down != 0;
        if (down && (page == 0 || page == 7) && usage > 0) enc = [NSString stringWithFormat:@"k:%d", usage];
    } else if (type == kBKTypeKeyExtra) {
        if (!gBindKeyDown) return;
        int usage = IOHIDEventGetIntegerValue(ev, kBKTypeKeyExtra << 16);
        if (usage > 0) enc = [NSString stringWithFormat:@"k:%d", usage];
    } else if (type == kIOHIDEventTypeMouse) {
        int bm = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldMouseButtonMask);
        if (bm & 1) enc = @"m:0";
        else if (bm & 2) enc = @"m:1";
        else if (bm & 4) enc = @"m:2";
    } else if (type == kIOHIDEventTypeButton) {
        int num = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonNumber);
        int click = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonClickCount);
        int idx = (num >= 1) ? num - 1 : num;
        if (click > 0 && idx >= 0 && idx <= 2) enc = [NSString stringWithFormat:@"m:%d", idx];
    }
    if (!enc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BKMarkerView *m = (BKMarkerView *)gPendingBind;
        if (![m isKindOfClass:[BKMarkerView class]]) return;
        m.keyEnc = enc;
        m.label.text = [NSString stringWithFormat:@"%@\n%@", BKTypeLabel(m.type), BKKeyDisplayName(enc)];
        gPendingBind = nil;
        gBindBanner.hidden = YES;
        BKStopBindClient();
    });
}

static void BKStartBindCapture(void)
{
    BKStopBindClient();
    gBindKeyDown = NO;
    gBindClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 1, NULL);
    if (!gBindClient) gBindClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gBindClient) return;
    IOHIDEventSystemClientRegisterEventCallback(gBindClient, BKBindCB, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(gBindClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
}

@interface BKActionTarget : NSObject
+ (instancetype)shared;
- (void)ballTap;
- (void)ballPan:(UIPanGestureRecognizer *)pan;
- (void)menuEdit;
- (void)menuToggle;
- (void)addTap;
- (void)addPress;
- (void)addHold;
- (void)addDir;
- (void)editorDone;
@end

@implementation BKActionTarget
+ (instancetype)shared { static BKActionTarget *t; static dispatch_once_t once; dispatch_once(&once, ^{ t = [BKActionTarget new]; }); return t; }
- (void)ballTap { BKShowMenu(); }
- (void)ballPan:(UIPanGestureRecognizer *)pan
{
    if (!gBallContainer) return;
    CGPoint t = [pan translationInView:gBallContainer];
    CGSize p = gBallContainer.bounds.size;
    gBallNX += t.x / p.width;
    gBallNY += t.y / p.height;
    BKPlaceBall();
    BKPlaceMenu();
    [pan setTranslation:CGPointZero inView:gBallContainer];
}
- (void)menuEdit { [gMenuView removeFromSuperview]; gMenuView = nil; BKOpenEditor(); }
- (void)menuToggle { BKToggleEnabled(); [gMenuView removeFromSuperview]; gMenuView = nil; }
- (void)addTap { [self addType:@"Tap" dx:0]; }
- (void)addPress { [self addType:@"Press" dx:60]; }
- (void)addHold { [self addType:@"Hold" dx:-60]; }
- (void)addDir { [self addType:@"Dir" dx:-100]; }
- (void)addType:(NSString *)type dx:(CGFloat)dx
{
    if (!gEditContainer) return;
    CGSize p = gEditContainer.bounds.size;
    CGPoint c = CGPointMake(p.width / 2.0 + dx, p.height / 2.0);
    BKMarkerView *m = BKMakeMarker(type, c);
    [gEditContainer addSubview:m];
    [gMarkers addObject:m];
}
- (void)editorDone
{
    if (!gEditContainer) return;
    CGSize cs = gEditContainer.bounds.size;
    NSMutableArray *pts = [NSMutableArray array];
    for (BKMarkerView *m in gMarkers) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"Type"] = m.type;
        d[@"X"] = @(MAX(0.0, MIN(1.0, m.center.x / cs.width)));
        d[@"Y"] = @(MAX(0.0, MIN(1.0, m.center.y / cs.height)));
        if ([m.type isEqualToString:@"Dir"]) {
            d[@"Button"] = m.keyEnc ?: @"m:0";
            d[@"Radius"] = @(m.radius);
            d[@"Sens"] = @(m.sens);
        } else {
            d[@"Key"] = m.keyEnc ?: @"";
            if ([m.type isEqualToString:@"Hold"]) d[@"HoldMs"] = @(m.holdMs);
        }
        [pts addObject:d];
    }
    NSString *bundle = gFrontBundle ?: @"unknown";
    BKWriteCfg(^(NSMutableDictionary *cfg) {
        NSMutableDictionary *profiles = [cfg[@"Profiles"] isKindOfClass:[NSDictionary class]] ? [cfg[@"Profiles"] mutableCopy] : [NSMutableDictionary dictionary];
        profiles[bundle] = pts;
        cfg[@"Profiles"] = profiles;
    });
    BKStopBindClient();
    [gEditorWindow setHidden:YES];
    gEditorWindow = nil;
    gEditContainer = nil;
    gMarkers = nil;
    gPendingBind = nil;
    gBindBanner = nil;
    gAppliedOrient = 0;
}
@end

static UIButton *BKMenuBtn(NSString *title, SEL sel, UIColor *color)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:color forState:UIControlStateNormal];
    [b addTarget:[BKActionTarget shared] action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void BKShowMenu(void)
{
    if (gMenuView) { [gMenuView removeFromSuperview]; gMenuView = nil; return; }
    if (!gBallContainer) return;
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 168, 96)];
    menu.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    menu.layer.cornerRadius = 12;
    menu.clipsToBounds = YES;
    UIButton *b1 = BKMenuBtn(@"Editar teclas", @selector(menuEdit), UIColor.whiteColor);
    b1.frame = CGRectMake(0, 0, 168, 48);
    UIButton *b2 = BKMenuBtn(gEnabledFlag ? @"Mapeamento: ON" : @"Mapeamento: OFF", @selector(menuToggle),
                             gEnabledFlag ? UIColor.systemGreenColor : UIColor.systemGrayColor);
    b2.frame = CGRectMake(0, 48, 168, 48);
    [menu addSubview:b1];
    [menu addSubview:b2];
    gMenuView = menu;
    [gBallContainer addSubview:menu];
    BKPlaceMenu();
}

static void BKAddBtn(UIStackView *bar, NSString *title, SEL sel, UIColor *color)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *bc = [UIButtonConfiguration plainButtonConfiguration];
    bc.title = title;
    bc.contentInsets = NSDirectionalEdgeInsetsMake(8, 10, 8, 10);
    bc.baseForegroundColor = UIColor.whiteColor;
    bc.background.backgroundColor = [color colorWithAlphaComponent:0.7];
    bc.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    b.configuration = bc;
    [b addTarget:[BKActionTarget shared] action:sel forControlEvents:UIControlEventTouchUpInside];
    [bar addArrangedSubview:b];
}

static void BKReloadMarkersFromCfg(void)
{
    if (!gMarkers) return;
    for (UIView *v in gMarkers) [v removeFromSuperview];
    [gMarkers removeAllObjects];
    if (!gEditContainer) return;
    NSDictionary *cfg = BKReadCfg();
    id pts = cfg[@"Profiles"][gFrontBundle ?: @""];
    if (![pts isKindOfClass:[NSArray class]]) return;
    CGSize cs = gEditContainer.bounds.size;
    for (NSDictionary *pt in (NSArray *)pts) {
        NSString *type = pt[@"Type"] ?: @"Tap";
        CGPoint uiPt = CGPointMake([pt[@"X"] floatValue] * cs.width, [pt[@"Y"] floatValue] * cs.height);
        BKMarkerView *m = BKMakeMarker(type, uiPt);
        m.keyEnc = pt[@"Key"] ?: pt[@"Button"];
        m.holdMs = pt[@"HoldMs"] ? [pt[@"HoldMs"] intValue] : 400;
        m.radius = pt[@"Radius"] ? [pt[@"Radius"] floatValue] : 0.12;
        m.sens = pt[@"Sens"] ? [pt[@"Sens"] floatValue] : 1.0;
        m.label.text = [NSString stringWithFormat:@"%@\n%@", BKTypeLabel(type), BKKeyDisplayName(m.keyEnc)];
        [gMarkers addObject:m];
    }
}

static void BKOpenEditor(void)
{
    if (gEditorWindow) return;
    gEditorWindow = BKMakeWindow(UIWindowLevelAlert + 60, NO, &gEditContainer);
    if (!gEditorWindow) return;
    gMarkers = [NSMutableArray array];
    gAppliedOrient = 0;
    BKApplyTo(gEditorWindow, gEditContainer, BKCurrentOrient());
    gAppliedOrient = BKCurrentOrient();

    UIView *canvas = gEditContainer;
    canvas.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];

    UIStackView *bar = [[UIStackView alloc] init];
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.spacing = 6;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [canvas addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:canvas.topAnchor constant:8],
        [bar.centerXAnchor constraintEqualToAnchor:canvas.centerXAnchor],
    ]];
    BKAddBtn(bar, @"+Toque", @selector(addTap), UIColor.systemBlueColor);
    BKAddBtn(bar, @"+Segurar", @selector(addPress), UIColor.systemGreenColor);
    BKAddBtn(bar, @"+Longo", @selector(addHold), UIColor.systemOrangeColor);
    BKAddBtn(bar, @"+Direção", @selector(addDir), UIColor.systemPurpleColor);
    BKAddBtn(bar, @"Concluir", @selector(editorDone), UIColor.systemGrayColor);

    CGSize p = canvas.bounds.size;
    gBindBanner = [[UIView alloc] initWithFrame:CGRectMake(p.width / 2.0 - 130, p.height - 90, 260, 36)];
    gBindBanner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    gBindBanner.layer.cornerRadius = 8;
    gBindBanner.hidden = YES;
    UILabel *bl = [[UILabel alloc] initWithFrame:gBindBanner.bounds];
    bl.textAlignment = NSTextAlignmentCenter;
    bl.textColor = UIColor.whiteColor;
    bl.font = [UIFont systemFontOfSize:13];
    bl.text = @"Pressione a tecla ou o botão do mouse…";
    bl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gBindBanner addSubview:bl];
    [canvas addSubview:gBindBanner];

    gEditorWindow.hidden = NO;
    BKReloadMarkersFromCfg();
    for (UIView *m in gMarkers) [canvas addSubview:m];
}

static void BKToggleEnabled(void)
{
    gEnabledFlag = !gEnabledFlag;
    BOOL en = gEnabledFlag;
    BKWriteCfg(^(NSMutableDictionary *cfg) { cfg[@"Enabled"] = @(en); });
}

static void BKSetupBall(void)
{
    if (gBallWindow) return;
    gBallWindow = BKMakeWindow(UIWindowLevelAlert + 50, YES, &gBallContainer);
    if (!gBallWindow) return;
    BKApplyTo(gBallWindow, gBallContainer, BKCurrentOrient());
    gAppliedOrient = BKCurrentOrient();

    gBall = [UIButton buttonWithType:UIButtonTypeCustom];
    gBall.frame = CGRectMake(0, 0, 56, 56);
    gBall.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.85];
    gBall.layer.cornerRadius = 28;
    gBall.layer.borderColor = UIColor.systemYellowColor.CGColor;
    gBall.layer.borderWidth = 2;
    [gBall setTitle:@"BK" forState:UIControlStateNormal];
    [gBall setTitleColor:UIColor.systemYellowColor forState:UIControlStateNormal];
    gBall.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [gBall addTarget:[BKActionTarget shared] action:@selector(ballTap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[BKActionTarget shared] action:@selector(ballPan:)];
    [gBall addGestureRecognizer:pan];
    [gBallContainer addSubview:gBall];
    BKPlaceBall();

    gBallWindow.hidden = NO;
    [@"ball" writeToFile:@"/var/mobile/bk_ball_shown.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BKPollFrontmost(void)
{
    NSString *bid = nil;
    Class sbCls = objc_getClass("SpringBoard");
    if (sbCls) {
        id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
        SEL sel = @selector(_accessibilityFrontMostApplication);
        if ([sb respondsToSelector:sel]) {
            id app = ((id (*)(id, SEL))objc_msgSend)(sb, sel);
            if ([app respondsToSelector:@selector(bundleIdentifier)]) bid = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
        }
    }
    if (bid.length && ![bid isEqualToString:gFrontBundle]) {
        gFrontBundle = bid;
        BKWriteCfg(^(NSMutableDictionary *cfg) { cfg[@"ActiveBundle"] = bid; });
    }
}

static void BKOverlayInit(void)
{
    gIOQ = dispatch_queue_create("com.wjf.ballkey.io", DISPATCH_QUEUE_SERIAL);
    NSDictionary *cfg = BKReadCfg();
    gEnabledFlag = cfg[@"Enabled"] ? [cfg[@"Enabled"] boolValue] : YES;
    gFrontBundle = cfg[@"ActiveBundle"];
    gOrientOverride = cfg[@"OrientOverride"] ? [cfg[@"OrientOverride"] intValue] : 0;
    [@"overlay" writeToFile:@"/var/mobile/bk_overlay_loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

    __block int tries = 0;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (gBallWindow || ++tries > 30) { [t invalidate]; return; }
        BKSetupBall();
    }];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        if (gBallWindow && gBallWindow.hidden) gBallWindow.hidden = NO;
        if (gEditorWindow && gEditorWindow.hidden) gEditorWindow.hidden = NO;
        BKRelayoutAll();
        BKPollFrontmost();
    }];
}

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BKOverlayInit();
        });
    }
}
