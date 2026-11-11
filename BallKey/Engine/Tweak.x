#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <math.h>

typedef void *BKIOHIDEventSystemClientRef;
typedef void *BKIOHIDEventRef;

typedef struct {
    BKIOHIDEventSystemClientRef (*ClientCreate)(CFAllocatorRef);
    BKIOHIDEventSystemClientRef (*ClientCreateType)(CFAllocatorRef, uint32_t, CFDictionaryRef);
    void (*SetMatching)(BKIOHIDEventSystemClientRef, CFDictionaryRef);
    void (*SetQueue)(BKIOHIDEventSystemClientRef, dispatch_queue_t);
    void (*ScheduleRL)(BKIOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    void (*RegisterCB)(BKIOHIDEventSystemClientRef, void *, void *, void *);
    void (*Activate)(BKIOHIDEventSystemClientRef);
    void (*Dispatch)(BKIOHIDEventSystemClientRef, BKIOHIDEventRef);
    int  (*GetType)(BKIOHIDEventRef);
    int  (*GetInt)(BKIOHIDEventRef, uint32_t);
    double (*GetFloat)(BKIOHIDEventRef, uint32_t);
    uint64_t (*GetSender)(BKIOHIDEventRef);
    void (*SetInt)(BKIOHIDEventRef, uint32_t, int);
    void (*SetFloat)(BKIOHIDEventRef, uint32_t, double);
    void (*SetSender)(BKIOHIDEventRef, uint64_t);
    void (*Append)(BKIOHIDEventRef, BKIOHIDEventRef, uint32_t);
    BKIOHIDEventRef (*CreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
        uint32_t, uint32_t, uint32_t, double, double, double, double, double,
        uint8_t, uint8_t, uint32_t);
    BKIOHIDEventRef (*CreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        double, double, double, double, double, uint8_t, uint8_t, uint32_t);
} BKIO;

#define kBKConfigPath           @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKStatusPath           @"/var/mobile/bk_status.txt"
#define kBKLogPath              @"/var/mobile/bk_debug.log"
#define kBKPtrPath              @"/var/mobile/bk_ptr.txt"
#define kBKCaptureReqPath       @"/var/mobile/bk_capture.txt"
#define kBKCaptureResPath       @"/var/mobile/bk_capture_result.txt"
#define kBKNotifyReload         "com.wjf.ballkey.reload"
#define kBKNotifyTest           "com.wjf.ballkey.test"
#define kBKNotifyProbe          "com.wjf.ballkey.probe"
#define kBKNotifyClose          "com.wjf.ballkey.close"
#define kBKNotifyCapture        "com.wjf.ballkey.capture"
#define kBKNotifyCapRes         "com.wjf.ballkey.capres"

#define kBKTransducerHand       0x23
#define kBKSenderID             0x8000000817319372ull
#define kBKMaxFinger            10

#define kBKFieldX               (11u << 16 | 0u)
#define kBKFieldY               (11u << 16 | 1u)
#define kBKFieldBtnMask         (11u << 16 | 3u)
#define kBKFieldHandMask        (11u << 16 | 7u)
#define kBKFieldRange           (11u << 16 | 8u)
#define kBKFieldTouch           (11u << 16 | 9u)
#define kBKFieldMajorR          0xb0014u
#define kBKFieldMinorR          0xb0015u
#define kBKFieldDisplayInt      0xb0019u
#define kBKFieldIsBuiltIn       0x4u

#define kBKFieldPtrX            (17u << 16 | 0u)
#define kBKFieldPtrY            (17u << 16 | 1u)
#define kBKFieldPtrBtn          (17u << 16 | 2u)

#define kBKFlagRange            0x01u
#define kBKFlagTouch            0x02u
#define kBKFlagPosition         0x04u
#define kBKFlagIdentity         0x20u

#define kBKTypeButton           2
#define kBKTypeKeyboard         3
#define kBKTypeDigitizer        11
#define kBKTypeKeyExtra         15
#define kBKTypePointer          17

#define kBKDefaultFpsKey        224
#define kBKCtrlRight            228
#define kBKUsageBtnBase         64
#define kBKMaxBtn               3

#define kBKMoveFactor           0.0015
#define kBKMoveDead             0.35
#define kBKMoveDedupNs          3000000ull
#define kBKEdge                 0.06
#define kBKPressNs              (60ull * NSEC_PER_MSEC)
#define kBKBtnLockNs            100000000ull
#define kBKCapArmNs             90000000ull
#define kBKCapLifeNs            8000000000ull

#define kBKIdxAim               70
#define kBKIdxAds               71
#define kBKIdxDir               72
#define kBKIdxFogo              73
#define kBKIdxCursor            40

static void *gIOKit = NULL;
static BKIO gIO;
static BKIOHIDEventSystemClientRef gListenClient = NULL;
static BKIOHIDEventSystemClientRef gSendClient = NULL;
static dispatch_queue_t gSendQ = NULL;
static NSArray *gPoints = nil;
static BOOL gEnabled = NO;
static NSString *gActiveBundle = nil;
static NSMutableDictionary *gDown = nil;
static NSMutableDictionary *gGen = nil;
static NSMutableDictionary *gSlotOf = nil;
static NSMutableDictionary *gKeyDown = nil;
static BOOL gRotate = YES;
static BOOL gFollowCursor = NO;
static BOOL gCursorOn = YES;
static double gFollowSens = 1.0;
static int gOrientOverride = 0;
static BOOL gDump = NO;
static BOOL gFps = NO;
static double gFpsSens = 1.0;
static int gFpsKey = kBKDefaultFpsKey;
static double gFpsX = 0.5, gFpsY = 0.5;
static double gFireX = 0.86, gFireY = 0.62;
static double gAdsX = 0.95, gAdsY = 0.50;
static double gAimX = 0.5, gAimY = 0.5;
static int gAimSlot = 0;
static BOOL gFogoDown = NO, gAdsDown = NO, gDirActive = NO;
static double gDirSens = 1.0;
static BOOL gAimB = NO;
static double gCx = 0.5, gCy = 0.5;
static uint64_t gLastPtrWrite = 0;
static BOOL gLastPtrValid = NO;
static double gLastPtrX = 0.0, gLastPtrY = 0.0;
static int gPtrMask = 0;
static uint64_t gLastMoveNs = 0;
static double gLastMdx = 0.0, gLastMdy = 0.0;
static BOOL gCapArm = NO;
static uint64_t gCapArmNs = 0;
static NSString *gCapNonce = nil;
static uint64_t gLastKeyNs = 0;
static uint64_t gLastBtnNs = 0;
static int gEvSeen = 0;
static int gKeySeen = 0;
static int gPtrSeen = 0;
static NSString *gLogBuf = nil;
static uint64_t gLogLast = 0;

typedef struct { int on; double x, y; } BKAct;
static BKAct gAct[kBKMaxFinger + 1];
static int gSlotOwner[kBKMaxFinger + 1];
static NSMutableSet *gEnding = nil;
static int gPending = 0;
static int gSched = 0;

static void BKMove(NSUInteger idx, double nx, double ny);
static void BKStatus(void);

static uint64_t BKNow(void) { return mach_absolute_time() / 1000000ull; }

static void BKAppend(NSString *s)
{
    if (!gLogBuf) gLogBuf = [NSMutableString string];
    [(NSMutableString *)gLogBuf appendFormat:@"%@\n", s];
    uint64_t now = BKNow();
    if (now - gLogLast < 100) return;
    gLogLast = now;
    NSString *out = [gLogBuf copy];
    gLogBuf = [NSMutableString string];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kBKLogPath];
        if (!fh) { [out writeToFile:kBKLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
        @try { [fh seekToEndOfFile]; [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        @catch (NSException *e) { }
    });
}

static void BKAppendD(NSString *s) { if (gDump) BKAppend(s); }

static void BKMark(NSString *name)
{
    [[NSString stringWithFormat:@"%.0f", (double)BKNow()]
        writeToFile:[@"/var/mobile/" stringByAppendingString:name]
        atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static double BKClamp(double v) { if (v < 0) return 0; if (v > 1) return 1; return v; }

static void BKNotifyUserActivity(void)
{
    static uint64_t last = 0;
    uint64_t now = BKNow();
    if (now - last < 100) return;
    last = now;
    Class c = objc_getClass("BKUserEventTimer");
    if (!c) return;
    SEL s1 = @selector(userEventOccurred);
    SEL s2 = @selector(userEventOccurredOnDisplay:);
    id timer = ((id (*)(id, SEL))objc_msgSend)(c, @selector(sharedInstance));
    if (!timer) return;
    if ([timer respondsToSelector:s1]) ((void (*)(id, SEL))objc_msgSend)(timer, s1);
    else if ([timer respondsToSelector:s2]) ((void (*)(id, SEL, id))objc_msgSend)(timer, s2, nil);
}

static int BKCurrentOrient(void)
{
    if (gOrientOverride > 0) return gOrientOverride;
    Class sbCls = objc_getClass("SpringBoard");
    if (!sbCls) return 3;
    id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
    if (!sb) return 3;
    SEL sel = @selector(_frontMostAppOrientation);
    if (![sb respondsToSelector:sel]) return 3;
    return (int)((int (*)(id, SEL))objc_msgSend)(sb, sel);
}

static void BKConvInv(double vx, double vy, int orient, double *ox, double *oy)
{
    double rx = vx, ry = vy;
    switch (orient) {
        case 2: rx = 1.0 - vx; ry = 1.0 - vy; break;
        case 3: rx = vy;       ry = 1.0 - vx; break;
        case 4: rx = 1.0 - vy; ry = vx;       break;
        default: break;
    }
    *ox = BKClamp(rx); *oy = BKClamp(ry);
}

static int BKSlotFor(NSUInteger idx)
{
    NSNumber *n = gSlotOf[@(idx)];
    if (n) return [n intValue];
    for (int s = 1; s <= kBKMaxFinger; s++) {
        if (s >= kBKMaxFinger - 1) continue;
        if (gAct[s].on || gSlotOwner[s]) continue;
        gSlotOwner[s] = (int)idx + 1;
        gSlotOf[@(idx)] = @(s);
        return s;
    }
    return 0;
}

static void BKFlushNow(void)
{
    int pending = gPending;
    gPending = 0;
    if (!pending || !gIO.Dispatch || !gSendClient) return;

    uint64_t ts = mach_absolute_time();
    int anyDown = 0;
    for (int s = 1; s <= kBKMaxFinger; s++) if (gAct[s].on) { anyDown = 1; break; }

    uint32_t hmask = 0;
    if (pending & 2) hmask |= (kBKFlagRange | kBKFlagTouch | kBKFlagIdentity);
    if (pending & 1) hmask |= kBKFlagPosition;
    if (!hmask) hmask = kBKFlagPosition;

    @try {
    BKIOHIDEventRef hand = gIO.CreateDigitizer(kCFAllocatorDefault, ts, kBKTransducerHand,
        0, 0, hmask, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, (uint8_t)(anyDown ? 1 : 0), 0);
    if (!hand) return;
    gIO.SetInt(hand, kBKFieldDisplayInt, 1);
    gIO.SetInt(hand, kBKFieldIsBuiltIn, 1);

    BOOL moveOnly = ((pending & 1) && !(pending & 2));

    for (int s = 1; s <= kBKMaxFinger; s++) {
        if (!gAct[s].on) continue;
        BOOL ending = [gEnding containsObject:@(s)];
        uint32_t cmask = moveOnly ? kBKFlagPosition : (kBKFlagRange | kBKFlagTouch);
        uint8_t rng = ending ? 0 : 1;
        uint8_t tch = ending ? 0 : 1;
        BKIOHIDEventRef ch = gIO.CreateFinger(kCFAllocatorDefault, ts, (uint32_t)s, (uint32_t)s,
            cmask, gAct[s].x, gAct[s].y, 0.0, 0.0, 0.0, rng, tch, 0);
        if (ch) {
            gIO.SetFloat(ch, kBKFieldMajorR, 0.05);
            gIO.SetFloat(ch, kBKFieldMinorR, 0.05);
            gIO.Append(hand, ch, 0);
            CFRelease(ch);
        }
        if (ending) {
            gAct[s].on = 0;
            int owner = gSlotOwner[s];
            if (owner > 0) [gSlotOf removeObjectForKey:@((NSUInteger)(owner - 1))];
            gSlotOwner[s] = 0;
        }
    }
    [gEnding removeAllObjects];

    gIO.SetInt(hand, kBKFieldHandMask, (int)hmask);
    gIO.SetInt(hand, kBKFieldTouch, anyDown ? 1 : 0);
    gIO.SetSender(hand, kBKSenderID);

    CFRetain(hand);
    dispatch_async(gSendQ, ^{
        @try { gIO.Dispatch(gSendClient, hand); } @catch (NSException *e) { }
        CFRelease(hand);
    });
    BKNotifyUserActivity();
    } @catch (NSException *e) { BKAppend(@"! flush"); }
}

static void BKSched(void)
{
    if (gSched) return;
    gSched = 1;
    dispatch_async(dispatch_get_main_queue(), ^{ gSched = 0; BKFlushNow(); });
}

static void BKSlotDown(int slot, double x, double y)
{
    if (slot < 1 || slot > kBKMaxFinger) return;
    gAct[slot].on = 1;
    gAct[slot].x = BKClamp(x);
    gAct[slot].y = BKClamp(y);
    gPending |= 2;
    BKSched();
}

static void BKSlotMove(int slot, double x, double y)
{
    if (slot < 1 || slot > kBKMaxFinger || !gAct[slot].on) return;
    if ([gEnding containsObject:@(slot)]) return;
    gAct[slot].x = BKClamp(x);
    gAct[slot].y = BKClamp(y);
    gPending |= 1;
    BKSched();
}

static void BKSlotUp(int slot)
{
    if (slot < 1 || slot > kBKMaxFinger || !gAct[slot].on) return;
    [gEnding addObject:@(slot)];
    gPending |= 2;
    BKSched();
}

static void BKDown(NSUInteger idx, double nx, double ny)
{
    if ([gDown[@(idx)] boolValue]) { BKMove(idx, nx, ny); return; }
    int slot = BKSlotFor(idx);
    if (!slot) { BKAppend(@"! sem dedo"); return; }
    gDown[@(idx)] = @YES;
    BKSlotDown(slot, nx, ny);
}

static void BKMove(NSUInteger idx, double nx, double ny)
{
    NSNumber *n = gSlotOf[@(idx)];
    if (!n) return;
    BKSlotMove([n intValue], nx, ny);
}

static void BKUp(NSUInteger idx)
{
    NSNumber *n = gSlotOf[@(idx)];
    gDown[@(idx)] = @NO;
    if (!n) return;
    BKSlotUp([n intValue]);
}

static void BKTap(NSUInteger idx, double nx, double ny)
{
    if ([gDown[@(idx)] boolValue]) { BKMove(idx, nx, ny); return; }
    BKDown(idx, nx, ny);
    NSNumber *gen = @([gGen[@(idx)] intValue] + 1);
    gGen[@(idx)] = gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kBKPressNs),
                   dispatch_get_main_queue(), ^{
        if (![gGen[@(idx)] isEqualToNumber:gen]) return;
        BKUp(idx);
    });
}

static void BKReleaseAll(void)
{
    for (NSNumber *k in [gDown allKeys]) {
        if ([gDown[k] boolValue]) BKUp([k unsignedIntegerValue]);
    }
    gFogoDown = NO; gAdsDown = NO; gDirActive = NO;
}

static void BKListenCB(void *target, void *refcon, void *service, BKIOHIDEventRef event);

static BOOL BKInitIO(void)
{
    gIOKit = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!gIOKit) gIOKit = dlopen("/var/jb/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!gIOKit) { BKAppend(@"I io=0"); return NO; }
    gIO.ClientCreate = dlsym(gIOKit, "IOHIDEventSystemClientCreate");
    gIO.ClientCreateType = dlsym(gIOKit, "IOHIDEventSystemClientCreateWithType");
    gIO.SetMatching = dlsym(gIOKit, "IOHIDEventSystemClientSetMatching");
    gIO.SetQueue     = dlsym(gIOKit, "IOHIDEventSystemClientSetDispatchQueue");
    gIO.ScheduleRL   = dlsym(gIOKit, "IOHIDEventSystemClientScheduleWithRunLoop");
    gIO.RegisterCB   = dlsym(gIOKit, "IOHIDEventSystemClientRegisterEventCallback");
    gIO.Activate     = dlsym(gIOKit, "IOHIDEventSystemClientActivate");
    gIO.Dispatch     = dlsym(gIOKit, "IOHIDEventSystemClientDispatchEvent");
    gIO.GetType      = dlsym(gIOKit, "IOHIDEventGetType");
    gIO.GetInt       = dlsym(gIOKit, "IOHIDEventGetIntegerValue");
    gIO.GetFloat     = dlsym(gIOKit, "IOHIDEventGetFloatValue");
    gIO.GetSender    = dlsym(gIOKit, "IOHIDEventGetSenderID");
    gIO.SetInt       = dlsym(gIOKit, "IOHIDEventSetIntegerValue");
    gIO.SetFloat     = dlsym(gIOKit, "IOHIDEventSetFloatValue");
    gIO.SetSender    = dlsym(gIOKit, "IOHIDEventSetSenderID");
    gIO.Append       = dlsym(gIOKit, "IOHIDEventAppendEvent");
    gIO.CreateDigitizer = dlsym(gIOKit, "IOHIDEventCreateDigitizerEvent");
    gIO.CreateFinger = dlsym(gIOKit, "IOHIDEventCreateDigitizerFingerEvent");
    if (!gIO.ClientCreate || !gIO.Dispatch || !gIO.CreateDigitizer || !gIO.CreateFinger
        || !gIO.GetType || !gIO.GetInt || !gIO.GetFloat || !gIO.SetInt
        || !gIO.SetFloat || !gIO.SetSender || !gIO.Append) { BKAppend(@"I sym=0"); return NO; }
    BKAppend(@"I io=1");
    BKMark(@"engine_io.txt");
    return YES;
}

static void BKPtrWrite(void)
{
    uint64_t now = BKNow();
    if (now - gLastPtrWrite < 8) return;
    gLastPtrWrite = now;
    [[NSString stringWithFormat:@"%.4f %.4f", gCx, gCy]
        writeToFile:kBKPtrPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static void BKCursorMove(double dx, double dy)
{
    gCx = BKClamp(gCx + dx * gFollowSens * kBKMoveFactor);
    gCy = BKClamp(gCy + dy * gFollowSens * kBKMoveFactor);
    BKPtrWrite();
}

static void BKCursorTap(void)
{
    if (!gCursorOn) return;
    double px = gCx, py = gCy;
    if (gRotate) BKConvInv(gCx, gCy, BKCurrentOrient(), &px, &py);
    BKTap(kBKIdxCursor, px, py);
}

static void BKFpsFire(BOOL down)
{
    if (down) {
        if (gFogoDown) return;
        gFogoDown = YES;
        double px = gFireX, py = gFireY;
        if (gRotate) BKConvInv(gFireX, gFireY, BKCurrentOrient(), &px, &py);
        BKDown(kBKIdxFogo, px, py);
        BKAppend(@"F fogo down");
    } else {
        if (!gFogoDown) return;
        gFogoDown = NO;
        BKUp(kBKIdxFogo);
        BKAppend(@"F fogo up");
    }
}

static void BKFpsAdsToggle(void)
{
    if (gAdsDown) { gAdsDown = NO; BKUp(kBKIdxAds); BKAppend(@"F mirar off"); return; }
    gAdsDown = YES;
    double px = gAdsX, py = gAdsY;
    if (gRotate) BKConvInv(gAdsX, gAdsY, BKCurrentOrient(), &px, &py);
    BKDown(kBKIdxAds, px, py);
    BKAppend(@"F mirar on");
}

static void BKAimRecenter(int fromSlot, double cx, double cy)
{
    int toSlot = gAimB ? (kBKMaxFinger - 1) : kBKMaxFinger;
    gAimB = !gAimB;
    if (fromSlot == toSlot) { BKSlotMove(fromSlot, cx, cy); return; }
    if (fromSlot > 0) { BKSlotUp(fromSlot); gSlotOwner[fromSlot] = 0; }
    gAct[toSlot].on = 1;
    gAct[toSlot].x = BKClamp(cx);
    gAct[toSlot].y = BKClamp(cy);
    gSlotOwner[toSlot] = (int)kBKIdxAim + 1;
    gSlotOf[@(kBKIdxAim)] = @(toSlot);
    gPending |= 2;
    BKSched();
}

static void BKFpsMove(double dx, double dy)
{
    if (!gFps || !gAimSlot) return;
    uint64_t now = BKNow();
    if (fabs(dx) < kBKMoveDead && fabs(dy) < kBKMoveDead
        && dx == gLastMdx && dy == gLastMdy && (now - gLastMoveNs) < kBKMoveDedupNs) return;
    gLastMdx = dx; gLastMdy = dy; gLastMoveNs = now;

    double nx = BKClamp(gAimX + dx * gFpsSens * kBKMoveFactor);
    double ny = BKClamp(gAimY + dy * gFpsSens * kBKMoveFactor);

    double px, py;
    int o = BKCurrentOrient();
    if (gRotate) BKConvInv(nx, ny, o, &px, &py);
    else { px = nx; py = ny; }

    gAimX = nx; gAimY = ny;
    BKSlotMove(gAimSlot, px, py);

    if (px < kBKEdge || px > 1.0 - kBKEdge || py < kBKEdge || py > 1.0 - kBKEdge) {
        BKAimRecenter(gAimSlot, 0.5, 0.5);
        gAimX = 0.5; gAimY = 0.5;
        gAimSlot = [gSlotOf[@(kBKIdxAim)] intValue];
        BKAppendD([NSString stringWithFormat:@"F borda dedo=%d", gAimSlot]);
    }
}

static void BKFpsEnsure(void)
{
    if (!gFps) return;
    if (gAimSlot && gAct[gAimSlot].on) return;
    gAimX = 0.5; gAimY = 0.5;
    BKDown(kBKIdxAim, 0.5, 0.5);
    gAimSlot = [gSlotOf[@(kBKIdxAim)] intValue];
    BKAppendD(@"F repor");
}

static void BKFpsOn(void)
{
    if (gFps) return;
    gFps = YES;
    gCx = 0.5; gCy = 0.5;
    BKPtrWrite();
    gAimX = 0.5; gAimY = 0.5;
    BKDown(kBKIdxAim, 0.5, 0.5);
    gAimSlot = [gSlotOf[@(kBKIdxAim)] intValue];
    BKAppend([NSString stringWithFormat:@"F on dedo=%d", gAimSlot]);
    notify_post("com.wjf.ballkey.fps_on");
}

static void BKFpsOff(void)
{
    if (!gFps) return;
    gFps = NO;
    if (gFogoDown) { gFogoDown = NO; BKUp(kBKIdxFogo); }
    if (gAdsDown) { gAdsDown = NO; BKUp(kBKIdxAds); }
    BKUp(kBKIdxAim);
    gAimSlot = 0;
    gCx = 0.5; gCy = 0.5;
    gLastPtrWrite = 0;
    BKPtrWrite();
    BKAppend(@"F off");
    notify_post("com.wjf.ballkey.fps_off");
}

static void BKStatus(void)
{
    NSString *s = [NSString stringWithFormat:@"e%d k%d p%d m%lu a=%@ o%d\n",
        (int)gEnabled, gKeySeen, gPtrSeen, (unsigned long)gPoints.count,
        gActiveBundle ?: @"-", BKCurrentOrient()];
    [s writeToFile:kBKStatusPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static void BKLoadConfig(void)
{
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
    BOOL enabled = [cfg[@"Enabled"] boolValue];
    NSString *active = cfg[@"ActiveBundle"];
    NSArray *pts = nil;
    NSDictionary *profiles = cfg[@"Profiles"];
    if ([profiles isKindOfClass:[NSDictionary class]]) {
        if ([active isKindOfClass:[NSString class]]) {
            id p = profiles[active];
            if ([p isKindOfClass:[NSArray class]]) pts = p;
        }
        if (!pts) {
            id p = profiles[@"*"];
            if ([p isKindOfClass:[NSArray class]]) pts = p;
        }
        if (!pts && profiles.count == 1) {
            id p = [[profiles allValues] firstObject];
            if ([p isKindOfClass:[NSArray class]]) pts = p;
        }
    }

    if ([cfg[@"Rotate"] isKindOfClass:[NSNumber class]]) gRotate = [cfg[@"Rotate"] boolValue];
    if ([cfg[@"FollowCursor"] isKindOfClass:[NSNumber class]]) gFollowCursor = [cfg[@"FollowCursor"] boolValue];
    if ([cfg[@"CursorOn"] isKindOfClass:[NSNumber class]]) gCursorOn = [cfg[@"CursorOn"] boolValue];
    if ([cfg[@"FollowSens"] isKindOfClass:[NSNumber class]]) gFollowSens = [cfg[@"FollowSens"] doubleValue];
    if ([cfg[@"OrientOverride"] isKindOfClass:[NSNumber class]]) gOrientOverride = [cfg[@"OrientOverride"] intValue];
    if ([cfg[@"Dump"] isKindOfClass:[NSNumber class]]) gDump = [cfg[@"Dump"] boolValue];
    if ([cfg[@"FpsSens"] isKindOfClass:[NSNumber class]]) gFpsSens = [cfg[@"FpsSens"] doubleValue];
    if ([cfg[@"FpsKey"] isKindOfClass:[NSNumber class]]) gFpsKey = [cfg[@"FpsKey"] intValue];
    if ([cfg[@"FpsX"] isKindOfClass:[NSNumber class]]) gFpsX = [cfg[@"FpsX"] doubleValue];
    if ([cfg[@"FpsY"] isKindOfClass:[NSNumber class]]) gFpsY = [cfg[@"FpsY"] doubleValue];
    if ([cfg[@"FireX"] isKindOfClass:[NSNumber class]]) gFireX = [cfg[@"FireX"] doubleValue];
    if ([cfg[@"FireY"] isKindOfClass:[NSNumber class]]) gFireY = [cfg[@"FireY"] doubleValue];
    if ([cfg[@"AdsX"] isKindOfClass:[NSNumber class]]) gAdsX = [cfg[@"AdsX"] doubleValue];
    if ([cfg[@"AdsY"] isKindOfClass:[NSNumber class]]) gAdsY = [cfg[@"AdsY"] doubleValue];

    if (gFpsSens <= 0) gFpsSens = 1.0;
    if (gFollowSens <= 0) gFollowSens = 1.0;

    BOOL wasEnabled = gEnabled;
    gEnabled = enabled;
    gActiveBundle = active;
    gPoints = pts;

    if (!enabled && wasEnabled) { BKReleaseAll(); if (gFps) BKFpsOff(); }
    if (enabled && gPoints.count) BKMark(@"engine_armed.txt");
    BKStatus();
}

static void BKCaptureWrite(NSString *key)
{
    if (!gCapArm || !gCapNonce) return;
    gCapArm = NO;
    NSString *s = [NSString stringWithFormat:@"%@|%@", gCapNonce, key];
    [s writeToFile:kBKCaptureResPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    notify_post(kBKNotifyCapRes);
    BKAppend([NSString stringWithFormat:@"C res=%@", key]);
}

static void BKArmCapture(void)
{
    NSString *req = [NSString stringWithContentsOfFile:kBKCaptureReqPath
        encoding:NSUTF8StringEncoding error:nil];
    req = [req stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (req.length < 3) { BKAppend(@"C sem nonce"); return; }
    gCapNonce = req;
    gCapArm = YES;
    gCapArmNs = BKNow();
    [@"" writeToFile:kBKCaptureResPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    BKAppend([NSString stringWithFormat:@"C arm %@", req]);
}

static void BKCaptureWatch(void)
{
    if (!gCapArm) return;
    if (BKNow() - gCapArmNs > (kBKCapLifeNs / 1000000ull)) {
        gCapArm = NO;
        BKAppend(@"C expirou");
    }
}

static void BKPonto(NSDictionary *pt, double *ox, double *oy)
{
    double nx = [pt[@"X"] doubleValue];
    double ny = [pt[@"Y"] doubleValue];
    if (gRotate) BKConvInv(nx, ny, BKCurrentOrient(), &nx, &ny);
    *ox = nx; *oy = ny;
}

static void BKHandleDir(NSDictionary *pt, int dir, BOOL down)
{
    if (dir < 0 || dir > 3) return;
    if (down) {
        if (!gDirActive) {
            gDirActive = YES;
            gDirSens = pt[@"Sens"] ? [pt[@"Sens"] doubleValue] : 1.0;
            if (gDirSens <= 0) gDirSens = 1.0;
            BKDown(kBKIdxDir + (NSUInteger)dir, 0.5, 0.5);
        }
        return;
    }
    if (!gDirActive) return;
    gDirActive = NO;
    for (int i = 0; i < 4; i++) BKUp(kBKIdxDir + (NSUInteger)i);
}

static void BKHandlePoint(NSDictionary *pt, NSUInteger idx, BOOL down)
{
    NSString *type = pt[@"Type"] ?: @"Tap";
    double nx, ny;
    BKPonto(pt, &nx, &ny);
    if ([type isEqualToString:@"Tap"]) { if (down) BKTap(idx, nx, ny); return; }
    if ([type isEqualToString:@"Press"] || [type isEqualToString:@"Hold"]) {
        if (down) BKDown(idx, nx, ny); else BKUp(idx);
        return;
    }
    if ([type isEqualToString:@"Dir"]) { BKHandleDir(pt, [pt[@"Dir"] intValue], down); return; }
}

static void BKHandleKey(int usage, BOOL down)
{
    if (usage == kBKCtrlRight && gDirActive) {
        if (!down) {
            gDirActive = NO;
            for (int i = 0; i < 4; i++) BKUp(kBKIdxDir + (NSUInteger)i);
        }
        return;
    }
    if (down && [gKeyDown[@(usage)] boolValue]) return;
    gKeyDown[@(usage)] = @(down);
    gLastKeyNs = BKNow();

    if (down) {
        if (gCapArm && BKNow() - gCapArmNs >= (kBKCapArmNs / 1000000ull))
            BKCaptureWrite([NSString stringWithFormat:@"k:%d", usage]);
        if (usage == gFpsKey) { if (gFps) BKFpsOff(); else BKFpsOn(); return; }
    }

    if (!gEnabled || !gPoints.count) return;

    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        if (![pt isKindOfClass:[NSDictionary class]]) continue;
        if ([pt[@"Key"] intValue] != usage) continue;
        BKHandlePoint(pt, i, down);
    }
}

static void BKHandleButton(int b, BOOL down)
{
    if (down && BKNow() - gLastBtnNs < (kBKBtnLockNs / 1000000ull)) return;
    if (down) gLastBtnNs = BKNow();

    if (down && gCapArm && BKNow() - gCapArmNs >= (kBKCapArmNs / 1000000ull))
        BKCaptureWrite([NSString stringWithFormat:@"m:%d", b]);

    if (b == 0) {
        if (gFps) { BKFpsFire(down); return; }
        if (gFollowCursor && down) { BKCursorTap(); return; }
    }
    if (b == 1) {
        if (gFps) { if (down) BKFpsAdsToggle(); return; }
        if (gFollowCursor && down) { BKCursorTap(); return; }
    }
    if (!gEnabled || !gPoints.count) return;
    NSString *key = [NSString stringWithFormat:@"m:%d", b];
    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        if (![pt isKindOfClass:[NSDictionary class]]) continue;
        if (![pt[@"Key"] isEqualToString:key]) continue;
        BKHandlePoint(pt, i, down);
    }
}

static void BKPtrButtons(int mask)
{
    if (mask == gPtrMask) return;
    int diff = mask ^ gPtrMask;
    gPtrMask = mask;
    if (diff & 1) BKHandleButton(0, (mask & 1) != 0);
    if (diff & 2) BKHandleButton(1, (mask & 2) != 0);
}

static void BKListenCB(void *target, void *refcon, void *service, BKIOHIDEventRef event)
{
    (void)target; (void)refcon; (void)service;
    @try {
        if (!gIO.GetType || !event) return;
        int type = gIO.GetType(event);
        gEvSeen++;

        if (type == kBKTypePointer) {
            gPtrSeen++;
            double x = gIO.GetFloat(event, kBKFieldPtrX);
            double y = gIO.GetFloat(event, kBKFieldPtrY);
            if (gLastPtrValid) {
                double dx = x - gLastPtrX;
                double dy = y - gLastPtrY;
                if (fabs(dx) < 9000 && fabs(dy) < 9000) {
                    if (gFps) BKFpsMove(dx, dy);
                    else if (gCursorOn) BKCursorMove(dx, dy);
                }
            }
            gLastPtrX = x; gLastPtrY = y; gLastPtrValid = YES;
            BKPtrButtons((int)gIO.GetInt(event, kBKFieldPtrBtn));
            BKAppendD([NSString stringWithFormat:@"P x=%.1f y=%.1f m=%d", x, y, gPtrMask]);
            return;
        }

        if (type == kBKTypeDigitizer) return;

        if (type == kBKTypeKeyExtra || type == kBKTypeKeyboard) {
            gKeySeen++;
            int page = gIO.GetInt(event, (3u << 16 | 0u));
            int usage = gIO.GetInt(event, (3u << 16 | 1u));
            int down = gIO.GetInt(event, (3u << 16 | 2u));
            BKAppendD([NSString stringWithFormat:@"K pg=%d u=%d d=%d", page, usage, down]);
            if (page != 7 && page != 0) return;
            BKHandleKey(usage, down != 0);
            return;
        }

        if (type == kBKTypeButton) {
            int usage = gIO.GetInt(event, kBKFieldBtnMask);
            int b = usage - kBKUsageBtnBase;
            if (b < 0 || b >= kBKMaxBtn) return;
            BKHandleButton(b, gIO.GetInt(event, (kBKTypeButton << 16 | 3u)) != 0);
            return;
        }
    } @catch (NSException *e) { }
}

static void BKTestCenter(void)
{
    BKAppend(@"T ini");
    notify_post(kBKNotifyClose);
    for (int i = 0; i < 3; i++) {
        int64_t d = (int64_t)(900 + i * 700) * NSEC_PER_MSEC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d), dispatch_get_main_queue(), ^{
            double px = 0.5, py = 0.5;
            if (gRotate) BKConvInv(0.5, 0.5, BKCurrentOrient(), &px, &py);
            BKAppend([NSString stringWithFormat:@"T %d pn=%.3f,%.3f", i, px, py]);
            BKTap(kBKIdxCursor + 9, px, py);
        });
    }
}

static void BKProbe(void)
{
    BKAppend(@"P ini");
    notify_post(kBKNotifyClose);
    for (int i = 0; i < 10; i++) {
        int64_t d = (int64_t)(i * 320) * NSEC_PER_MSEC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d), dispatch_get_main_queue(), ^{
            double x = (i == 4 || i == 9) ? 0.5 : (i % 2 ? 0.9 : 0.1);
            double y = (i == 4 || i == 9) ? 0.5 : (i < 4 ? 0.1 : 0.9);
            double px = x, py = y;
            if (gRotate) BKConvInv(x, y, BKCurrentOrient(), &px, &py);
            BKAppend([NSString stringWithFormat:@"P %d pn=%.3f,%.3f", i, px, py]);
            BKTap(90 + (NSUInteger)i, px, py);
            if (i == 9) BKAppend(@"P fim");
        });
    }
}

static BKIOHIDEventSystemClientRef BKNewListen(void)
{
    BKIOHIDEventSystemClientRef c = NULL;
    if (gIO.ClientCreateType) c = gIO.ClientCreateType(kCFAllocatorDefault, 2, NULL);
    if (!c && gIO.ClientCreate) {
        c = gIO.ClientCreate(kCFAllocatorDefault);
        if (c && gIO.SetMatching) {
            NSDictionary *m = @{ @"PrimaryUsagePage": @1 };
            gIO.SetMatching(c, (__bridge CFDictionaryRef)m);
        }
    }
    if (!c) return NULL;
    if (gIO.SetQueue) gIO.SetQueue(c, dispatch_get_main_queue());
    else if (gIO.ScheduleRL) gIO.ScheduleRL(c, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    if (gIO.RegisterCB) gIO.RegisterCB(c, (void *)BKListenCB, NULL, NULL);
    if (gIO.Activate) gIO.Activate(c);
    return c;
}

__attribute__((constructor)) static void BKInitC(void)
{
    BKMark(@"engine_ctor.txt");
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
        gDown = [NSMutableDictionary dictionary];
        gGen = [NSMutableDictionary dictionary];
        gSlotOf = [NSMutableDictionary dictionary];
        gKeyDown = [NSMutableDictionary dictionary];
        gEnding = [NSMutableSet set];
        gSendQ = dispatch_queue_create("com.wjf.ballkey.send", DISPATCH_QUEUE_SERIAL);

        if (!BKInitIO()) { BKStatus(); return; }

        gSendClient = gIO.ClientCreate(kCFAllocatorDefault);
        BKAppend(gSendClient ? @"I send=1" : @"I send=0");

        @try {
            gListenClient = BKNewListen();
            if (!gListenClient) { BKAppend(@"I client=0"); BKStatus(); return; }
            BKAppend(@"I listen=1");
            BKMark(@"engine_listen.txt");
        } @catch (NSException *e) {
            BKAppend([NSString stringWithFormat:@"! init %@", e.reason]);
            BKStatus();
            return;
        }

        dispatch_queue_t q = dispatch_get_main_queue();
        int t1 = 0, t2 = 0, t3 = 0, t4 = 0;
        notify_register_dispatch(kBKNotifyReload, &t1, q, ^(int t) { (void)t; BKLoadConfig(); });
        notify_register_dispatch(kBKNotifyTest, &t2, q, ^(int t) { (void)t; BKTestCenter(); });
        notify_register_dispatch(kBKNotifyProbe, &t3, q, ^(int t) { (void)t; BKProbe(); });
        notify_register_dispatch(kBKNotifyCapture, &t4, q, ^(int t) { (void)t; BKArmCapture(); });
        BKAppend(@"I notify=1");

        BKLoadConfig();

        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        if (src) {
            dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 120ull * NSEC_PER_MSEC),
                                      120ull * NSEC_PER_MSEC, 20ull * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(src, ^{
                @try { BKCaptureWatch(); BKFpsEnsure(); BKStatus(); } @catch (NSException *e) { }
            });
            dispatch_resume(src);
        }

        BKAppend(@"I ready");
        BKMark(@"engine_ready.txt");
        BKStatus();
        }
    });
}
