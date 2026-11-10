// Teclado e Mouse Mapeador / Engine / Tweak.x
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
#define kBKCaptureReqPath       @"/var/mobile/bk_capture.txt"
#define kBKCaptureResPath       @"/var/mobile/bk_capture_result.txt"
#define kBKNotifyReload         "com.wjf.ballkey.reload"
#define kBKNotifyTest           "com.wjf.ballkey.test"
#define kBKNotifyProbe          "com.wjf.ballkey.probe"
#define kBKNotifyClose          "com.wjf.ballkey.close"

#define kBKTransducerHand       0x23
#define kBKSenderID             0x8000000817319372ull
#define kBKParentBase           100
#define kBKChildIdentity        3
#define kBKChildIndex           1
#define kBKMaxFinger            10

#define kBKFieldHandMask        (11u << 16 | 7u)
#define kBKFieldRange           (11u << 16 | 8u)
#define kBKFieldTouch           (11u << 16 | 9u)
#define kBKFieldX               (11u << 16 | 0u)
#define kBKFieldY               (11u << 16 | 1u)
#define kBKFieldBtnMask         (11u << 16 | 3u)
#define kBKFieldMajorR          0xb0014u
#define kBKFieldMinorR          0xb0015u
#define kBKFieldDisplayInt      0xb0019u
#define kBKFieldIsBuiltIn       0x4u

#define kBKPhaseBegan           1
#define kBKPhaseMoved           2
#define kBKPhaseEnded           3
#define kBKPhaseDelayUs         8000

#define kBKFlagRange            0x01u
#define kBKFlagTouch            0x02u
#define kBKFlagPosition         0x04u

#define kBKTypeKeyExtra         15
#define kBKTypePointer          17
#define kBKTypeDigitizer        11
#define kBKTypeMove             12
#define kBKTypeBtn              32
#define kBKTypeButton           2

#define kBKDefaultFpsKey        224
#define kBKCtrlRight            228
#define kBKPageBtn              12
#define kBKUsageBtnBase         64
#define kBKMaxBtn               3

#define kBKMoveFactor           0.0015
#define kBKMoveDead             0.4
#define kBKMoveDedupNs          4000000ull
#define kBKEdge                 0.05
#define kBKRecenter             0.34
#define kBKPtrScale             3000.0

#define kBKKey3GraceNs          80000000ull
#define kBKTravaGuardNs         250000000ull
#define kBKBtnWatchNs           1500000000ull
#define kBKBtnLockNs            100000000ull
#define kBKNumGraceNs           250000000ull
#define kBKCapIgnoreNs          120000000ull

#define kIOHIDEventTypeKeyboard                3
#define kIOHIDEventFieldKeyboardUsagePage      (3u << 16 | 0u)
#define kIOHIDEventFieldKeyboardUsage          (3u << 16 | 1u)
#define kIOHIDEventFieldKeyboardDown           (3u << 16 | 2u)
#define kIOHIDEventFieldKeyboardRepeat         (3u << 16 | 3u)

#define kBKIdxAim               70
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
static NSMutableDictionary *gCur = nil;
static NSMutableDictionary *gSlotOf = nil;
static int gSlotOwner[kBKMaxFinger + 1];
static BOOL gRotate = YES;
static BOOL gFollowCursor = NO;
static double gFollowSens = 1.0;
static int gOrientOverride = 0;
static BOOL gDump = NO;
static BOOL gFps = NO;
static double gFpsSens = 1.0;
static int gFpsKey = kBKDefaultFpsKey;
static double gFpsX = 0.5, gFpsY = 0.5;
static double gFireX = 0.83, gFireY = 0.66;
static double gAdsX = 0.95, gAdsY = 0.53;
static double gAimX = 0.5, gAimY = 0.5;
static BOOL gFireSet = NO, gAdsSet = NO;
static BOOL gFogoDown = NO, gMirarDown = NO, gAdsDown = NO;
static int gBtnOwner[kBKMaxBtn] = {0, 0, 0};
static uint64_t gBtnOwnerNs[kBKMaxBtn] = {0, 0, 0};
static int gLastBtnNum = -1;
static uint64_t gLastBtnNs = 0;
static NSMutableDictionary *gKeyDown = nil;
static NSMutableDictionary *gKeyLast3 = nil;
static uint64_t gFpsToggleNs = 0;
static BOOL gDirActive = NO;
static double gDirCX = 0, gDirCY = 0;
static double gDirPX[4] = {0,0,0,0};
static double gDirPY[4] = {0,0,0,0};
static BOOL gDirHeld[4] = {NO,NO,NO,NO};
static double gDirSens = 1.0;
static double gCx = 0.5, gCy = 0.5;
static int gLastOrient = 3;
static int gEvSeen = 0;
static int gLastExtra = -1;
static uint64_t gLastExtraNs = 0;
static double gLastPtrX = 0, gLastPtrY = 0;
static int gLastPtrValid = 0;
static double gLastMdx = 0, gLastMdy = 0;
static uint64_t gLastMNs = 0;
static int gFpsMoveLog = 0;
static int gFpsRepor = 0;
static int gM11Zero = 0;
static BOOL gCaptureArmed = NO;
static uint64_t gCaptureArmNs = 0;
static int gCapKey = -1;
static NSString *gCapReq = nil;

static void BKSendLast(NSNumber *idx);
static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev);
static void BKReleaseAll(void);
static void BKHandleButton(int b, BOOL down);
static void BKLoadConfig(void);

static uint64_t BKNowNs(void)
{
    static mach_timebase_info_data_t tb;
    static int once = 0;
    if (!once) { mach_timebase_info(&tb); once = 1; }
    uint64_t t = mach_absolute_time();
    if (tb.denom == 0) return t;
    return t * tb.numer / tb.denom;
}

static void BKAppend(NSString *line)
{
    NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kBKLogPath];
    if (!fh) { [d writeToFile:kBKLogPath atomically:YES]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
    @catch (NSException *e) { }
}

static void BKMark(NSString *name)
{
    [name writeToFile:[@"/var/mobile/bk_" stringByAppendingString:name]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BKStatus(void)
{
    NSString *s = [NSString stringWithFormat:@"ativo=%d marcadores=%lu app=%@ trava=%d tecla=%d sensi=%.2f ev=%d",
                   (int)gEnabled, (unsigned long)gPoints.count, gActiveBundle ?: @"-",
                   (int)gFps, gFpsKey, gFpsSens, gEvSeen];
    [s writeToFile:kBKStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL BKLoadIOKit(void)
{
    if (gIOKit) return YES;
    gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!gIOKit) gIOKit = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
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

static BKIOHIDEventSystemClientRef BKNewListen(void)
{
    BKIOHIDEventSystemClientRef c = gIO.ClientCreate(kCFAllocatorDefault);
    if (!c) return NULL;
    if (gIO.RegisterCB) gIO.RegisterCB(c, BKListenCB, NULL, NULL);
    if (gIO.SetQueue) gIO.SetQueue(c, dispatch_get_main_queue());
    if (gIO.Activate) gIO.Activate(c);
    return c;
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

static int BKDeviceOrientation(void)
{
    Class c = objc_getClass("UIDevice");
    if (!c) return 0;
    id d = ((id (*)(id, SEL))objc_msgSend)(c, @selector(currentDevice));
    if (!d) return 0;
    return (int)((int (*)(id, SEL))objc_msgSend)(d, @selector(orientation));
}

static int BKCurrentOrient(void)
{
    if (gOrientOverride) return gOrientOverride;
    int o = BKFrontMostOrientation();
    if (o) { gLastOrient = o; return o; }
    if (gLastOrient >= 1 && gLastOrient <= 4) return gLastOrient;
    int d = BKDeviceOrientation();
    if (d >= 1 && d <= 4) { gLastOrient = d; return d; }
    return 3;
}

static double BKClamp(double v) { if (v < 0) return 0; if (v > 1) return 1; return v; }

// Paisagem esquerda e paisagem direita são 180° uma da outra: a segunda inverte
// os dois eixos. Estavam trocadas, e por isso mira, teclas e captura saíam
// espelhados.
static void BKConvInv(double vx, double vy, int orient, double *ox, double *oy)
{
    double rx = vx, ry = vy;
    switch (orient) {
        case 2: rx = 1.0 - vx; ry = 1.0 - vy; break;
        case 3: rx = vy;       ry = 1.0 - vx; break;
        case 4: rx = 1.0 - vy; ry = vx;       break;
        default: break;
    }
    *ox = BKClamp(rx);
    *oy = BKClamp(ry);
}

static void BKConv(double rx, double ry, int orient, double *ox, double *oy)
{
    double vx = rx, vy = ry;
    switch (orient) {
        case 2: vx = 1.0 - rx; vy = 1.0 - ry; break;
        case 3: vx = 1.0 - ry; vy = rx;       break;
        case 4: vx = ry;       vy = 1.0 - rx; break;
        default: break;
    }
    *ox = BKClamp(vx);
    *oy = BKClamp(vy);
}

static int BKUsageFromKey(id k)
{
    if (![k isKindOfClass:[NSString class]]) return 0;
    NSArray *p = [(NSString *)k componentsSeparatedByString:@":"];
    if (p.count != 2 || ![p[0] isEqualToString:@"k"]) return 0;
    return [p[1] intValue];
}

static void BKLoadConfig(void)
{
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
    BOOL enabled = [cfg[@"Enabled"] boolValue];
    NSString *active = cfg[@"ActiveBundle"];
    NSArray *pts = nil;
    BOOL hasProfile = NO;
    NSDictionary *profiles = cfg[@"Profiles"];
    if ([profiles isKindOfClass:[NSDictionary class]] && [active isKindOfClass:[NSString class]]) {
        id p = profiles[active];
        if ([p isKindOfClass:[NSArray class]]) { pts = p; hasProfile = YES; }
    }

    if ([cfg[@"Rotate"] isKindOfClass:[NSNumber class]]) gRotate = [cfg[@"Rotate"] boolValue];
    if ([cfg[@"FollowCursor"] isKindOfClass:[NSNumber class]]) gFollowCursor = [cfg[@"FollowCursor"] boolValue];
    if ([cfg[@"FollowSens"] isKindOfClass:[NSNumber class]]) gFollowSens = [cfg[@"FollowSens"] doubleValue];
    if ([cfg[@"OrientOverride"] isKindOfClass:[NSNumber class]]) gOrientOverride = [cfg[@"OrientOverride"] intValue];
    if ([cfg[@"Dump"] isKindOfClass:[NSNumber class]]) gDump = [cfg[@"Dump"] boolValue];
    if ([cfg[@"FpsSens"] isKindOfClass:[NSNumber class]]) gFpsSens = [cfg[@"FpsSens"] doubleValue];
    if ([cfg[@"FpsX"] isKindOfClass:[NSNumber class]]) gFpsX = [cfg[@"FpsX"] doubleValue];
    if ([cfg[@"FpsY"] isKindOfClass:[NSNumber class]]) gFpsY = [cfg[@"FpsY"] doubleValue];
    if ([cfg[@"FireX"] isKindOfClass:[NSNumber class]]) { gFireX = [cfg[@"FireX"] doubleValue]; gFireSet = YES; }
    if ([cfg[@"FireY"] isKindOfClass:[NSNumber class]]) { gFireY = [cfg[@"FireY"] doubleValue]; gFireSet = YES; }
    if ([cfg[@"AdsX"] isKindOfClass:[NSNumber class]]) { gAdsX = [cfg[@"AdsX"] doubleValue]; gAdsSet = YES; }
    if ([cfg[@"AdsY"] isKindOfClass:[NSNumber class]]) { gAdsY = [cfg[@"AdsY"] doubleValue]; gAdsSet = YES; }

    int fk = BKUsageFromKey(cfg[@"FpsKey"]);
    gFpsKey = fk > 0 ? fk : kBKDefaultFpsKey;

    // perfil vazio é perfil vazio: não volta a lista antiga depois de "Limpar tudo"
    if (hasProfile) { gPoints = pts; gActiveBundle = active; }
    else if (gPoints.count == 0) { gActiveBundle = active; gPoints = pts; }

    gEnabled = enabled && gPoints.count > 0;
    gFps = NO;
    gFogoDown = NO;
    gMirarDown = NO;
    gAdsDown = NO;
    for (int i = 0; i < kBKMaxBtn; i++) gBtnOwner[i] = 0;
    gLastBtnNum = -1;
    [gKeyDown removeAllObjects];
    [gKeyLast3 removeAllObjects];
    gFpsToggleNs = 0;
    gAimX = gFpsX;
    gAimY = gFpsY;

    if (!gEnabled) BKReleaseAll();

    BKStatus();
    BKAppend([NSString stringWithFormat:@"C en=%d b=%@ n=%lu key=%d fogo=%d mirar=%d",
              (int)gEnabled, gActiveBundle ?: @"-", (unsigned long)gPoints.count, gFpsKey,
              (int)gFireSet, (int)gAdsSet]);
}

static void BKNotifyUserActivity(void)
{
    Class cls = objc_getClass("BKUserEventTimer");
    if (!cls) return;
    id timer = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    if (!timer) return;
    SEL s1 = @selector(userEventOccurred);
    SEL s2 = @selector(userEventOccurredOnDisplay:);
    if ([timer respondsToSelector:s1]) ((void (*)(id, SEL))objc_msgSend)(timer, s1);
    else if ([timer respondsToSelector:s2]) ((void (*)(id, SEL, id))objc_msgSend)(timer, s2, nil);
}

// Cada ponto lógico tem dedo próprio. Sem isso todos os pontos usavam o mesmo
// índice de dedo e o sistema tratava dois toques simultâneos como o mesmo toque:
// a tecla "roubava" a mira e a mira "roubava" o tiro.
static int BKSlotFor(NSUInteger idx)
{
    NSNumber *n = gSlotOf[@(idx)];
    if (n) return [n intValue];
    for (int s = 1; s <= kBKMaxFinger; s++) {
        if (gSlotOwner[s]) continue;
        gSlotOwner[s] = (int)idx + 1;
        gSlotOf[@(idx)] = @(s);
        return s;
    }
    gSlotOf[@(idx)] = @1;
    return 1;
}

static void BKSlotFree(NSUInteger idx)
{
    NSNumber *n = gSlotOf[@(idx)];
    if (!n) return;
    int s = [n intValue];
    if (s >= 1 && s <= kBKMaxFinger) gSlotOwner[s] = 0;
    [gSlotOf removeObjectForKey:@(idx)];
}

static BKIOHIDEventRef BKChild(double x, double y, int phase)
{
    uint32_t mask = kBKFlagRange | kBKFlagTouch;
    BOOL range = YES, touch = YES;
    if (phase == kBKPhaseMoved) mask = kBKFlagPosition;
    else if (phase == kBKPhaseEnded) { mask = kBKFlagTouch; range = NO; touch = NO; }

    BKIOHIDEventRef child = gIO.CreateFinger(kCFAllocatorDefault, mach_absolute_time(),
        kBKChildIndex, kBKChildIdentity, mask, x, y, 0.0, 0.0, 0.0,
        (uint8_t)range, (uint8_t)touch, 0);
    if (child) {
        gIO.SetFloat(child, kBKFieldMajorR, 0.04);
        gIO.SetFloat(child, kBKFieldMinorR, 0.04);
    }
    return child;
}

static void BKPost(double x, double y, int phase, int slot)
{
    if (!gIO.Dispatch) return;
    if (slot < 1) slot = 1;
    if (slot > kBKMaxFinger) slot = kBKMaxFinger;
    uint32_t parent = (uint32_t)(kBKParentBase + slot);
    @try {
    BKIOHIDEventRef parent = gIO.CreateDigitizer(kCFAllocatorDefault, mach_absolute_time(),
        kBKTransducerHand, parent, parent, 0, 0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0);
    if (!parent) { BKAppend(@"! sem parent"); return; }

    gIO.SetInt(parent, kBKFieldDisplayInt, 1);
    gIO.SetInt(parent, kBKFieldIsBuiltIn, 1);

    BKIOHIDEventRef child = BKChild(x, y, phase);
    if (child) { gIO.Append(parent, child, 0); CFRelease(child); }
    else { BKAppend(@"! sem child"); }

    gIO.SetInt(parent, kBKFieldHandMask, 0x23);
    gIO.SetInt(parent, kBKFieldRange, 1);
    gIO.SetInt(parent, kBKFieldTouch, 1);
    gIO.SetSender(parent, kBKSenderID);

    CFRetain(parent);
    dispatch_async(gSendQ, ^{
        @try { if (gSendClient) gIO.Dispatch(gSendClient, parent); }
        @catch (NSException *e) { }
        CFRelease(parent);
    });

    BKNotifyUserActivity();
    BKAppend([NSString stringWithFormat:@"D ph=%d o=%d x=%.3f y=%.3f s=%d", phase,
              BKCurrentOrient(), x, y, slot]);
    } @catch (NSException *e) {
        BKAppend([NSString stringWithFormat:@"! send %@", e.reason]);
    }
}

static void BKSendLast(NSNumber *idx)
{
    NSArray *a = gCur[idx];
    if (![a isKindOfClass:[NSArray class]] || a.count < 2) return;
    NSNumber *sn = gSlotOf[idx];
    BKPost([a[0] doubleValue], [a[1] doubleValue], kBKPhaseEnded, sn ? [sn intValue] : 1);
}

static void BKDown(NSUInteger idx, double nx, double ny)
{
    if ([gDown[@(idx)] boolValue]) return;
    nx = BKClamp(nx); ny = BKClamp(ny);
    gDown[@(idx)] = @YES;
    gCur[@(idx)] = @[ @(nx), @(ny) ];
    BKPost(nx, ny, kBKPhaseBegan, BKSlotFor(idx));
}

static void BKMove(NSUInteger idx, double nx, double ny)
{
    if (![gDown[@(idx)] boolValue]) return;
    nx = BKClamp(nx); ny = BKClamp(ny);
    gCur[@(idx)] = @[ @(nx), @(ny) ];
    NSNumber *sn = gSlotOf[@(idx)];
    BKPost(nx, ny, kBKPhaseMoved, sn ? [sn intValue] : 1);
}

static void BKUp(NSUInteger idx)
{
    if (![gDown[@(idx)] boolValue]) return;
    gDown[@(idx)] = @NO;
    BKSendLast(@(idx));
    [gCur removeObjectForKey:@(idx)];
    BKSlotFree(idx);
}

static void BKTap(NSUInteger idx, double nx, double ny)
{
    if ([gDown[@(idx)] boolValue]) BKUp(idx);
    BKDown(idx, nx, ny);
    NSNumber *gen = @([gGen[@(idx)] intValue] + 1);
    gGen[@(idx)] = gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kBKPhaseDelayUs * 1000ull),
                   dispatch_get_main_queue(), ^{
        if (![gGen[@(idx)] isEqualToNumber:gen]) return;
        BKMove(idx, nx, ny);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kBKPhaseDelayUs * 1000ull),
                       dispatch_get_main_queue(), ^{
            if ([gGen[@(idx)] isEqualToNumber:gen]) BKUp(idx);
        });
    });
}

static void BKHold(NSUInteger idx, double nx, double ny, int ms)
{
    BKDown(idx, nx, ny);
    NSNumber *gen = @([gGen[@(idx)] intValue] + 1);
    gGen[@(idx)] = gen;
    if (ms < 60) ms = 60;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if ([gGen[@(idx)] isEqualToNumber:gen]) BKUp(idx);
    });
}

static void BKReleaseAll(void)
{
    for (NSNumber *k in gDown.allKeys) {
        if ([gDown[k] boolValue]) { gDown[k] = @NO; BKSendLast(k); }
    }
    [gCur removeAllObjects];
    [gGen removeAllObjects];
    [gSlotOf removeAllObjects];
    for (int i = 0; i <= kBKMaxFinger; i++) gSlotOwner[i] = 0;
    for (int i = 0; i < 4; i++) gDirHeld[i] = NO;
    gDirActive = NO;
    gFps = NO;
    gFogoDown = NO;
    gMirarDown = NO;
    gAdsDown = NO;
    for (int i = 0; i < kBKMaxBtn; i++) gBtnOwner[i] = 0;
    gAimX = gFpsX;
    gAimY = gFpsY;
}

static void BKPonto(NSDictionary *pt, double *ox, double *oy)
{
    double nx = [pt[@"X"] doubleValue];
    double ny = [pt[@"Y"] doubleValue];
    if (gRotate) BKConvInv(nx, ny, BKCurrentOrient(), &nx, &ny);
    *ox = nx; *oy = ny;
}

static void BKPar(NSDictionary *pt, NSString *k, double *ox, double *oy)
{
    NSString *s = pt[k];
    double nx = 0.5, ny = 0.5;
    if ([s isKindOfClass:[NSString class]]) {
        NSArray *p = [s componentsSeparatedByString:@","];
        if (p.count >= 2) { nx = [p[0] doubleValue]; ny = [p[1] doubleValue]; }
    }
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
            double cx, cy;
            BKPar(pt, @"Center", &cx, &cy);
            gDirCX = cx; gDirCY = cy;
            for (int i = 0; i < 4; i++) {
                NSString *k = @[@"Up", @"Down", @"Left", @"Right"][i];
                BKPar(pt, k, &gDirPX[i], &gDirPY[i]);
                gDirHeld[i] = NO;
            }
            BKDown(kBKIdxDir, gDirCX, gDirCY);
        }
        gDirHeld[dir] = YES;
        BKMove(kBKIdxDir, (gDirPX[dir] - gDirCX) * gDirSens + gDirCX,
                            (gDirPY[dir] - gDirCY) * gDirSens + gDirCY);
        return;
    }
    if (!gDirActive) return;
    gDirHeld[dir] = NO;
    for (int i = 0; i < 4; i++) {
        if (gDirHeld[i]) {
            BKMove(kBKIdxDir, (gDirPX[i] - gDirCX) * gDirSens + gDirCX,
                                (gDirPY[i] - gDirCY) * gDirSens + gDirCY);
            return;
        }
    }
    BKMove(kBKIdxDir, gDirCX, gDirCY);
    BKUp(kBKIdxDir);
    gDirActive = NO;
}

// Um único acumulador alimenta o cursor e o ponto injetado. A borda é medida já
// na coordenada girada, que é a que existe na tela.
static void BKFpsMove(double dx, double dy)
{
    if (!gFps || (dx == 0 && dy == 0)) return;
    if (fabs(dx) < kBKMoveDead && fabs(dy) < kBKMoveDead) return;

    uint64_t now = BKNowNs();
    if (dx == gLastMdx && dy == gLastMdy && (now - gLastMNs) < kBKMoveDedupNs) return;
    gLastMdx = dx; gLastMdy = dy; gLastMNs = now;

    double nx = gAimX + dx * gFpsSens * kBKMoveFactor;
    double ny = gAimY + dy * gFpsSens * kBKMoveFactor;

    int o = BKCurrentOrient();
    double px, py;
    if (gRotate) BKConvInv(nx, ny, o, &px, &py);
    else { px = BKClamp(nx); py = BKClamp(ny); }

    if (px < kBKEdge || px > 1.0 - kBKEdge || py < kBKEdge || py > 1.0 - kBKEdge) {
        BKUp(kBKIdxAim);
        double rx = px, ry = py;
        if (px < kBKEdge) rx = px + kBKRecenter;
        else if (px > 1.0 - kBKEdge) rx = px - kBKRecenter;
        if (py < kBKEdge) ry = py + kBKRecenter;
        else if (py > 1.0 - kBKEdge) ry = py - kBKRecenter;
        rx = BKClamp(rx); ry = BKClamp(ry);
        double bx = rx, by = ry;
        if (gRotate) BKConv(rx, ry, o, &bx, &by);
        else { bx = rx; by = ry; }
        gAimX = bx; gAimY = by;
        BKDown(kBKIdxAim, rx, ry);
        BKAppend([NSString stringWithFormat:@"F recuo x=%.3f y=%.3f", bx, by]);
        return;
    }

    gAimX = nx; gAimY = ny;
    BKMove(kBKIdxAim, px, py);
    if (gFpsMoveLog < 40) {
        gFpsMoveLog++;
        BKAppend([NSString stringWithFormat:@"F move dx=%.2f dy=%.2f x=%.3f y=%.3f",
                  dx, dy, gAimX, gAimY]);
    }
}

static void BKFpsEnsure(void)
{
    if (!gFps) return;
    if ([gDown[@(kBKIdxAim)] boolValue]) return;
    double px = gAimX, py = gAimY;
    if (gRotate) BKConvInv(gAimX, gAimY, BKCurrentOrient(), &px, &py);
    BKDown(kBKIdxAim, px, py);
    if (gFpsRepor < 30) { gFpsRepor++; BKAppend(@"F repor"); }
}

static void BKFpsOn(void)
{
    if (gFps) return;
    gFps = YES;
    gFpsMoveLog = 0;
    gFpsRepor = 0;
    BKUp(kBKIdxCursor);
    gAimX = gFpsX;
    gAimY = gFpsY;
    double px = gFpsX, py = gFpsY;
    if (gRotate) BKConvInv(gFpsX, gFpsY, BKCurrentOrient(), &px, &py);
    BKDown(kBKIdxAim, px, py);
    BKAppend([NSString stringWithFormat:@"F on ponto=%.3f,%.3f fogo=%.3f,%.3f mirar=%.3f,%.3f",
              gFpsX, gFpsY, gFireX, gFireY, gAdsX, gAdsY]);
    BKStatus();
}

static void BKFpsOff(void)
{
    if (!gFps) return;
    gFps = NO;
    if (gFogoDown) { gFogoDown = NO; BKUp(kBKIdxFogo); }
    if (gAdsDown) { gAdsDown = NO; BKUp(kBKIdxAds); }
    if (gMirarDown) { gMirarDown = NO; BKUp(kBKIdxMirar); }
    BKUp(kBKIdxAim);
    for (int i = 0; i < kBKMaxBtn; i++) gBtnOwner[i] = 0;
    BKAppend(@"F off");
    BKStatus();
}

static void BKFpsToggle(void) { if (gFps) BKFpsOff(); else BKFpsOn(); }

// Segurar = rajada contínua; soltar = para. Um clique curto gera um toque só.
static void BKFpsFire(BOOL down)
{
    if (!gEnabled || !gPoints.count) return;
    if (down) {
        if (gFogoDown) return;
        gFogoDown = YES;
        double px = gFireX, py = gFireY;
        if (gRotate) BKConvInv(gFireX, gFireY, BKCurrentOrient(), &px, &py);
        BKDown(kBKIdxFogo, px, py);
    } else {
        if (!gFogoDown) return;
        gFogoDown = NO;
        BKUp(kBKIdxFogo);
    }
}

// Um clique liga a mira, outro clique desliga. O dedo fica preso no ponto
// enquanto a mira estiver ativa.
static void BKFpsAdsToggle(void)
{
    if (!gEnabled || !gPoints.count) return;
    if (gAdsDown) {
        gAdsDown = NO;
        BKUp(kBKIdxAds);
        return;
    }
    gAdsDown = YES;
    double px = gAdsX, py = gAdsY;
    if (gRotate) BKConvInv(gAdsX, gAdsY, BKCurrentOrient(), &px, &py);
    BKDown(kBKIdxAds, px, py);
}

static void BKCursorMove(double dx, double dy)
{
    gCx = BKClamp(gCx + dx * gFollowSens * kBKMoveFactor);
    gCy = BKClamp(gCy + dy * gFollowSens * kBKMoveFactor);
}

static void BKCursorTap(void)
{
    double px = gCx, py = gCy;
    if (gRotate) BKConvInv(gCx, gCy, BKCurrentOrient(), &px, &py);
    BKTap(kBKIdxCursor, px, py);
}

static void BKHandlePoint(NSDictionary *pt, NSUInteger idx, BOOL down)
{
    NSString *type = pt[@"Type"] ?: @"Tap";
    double nx, ny;
    BKPonto(pt, &nx, &ny);
    if ([type isEqualToString:@"Tap"]) { if (down) BKTap(idx, nx, ny); }
    else if ([type isEqualToString:@"Press"]) { if (down) BKDown(idx, nx, ny); else BKUp(idx); }
    else if ([type isEqualToString:@"Hold"]) {
        if (down) BKHold(idx, nx, ny, pt[@"HoldMs"] ? [pt[@"HoldMs"] intValue] : 400);
    }
}

static int BKDirOfKey(NSString *key)
{
    if ([key isEqualToString:@"k:26"] || [key isEqualToString:@"k:82"]) return 0;
    if ([key isEqualToString:@"k:22"] || [key isEqualToString:@"k:81"]) return 1;
    if ([key isEqualToString:@"k:4"]  || [key isEqualToString:@"k:80"]) return 2;
    if ([key isEqualToString:@"k:7"]  || [key isEqualToString:@"k:79"]) return 3;
    return -1;
}

static void BKHandleKey(int usage, BOOL down)
{
    NSString *key = [NSString stringWithFormat:@"k:%d", usage];
    int d = BKDirOfKey(key);
    if (d >= 0) {
        for (NSUInteger i = 0; i < gPoints.count; i++) {
            NSDictionary *pt = gPoints[i];
            if (![pt[@"Type"] isEqualToString:@"Dir"]) continue;
            BKHandleDir(pt, d, down);
            BKAppend([NSString stringWithFormat:@"B %@ dir=%d d=%d", key, d, (int)down]);
            return;
        }
    }
    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        NSString *t = pt[@"Type"];
        if ([t isEqualToString:@"Dir"] || [t isEqualToString:@"Fps"]) continue;
        NSString *k = pt[@"Key"];
        if (![k isKindOfClass:[NSString class]] || ![k isEqualToString:key]) continue;
        BKHandlePoint(pt, i, down);
        BKAppend([NSString stringWithFormat:@"B %@ hit=1", key]);
        return;
    }
    BKAppend([NSString stringWithFormat:@"B %@ hit=0", key]);
}

// Tipo 3 manda o estado real; tipo 15 só vale quando o tipo 3 não falou nada
// sobre a mesma tecla nos últimos 80 ms.
static BOOL BKKeyEdge(int usage, int downHint, BOOL *outDown)
{
    NSNumber *k = @(usage);
    uint64_t now = BKNowNs();
    if (downHint >= 0) {
        gKeyLast3[k] = @(now);
        BOOL cur = [gKeyDown[k] boolValue];
        if (cur == (downHint != 0)) return NO;
        gKeyDown[k] = @(downHint != 0);
        *outDown = (downHint != 0);
        return YES;
    }
    uint64_t last3 = [gKeyLast3[k] unsignedLongLongValue];
    if (last3 && (now - last3) < kBKKey3GraceNs) return NO;
    BOOL cur = [gKeyDown[k] boolValue];
    BOOL nd = !cur;
    gKeyDown[k] = @(nd);
    *outDown = nd;
    return YES;
}

// Cada botão tem dono: só a fonte que apertou pode soltar.
static void BKButtonEvent(int num, BOOL down, int src)
{
    if (num < 0) num = 0;
    if (num >= kBKMaxBtn) num = kBKMaxBtn - 1;
    uint64_t now = BKNowNs();
    gLastBtnNum = num;
    gLastBtnNs = now;

    if (down) {
        if (gBtnOwner[num]) { gBtnOwnerNs[num] = now; return; }
        gBtnOwner[num] = src ? src : 1;
        gBtnOwnerNs[num] = now;
        BKAppend([NSString stringWithFormat:@"B m:%d d=1 s=%d", num, src]);
        if (gEnabled && gPoints.count) BKHandleButton(num, YES);
        return;
    }
    if (!gBtnOwner[num]) {
        BKAppend([NSString stringWithFormat:@"B m:%d d=0 s=%d orfao", num, src]);
        if (gEnabled && gPoints.count) BKHandleButton(num, NO);
        return;
    }
    if ((now - gBtnOwnerNs[num]) < kBKBtnLockNs) return;
    gBtnOwner[num] = 0;
    gBtnOwnerNs[num] = 0;
    BKAppend([NSString stringWithFormat:@"B m:%d d=0 s=%d", num, src]);
    if (gEnabled && gPoints.count) BKHandleButton(num, NO);
}

static void BKButtonWatch(void)
{
    uint64_t now = BKNowNs();
    for (int i = 0; i < kBKMaxBtn; i++) {
        if (!gBtnOwner[i]) continue;
        if ((now - gBtnOwnerNs[i]) < kBKBtnWatchNs) continue;
        gBtnOwner[i] = 0;
        gBtnOwnerNs[i] = 0;
        BKAppend([NSString stringWithFormat:@"B m:%d vigia", i]);
        if (gEnabled && gPoints.count) BKHandleButton(i, NO);
    }
}

static void BKHandleButton(int b, BOOL down)
{
    // Na trava o botão esquerdo é fogo e o direito é alterna-mira, sempre.
    // Fora da trava os dois caem no mapeamento normal por marcador.
    if (gFps) {
        if (b == 0) { BKFpsFire(down); return; }
        if (b == 1) { if (down) BKFpsAdsToggle(); return; }
    }
    if (b == 0 && gFollowCursor && down) { BKCursorTap(); return; }

    NSString *key = [NSString stringWithFormat:@"m:%d", b];
    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        NSString *k = pt[@"Key"];
        if (![k isKindOfClass:[NSString class]] || ![k isEqualToString:key]) continue;
        BKHandlePoint(pt, i, down);
        BKAppend([NSString stringWithFormat:@"B %@ hit=1", key]);
        return;
    }
}

// Protocolo de captura por nonce: a requisição só é consumida uma vez e o
// resultado carrega o mesmo nonce. Antes o vigia apagava o resultado antes de o
// overlay ler, e a tecla nunca chegava no marcador.
static void BKCaptureWatch(void)
{
    NSString *req = [NSString stringWithContentsOfFile:kBKCaptureReqPath
                                             encoding:NSUTF8StringEncoding error:nil];
    req = [req stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!req.length) return;
    if (gCapReq && [req isEqualToString:gCapReq]) return;
    gCapReq = req;
    gCaptureArmed = YES;
    gCaptureArmNs = BKNowNs();
    gCapKey = -1;
    BKAppend([NSString stringWithFormat:@"@ arm %@", req]);
}

static void BKCaptureSave(int usage, double x, double y)
{
    double nx = x, ny = y;
    if (gRotate) BKConv(x, y, BKCurrentOrient(), &nx, &ny);
    NSString *key = usage >= 300 ? [NSString stringWithFormat:@"m:%d", usage - 300]
                                 : [NSString stringWithFormat:@"k:%d", usage];
    NSString *out = [NSString stringWithFormat:@"%@ %@ %.4f %.4f\n", gCapReq ?: @"-", key, nx, ny];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kBKCaptureResPath];
    if (!fh) {
        [out writeToFile:kBKCaptureResPath atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) { }
    }
    BKAppend([NSString stringWithFormat:@"ov cap ok %@", key]);
}

static BOOL BKTryCapture(int type, BKIOHIDEventRef ev)
{
    if (!gCaptureArmed) return NO;
    if (BKNowNs() < gCaptureArmNs + kBKCapIgnoreNs) return NO;

    if (type == kIOHIDEventTypeKeyboard) {
        int page = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardUsage);
        int down = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardDown);
        if ((page == 0 || page == 7) && down && usage >= 4 && usage <= 231) {
            gCapKey = usage;
            BKAppend([NSString stringWithFormat:@"@ cap k:%d", usage]);
            return YES;
        }
        return NO;
    }
    if (type == kBKTypeButton || type == kBKTypeBtn || type == kBKTypePointer) {
        int num = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 0));
        int st = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 1));
        if (type == kBKTypePointer) {
            int f3 = (int)gIO.GetInt(ev, (17u << 16 | 3u));
            st = (f3 == 1);
            num = 0;
        }
        if (num < 0 || num > 2) num = 0;
        if (st) {
            gCapKey = 300 + num;
            BKAppend([NSString stringWithFormat:@"@ cap m:%d", num]);
            return YES;
        }
        return NO;
    }
    if (type == kBKTypeDigitizer) {
        if (gCapKey < 0) return NO;
        int m = (int)gIO.GetInt(ev, kBKFieldBtnMask);
        if (m != 0) return NO;
        double x = gIO.GetFloat(ev, kBKFieldX);
        double y = gIO.GetFloat(ev, kBKFieldY);
        if (x <= 0.0 && y <= 0.0) return NO;
        BKCaptureSave(gCapKey, x, y);
        gCapKey = -1;
        gCaptureArmed = NO;
        return YES;
    }
    return NO;
}

static void BKDumpEv(int type, BKIOHIDEventRef ev)
{
    if (!gDump) return;
    int f0 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 0));
    int f1 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 1));
    int f2 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 2));
    int f3 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 3));
    BKAppend([NSString stringWithFormat:@"E t=%d f=%d,%d,%d,%d", type, f0, f1, f2, f3]);
}

static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    (void)target; (void)refcon; (void)queue;
    if (!ev) return;
    @try {
    int type = gIO.GetType(ev);
    if (gIO.GetSender && gIO.GetSender(ev) == kBKSenderID) return;

    if (gEvSeen < 40) {
        gEvSeen++;
        BKAppend([NSString stringWithFormat:@"E t=%d", type]);
    }
    if (BKTryCapture(type, ev)) return;

    if (type == kIOHIDEventTypeKeyboard) {
        int page = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardUsage);
        int down = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardDown);
        int repeat = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardRepeat);
        if (repeat) return;
        if (gDump) BKAppend([NSString stringWithFormat:@"K %d pg=%d d=%d", usage, page, down]);
        if (usage <= 0) return;

        if (page == kBKPageBtn) {
            if (usage >= kBKUsageBtnBase && usage < kBKUsageBtnBase + kBKMaxBtn) {
                BKButtonEvent(usage - kBKUsageBtnBase, down != 0, 17);
            }
            return;
        }
        if ((page == 0 || page == 7) && usage >= 4 && usage <= 231) {
            if (usage == gFpsKey || (gFpsKey == kBKDefaultFpsKey &&
                                     (usage == kBKDefaultFpsKey || usage == kBKCtrlRight))) {
                if (!down) return;
                uint64_t now = BKNowNs();
                if (gFpsToggleNs && (now - gFpsToggleNs) < kBKTravaGuardNs) {
                    BKAppend([NSString stringWithFormat:@"F repetido %d", usage]);
                    return;
                }
                gFpsToggleNs = now;
                BKAppend([NSString stringWithFormat:@"F tecla %d", usage]);
                BKFpsToggle();
                return;
            }
            BOOL dn = NO;
            if (!BKKeyEdge(usage, down, &dn)) return;
            if (gEnabled && gPoints.count) BKHandleKey(usage, dn);
        }
    } else if (type == kBKTypeKeyExtra) {
        int usage = (int)gIO.GetInt(ev, 0);
        if (usage <= 0) return;
        if (!(usage >= 4 && usage <= 231)) return;
        uint64_t now = BKNowNs();
        if (usage == gLastExtra && (now - gLastExtraNs) < kBKKey3GraceNs) return;
        gLastExtra = usage;
        gLastExtraNs = now;
        if (gDump) BKAppend([NSString stringWithFormat:@"K %d (x)", usage]);
        if (usage == gFpsKey || (gFpsKey == kBKDefaultFpsKey &&
                                 (usage == kBKDefaultFpsKey || usage == kBKCtrlRight))) {
            if (gFpsToggleNs && (now - gFpsToggleNs) < kBKTravaGuardNs) return;
            gFpsToggleNs = now;
            BKAppend([NSString stringWithFormat:@"F tecla %d (x)", usage]);
            BKFpsToggle();
            return;
        }
        BOOL dn = NO;
        if (!BKKeyEdge(usage, -1, &dn)) return;
        if (gEnabled && gPoints.count) BKHandleKey(usage, dn);
    } else if (type == kBKTypeDigitizer) {
        double x = gIO.GetFloat(ev, kBKFieldX);
        double y = gIO.GetFloat(ev, kBKFieldY);
        int m = (int)gIO.GetInt(ev, kBKFieldBtnMask);
        double dx = 0, dy = 0;
        if (gLastPtrValid) {
            dx = (x - gLastPtrX) * kBKPtrScale;
            dy = (y - gLastPtrY) * kBKPtrScale;
            if (fabs(dx) > 900.0 || fabs(dy) > 900.0) { dx = 0; dy = 0; }
        }
        gLastPtrX = x;
        gLastPtrY = y;
        gLastPtrValid = 1;
        if (!gFps) {
            if (dx != 0.0 || dy != 0.0) BKCursorMove(dx, dy);
            gM11Zero++;
            if (gM11Zero >= 20) {
                gM11Zero = 0;
                double px = gCx, py = gCy;
                if (gRotate) BKConvInv(gCx, gCy, BKCurrentOrient(), &px, &py);
                if ([gDown[@(kBKIdxCursor)] boolValue]) BKMove(kBKIdxCursor, px, py);
                BKAppend([NSString stringWithFormat:@"M11 zero m=0 (%d)", gEvSeen]);
            }
        }
        if (gDump) BKAppend([NSString stringWithFormat:@"M11 x=%.4f y=%.4f m=%x", x, y, m]);
    } else if (type == kBKTypeMove) {
        BKDumpEv(type, ev);
    } else if (type == kBKTypePointer) {
        double dx = gIO.GetFloat(ev, (17u << 16 | 0u));
        double dy = gIO.GetFloat(ev, (17u << 16 | 1u));
        int st = (int)gIO.GetInt(ev, (17u << 16 | 3u));
        if (gDump) BKAppend([NSString stringWithFormat:@"M17 dx=%d dy=%d s=%d",
                             (int)dx, (int)dy, st]);
        if (st == 1) { BKButtonEvent(0, YES, 17); return; }
        if (st == 2) { BKButtonEvent(0, NO, 17); return; }
        if (dx != 0 || dy != 0) BKFpsMove(dx, dy);
    } else if (type == kBKTypeButton || type == kBKTypeBtn) {
        int num = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 0));
        int st = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 1));
        if (num <= 0 && gLastBtnNum >= 0 && (BKNowNs() - gLastBtnNs) < kBKNumGraceNs) {
            num = gLastBtnNum;
        }
        if (num < 0 || num > 2) num = 0;
        BKDumpEv(type, ev);
        BKButtonEvent(num, st != 0, type);
    }
    } @catch (NSException *e) {
        BKAppend([NSString stringWithFormat:@"! cb %@", e.reason]);
    }
}

static void BKProbe(void)
{
    BKAppend(@"P ini");
    for (int i = 0; i < 10; i++) {
        int64_t d = (int64_t)(i * 320) * NSEC_PER_MSEC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d), dispatch_get_main_queue(), ^{
            double x = (i == 4 || i == 9) ? 0.5 : (i % 2 ? 0.9 : 0.1);
            double y = (i == 4 || i == 9) ? 0.5 : (i < 4 ? 0.1 : 0.9);
            double px = x, py = y;
            if (gRotate) BKConvInv(x, y, BKCurrentOrient(), &px, &py);
            BKAppend([NSString stringWithFormat:@"P %d vis=%.3f,%.3f pn=%.3f,%.3f", i, x, y, px, py]);
            BKTap(90 + (NSUInteger)i, px, py);
            if (i == 9) BKAppend(@"P fim");
        });
    }
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

static void BKEngineInit(void)
{
    gDown = [NSMutableDictionary dictionary];
    gGen = [NSMutableDictionary dictionary];
    gCur = [NSMutableDictionary dictionary];
    gSlotOf = [NSMutableDictionary dictionary];
    gKeyDown = [NSMutableDictionary dictionary];
    gKeyLast3 = [NSMutableDictionary dictionary];
    gSendQ = dispatch_queue_create("com.wjf.ballkey.send", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(gSendQ, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));

    BKAppend(@"I init");
    if (!BKLoadIOKit()) return;

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
    int t1 = 0, t2 = 0, t3 = 0;
    notify_register_dispatch(kBKNotifyReload, &t1, q, ^(int t) { (void)t; BKLoadConfig(); });
    notify_register_dispatch(kBKNotifyTest, &t2, q, ^(int t) { (void)t; BKTestCenter(); });
    notify_register_dispatch(kBKNotifyProbe, &t3, q, ^(int t) { (void)t; BKProbe(); });
    BKAppend(@"I notify=1");

    BKLoadConfig();

    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (src) {
        dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 100ull * NSEC_PER_MSEC),
                                  100ull * NSEC_PER_MSEC, 20ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(src, ^{
            @try { BKCaptureWatch(); BKButtonWatch(); BKFpsEnsure(); }
            @catch (NSException *e) { }
        });
        dispatch_resume(src);
    }

    BKAppend(@"I ready");
    BKMark(@"engine_loaded.txt");
}

__attribute__((constructor)) static void BKInitCtor(void)
{
    @autoreleasepool {
        BKMark(@"engine_ctor.txt");
        BKAppend(@"I ctor");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)800 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            @try { BKEngineInit(); }
            @catch (NSException *e) {
                BKAppend([NSString stringWithFormat:@"! init %@", e.reason]);
            }
        });
    }
}
