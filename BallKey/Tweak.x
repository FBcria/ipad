//
// BallKey — mapeador de teclado/mouse para o Free Fire
// Variante dylib injetável: sem substrate, sem jbroot, sem UIWindow extra.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <notify.h>

#define BK_DIR   @"/var/mobile/Library/Caches/ballkey"
#define BK_LOG   BK_DIR "/ballkey.log"
#define BK_CFG   BK_DIR "/config.plist"
#define BK_MAP   BK_DIR "/map.plist"
#define BK_FLAG  BK_DIR "/enabled"

static const uint64_t BK_SENDER = 0x8000000817319375ULL;

#pragma mark - Log

static void BKLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    NSString *line = [NSString stringWithFormat:@"%ld.%03ld %@\n", (long)ts.tv_sec, ts.tv_nsec / 1000000, msg];
    FILE *f = fopen(BK_LOG.UTF8String, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

#pragma mark - Símbolos HID

typedef struct __IOHIDEvent *BKEvent;
typedef struct __IOHIDEventSystemClient *BKClient;

static BKClient (*pCreateClient)(CFAllocatorRef, int, void *);
static void (*pSetMatching)(BKClient, CFDictionaryRef);
static void (*pSetMatchingMultiple)(BKClient, CFArrayRef);
static void (*pRegisterCB)(BKClient, void *, void *, void *);
static void (*pSchedule)(BKClient, CFRunLoopRef, CFStringRef);
static uint64_t (*pGetSender)(BKEvent);
static int (*pGetType)(BKEvent);
static int64_t (*pGetInt)(BKEvent, uint32_t);
static BKEvent (*pCreateFinger)(CFAllocatorRef, AbsoluteTime, uint32_t, uint32_t, uint32_t,
                                uint32_t, double, double, double, Boolean, Boolean, Boolean);
static void (*pSetSender)(BKEvent, uint64_t);

static BOOL BKLoadSymbols(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) h = RTLD_DEFAULT;

    pCreateClient        = dlsym(h, "IOHIDEventSystemClientCreateWithType");
    pSetMatching         = dlsym(h, "IOHIDEventSystemClientSetMatching");
    pSetMatchingMultiple = dlsym(h, "IOHIDEventSystemClientSetMatchingMultiple");
    pRegisterCB          = dlsym(h, "IOHIDEventSystemClientRegisterEventCallback");
    pSchedule            = dlsym(h, "IOHIDEventSystemClientScheduleWithRunLoop");
    pGetSender           = dlsym(h, "IOHIDEventGetSenderID");
    pGetType             = dlsym(h, "IOHIDEventGetType");
    pGetInt              = dlsym(h, "IOHIDEventGetIntegerValue");
    pCreateFinger        = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    pSetSender           = dlsym(h, "IOHIDEventSetSenderID");

    BKLog(@"syms client=%d finger=%d int=%d", !!pCreateClient, !!pCreateFinger, !!pGetInt);
    return pCreateClient && pCreateFinger && pGetInt;
}

enum { kTypeKeyboard = 3 };
enum { kDigitizerRange = 0x01, kDigitizerTouch = 0x02, kDigitizerPosition = 0x04 };
static const uint32_t kFieldKeyboardUsage = 0x00030001;
static const uint32_t kFieldKeyboardDown  = 0x00030002;

#pragma mark - Declarações

@class BKContainerView, BKZoneView, BKCursorView, BKButton, BKPanelView;

@interface BKContainerView : UIView
- (void)moveBy:(CGFloat)dx dy:(CGFloat)dy;
- (void)click:(BOOL)down;
- (void)clickRight;
@end

@interface BKZoneView : UIView
@end

@interface BKCursorView : UIView
@end

@interface BKButton : UIView
@end

@interface BKPanelView : UIView
@property (nonatomic, strong) UISegmentedControl *tabs;
@property (nonatomic, strong) UIScrollView *body;
@property (nonatomic, strong) UILabel *diag;
@property (nonatomic, strong) UISlider *sens;
@property (nonatomic, strong) UISwitch *cur;
@property (nonatomic, strong) UISwitch *clk;
@property (nonatomic, assign) NSInteger tab;
@property (nonatomic, assign) BOOL open;
- (void)toggle;
- (void)rebuild;
- (void)refreshDiag;
- (void)finishBind;
- (void)openNow;
@end

#pragma mark - Estado

static UIApplication *BKApp(void) { return UIApplication.sharedApplication; }
static BKClient gClient;
static BOOL gMonLive, gHookOn, gEnabled;
static NSUInteger gEvCount, gKeyCount;
static NSMutableDictionary<NSString *, NSString *> *gKeyMap;   // usage -> ação
static NSMutableDictionary<NSString *, NSValue *> *gPoints;    // ação -> ponto
static NSMutableDictionary<NSString *, NSNumber *> *gHeld;     // ação -> ident
static uint32_t gIdent = 100, gClickIdent;
static BOOL gClickDown;

static BKContainerView *gContainer;
static BKPanelView *gPanel;
static BKCursorView *gCursor;
static BKButton *gKnob;
static UIViewController *gHost;
static CGPoint gCursorPos;
static BOOL gCursorVisible = YES;
static CGFloat gSensitivity = 1.6;
static BOOL gClickOnPress = YES;
static NSString *gArmed;
static int gAttempt;

#pragma mark - Toque sintético

static void BKSendTouch(CGPoint norm, BOOL down, uint32_t ident) {
    if (!pCreateFinger || !BKApp()) return;
    uint32_t mask = kDigitizerRange | kDigitizerTouch | (down ? kDigitizerPosition : 0);
    BKEvent ev = pCreateFinger(kCFAllocatorDefault, mach_absolute_time(), 1, ident, mask,
                               down ? 1 : 0, norm.x, norm.y, 0, true, down, false);
    if (!ev) return;
    if (pSetSender) pSetSender(ev, BK_SENDER);
    [(id)BKApp() _enqueueHIDEvent:(id)ev];
    CFRelease(ev);
    gEvCount++;
}

static uint32_t BKTouchDown(CGPoint norm) {
    uint32_t ident = ++gIdent;
    BKSendTouch(norm, YES, ident);
    return ident;
}

static void BKTouchUp(CGPoint norm, uint32_t ident) {
    BKSendTouch(norm, NO, ident);
}

static CGPoint BKNorm(void) {
    CGSize s = gContainer ? gContainer.bounds.size : CGSizeZero;
    if (!s.width || !s.height) return CGPointMake(0.5, 0.5);
    return CGPointMake(gCursorPos.x / s.width, gCursorPos.y / s.height);
}

#pragma mark - Mapa padrão

static NSDictionary *BKDefaultKeys(void) {
    return @{ @"4": @"Frente", @"22": @"Trás", @"5": @"Esquerda", @"7": @"Direita",
              @"44": @"Pular", @"225": @"Agachar", @"229": @"Agachar",
              @"21": @"Recarregar", @"9": @"Pegar", @"8": @"Porta",
              @"20": @"Trocar arma", @"25": @"Mira", @"30": @"Curar",
              @"31": @"Mochila", @"43": @"Mapa" };
}

static NSDictionary *BKDefaultPoints(void) {
    return @{ @"Frente":     [NSValue valueWithCGPoint:CGPointMake(0.42, 0.80)],
              @"Trás":       [NSValue valueWithCGPoint:CGPointMake(0.42, 0.93)],
              @"Esquerda":   [NSValue valueWithCGPoint:CGPointMake(0.33, 0.86)],
              @"Direita":    [NSValue valueWithCGPoint:CGPointMake(0.51, 0.86)],
              @"Pular":      [NSValue valueWithCGPoint:CGPointMake(0.90, 0.62)],
              @"Agachar":    [NSValue valueWithCGPoint:CGPointMake(0.90, 0.78)],
              @"Recarregar": [NSValue valueWithCGPoint:CGPointMake(0.78, 0.88)],
              @"Pegar":      [NSValue valueWithCGPoint:CGPointMake(0.66, 0.55)],
              @"Porta":      [NSValue valueWithCGPoint:CGPointMake(0.72, 0.50)],
              @"Trocar arma": [NSValue valueWithCGPoint:CGPointMake(0.80, 0.72)],
              @"Mira":       [NSValue valueWithCGPoint:CGPointMake(0.72, 0.80)],
              @"Curar":      [NSValue valueWithCGPoint:CGPointMake(0.60, 0.88)],
              @"Mochila":    [NSValue valueWithCGPoint:CGPointMake(0.68, 0.88)],
              @"Mapa":       [NSValue valueWithCGPoint:CGPointMake(0.55, 0.12)] };
}

static void BKLoadConfig(void) {
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:BK_CFG];
    if (c) {
        gSensitivity = c[@"sens"] ? [c[@"sens"] doubleValue] : 1.6;
        gCursorVisible = c[@"cursor"] ? [c[@"cursor"] boolValue] : YES;
        gClickOnPress = c[@"click"] ? [c[@"click"] boolValue] : YES;
    }
    NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:BK_MAP];
    gKeyMap = [NSMutableDictionary dictionaryWithDictionary:m[@"keys"] ?: BKDefaultKeys()];
    gPoints = [NSMutableDictionary dictionary];
    NSDictionary *p = m[@"points"] ?: BKDefaultPoints();
    for (NSString *k in p) gPoints[k] = [NSValue valueWithCGPoint:CGPointFromString(p[k])];
    if (!gPoints.count) for (NSString *k in BKDefaultPoints()) gPoints[k] = BKDefaultPoints()[k];
}

static void BKSaveConfig(void) {
    [@{ @"sens": @(gSensitivity), @"cursor": @(gCursorVisible), @"click": @(gClickOnPress) }
        writeToFile:BK_CFG atomically:YES];
    NSMutableDictionary *pts = [NSMutableDictionary dictionary];
    for (NSString *k in gPoints) pts[k] = NSStringFromCGPoint(gPoints[k].CGPointValue);
    [@{ @"keys": gKeyMap, @"points": pts } writeToFile:BK_MAP atomically:YES];
}

#pragma mark - Container

@implementation BKContainerView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == gCursor) return nil;
    return hit;
}
- (void)moveBy:(CGFloat)dx dy:(CGFloat)dy {
    CGSize s = self.bounds.size;
    gCursorPos.x = MAX(0, MIN(s.width,  gCursorPos.x + dx * gSensitivity));
    gCursorPos.y = MAX(0, MIN(s.height, gCursorPos.y + dy * gSensitivity));
    gCursor.center = gCursorPos;
    gCursor.hidden = !gCursorVisible;
}
- (void)click:(BOOL)down {
    if (!gEnabled) return;
    if (down) {
        if (!gClickOnPress || gClickDown) return;
        gClickDown = YES;
        gClickIdent = BKTouchDown(BKNorm());
    } else {
        if (!gClickDown) return;
        gClickDown = NO;
        BKTouchUp(BKNorm(), gClickIdent);
    }
}
- (void)clickRight {
    if (!gEnabled) return;
    CGPoint n = BKNorm();
    uint32_t ident = BKTouchDown(n);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKTouchUp(n, ident);
    });
}
@end

#pragma mark - Cursor

@implementation BKCursorView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.9;
        self.layer.shadowRadius = 2;
        self.layer.shadowOffset = CGSizeZero;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(c, UIColor.whiteColor.CGColor);
    CGContextMoveToPoint(c, 2, 1);
    CGContextAddLineToPoint(c, 2, 17);
    CGContextAddLineToPoint(c, 6.5, 13);
    CGContextAddLineToPoint(c, 10, 20);
    CGContextAddLineToPoint(c, 13, 18.5);
    CGContextAddLineToPoint(c, 9.5, 11.5);
    CGContextAddLineToPoint(c, 15, 11.5);
    CGContextClosePath(c);
    CGContextFillPath(c);
}
@end

#pragma mark - Zona

@implementation BKZoneView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.16];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (gArmed) return self;
    return nil;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (!gArmed) return;
    CGPoint p = [touches.anyObject locationInView:self];
    CGSize s = self.bounds.size;
    gPoints[gArmed] = [NSValue valueWithCGPoint:CGPointMake(p.x / s.width, p.y / s.height)];
    BKSaveConfig();
    BKLog(@"bind ponto %@ %.3f,%.3f", gArmed, p.x / s.width, p.y / s.height);
    gArmed = nil;
    [gPanel finishBind];
}
@end

#pragma mark - Botão

@implementation BKButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:0.92];
        self.layer.cornerRadius = 22;
        self.layer.borderWidth = 2;
        self.layer.borderColor = UIColor.whiteColor.CGColor;
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)]];
    }
    return self;
}
- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self.superview];
    CGPoint c = CGPointMake(self.center.x + d.x, self.center.y + d.y);
    c.x = MAX(24, MIN(self.superview.bounds.size.width - 24, c.x));
    c.y = MAX(24, MIN(self.superview.bounds.size.height - 24, c.y));
    self.center = c;
    [g setTranslation:CGPointZero inView:self.superview];
}
- (void)tap { [gPanel toggle]; }
- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(c, UIColor.whiteColor.CGColor);
    for (int i = 0; i < 3; i++)
        CGContextFillRect(c, CGRectMake(14, 14 + i * 6, 16, 2.5));
}
@end

#pragma mark - Painel

@implementation BKPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.13 alpha:0.97];
        self.layer.cornerRadius = 16;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        self.clipsToBounds = YES;

        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 44)];
        bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
        [self addSubview:bar];

        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 200, 44)];
        t.text = @"BALLKEY";
        t.textColor = UIColor.whiteColor;
        t.font = [UIFont boldSystemFontOfSize:15];
        [bar addSubview:t];

        UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
        x.frame = CGRectMake(frame.size.width - 44, 0, 44, 44);
        x.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [x setTitle:@"✕" forState:UIControlStateNormal];
        [x addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:x];

        [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];

        self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"Mapa", @"Ajustes", @"Sobre"]];
        self.tabs.frame = CGRectMake(12, 52, frame.size.width - 24, 32);
        self.tabs.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.tabs.selectedSegmentIndex = 0;
        [self.tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
        [self addSubview:self.tabs];

        self.body = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 92, frame.size.width, frame.size.height - 92)];
        self.body.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.body.alwaysBounceVertical = YES;
        [self addSubview:self.body];

        self.diag = [UILabel new];
        self.diag.numberOfLines = 0;
        self.diag.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        self.diag.textColor = [UIColor colorWithWhite:0.8 alpha:1];

        [self rebuild];
    }
    return self;
}

- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self.superview];
    CGPoint c = CGPointMake(self.center.x + d.x, self.center.y + d.y);
    CGSize s = self.superview.bounds.size;
    c.x = MAX(self.bounds.size.width / 2, MIN(s.width - self.bounds.size.width / 2, c.x));
    c.y = MAX(self.bounds.size.height / 2, MIN(s.height - self.bounds.size.height / 2, c.y));
    self.center = c;
    [g setTranslation:CGPointZero inView:self.superview];
}

- (void)toggle {
    self.open = !self.open;
    [UIView animateWithDuration:0.18 animations:^{ self.alpha = self.open ? 1 : 0; }];
    self.userInteractionEnabled = self.open;
    if (self.open) [self rebuild];
}

- (void)openNow { if (!self.open) [self toggle]; }

- (void)tabChanged {
    self.tab = self.tabs.selectedSegmentIndex;
    [self rebuild];
}

- (void)rebuild {
    for (UIView *v in self.body.subviews) [v removeFromSuperview];
    self.body.contentOffset = CGPointZero;
    if (self.tab == 0) [self buildMap];
    else if (self.tab == 1) [self buildSettings];
    else [self buildAbout];
}

- (CGFloat)width { return self.body.bounds.size.width ?: self.bounds.size.width; }

- (void)buildMap {
    CGFloat y = 8, w = [self width];
    NSArray *actions = [gPoints.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *action in actions) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10, y, w - 20, 40)];
        row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
        row.layer.cornerRadius = 8;

        UILabel *n = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, row.bounds.size.width - 130, 40)];
        n.text = action;
        n.textColor = UIColor.whiteColor;
        n.font = [UIFont systemFontOfSize:13];
        [row addSubview:n];

        NSString *key = nil;
        for (NSString *k in gKeyMap) if ([gKeyMap[k] isEqualToString:action]) { key = k; break; }
        UILabel *kb = [[UILabel alloc] initWithFrame:CGRectMake(row.bounds.size.width - 118, 8, 50, 24)];
        kb.text = key ?: @"—";
        kb.textAlignment = NSTextAlignmentCenter;
        kb.textColor = [UIColor colorWithWhite:0.85 alpha:1];
        kb.font = [UIFont boldSystemFontOfSize:12];
        kb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        kb.layer.cornerRadius = 5;
        kb.clipsToBounds = YES;
        [row addSubview:kb];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(row.bounds.size.width - 62, 6, 54, 28);
        [b setTitle:@"Definir" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12];
        b.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.layer.cornerRadius = 6;
        b.tag = [actions indexOfObject:action];
        [b addTarget:self action:@selector(arm:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:b];

        [self.body addSubview:row];
        y += 46;
    }
    self.body.contentSize = CGSizeMake(w, y + 10);
}

- (void)arm:(UIButton *)b {
    NSArray *actions = [gPoints.allKeys sortedArrayUsingSelector:@selector(compare:)];
    gArmed = actions[b.tag];
    self.alpha = 0.22;
    BKLog(@"arm %@", gArmed);
}

- (void)finishBind { self.alpha = 1; [self rebuild]; }

- (void)buildSettings {
    CGFloat w = [self width];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, w - 28, 20)];
    l.text = [NSString stringWithFormat:@"Sensibilidade  %.1f", gSensitivity];
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:13];
    l.tag = 900;
    [self.body addSubview:l];

    self.sens = [[UISlider alloc] initWithFrame:CGRectMake(14, 32, w - 28, 30)];
    self.sens.minimumValue = 0.4; self.sens.maximumValue = 5.0; self.sens.value = gSensitivity;
    [self.sens addTarget:self action:@selector(sensChanged) forControlEvents:UIControlEventValueChanged];
    [self.body addSubview:self.sens];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(14, 78, w - 120, 32)];
    l2.text = @"Mostrar cursor";
    l2.textColor = UIColor.whiteColor;
    l2.font = [UIFont systemFontOfSize:13];
    [self.body addSubview:l2];
    self.cur = [[UISwitch alloc] initWithFrame:CGRectMake(w - 70, 78, 51, 31)];
    self.cur.on = gCursorVisible;
    [self.cur addTarget:self action:@selector(swChanged) forControlEvents:UIControlEventValueChanged];
    [self.body addSubview:self.cur];

    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(14, 118, w - 120, 32)];
    l3.text = @"Clique esquerdo atira";
    l3.textColor = UIColor.whiteColor;
    l3.font = [UIFont systemFontOfSize:13];
    [self.body addSubview:l3];
    self.clk = [[UISwitch alloc] initWithFrame:CGRectMake(w - 70, 118, 51, 31)];
    self.clk.on = gClickOnPress;
    [self.clk addTarget:self action:@selector(swChanged) forControlEvents:UIControlEventValueChanged];
    [self.body addSubview:self.clk];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(14, 168, w - 28, 36);
    [reset setTitle:@"Restaurar mapa padrão" forState:UIControlStateNormal];
    [reset setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    reset.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    reset.layer.cornerRadius = 8;
    [reset addTarget:self action:@selector(resetMap) forControlEvents:UIControlEventTouchUpInside];
    [self.body addSubview:reset];

    self.body.contentSize = CGSizeMake(w, 220);
}

- (void)sensChanged {
    gSensitivity = self.sens.value;
    UILabel *l = [self.body viewWithTag:900];
    l.text = [NSString stringWithFormat:@"Sensibilidade  %.1f", gSensitivity];
    BKSaveConfig();
}

- (void)swChanged {
    gCursorVisible = self.cur.on;
    gClickOnPress = self.clk.on;
    gCursor.hidden = !gCursorVisible;
    BKSaveConfig();
}

- (void)resetMap {
    gKeyMap = [NSMutableDictionary dictionaryWithDictionary:BKDefaultKeys()];
    gPoints = [NSMutableDictionary dictionary];
    for (NSString *k in BKDefaultPoints()) gPoints[k] = BKDefaultPoints()[k];
    BKSaveConfig();
    [self rebuild];
}

- (void)buildAbout {
    CGFloat w = [self width];
    self.diag.frame = CGRectMake(14, 10, w - 28, 210);
    [self.body addSubview:self.diag];
    [self refreshDiag];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(14, 232, w - 28, 34);
    [copy setTitle:@"Copiar log" forState:UIControlStateNormal];
    [copy setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    copy.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    copy.layer.cornerRadius = 8;
    [copy addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside];
    [self.body addSubview:copy];
    self.body.contentSize = CGSizeMake(w, 280);
}

- (void)refreshDiag {
    CGSize s = gContainer ? gContainer.bounds.size : CGSizeZero;
    self.diag.text = [NSString stringWithFormat:
        @"estado    %@\nmonitor   %@\nhook      %@\neventos   %lu\nteclas    %lu\nsender    %llx\nbounds    %.0fx%.0f\ncursor    %.0f,%.0f\nhost      %@\n",
        gEnabled ? @"ligado" : @"desligado",
        gMonLive ? @"vivo" : @"morto",
        gHookOn ? @"instalado" : @"ausente",
        (unsigned long)gEvCount, (unsigned long)gKeyCount, BK_SENDER,
        s.width, s.height, gCursorPos.x, gCursorPos.y,
        gHost ? NSStringFromClass([gHost class]) : @"nil"];
}

- (void)copyLog {
    UIPasteboard.generalPasteboard.string =
        [NSString stringWithContentsOfFile:BK_LOG encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

@end

#pragma mark - Despacho de tecla

static void BKBeginAction(NSString *action) {
    if (gHeld[action]) return;
    NSValue *v = gPoints[action];
    if (!v) return;
    uint32_t ident = BKTouchDown(v.CGPointValue);
    gHeld[action] = @(ident);
    gKeyCount++;
}

static void BKEndAction(NSString *action) {
    NSNumber *ident = gHeld[action];
    if (!ident) return;
    NSValue *v = gPoints[action] ?: [NSValue valueWithCGPoint:gCursorPos];
    BKTouchUp(v.CGPointValue, ident.unsignedIntValue);
    [gHeld removeObjectForKey:action];
}

static void BKHandleUsage(uint32_t usage, BOOL down) {
    NSString *key = [NSString stringWithFormat:@"%u", usage];

    if (gArmed && down) {
        for (NSString *k in [gKeyMap allKeysForObject:gArmed]) [gKeyMap removeObjectForKey:k];
        gKeyMap[key] = gArmed;
        BKSaveConfig();
        BKLog(@"bind tecla %u -> %@", usage, gArmed);
        gArmed = nil;
        [gPanel finishBind];
        return;
    }

    if (!gEnabled) return;
    NSString *action = gKeyMap[key];
    if (!action) return;
    if (down) BKBeginAction(action);
    else BKEndAction(action);
}

#pragma mark - Monitor HID

static void BKClientCB(void *target, void *refcon, BKClient client, BKEvent ev) {
    (void)target; (void)refcon; (void)client;
    if (!ev || !pGetType || !pGetInt) return;
    if (pGetSender && pGetSender(ev) == BK_SENDER) return;
    if (pGetType(ev) != kTypeKeyboard) return;
    int64_t usage = pGetInt(ev, kFieldKeyboardUsage);
    int64_t down = pGetInt(ev, kFieldKeyboardDown);
    if (usage) BKHandleUsage((uint32_t)usage, down != 0);
}

static BOOL BKMonitorStart(void) {
    if (gMonLive || !pCreateClient) return gMonLive;
    gClient = pCreateClient(kCFAllocatorDefault, 1, NULL);
    if (!gClient) { BKLog(@"client nil"); return NO; }

    NSDictionary *kb = @{ @"PrimaryUsagePage": @1, @"PrimaryUsage": @6 };
    NSDictionary *ms = @{ @"PrimaryUsagePage": @1, @"PrimaryUsage": @2 };
    BOOL ok = NO;
    if (pSetMatchingMultiple) { pSetMatchingMultiple(gClient, (__bridge CFArrayRef)@[kb, ms]); ok = YES; }
    else if (pSetMatching) { pSetMatching(gClient, (__bridge CFDictionaryRef)kb); ok = YES; }
    if (!ok) { BKLog(@"sem setmatching"); return NO; }

    pRegisterCB(gClient, NULL, NULL, (void *)BKClientCB);
    if (pSchedule) pSchedule(gClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    gMonLive = YES;
    BKLog(@"monitor on");
    return YES;
}

#pragma mark - Hook

static IMP gOrigEnqueue;

static void BKEnqueue(id self, SEL _cmd, id event) {
    if (event && pGetType && pGetInt) {
        BKEvent ev = (BKEvent)event;
        BOOL own = pGetSender && pGetSender(ev) == BK_SENDER;
        if (!own) {
            gEvCount++;
            if (pGetType(ev) == kTypeKeyboard) {
                int64_t usage = pGetInt(ev, kFieldKeyboardUsage);
                int64_t down = pGetInt(ev, kFieldKeyboardDown);
                if (usage) BKHandleUsage((uint32_t)usage, down != 0);
            }
        }
    }
    ((void (*)(id, SEL, id))gOrigEnqueue)(self, _cmd, event);
}

static void BKInstallHook(void) {
    if (gHookOn) return;
    Method m = class_getInstanceMethod(UIApplication.class, @selector(_enqueueHIDEvent:));
    if (!m) { BKLog(@"hook ausente"); return; }
    gOrigEnqueue = method_getImplementation(m);
    method_setImplementation(m, (IMP)BKEnqueue);
    gHookOn = YES;
    BKLog(@"hook on");
}

#pragma mark - GameController

static void BKStartGC(void) {
    GCKeyboard *kbd = GCKeyboard.coalescedKeyboard;
    if (kbd) {
        kbd.keyboardInput.keyChangedHandler =
            ^(GCKeyboardInput *input, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) {
            (void)input; (void)key;
            BKHandleUsage((uint32_t)code, pressed);
        };
    }
    [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        GCKeyboard *k = n.object;
        k.keyboardInput.keyChangedHandler =
            ^(GCKeyboardInput *input, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) {
            (void)input; (void)key;
            BKHandleUsage((uint32_t)code, pressed);
        };
    }];

    void (^bindMouse)(GCMouse *) = ^(GCMouse *mouse) {
        mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput *in, float dx, float dy) {
            (void)in;
            [gContainer moveBy:dx dy:dy];
        };
        mouse.mouseInput.leftButton.pressedChangedHandler =
            ^(GCControllerButtonInput *b, float v, BOOL pressed) { (void)b; (void)v; [gContainer click:pressed]; };
        mouse.mouseInput.rightButton.pressedChangedHandler =
            ^(GCControllerButtonInput *b, float v, BOOL pressed) { (void)b; (void)v; if (pressed) [gContainer clickRight]; };
    };

    if (GCMouse.current) bindMouse(GCMouse.current);
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidBecomeCurrentNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { bindMouse(n.object); }];
}

#pragma mark - Montagem

static BOOL BKAttached(void) { return gContainer != nil; }

static void BKSetEnabled(BOOL on) {
    gEnabled = on;
    [[NSFileManager defaultManager] createDirectoryAtPath:BK_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    if (on) [@"" writeToFile:BK_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    else [[NSFileManager defaultManager] removeItemAtPath:BK_FLAG error:nil];
    if (on) { BKMonitorStart(); BKInstallHook(); }
    BKLog(@"enabled %d", on);
    [gPanel refreshDiag];
}

static UIViewController *BKHost(void) {
    for (UIWindow *w in BKApp().windows) {
        UIViewController *vc = w.rootViewController;
        if (vc.isViewLoaded && vc.view.window) return vc;
    }
    return nil;
}

static void BKTryAttach(void);

static void BKScheduleAttach(double delay, int attempt) {
    if (BKAttached() || attempt > 60) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BKTryAttach(); });
}

static void BKTryAttach(void) {
    if (BKAttached()) return;
    gAttempt++;
    UIViewController *host = BKHost();
    if (!host || BKApp().applicationState != UIApplicationStateActive) {
        BKScheduleAttach(1.0, gAttempt);
        return;
    }
    gHost = host;
    CGSize s = host.view.bounds.size;

    gContainer = [[BKContainerView alloc] initWithFrame:host.view.bounds];
    gContainer.backgroundColor = UIColor.clearColor;
    gContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIView *zone = [[BKZoneView alloc] initWithFrame:gContainer.bounds];
    [gContainer addSubview:zone];

    gCursorPos = CGPointMake(s.width * 0.5, s.height * 0.5);
    gCursor = [[BKCursorView alloc] initWithFrame:CGRectMake(gCursorPos.x - 7, gCursorPos.y - 10, 22, 22)];
    gCursor.hidden = !gCursorVisible;
    [gContainer addSubview:gCursor];

    CGFloat pw = MIN(s.width * 0.86, 560);
    CGFloat ph = MIN(s.height * 0.86, 420);
    gPanel = [[BKPanelView alloc] initWithFrame:CGRectMake((s.width - pw) / 2, (s.height - ph) / 2, pw, ph)];
    gPanel.alpha = 0;
    gPanel.userInteractionEnabled = NO;
    [gContainer addSubview:gPanel];

    gKnob = [[BKButton alloc] initWithFrame:CGRectMake(24, s.height / 2 - 22, 44, 44)];
    [gContainer addSubview:gKnob];

    @try {
        [host.view addSubview:gContainer];
        BKLog(@"anexado a %@ %.0fx%.0f", NSStringFromClass([host class]), s.width, s.height);
    } @catch (NSException *e) {
        BKLog(@"falha anexar: %@", e.name);
        gContainer = nil;
        BKScheduleAttach(2.0, gAttempt);
    }
}

#pragma mark - Notificações

static void BKRegisterNotify(void) {
    int t1, t2, t3;
    notify_register_dispatch("com.wjf.ballkey.on", &t1, dispatch_get_main_queue(), ^(int x) {
        (void)x; BKSetEnabled(YES); [gPanel openNow];
    });
    notify_register_dispatch("com.wjf.ballkey.off", &t2, dispatch_get_main_queue(), ^(int x) {
        (void)x; BKSetEnabled(NO);
    });
    notify_register_dispatch("com.wjf.ballkey.show", &t3, dispatch_get_main_queue(), ^(int x) {
        (void)x; [gPanel openNow];
    });
}

#pragma mark - Entrada

static void BKEntry(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:BK_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    BKLog(@"ctor");
    if (!BKLoadSymbols()) BKLog(@"símbolos HID incompletos");

    BKLoadConfig();
    gHeld = [NSMutableDictionary dictionary];
    gEnabled = [[NSFileManager defaultManager] fileExistsAtPath:BK_FLAG];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        BKRegisterNotify();
        BKStartGC();
        BKInstallHook();
        if (gEnabled) BKMonitorStart();
        BKTryAttach();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!gMonLive) { BKLog(@"watchdog monitor"); BKMonitorStart(); }
            BKLog(@"estado mon=%d hook=%d anexado=%d", gMonLive, gHookOn, BKAttached());
        });
    });

    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        (void)n;
        gAttempt = 0;
        BKTryAttach();
        if (gEnabled) BKMonitorStart();
    }];
}

__attribute__((constructor)) static void BKCtor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ BKEntry(); });
}
