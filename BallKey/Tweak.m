//
//  NativeInput — teclado e mouse -> toque HID nativo
//  ObjC puro. Sem Logos, sem Substrate, sem dependencia externa.
//

#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDEvent.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>

// kIOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | IsDisplayIntegrated
#define BK_FIELD_DISPLAY 0xB0019
#define BK_TYPE_DIGITIZER 11

#define BK_LEFT   (-1)
#define BK_RIGHT  (-2)
#define BK_MIDDLE (-3)
#define BK_FWD    (-4)
#define BK_BACK   (-5)

#pragma mark - Estado

static NSMutableArray<NSMutableDictionary *> *gBinds;
static NSMutableDictionary<NSNumber *, NSNumber *> *gHeld;

static UIWindow *gHUD;
static UIView *gRootView;
static UIView *gPanel;
static UIView *gBall;
static UIView *gPointer;
static UIView *gBanner;
static UILabel *gHint;
static UILabel *gStatus;
static UILabel *gDiag;
static UIStackView *gStack;
static NSMutableArray<UIView *> *gMarks;
static UIButton *gAtivoBtn, *gMarcasBtn, *gRotBtn;

static BOOL gEnabled = YES;
static BOOL gPanelOpen = YES;
static BOOL gShowMarks = NO;
static BOOL gFixRotation = YES;
static CGFloat gSens = 1.6;
static CGPoint gPtr;

static NSInteger gStep = 0;
static NSMutableDictionary *gPending = nil;
static BOOL gLeftHeld = NO;
static uint32_t gDragFinger = 9;

static BOOL gHasEnqueue = NO;
static void *gHIDClient = NULL;
static void (*fnDispatch)(void *, IOHIDEventRef) = NULL;
static uint64_t (*fnGetSender)(IOHIDEventRef) = NULL;
static void (*fnSetSender)(IOHIDEventRef, uint64_t) = NULL;
static uint64_t gSenderID = 0;
static id gMonitorBlock = nil;
static void *gMonitor = NULL;

#pragma mark - Injecao

static AbsoluteTime BKNow(void) {
    uint64_t t = mach_absolute_time();
    AbsoluteTime a = {0, 0};
    memcpy(&a, &t, sizeof(a));
    return a;
}

static void BKStartMonitor(void);

static void BKSetupInject(void) {
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        void *c = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        fnDispatch = (void (*)(void *, IOHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        fnGetSender = (uint64_t (*)(IOHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetSenderID");
        fnSetSender = (void (*)(IOHIDEventRef, uint64_t))dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        if (c && fnDispatch) gHIDClient = ((void *(*)(CFAllocatorRef))c)(kCFAllocatorDefault);
        gHasEnqueue = [UIApplication.sharedApplication respondsToSelector:sel_registerName("_enqueueHIDEvent:")];
        BKStartMonitor();
    });
}

static void BKStartMonitor(void) {
    void *reg = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventBlock");
    void *sched = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
    void *createT = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");
    if (!reg || !sched || !fnGetSender) return;

    if (createT) gMonitor = ((void *(*)(CFAllocatorRef, int, void *))createT)(kCFAllocatorDefault, 2, NULL);
    if (!gMonitor) {
        void *c = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        if (!c) return;
        gMonitor = ((void *(*)(CFAllocatorRef))c)(kCFAllocatorDefault);
    }
    if (!gMonitor) return;

    void (^blk)(void *, void *, void *, IOHIDEventRef) = ^(void *t, void *r, void *s, IOHIDEventRef e) {
        if (!e) return;
        if (IOHIDEventGetType(e) != BK_TYPE_DIGITIZER) return;
        uint64_t sid = fnGetSender(e);
        if (sid) gSenderID = sid;
    };
    gMonitorBlock = [blk copy];
    ((void (*)(void *, void *, void *, void *))reg)(gMonitor, (__bridge void *)gMonitorBlock, NULL, NULL);
    ((void (*)(void *, CFRunLoopRef, CFStringRef))sched)(gMonitor, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
}

static CGPoint BKToDevice(CGPoint p) {
    CGSize s = UIScreen.mainScreen.bounds.size;
    UIInterfaceOrientation o = gHUD.windowScene.interfaceOrientation;
    switch (o) {
        case UIInterfaceOrientationLandscapeLeft:  return CGPointMake(s.width - p.y, p.x);
        case UIInterfaceOrientationLandscapeRight: return CGPointMake(p.y, s.height - p.x);
        case UIInterfaceOrientationPortraitUpsideDown: return CGPointMake(s.width - p.x, s.height - p.y);
        default: return p;
    }
}

static void BKDiag(void) {
    NSString *t;
    if (gSenderID && fnSetSender)      t = @"via: hid+sender";
    else if (gHasEnqueue)              t = @"via: enqueue";
    else if (gHIDClient && fnDispatch) t = @"via: hid";
    else                               t = @"via: NENHUM";
    if (![gDiag.text isEqualToString:t]) {
        gDiag.text = t;
        gDiag.textColor = [t isEqualToString:@"via: NENHUM"] ? UIColor.systemRedColor : UIColor.lightGrayColor;
    }
}

static void BKInjectNow(CGPoint p, BOOL down, uint32_t idx) {
    BKSetupInject();
    CGPoint d = gFixRotation ? BKToDevice(p) : p;
    IOHIDEventRef ev = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, BKNow(),
        kIOHIDDigitizerTransducerTypeHand, 0, idx,
        down ? kIOHIDDigitizerEventTouch : 0, down,
        d.x, d.y, 0, 0, 0, 1, down, 0);
    if (!ev) return;
    IOHIDEventSetIntegerValue(ev, BK_FIELD_DISPLAY, 1);

    if (gSenderID && fnSetSender && gHIDClient && fnDispatch) {
        fnSetSender(ev, gSenderID);
        fnDispatch(gHIDClient, ev);
    } else if (gHasEnqueue) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(
            UIApplication.sharedApplication, sel_registerName("_enqueueHIDEvent:"), ev);
    } else if (gHIDClient && fnDispatch) {
        fnDispatch(gHIDClient, ev);
    }
    CFRelease(ev);
    BKDiag();
}

static void BKInject(CGPoint p, BOOL down, uint32_t idx) {
    if (NSThread.isMainThread) BKInjectNow(p, down, idx);
    else dispatch_async(dispatch_get_main_queue(), ^{ BKInjectNow(p, down, idx); });
}

#pragma mark - Binds

static NSInteger BKIndexOf(int code) {
    for (NSUInteger i = 0; i < gBinds.count; i++)
        if ([gBinds[i][@"k"] intValue] == code) return (NSInteger)i;
    return -1;
}

static void BKDown(int code, CGPoint p) {
    NSInteger i = BKIndexOf(code);
    if (i < 0 || gHeld[@(i)]) return;
    uint32_t f = (uint32_t)(i + 1);
    gHeld[@(i)] = @(f);
    BKInject(p, YES, f);
}

static void BKUp(int code) {
    NSInteger i = BKIndexOf(code);
    if (i < 0) return;
    NSNumber *f = gHeld[@(i)];
    if (!f) return;
    NSDictionary *b = gBinds[i];
    BKInject(CGPointMake([b[@"x"] doubleValue], [b[@"y"] doubleValue]), NO, f.unsignedIntValue);
    [gHeld removeObjectForKey:@(i)];
}

static void BKReleaseAll(void) {
    for (NSNumber *i in gHeld.allKeys) {
        NSInteger n = i.integerValue;
        if (n >= (NSInteger)gBinds.count) continue;
        NSDictionary *b = gBinds[n];
        BKInject(CGPointMake([b[@"x"] doubleValue], [b[@"y"] doubleValue]), NO, gHeld[i].unsignedIntValue);
    }
    [gHeld removeAllObjects];
    if (gLeftHeld) { BKInject(gPtr, NO, gDragFinger); gLeftHeld = NO; }
}

#pragma mark - Config

static NSString *BKConfigPath(void) {
    static NSString *p;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSString *base;
        if (access("/var/mobile/Documents", W_OK) == 0) {
            base = @"/var/mobile/Documents";
        } else {
            NSArray *d = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
            base = [d.firstObject stringByAppendingPathComponent:@"GameInput"];
            [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
        }
        p = [base stringByAppendingPathComponent:@"input.cfg"];
    });
    return p;
}

static void BKSave(void) {
    NSDictionary *r = @{ @"binds": gBinds ?: @[],
                         @"sens": @(gSens),
                         @"on": @(gEnabled),
                         @"marks": @(gShowMarks),
                         @"rot": @(gFixRotation),
                         @"panel": @(gPanelOpen) };
    [r writeToFile:BKConfigPath() atomically:YES];
}

static void BKLoad(void) {
    NSDictionary *r = [NSDictionary dictionaryWithContentsOfFile:BKConfigPath()];
    gBinds = [NSMutableArray array];
    if (![r isKindOfClass:NSDictionary.class]) return;
    if ([r[@"binds"] isKindOfClass:NSArray.class]) {
        for (id o in r[@"binds"])
            if ([o isKindOfClass:NSDictionary.class])
                [gBinds addObject:[o mutableCopy]];
    }
    if (r[@"sens"])  gSens = [r[@"sens"] doubleValue];
    if (r[@"on"])    gEnabled = [r[@"on"] boolValue];
    if (r[@"marks"]) gShowMarks = [r[@"marks"] boolValue];
    if (r[@"rot"])   gFixRotation = [r[@"rot"] boolValue];
    if (r[@"panel"]) gPanelOpen = [r[@"panel"] boolValue];
}

#pragma mark - Nomes

static NSString *BKName(int c) {
    switch (c) {
        case BK_LEFT: return @"Mouse1";
        case BK_RIGHT: return @"Mouse2";
        case BK_MIDDLE: return @"Mouse3";
        case BK_FWD: return @"Mouse4";
        case BK_BACK: return @"Mouse5";
        default: break;
    }
    if (c >= 4 && c <= 29) return [NSString stringWithFormat:@"%c", 'A' + (c - 4)];
    if (c >= 30 && c <= 38) return [NSString stringWithFormat:@"%d", c - 29];
    switch (c) {
        case 39: return @"0";
        case 40: return @"Enter";
        case 41: return @"Esc";
        case 42: return @"Back";
        case 43: return @"Tab";
        case 44: return @"Espaco";
        case 79: return @"Dir";
        case 80: return @"Esq";
        case 81: return @"Baixo";
        case 82: return @"Cima";
        case 225: return @"Shift";
        case 224: return @"Ctrl";
        case 226: return @"Alt";
        case 227: return @"Cmd";
        default: return [NSString stringWithFormat:@"#%d", c];
    }
}

#pragma mark - UI

static void BKRefresh(void);

static void BKMarkers(void) {
    for (UIView *v in gMarks) [v removeFromSuperview];
    [gMarks removeAllObjects];
    if (!gShowMarks) return;
    for (NSDictionary *b in gBinds) {
        CGFloat x = [b[@"x"] doubleValue], y = [b[@"y"] doubleValue];
        if (x == 0 && y == 0) continue;
        UIView *m = [[UIView alloc] initWithFrame:CGRectMake(x - 19, y - 19, 38, 38)];
        m.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        m.layer.cornerRadius = 19;
        m.layer.borderWidth = 1.5;
        m.layer.borderColor = [UIColor colorWithRed:0.3 green:0.95 blue:0.6 alpha:0.9].CGColor;
        m.userInteractionEnabled = NO;
        UILabel *l = [[UILabel alloc] initWithFrame:m.bounds];
        l.text = BKName([b[@"k"] intValue]);
        l.font = [UIFont boldSystemFontOfSize:10];
        l.textColor = UIColor.whiteColor;
        l.textAlignment = NSTextAlignmentCenter;
        [m addSubview:l];
        [gRootView insertSubview:m belowSubview:gPanel];
        [gMarks addObject:m];
    }
}

static void BKRefresh(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ BKRefresh(); }); return; }

    for (UIView *v in gStack.arrangedSubviews) {
        [gStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (gBinds.count == 0) {
        UILabel *l = [UILabel new];
        l.text = @"Nenhum bind.\nToque em + Bind e pressione uma tecla.";
        l.numberOfLines = 0;
        l.font = [UIFont systemFontOfSize:11];
        l.textColor = UIColor.lightGrayColor;
        [gStack addArrangedSubview:l];
    }

    for (NSUInteger i = 0; i < gBinds.count; i++) {
        NSMutableDictionary *b = gBinds[i];
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 236, 30)];
        row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
        row.layer.cornerRadius = 6;

        UILabel *n = [[UILabel alloc] initWithFrame:CGRectMake(8, 5, 62, 20)];
        n.text = BKName([b[@"k"] intValue]);
        n.font = [UIFont boldSystemFontOfSize:12];
        n.textColor = UIColor.whiteColor;
        [row addSubview:n];

        UIButton *pos = [UIButton buttonWithType:UIButtonTypeSystem];
        pos.frame = CGRectMake(70, 5, 92, 20);
        pos.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
        [pos setTitle:[NSString stringWithFormat:@"%.0f, %.0f", [b[@"x"] doubleValue], [b[@"y"] doubleValue]]
             forState:UIControlStateNormal];
        pos.tag = i;
        [pos addTarget:gHUD.rootViewController action:@selector(bkMove:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:pos];

        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        del.frame = CGRectMake(198, 2, 30, 26);
        [del setTitle:@"x" forState:UIControlStateNormal];
        del.tag = i;
        [del addTarget:gHUD.rootViewController action:@selector(bkDelete:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:del];

        [gStack addArrangedSubview:row];
    }

    gStack.frame = CGRectMake(0, 0, 236, gStack.arrangedSubviews.count * 36);
    gStatus.text = gEnabled ? @"ATIVO" : @"PAUSADO";
    gStatus.textColor = gEnabled ? [UIColor colorWithRed:0.3 green:0.95 blue:0.55 alpha:1] : UIColor.systemOrangeColor;
    [gAtivoBtn setTitle:(gEnabled ? @"Ativo: ON" : @"Ativo: OFF") forState:UIControlStateNormal];
    [gMarcasBtn setTitle:(gShowMarks ? @"Marcas: ON" : @"Marcas: OFF") forState:UIControlStateNormal];
    [gRotBtn setTitle:(gFixRotation ? @"Girar: ON" : @"Girar: OFF") forState:UIControlStateNormal];
    BKMarkers();
    BKDiag();
}

static void BKSetStep(NSInteger s, NSString *msg) {
    gStep = s;
    gBanner.hidden = (s == 0);
    gHint.text = msg ?: @"";
}

@interface BKRootView : UIView
@end

@interface BKRoot : UIViewController
@end

#pragma mark - Instalacao

static UIWindowScene *BKScene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)s;
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    return nil;
}

static void BKInstallHUD(void) {
    if (gHUD) { gHUD.hidden = NO; BKRefresh(); return; }

    UIWindowScene *sc = BKScene();
    if (!sc) return;

    UIWindow *w = [[UIWindow alloc] initWithWindowScene:sc];
    w.frame = sc.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelAlert - 1;
    w.backgroundColor = UIColor.clearColor;

    BKRoot *vc = [BKRoot new];
    w.rootViewController = vc;
    gHUD = w;
    gRootView = vc.view;
    gRootView.backgroundColor = UIColor.clearColor;

    gMarks = [NSMutableArray array];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(bkTap:)];
    tap.cancelsTouchesInView = NO;
    [gRootView addGestureRecognizer:tap];

    CGSize s = w.bounds.size;

    gPointer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 15, 15)];
    gPointer.backgroundColor = [UIColor colorWithRed:1 green:0.25 blue:0.35 alpha:0.9];
    gPointer.layer.cornerRadius = 7.5;
    gPointer.userInteractionEnabled = NO;
    gPointer.hidden = YES;
    [gRootView addSubview:gPointer];
    gPtr = CGPointMake(s.width / 2, s.height / 2);

    gBanner = [[UIView alloc] initWithFrame:CGRectMake(s.width / 2 - 160, 8, 320, 30)];
    gBanner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    gBanner.layer.cornerRadius = 8;
    gBanner.userInteractionEnabled = NO;
    gBanner.hidden = YES;
    [gRootView addSubview:gBanner];
    gHint = [[UILabel alloc] initWithFrame:gBanner.bounds];
    gHint.font = [UIFont systemFontOfSize:11];
    gHint.textColor = UIColor.whiteColor;
    gHint.textAlignment = NSTextAlignmentCenter;
    [gBanner addSubview:gHint];

    gBall = [[UIView alloc] initWithFrame:CGRectMake(12, 12, 44, 44)];
    gBall.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    gBall.layer.cornerRadius = 22;
    gBall.layer.borderWidth = 1.5;
    gBall.layer.borderColor = [UIColor colorWithRed:0.3 green:0.95 blue:0.6 alpha:0.9].CGColor;
    [gRootView addSubview:gBall];
    UILabel *bl = [[UILabel alloc] initWithFrame:gBall.bounds];
    bl.text = @"KB";
    bl.font = [UIFont boldSystemFontOfSize:13];
    bl.textColor = UIColor.whiteColor;
    bl.textAlignment = NSTextAlignmentCenter;
    bl.userInteractionEnabled = NO;
    [gBall addSubview:bl];
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(bkToggle:)]];
    [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:vc action:@selector(bkDrag:)]];

    gPanel = [[UIView alloc] initWithFrame:CGRectMake(12, 64, 272, s.height - 76)];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.92];
    gPanel.layer.cornerRadius = 12;
    gPanel.layer.borderWidth = 1;
    gPanel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    [gRootView addSubview:gPanel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 120, 20)];
    title.text = @"INPUT";
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textColor = UIColor.whiteColor;
    [gPanel addSubview:title];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(238, 6, 28, 26);
    [x setTitle:@"x" forState:UIControlStateNormal];
    [x addTarget:vc action:@selector(bkToggle:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:x];

    gStatus = [[UILabel alloc] initWithFrame:CGRectMake(14, 32, 120, 16)];
    gStatus.font = [UIFont boldSystemFontOfSize:11];
    [gPanel addSubview:gStatus];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(14, 54, 96, 30);
    [add setTitle:@"+ Bind" forState:UIControlStateNormal];
    [add addTarget:vc action:@selector(bkAdd:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:add];

    UIButton *sens = [UIButton buttonWithType:UIButtonTypeSystem];
    sens.frame = CGRectMake(114, 54, 80, 30);
    [sens setTitle:[NSString stringWithFormat:@"Sens %.1f", gSens] forState:UIControlStateNormal];
    sens.titleLabel.font = [UIFont systemFontOfSize:11];
    [sens addTarget:vc action:@selector(bkSens:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:sens];

    UIButton *test = [UIButton buttonWithType:UIButtonTypeSystem];
    test.frame = CGRectMake(198, 54, 60, 30);
    [test setTitle:@"Testar" forState:UIControlStateNormal];
    test.titleLabel.font = [UIFont systemFontOfSize:11];
    [test addTarget:vc action:@selector(bkTest:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:test];

    gAtivoBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gAtivoBtn.frame = CGRectMake(14, 90, 76, 26);
    gAtivoBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    [gAtivoBtn addTarget:vc action:@selector(bkPower:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:gAtivoBtn];

    gMarcasBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gMarcasBtn.frame = CGRectMake(94, 90, 76, 26);
    gMarcasBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    [gMarcasBtn addTarget:vc action:@selector(bkMarks:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:gMarcasBtn];

    gRotBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gRotBtn.frame = CGRectMake(174, 90, 84, 26);
    gRotBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    [gRotBtn addTarget:vc action:@selector(bkRot:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:gRotBtn];

    gDiag = [[UILabel alloc] initWithFrame:CGRectMake(14, gPanel.bounds.size.height - 20, 244, 14)];
    gDiag.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightRegular];
    gDiag.textColor = UIColor.lightGrayColor;
    [gPanel addSubview:gDiag];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(14, 124, 244, gPanel.bounds.size.height - 148)];
    sv.alwaysBounceVertical = YES;
    [gPanel addSubview:sv];

    gStack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 236, 0)];
    gStack.axis = UILayoutConstraintAxisVertical;
    gStack.spacing = 6;
    [sv addSubview:gStack];

    gPanel.hidden = !gPanelOpen;
    w.hidden = NO;
    BKRefresh();
}

#pragma mark - Acoes

@implementation BKRootView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v != self) return v;
    if (gStep == 2) return self;
    return nil;
}
@end

@implementation BKRoot

- (void)bkTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:gRootView];
    if (gStep != 2 || !gPending) return;
    if (!gPanel.hidden && CGRectContainsPoint(gPanel.frame, p)) return;
    gPending[@"x"] = @(p.x);
    gPending[@"y"] = @(p.y);
    gPending = nil;
    BKSetStep(0, nil);
    gPanel.hidden = !gPanelOpen;
    BKSave();
    BKRefresh();
}

- (void)bkAdd:(UIButton *)b {
    if (gStep != 0) { BKSetStep(0, nil); return; }
    BKSetStep(1, @"Pressione uma tecla ou botao do mouse (Esc cancela)");
}

- (void)bkMove:(UIButton *)b {
    if (b.tag >= gBinds.count) return;
    gPending = gBinds[b.tag];
    gPanel.hidden = YES;
    BKSetStep(2, @"Toque na tela para posicionar (Esc cancela)");
}

- (void)bkDelete:(UIButton *)b {
    if (b.tag >= gBinds.count) return;
    [gBinds removeObjectAtIndex:b.tag];
    [gHeld removeAllObjects];
    BKSave();
    BKRefresh();
}

- (void)bkPower:(UIButton *)b {
    gEnabled = !gEnabled;
    if (!gEnabled) BKReleaseAll();
    BKSave();
    BKRefresh();
}

- (void)bkMarks:(UIButton *)b { gShowMarks = !gShowMarks; BKSave(); BKRefresh(); }
- (void)bkRot:(UIButton *)b { gFixRotation = !gFixRotation; BKSave(); BKRefresh(); }

- (void)bkSens:(UIButton *)b {
    gSens = gSens >= 4.0 ? 0.4 : gSens + 0.4;
    [b setTitle:[NSString stringWithFormat:@"Sens %.1f", gSens] forState:UIControlStateNormal];
    BKSave();
}

- (void)bkTest:(UIButton *)b {
    gPointer.hidden = NO;
    gPointer.center = gPtr;
    BKInject(gPtr, YES, 8);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKInject(gPtr, NO, 8);
    });
}

- (void)bkToggle:(id)sender {
    gPanelOpen = !gPanelOpen;
    gPanel.hidden = !gPanelOpen;
    BKSave();
}

- (void)bkDrag:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:gRootView];
    CGSize s = gRootView.bounds.size;
    gBall.center = CGPointMake(MAX(22, MIN(s.width - 22, p.x)), MAX(22, MIN(s.height - 22, p.y)));
}

@end

#pragma mark - Entrada

static void BKKey(int c, BOOL down) {
    if (gStep == 1) {
        if (!down) return;
        if (c == 41) { BKSetStep(0, nil); return; }
        if (BKIndexOf(c) >= 0) { BKSetStep(1, @"Tecla ja usada, escolha outra"); return; }
        NSMutableDictionary *nb = [@{ @"k": @(c), @"x": @(0), @"y": @(0) } mutableCopy];
        [gBinds addObject:nb];
        gPending = nb;
        gPanel.hidden = YES;
        BKSetStep(2, @"Toque na tela para posicionar (Esc cancela)");
        BKSave();
        BKRefresh();
        return;
    }
    if (gStep == 2) {
        if (down && c == 41) {
            if (gPending && [gPending[@"x"] doubleValue] == 0 && [gPending[@"y"] doubleValue] == 0) {
                [gBinds removeObject:gPending];
            }
            gPending = nil;
            BKSetStep(0, nil);
            gPanel.hidden = !gPanelOpen;
            BKSave();
            BKRefresh();
        }
        return;
    }
    if (!gEnabled) return;
    NSInteger i = BKIndexOf(c);
    if (i < 0) return;
    if (down) BKDown(c, CGPointMake([gBinds[i][@"x"] doubleValue], [gBinds[i][@"y"] doubleValue]));
    else BKUp(c);
}

static void BKMouseButton(int c, BOOL down) {
    if (gStep == 1 || gStep == 2) { if (down) BKKey(c, down); return; }
    if (!gEnabled) return;

    if (c == BK_LEFT) {
        if (BKIndexOf(BK_LEFT) >= 0) { down ? BKDown(BK_LEFT, gPtr) : BKUp(BK_LEFT); return; }
        if (down) { gLeftHeld = YES; BKInject(gPtr, YES, gDragFinger); }
        else if (gLeftHeld) { BKInject(gPtr, NO, gDragFinger); gLeftHeld = NO; }
        return;
    }
    if (c == BK_RIGHT && BKIndexOf(BK_RIGHT) < 0) {
        if (down) dispatch_async(dispatch_get_main_queue(), ^{
            gPanelOpen = !gPanelOpen;
            gPanel.hidden = !gPanelOpen;
            BKSave();
        });
        return;
    }
    if (BKIndexOf(c) >= 0) { down ? BKDown(c, gPtr) : BKUp(c); }
}

static void BKMouseMove(float dx, float dy) {
    if (!gEnabled) return;
    CGSize s = gRootView.bounds.size;
    gPtr.x = MAX(0, MIN(s.width,  gPtr.x + dx * gSens));
    gPtr.y = MAX(0, MIN(s.height, gPtr.y + dy * gSens));
    dispatch_async(dispatch_get_main_queue(), ^{
        gPointer.hidden = NO;
        gPointer.center = gPtr;
    });
    if (gLeftHeld && BKIndexOf(BK_LEFT) < 0) BKInject(gPtr, YES, gDragFinger);
}

static id gGameKey = nil;
static id gGameMove = nil;

static void BKInstallKeyboard(GCKeyboard *kb) {
    if (!kb) return;
    GCKeyboardInput *in = kb.keyboardInput;
    if (!in) return;
    in.keyChangedHandler = ^(GCKeyboardInput *k, GCControllerButtonInput *b, GCKeyCode code, BOOL pressed) {
        if (gGameKey) ((void (^)(GCKeyboardInput *, GCControllerButtonInput *, GCKeyCode, BOOL))gGameKey)(k, b, code, pressed);
        BKKey((int)code, pressed);
    };
}

static void BKInstallMouse(GCMouse *m) {
    if (!m) return;
    GCMouseInput *in = m.mouseInput;
    if (!in) return;
    in.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) {
        if (gGameMove) ((void (^)(GCMouseInput *, float, float))gGameMove)(mi, dx, dy);
        BKMouseMove(dx, dy);
    };
    in.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) {
        BKMouseButton(BK_LEFT, p);
    };
    in.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) {
        BKMouseButton(BK_RIGHT, p);
    };
    if (in.middleButton) in.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) {
        BKMouseButton(BK_MIDDLE, p);
    };
}

static void BKInstallInput(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BKInstallKeyboard(GCKeyboard.coalescedKeyboard);
        BKInstallMouse(GCMouse.current);
    });
}

static void BKReapplyInput(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        GCKeyboard *kb = GCKeyboard.coalescedKeyboard;
        if (kb && kb.keyboardInput.keyChangedHandler == nil) BKInstallKeyboard(kb);
        GCMouse *m = GCMouse.current;
        if (m && m.mouseInput.mouseMovedHandler == nil) BKInstallMouse(m);
    });
}

#pragma mark - Ciclo de vida

__attribute__((constructor))
static void BKInit(void) {
    gHeld = [NSMutableDictionary dictionary];
    BKLoad();
    BKSetupInject();

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKInstallInput();
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallHUD(); });
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallHUD(); });
    }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKReleaseAll();
    }];
    [nc addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKInstallInput();
    }];
    [nc addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKInstallInput();
    }];
    [nc addObserverForName:UISceneDidActivateNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallHUD(); });
    }];

    __block int tries = 0;
    NSTimer *t = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        tries++;
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallHUD(); });
        BKReapplyInput();
        if (tries > 30) [tm invalidate];
    }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
}
