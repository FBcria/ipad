//
//  NativeInput — teclado e mouse -> toque nativo
//  Injecao por UITouch + sendEvent (funciona em app assinado, sem entitlement)
//  HID direto mantido como reserva (TrollStore/jailbreak).
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

#define BK_D_X        0xB0001
#define BK_D_Y        0xB0002
#define BK_D_MASK     0xB0004
#define BK_D_TYPE     0xB0005
#define BK_D_EVMASK   0xB0008
#define BK_D_RANGE    0xB0009
#define BK_D_TOUCH    0xB000A
#define BK_D_DISPLAY  0xB0019
#define BK_T_X        0x40001
#define BK_T_Y        0x40002
#define BK_T_DIGITIZER 11
#define BK_T_TRANSLATION 4

#define BK_M_POS  0x04
#define BK_M_RT   0x03
#define BK_SENDER 0xDEFACEDBEEFFECE5ULL

#define BK_LEFT   (-1)
#define BK_RIGHT  (-2)
#define BK_MIDDLE (-3)
#define BK_FWD    (-4)
#define BK_BACK   (-5)

#pragma mark - Privados

@interface UIApplication (BKPriv)
- (UIEvent *)_touchesEvent;
- (void)_setPointerLocked:(BOOL)locked;
@end

@interface UIEvent (BKPriv)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)delayed;
- (void)_setHIDEvent:(IOHIDEventRef)event;
@end

@interface UITouch (BKPriv)
- (void)setWindow:(UIWindow *)w;
- (void)setView:(UIView *)v;
- (void)setPhase:(UITouchPhase)p;
- (void)setTimestamp:(NSTimeInterval)t;
- (void)setGestureView:(UIView *)v;
- (void)setIsTap:(BOOL)b;
- (void)_setIsFirstTouchForView:(BOOL)b;
- (void)_setLocationInWindow:(CGPoint)p resetPrevious:(BOOL)r;
- (void)_setHidEvent:(IOHIDEventRef)e;
@end

@interface UIScene (BKPriv)
- (void)_setPointerLocked:(BOOL)locked;
@end

#pragma mark - Estado

static NSMutableArray<NSMutableDictionary *> *gBinds;
static NSMutableDictionary<NSNumber *, NSNumber *> *gHeld;
static NSMutableDictionary<NSNumber *, UITouch *> *gTouches;

static UIWindow *gHUD;
static UIView *gRootView;
static UIView *gPanel;
static UIView *gBall;
static UIView *gPointer;
static UIView *gBanner;
static UIScrollView *gScroll;
static NSMutableArray<UIView *> *gRows;
static UILabel *gHint;
static UILabel *gStatus;
static UILabel *gDiag;
static NSMutableArray<UIView *> *gMarks;
static UIButton *gAtivoBtn, *gMarcasBtn, *gSetaBtn, *gRotBtn, *gSumirBtn;

static BOOL gEnabled = YES;
static BOOL gPanelOpen = YES;
static BOOL gShowMarks = NO;
static BOOL gShowPtr = YES;
static BOOL gFixRotation = YES;
static CGFloat gSens = 1.6;
static CGPoint gPtr;

static NSInteger gStep = 0;
static NSMutableDictionary *gPending = nil;
static BOOL gLeftHeld = NO;
static uint32_t gDragFinger = 9;
static int gBtnMask = 0;
static BOOL gHidSeen = NO;
static BOOL gTouchOK = NO;

static int gKeyCount = 0;
static int gMouseCount = 0;

static uint64_t gSenderID = 0;
static void *gHIDClient = NULL;
static void (*fnDispatch)(void *, IOHIDEventRef) = NULL;
static void (*fnSetSender)(IOHIDEventRef, uint64_t) = NULL;
static uint64_t (*fnGetSender)(IOHIDEventRef) = NULL;
static void (*fnSetMatching)(void *, CFDictionaryRef) = NULL;
static void (*fnSetQueue)(void *, dispatch_queue_t) = NULL;
static void *gMonitor[3] = {NULL, NULL, NULL};
static int gMonitorCount = 0;
static id gMonitorBlock = nil;

static void (*orig_setKeyChanged)(id, SEL, id) = NULL;
static void (*orig_setMouseMoved)(id, SEL, id) = NULL;

#pragma mark - Prototipos

static void BKKey(int c, BOOL down);
static void BKMouseButton(int c, BOOL down);
static void BKMouseMove(float dx, float dy);
static void BKPtrSync(void);
static void BKDiag(void);
static void BKRefresh(void);

#pragma mark - HID (reserva)

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
        void *createT = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");
        void *create = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        fnDispatch = (void (*)(void *, IOHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        fnGetSender = (uint64_t (*)(IOHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetSenderID");
        fnSetSender = (void (*)(IOHIDEventRef, uint64_t))dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        fnSetMatching = (void (*)(void *, CFDictionaryRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetMatching");
        fnSetQueue = (void (*)(void *, dispatch_queue_t))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetDispatchQueue");

        if (fnDispatch) {
            if (createT) gHIDClient = ((void *(*)(CFAllocatorRef, int, void *))createT)(kCFAllocatorDefault, 1, NULL);
            if (!gHIDClient && create) gHIDClient = ((void *(*)(CFAllocatorRef))create)(kCFAllocatorDefault);
        }
        BKStartMonitor();
    });
}

static void BKStartMonitor(void) {
    void *reg = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventBlock");
    void *sched = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
    void *createT = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");
    void *create = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    if (!reg) return;

    void (^blk)(void *, void *, void *, IOHIDEventRef) = ^(void *t, void *r, void *s, IOHIDEventRef e) {
        if (!e) return;
        int type = (int)IOHIDEventGetType(e);

        if (type == BK_T_DIGITIZER) {
            int dt = (int)IOHIDEventGetIntegerValue(e, BK_D_TYPE);
            if (dt == 3) {
                uint64_t sid = fnGetSender ? fnGetSender(e) : 0;
                if (sid) gSenderID = sid;
                return;
            }
            if (dt < 4) return;

            double dx = IOHIDEventGetFloatValue(e, BK_D_X);
            double dy = IOHIDEventGetFloatValue(e, BK_D_Y);
            if (dx != 0 || dy != 0) {
                gHidSeen = YES;
                gMouseCount++;
                BKMouseMove((float)dx, (float)dy);
            }
            int mask = (int)IOHIDEventGetIntegerValue(e, BK_D_MASK);
            if (mask != gBtnMask) {
                gHidSeen = YES;
                BOOL l = (mask & 1) != 0, rt = (mask & 2) != 0, md = (mask & 4) != 0;
                if (l  != ((gBtnMask & 1) != 0)) BKMouseButton(BK_LEFT, l);
                if (rt != ((gBtnMask & 2) != 0)) BKMouseButton(BK_RIGHT, rt);
                if (md != ((gBtnMask & 4) != 0)) BKMouseButton(BK_MIDDLE, md);
                gBtnMask = mask;
            }
            return;
        }

        if (type == BK_T_TRANSLATION) {
            double dx = IOHIDEventGetFloatValue(e, BK_T_X);
            double dy = IOHIDEventGetFloatValue(e, BK_T_Y);
            if (dx != 0 || dy != 0) {
                gHidSeen = YES;
                gMouseCount++;
                BKMouseMove((float)dx, (float)dy);
            }
        }
    };
    gMonitorBlock = [blk copy];

    int types[3] = {2, 1, 0};
    for (int i = 0; i < 3; i++) {
        void *cl = NULL;
        if (createT) cl = ((void *(*)(CFAllocatorRef, int, void *))createT)(kCFAllocatorDefault, types[i], NULL);
        else if (i == 0 && create) cl = ((void *(*)(CFAllocatorRef))create)(kCFAllocatorDefault);
        if (!cl) continue;

        if (fnSetMatching) {
            NSDictionary *m = @{ @"PrimaryUsagePage": @(0x0D), @"PrimaryUsage": @(0x04) };
            fnSetMatching(cl, (__bridge CFDictionaryRef)m);
        }
        ((void (*)(void *, void *, void *, void *))reg)(cl, (__bridge void *)gMonitorBlock, NULL, NULL);
        if (i == 0 && fnSetQueue) fnSetQueue(cl, dispatch_get_main_queue());
        else if (sched) ((void (*)(void *, CFRunLoopRef, CFStringRef))sched)(cl, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        gMonitor[gMonitorCount++] = cl;
    }
}

static CGPoint BKToDevice(CGPoint p) {
    CGSize s = UIScreen.mainScreen.bounds.size;
    CGFloat Wp = MIN(s.width, s.height), Hp = MAX(s.width, s.height);
    CGPoint q = p;
    if (gFixRotation) {
        UIInterfaceOrientation o = gHUD.windowScene.interfaceOrientation;
        switch (o) {
            case UIInterfaceOrientationLandscapeLeft:  q = CGPointMake(Wp - p.y, p.x); break;
            case UIInterfaceOrientationLandscapeRight: q = CGPointMake(p.y, Hp - p.x); break;
            case UIInterfaceOrientationPortraitUpsideDown: q = CGPointMake(Wp - p.x, Hp - p.y); break;
            default: break;
        }
    }
    return CGPointMake(q.x / Wp, q.y / Hp);
}

static void BKHIDInject(CGPoint p, BOOL down, uint32_t idx) {
    BKSetupInject();
    CGPoint n = BKToDevice(p);
    AbsoluteTime ts = BKNow();

    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand, 0, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return;

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault, ts, idx, idx + 2, down ? BK_M_RT : BK_M_POS,
        n.x, n.y, 0, 0, 0, 0, 0, 0, 0, 0, down, down, 0);
    if (finger) {
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
    }

    IOHIDEventSetIntegerValue(hand, BK_D_EVMASK, down ? BK_M_RT : BK_M_POS);
    IOHIDEventSetIntegerValue(hand, BK_D_RANGE, down);
    IOHIDEventSetIntegerValue(hand, BK_D_TOUCH, down);
    IOHIDEventSetIntegerValue(hand, BK_D_DISPLAY, 1);
    if (fnSetSender) fnSetSender(hand, gSenderID ? gSenderID : BK_SENDER);

    if (gHIDClient && fnDispatch) fnDispatch(gHIDClient, hand);
    CFRelease(hand);
}

#pragma mark - Injecao por UITouch

static UIWindow *BKGameWindow(void) {
    UIWindow *best = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w == gHUD || w.hidden) continue;
        if (!best || w.windowLevel < best.windowLevel) best = w;
    }
    return best;
}

static IOHIDEventRef BKTouchHID(UITouch *t) {
    AbsoluteTime ts = BKNow();
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand, 0, 0,
        kIOHIDDigitizerEventTouch, 0, 0, 0, 0, 0, 0, 0, 1, 0);
    if (!hand) return NULL;
    IOHIDEventSetIntegerValue(hand, BK_D_DISPLAY, 1);

    CGPoint loc = [t locationInView:t.window];
    BOOL moved = (t.phase == UITouchPhaseMoved);
    uint32_t mask = moved ? BK_M_POS : BK_M_RT;
    BOOL touching = (t.phase != UITouchPhaseEnded);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault, ts, 1, 2, mask,
        loc.x, loc.y, 0, 0, 0, 5.0, 5.0, 1.0, 1.0, 1.0,
        touching, touching, 0);
    if (finger) {
        IOHIDEventSetIntegerValue(finger, BK_D_DISPLAY, 1);
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
    }
    return hand;
}

static void BKSend(UITouch *t) {
    UIApplication *app = UIApplication.sharedApplication;
    UIEvent *ev = ((UIEvent *(*)(id, SEL))objc_msgSend)(app, @selector(_touchesEvent));
    if (!ev) return;
    ((void (*)(id, SEL))objc_msgSend)(ev, @selector(_clearTouches));

    IOHIDEventRef hid = BKTouchHID(t);
    if (hid) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(ev, @selector(_setHIDEvent:), hid);
        CFRelease(hid);
    }
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ev, @selector(_addTouch:forDelayedDelivery:), t, NO);
    [app sendEvent:ev];
    gTouchOK = YES;
}

static UITouch *BKTouchCreate(CGPoint p, UIWindow *gw) {
    UITouch *t = [UITouch new];
    ((void (*)(id, SEL, id))objc_msgSend)(t, @selector(setWindow:), gw);
    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(t, @selector(_setLocationInWindow:resetPrevious:), p, YES);

    UIView *hv = [gw hitTest:p withEvent:nil];
    ((void (*)(id, SEL, id))objc_msgSend)(t, @selector(setView:), hv);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(t, @selector(setPhase:), (NSInteger)UITouchPhaseBegan);

    if ([t respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(t, @selector(setIsTap:), YES);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(t, @selector(_setIsFirstTouchForView:), YES);
    }
    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(t, @selector(setTimestamp:), NSProcessInfo.processInfo.systemUptime);
    if ([t respondsToSelector:@selector(setGestureView:)])
        ((void (*)(id, SEL, id))objc_msgSend)(t, @selector(setGestureView:), hv);

    IOHIDEventRef hid = BKTouchHID(t);
    if (hid) {
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(t, @selector(_setHidEvent:), hid);
        CFRelease(hid);
    }
    return t;
}

static void BKInjectNow(CGPoint p, BOOL down, uint32_t idx) {
    UIWindow *gw = BKGameWindow();
    if (!gw) { BKHIDInject(p, down, idx); return; }
    if (!gTouches) gTouches = [NSMutableDictionary dictionary];

    NSNumber *k = @(idx);
    UITouch *t = gTouches[k];

    if (down) {
        if (t) {
            ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(t, @selector(_setLocationInWindow:resetPrevious:), p, NO);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(t, @selector(setPhase:), (NSInteger)UITouchPhaseMoved);
            ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(t, @selector(setTimestamp:), NSProcessInfo.processInfo.systemUptime);
            BKSend(t);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(t, @selector(setPhase:), (NSInteger)UITouchPhaseStationary);
            return;
        }
        t = BKTouchCreate(p, gw);
        if (!t) { BKHIDInject(p, down, idx); return; }
        gTouches[k] = t;
        BKSend(t);
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(t, @selector(setPhase:), (NSInteger)UITouchPhaseStationary);
    } else {
        if (!t) return;
        ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(t, @selector(_setLocationInWindow:resetPrevious:), p, NO);
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(t, @selector(setPhase:), (NSInteger)UITouchPhaseEnded);
        ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(t, @selector(setTimestamp:), NSProcessInfo.processInfo.systemUptime);
        BKSend(t);
        [gTouches removeObjectForKey:k];
    }
}

static void BKInject(CGPoint p, BOOL down, uint32_t idx) {
    if (NSThread.isMainThread) BKInjectNow(p, down, idx);
    else dispatch_async(dispatch_get_main_queue(), ^{ BKInjectNow(p, down, idx); });
}

static void BKDiag(void) {
    GCKeyboard *kb = GCKeyboard.coalescedKeyboard;
    GCMouse *m = GCMouse.current;
    NSString *via = gTouchOK ? @"ui" : (gHIDClient && fnDispatch ? @"hid" : @"NONE");
    NSString *t = [NSString stringWithFormat:@"k%d m%d dev%d%d cl%d %@%@", gKeyCount, gMouseCount,
                   kb ? 1 : 0, m ? 1 : 0, gMonitorCount, via, gHidSeen ? @" +hid" : @""];
    if (![gDiag.text isEqualToString:t]) {
        gDiag.text = t;
        gDiag.textColor = [via isEqualToString:@"NONE"] ? UIColor.systemRedColor : UIColor.lightGrayColor;
    }
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
    gBtnMask = 0;
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
                         @"ptr": @(gShowPtr),
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
    if (r[@"ptr"])   gShowPtr = [r[@"ptr"] boolValue];
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

static void BKPtrSync(void) {
    if (!gPointer) return;
    gPointer.hidden = !gShowPtr;
    if (gShowPtr) gPointer.center = gPtr;
}

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

static void BKToggleStyle(UIButton *b, BOOL on) {
    [b setTitleColor:(on ? [UIColor colorWithRed:0.3 green:0.95 blue:0.55 alpha:1] : UIColor.grayColor)
            forState:UIControlStateNormal];
    b.layer.borderWidth = 1;
    b.layer.cornerRadius = 6;
    b.layer.borderColor = (on ? [UIColor colorWithRed:0.3 green:0.95 blue:0.55 alpha:0.7].CGColor
                              : [UIColor colorWithWhite:1 alpha:0.2].CGColor);
}

static void BKRefresh(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ BKRefresh(); }); return; }

    for (UIView *v in gRows) [v removeFromSuperview];
    [gRows removeAllObjects];

    if (gBinds.count == 0) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(2, 4, 232, 44)];
        l.text = @"Nenhum bind.\nToque em + Bind e pressione uma tecla.";
        l.numberOfLines = 0;
        l.font = [UIFont systemFontOfSize:11];
        l.textColor = UIColor.lightGrayColor;
        [gScroll addSubview:l];
        [gRows addObject:l];
    }

    CGFloat y = 0;
    for (NSUInteger i = 0; i < gBinds.count; i++) {
        NSMutableDictionary *b = gBinds[i];
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, 236, 30)];
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

        [gScroll addSubview:row];
        [gRows addObject:row];
        y += 36;
    }

    gScroll.contentSize = CGSizeMake(244, y);
    gStatus.text = gEnabled ? @"ATIVO" : @"PAUSADO";
    gStatus.textColor = gEnabled ? [UIColor colorWithRed:0.3 green:0.95 blue:0.55 alpha:1] : UIColor.systemOrangeColor;
    BKToggleStyle(gAtivoBtn, gEnabled);
    BKToggleStyle(gMarcasBtn, gShowMarks);
    BKToggleStyle(gSetaBtn, gShowPtr);
    BKToggleStyle(gRotBtn, gFixRotation);
    BKMarkers();
    BKPtrSync();
    BKDiag();
}

static void BKSetStep(NSInteger s, NSString *msg) {
    gStep = s;
    gBanner.hidden = (s == 0);
    gHint.text = msg ?: @"";
}

@interface BKWindow : UIWindow
@end

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

    BKWindow *w = [[BKWindow alloc] initWithWindowScene:sc];
    w.frame = sc.coordinateSpace.bounds;
    w.windowLevel = UIWindowLevelAlert - 1;
    w.backgroundColor = UIColor.clearColor;

    BKRoot *vc = [BKRoot new];
    w.rootViewController = vc;
    gHUD = w;
    gRootView = vc.view;
    gRootView.backgroundColor = UIColor.clearColor;

    gMarks = [NSMutableArray array];
    gRows = [NSMutableArray array];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(bkTap:)];
    tap.cancelsTouchesInView = NO;
    [gRootView addGestureRecognizer:tap];

    CGSize s = w.bounds.size;

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
    gAtivoBtn.frame = CGRectMake(14, 90, 44, 26);
    gAtivoBtn.titleLabel.font = [UIFont systemFontOfSize:9];
    [gAtivoBtn setTitle:@"Ativo" forState:UIControlStateNormal];
    [gAtivoBtn addTarget:vc action:@selector(bkPower:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:gAtivoBtn];

    gMarcasBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gMarcasBtn.frame = CGRectMake(63, 90, 44, 26);
    gMarcasBtn.titleLabel.font = [UIFont systemFontOfSize:9];
    [gMarcasBtn setTitle:@"Marca" forState:UIControlStateNormal];
    [gMarcasBtn addTarget:vc action:@selector(bkMarks:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:gMarcasBtn];

    gSetaBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gSetaBtn.frame = CGRectMake(112, 90, 44, 26);
    gSetaBtn.titleLabel.font = [UIFont systemFontOfSize:9];
    [gSetaBtn setTitle:@"Seta" forState:UIControlStateNormal];
    [gSetaBtn addTarget:vc action:@selector(bkPtr:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:gSetaBtn];

    gRotBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gRotBtn.frame = CGRectMake(161, 90, 44, 26);
    gRotBtn.titleLabel.font = [UIFont systemFontOfSize:9];
    [gRotBtn setTitle:@"Girar" forState:UIControlStateNormal];
    [gRotBtn addTarget:vc action:@selector(bkRot:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:gRotBtn];

    gSumirBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gSumirBtn.frame = CGRectMake(210, 90, 44, 26);
    gSumirBtn.titleLabel.font = [UIFont systemFontOfSize:9];
    [gSumirBtn setTitle:@"Sumir" forState:UIControlStateNormal];
    [gSumirBtn addTarget:vc action:@selector(bkSumir:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:gSumirBtn];

    gDiag = [[UILabel alloc] initWithFrame:CGRectMake(14, gPanel.bounds.size.height - 20, 244, 14)];
    gDiag.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightRegular];
    gDiag.textColor = UIColor.lightGrayColor;
    [gPanel addSubview:gDiag];

    gScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(14, 124, 244, gPanel.bounds.size.height - 148)];
    gScroll.alwaysBounceVertical = YES;
    [gPanel addSubview:gScroll];

    gPointer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    gPointer.backgroundColor = [UIColor colorWithRed:1 green:0.25 blue:0.35 alpha:0.55];
    gPointer.layer.cornerRadius = 9;
    gPointer.layer.borderWidth = 1.5;
    gPointer.layer.borderColor = [UIColor colorWithRed:1 green:0.35 blue:0.45 alpha:1].CGColor;
    gPointer.userInteractionEnabled = NO;
    [gRootView addSubview:gPointer];
    gPtr = CGPointMake(s.width / 2, s.height / 2);
    BKPtrSync();

    gPanel.hidden = !gPanelOpen;
    [w makeKeyAndVisible];
    [vc becomeFirstResponder];
    [vc setNeedsUpdateOfPrefersPointerLocked];
    BKRefresh();
}

#pragma mark - Janela e root

@implementation BKWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    if (gStep == 2) return gRootView;
    UIView *v = [super hitTest:p withEvent:e];
    if (!v || v == self || v == gRootView) return nil;
    return v;
}
@end

@implementation BKRootView
@end

@implementation BKRoot

- (void)loadView {
    self.view = [[BKRootView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (BOOL)prefersPointerLocked { return YES; }

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) {
        if (!p.key) continue;
        gKeyCount++;
        BKKey((int)p.key.keyCode, YES);
    }
    [super pressesBegan:presses withEvent:event];
    BKDiag();
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) {
        if (!p.key) continue;
        BKKey((int)p.key.keyCode, NO);
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self pressesEnded:presses withEvent:event];
}

- (void)bkSumir:(UIButton *)b {
    gHUD.hidden = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        gHUD.hidden = NO;
        BKRefresh();
    });
}

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
- (void)bkPtr:(UIButton *)b { gShowPtr = !gShowPtr; BKSave(); BKRefresh(); }
- (void)bkRot:(UIButton *)b { gFixRotation = !gFixRotation; BKSave(); BKRefresh(); }

- (void)bkSens:(UIButton *)b {
    gSens = gSens >= 4.0 ? 0.4 : gSens + 0.4;
    [b setTitle:[NSString stringWithFormat:@"Sens %.1f", gSens] forState:UIControlStateNormal];
    BKSave();
}

- (void)bkTest:(UIButton *)b {
    gShowPtr = YES;
    BKPtrSync();
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
    if (BKIndexOf(c) >= 0) { down ? BKDown(c, gPtr) : BKUp(c); }
}

static void BKMouseMove(float dx, float dy) {
    if (!gEnabled) return;
    CGSize s = gRootView.bounds.size;
    gPtr.x = MAX(0, MIN(s.width,  gPtr.x + dx * gSens));
    gPtr.y = MAX(0, MIN(s.height, gPtr.y + dy * gSens));
    dispatch_async(dispatch_get_main_queue(), ^{ BKPtrSync(); });
    if (gLeftHeld && BKIndexOf(BK_LEFT) < 0) BKInject(gPtr, YES, gDragFinger);
}

#pragma mark - Handlers

static id gGameKey = nil;
static id gGameMove = nil;

static id BKKeyBlock(void) {
    static id blk;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        blk = [^void(GCKeyboardInput *k, GCControllerButtonInput *b, GCKeyCode code, BOOL pressed) {
            if (gGameKey) ((void (^)(GCKeyboardInput *, GCControllerButtonInput *, GCKeyCode, BOOL))gGameKey)(k, b, code, pressed);
            gKeyCount++;
            BKKey((int)code, pressed);
            BKDiag();
        } copy];
    });
    return blk;
}

static id BKMouseBlock(void) {
    static id blk;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        blk = [^void(GCMouseInput *mi, float dx, float dy) {
            if (gGameMove) ((void (^)(GCMouseInput *, float, float))gGameMove)(mi, dx, dy);
            if (!gHidSeen) {
                gMouseCount++;
                BKMouseMove(dx, dy);
            }
        } copy];
    });
    return blk;
}

static void BKSetKeyChanged(id self, SEL _cmd, id handler) {
    gGameKey = (handler == BKKeyBlock()) ? nil : [handler copy];
    orig_setKeyChanged(self, _cmd, BKKeyBlock());
}

static void BKSetMouseMoved(id self, SEL _cmd, id handler) {
    gGameMove = (handler == BKMouseBlock()) ? nil : [handler copy];
    orig_setMouseMoved(self, _cmd, BKMouseBlock());
}

static void BKSwizzle(Class cls, SEL sel, IMP imp, void **orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, imp);
}

static void BKSetupSwizzle(void) {
    BKSwizzle(objc_getClass("GCKeyboardInput"), @selector(setKeyChangedHandler:), (IMP)BKSetKeyChanged, (void **)&orig_setKeyChanged);
    BKSwizzle(objc_getClass("GCMouseInput"), @selector(setMouseMovedHandler:), (IMP)BKSetMouseMoved, (void **)&orig_setMouseMoved);
}

static void BKInstallKeyboard(GCKeyboard *kb) {
    if (!kb) return;
    GCKeyboardInput *in = kb.keyboardInput;
    if (!in) return;
    if (orig_setKeyChanged) orig_setKeyChanged(in, @selector(setKeyChangedHandler:), in.keyChangedHandler);
    else in.keyChangedHandler = BKKeyBlock();
}

static void BKInstallMouse(GCMouse *m) {
    if (!m) return;
    GCMouseInput *in = m.mouseInput;
    if (!in) return;

    if (orig_setMouseMoved) orig_setMouseMoved(in, @selector(setMouseMovedHandler:), in.mouseMovedHandler);
    else in.mouseMovedHandler = BKMouseBlock();

    SEL v2 = sel_registerName("setMouseMovedHandlerV2:");
    if ([in respondsToSelector:v2])
        ((void (*)(id, SEL, id))objc_msgSend)(in, v2, BKMouseBlock());

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

static void BKTick(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        GCKeyboard *kb = GCKeyboard.coalescedKeyboard;
        if (kb) BKInstallKeyboard(kb);
        GCMouse *m = GCMouse.current;
        if (m) BKInstallMouse(m);

        if (gHUD) {
            UIViewController *vc = gHUD.rootViewController;
            if ([vc respondsToSelector:@selector(setNeedsUpdateOfPrefersPointerLocked)])
                [vc setNeedsUpdateOfPrefersPointerLocked];

            UIScene *sc = gHUD.windowScene;
            if ([sc respondsToSelector:@selector(_setPointerLocked:)])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(sc, @selector(_setPointerLocked:), YES);
            if ([UIApplication.sharedApplication respondsToSelector:@selector(_setPointerLocked:)])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(UIApplication.sharedApplication, @selector(_setPointerLocked:), YES);
        }
        BKDiag();
    });
}

static void BKCurrent(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKTick();
    });
}

#pragma mark - Ciclo de vida

__attribute__((constructor))
static void BKInit(void) {
    gHeld = [NSMutableDictionary dictionary];
    gTouches = [NSMutableDictionary dictionary];
    BKLoad();
    BKSetupInject();
    BKSetupSwizzle();

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKTick();
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallHUD(); });
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallHUD(); });
        BKTick();
    }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKReleaseAll();
    }];
    [nc addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKCurrent();
    }];
    [nc addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKCurrent();
    }];
    [nc addObserverForName:@"GCKeyboardDidBecomeCurrentNotification" object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKCurrent();
    }];
    [nc addObserverForName:@"GCMouseDidBecomeCurrentNotification" object:nil queue:nil usingBlock:^(NSNotification *n) {
        BKCurrent();
    }];
    [nc addObserverForName:UISceneDidActivateNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallHUD(); });
    }];

    __block int tries = 0;
    NSTimer *t = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        tries++;
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallHUD(); });
        BKTick();
        if (tries > 300) [tm invalidate];
    }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
}
