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
    void (*RegisterCB)(BKIOHIDEventSystemClientRef, void *, void *, void *);
    void (*SetQueue)(BKIOHIDEventSystemClientRef, dispatch_queue_t);
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

// Campo digitizer: (11 << 16) | n
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

// Máscaras reais do kIOHIDDigitizerEventMask
#define kBKFlagRange            0x01u
#define kBKFlagTouch            0x02u
#define kBKFlagPosition         0x04u
#define kBKFlagIdentity         0x20u

#define kBKTypeKeyExtra         15
#define kBKTypePointer          17
#define kBKTypeDigitizer        11
#define kBKTypeBtn              32
#define kBKTypeButton           2

#define kBKDefaultFpsKey        224
#define kBKCtrlRight            228
#define kBKPageBtn              12
#define kBKUsageBtnBase         64
#define kBKMaxBtn               3

#define kBKMoveFactor           0.0015
#define kBKMoveDead             0.35
#define kBKMoveDedupNs          3000000ull
#define kBKEdge                 0.06
#define kBKPressNs              (60ull * NSEC_PER_MSEC)   // Apple usa 50 ms
#define kBKPtrScale             3000.0
#define kBKPtrWriteNs           8000000ull

#define kBKKeyGraceNs           60000000ull
#define kBKBtnLockNs            100000000ull
#define kBKCapArmNs             90000000ull
#define kBKCapLifeNs            8000000000ull

#define kBKIdxAim               70
#define kBKIdxAimB              75
#define kBKIdxAds               71
#define kBKIdxDir               72
#define kBKIdxFogo              73
#define kBKIdxMirar             74
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
static int gBtnOwner[kBKMaxBtn];
static BOOL gAimB = NO;

static double gCx = 0.5, gCy = 0.5;
static uint64_t gLastPtrWrite = 0;
static BOOL gLastPtrValid = NO;
static double gLastPtrX = 0.0, gLastPtrY = 0.0;
static uint64_t gLastMoveNs = 0;
static double gLastMdx = 0.0, gLastMdy = 0.0;

static BOOL gCapArm = NO;
static uint64_t gCapArmNs = 0;
static NSString *gCapNonce = nil;
static BOOL gCapHave = NO;

static uint64_t gLastKeyNs = 0;
static uint64_t gLastBtnNs = 0;
static int gEvSeen = 0;

static NSString *gLogBuf = nil;
static uint64_t gLogLast = 0;

// ---------------------------------------------------------------- dedos ----
typedef struct { int on; double x, y; } BKAct;
static BKAct gAct[kBKMaxFinger + 1];
static int gSlotOwner[kBKMaxFinger + 1];
static NSMutableSet *gEnding = nil;
static int gPending = 0;
static int gSched = 0;

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
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) { }
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
    long o = (long)((int (*)(id, SEL))objc_msgSend)(sb, sel);
    return (int)o;
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

// Toque curto com pressão real de 60 ms. 8 ms cai dentro de um frame e o jogo
// não amostra o toque: era isso que obrigava a apertar duas vezes.
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

// ------------------------------------------------------------------ IOKit ---
static void BKListenCB(void *target, void *refcon, void *service, BKIOHIDEventRef event);

static BOOL BKInitIO(void)
{
    gIOKit = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!gIOKit) { BKAppend(@"I io=0"); return NO; }
    gIO.ClientCreate = dlsym(gIOKit, "IOHIDEventSystemClientCreate");
    gIO.RegisterCB   = dlsym(gIOKit, "IOHIDEventSystemClientRegisterEventCallback");
    gIO.SetQueue     = dlsym(gIOKit, "IOHIDEventSystemClientSetDispatchQueue");
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
    return YES;
}

// ------------------------------------------------------------- cursor/fps ---
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

// Troca atômica do dedo da câmera: o dedo antigo termina e o novo nasce no
// centro NO MESMO evento de mão. Sem frame vazio, sem toque engolido.
static void BKAimRecenter(int fromSlot, double cx, double cy)
{
    int toSlot = gAimB ? (kBKMaxFinger - 1) : kBKMaxFinger;
    gAimB = !gAimB;
    if (fromSlot == toSlot) return;
    BKSlotUp(fromSlot);
    gSlotOwner[toSlot] = 0;
    [gSlotOf removeObjectForKey:@(kBKIdxAim)];
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

    double nx = gAimX + dx * gFpsSens * kBKMoveFactor;
    double ny = gAimY + dy * gFpsSens * kBKMoveFactor;
    nx = BKClamp(nx); ny = BKClamp(ny);

    double px, py;
    int o = BKCurrentOrient();
    if (gRotate) BKConvInv(nx, ny, o, &px, &py);
    else { px = nx; py = ny; }

    gAimX = nx; gAimY = ny;
    BKSlotMove(gAimSlot, px, py);

    if (px < kBKEdge || px > 1.0 - kBKEdge || py < kBKEdge || py > 1.0 - kBKEdge) {
        double rx = 0.5, ry = 0.5;
        BKAimRecenter(gAimSlot, rx, ry);
        gAimX = 0.5; gAimY = 0.5;
        gAimSlot = [gSlotOf[@(kBKIdxAim)] intValue];
        BKAppendD([NSString stringWithFormat:@"F borda->centro dedo=%d", gAimSlot]);
    }
}

static void BKFpsEnsure(void)
{
    if (!gFps) return;
    if (gAimSlot && gAct[gAimSlot].on) return;
    double px = 0.5, py = 0.5;
    gAimX = 0.5; gAimY = 0.5;
    BKDown(kBKIdxAim, px, py);
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
    // cursor volta ao centro SEM tocar na câmera: só o dedo da mira é solto.
    gCx = 0.5; gCy = 0.5;
    gLastPtrWrite = 0;
    BKPtrWrite();
    BKAppend(@"F off");
    notify_post("com.wjf.ballkey.fps_off");
}

// -------------------------------------------------------------- config -----
static void BKLoadConfig(void)
{
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
    BOOL enabled = [cfg[@"Enabled"] boolValue];
    NSString *active = cfg[@"ActiveBundle"];
    NSArray *pts = nil;
    NSDictionary *profiles = cfg[@"Profiles"];
    if ([profiles isKindOfClass:[NSDictionary class]] && [active isKindOfClass:[NSString class]]) {
        id p = profiles[active];
        if ([p isKindOfClass:[NSArray class]]) pts = p;
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

static void BKStatus(void)
{
    NSString *s = [NSString stringWithFormat:
        @"enabled=%d bundle=%@ pontos=%lu fps=%d dedos=%d:%d:%d o=%d\n",
        (int)gEnabled, gActiveBundle ?: @"-", (unsigned long)gPoints.count,
        (int)gFps, (int)gAct[1].on, (int)gAct[2].on, (int)gAct[3].on, BKCurrentOrient()];
    [s writeToFile:kBKStatusPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

// -------------------------------------------------------------- captura ----
static void BKCaptureWrite(NSString *key)
{
    if (!gCapArm || !gCapNonce) return;
    gCapArm = NO;
    gCapHave = YES;
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
    gCapHave = NO;
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

// ------------------------------------------------------------- handlers ----
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

static void BKListenCB(void *target, void *refcon, void *service, BKIOHIDEventRef event)
{
    (void)target; (void)refcon; (void)service;
    @try {
        if (!gIO.GetType || !event) return;
        int type = gIO.GetType(event);
        gEvSeen++;

        if (type == kBKTypePointer) {
            double x = gIO.GetFloat(event, kBKFieldX);
            double y = gIO.GetFloat(event, kBKFieldY);
            if (gLastPtrValid) {
                double dx = x - gLastPtrX;
                double dy = y - gLastPtrY;
                if (fabs(dx) < 9000 && fabs(dy) < 9000) {
                    if (gFps) BKFpsMove(dx, dy);
                    else if (gCursorOn) BKCursorMove(dx, dy);
                }
            }
            gLastPtrX = x; gLastPtrY = y; gLastPtrValid = YES;
            BKAppendD([NSString stringWithFormat:@"P x=%.1f y=%.1f", x, y]);
            return;
        }

        if (type == kBKTypeDigitizer) {
            int btn = gIO.GetInt(event, kBKFieldBtnMask);
            if (btn) BKAppendD([NSString stringWithFormat:@"Dg btn=%d", btn]);
            return;
        }

        if (type == kBKTypeKeyExtra || type == kBKTypeKeyboard) {
            int page = gIO.GetInt(event, (3u << 16 | 0u));
            int usage = gIO.GetInt(event, (3u << 16 | 1u));
            int down = gIO.GetInt(event, (3u << 16 | 2u));
            if (page != 7 && page != 0) return;
            BKAppendD([NSString stringWithFormat:@"K %d d=%d", usage, down]);
            BKHandleKey(usage, down != 0);
            return;
        }

        if (type == kBKTypeBtn || type == kBKTypeButton) {
            int usage = gIO.GetInt(event, kBKFieldBtnMask);
            if (!usage) return;
            int b = usage - kBKUsageBtnBase;
            if (b < 0 || b >= kBKMaxBtn) return;
            int down = gIO.GetInt(event, (kBKTypeBtn << 16 | 3u));
            BKHandleButton(b, down != 0);
            return;
        }
    } @catch (NSException *e) { }
}

// ---------------------------------------------------------------- testes ----
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

// ------------------------------------------------------------------ init ----
static BKIOHIDEventSystemClientRef BKNewListen(void)
{
    BKIOHIDEventSystemClientRef c = gIO.ClientCreate(kCFAllocatorDefault);
    if (!c) return NULL;
    if (gIO.RegisterCB) gIO.RegisterCB(c, (void *)BKListenCB, NULL, NULL);
    if (gIO.SetQueue) gIO.SetQueue(c, dispatch_get_main_queue());
    if (gIO.Activate) gIO.Activate(c);
    return c;
}

__attribute__((constructor)) static void BKInitC(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
        gDown = [NSMutableDictionary dictionary];
        gGen = [NSMutableDictionary dictionary];
        gSlotOf = [NSMutableDictionary dictionary];
        gKeyDown = [NSMutableDictionary dictionary];
        gEnding = [NSMutableSet set];
        gSendQ = dispatch_queue_create("com.wjf.ballkey.send", DISPATCH_QUEUE_SERIAL);

        if (!BKInitIO()) return;

        gSendClient = gIO.ClientCreate(kCFAllocatorDefault);
        BKAppend(gSendClient ? @"I send=1" : @"I send=0");

        @try {
            gListenClient = BKNewListen();
            if (!gListenClient) { BKAppend(@"I client=0"); return; }
            BKAppend(@"I listen=1");
        } @catch (NSException *e) {
            BKAppend([NSString stringWithFormat:@"! init %@", e.reason]);
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
                @try { BKCaptureWatch(); BKFpsEnsure(); } @catch (NSException *e) { }
            });
            dispatch_resume(src);
        }

        BKAppend(@"I ready");
        BKMark(@"engine_loaded.txt");
        }
    });
}
