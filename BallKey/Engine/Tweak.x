#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <dlfcn.h>
#import <math.h>

typedef struct __IOHIDEvent *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;

typedef struct {
    BKIOHIDEventSystemClientRef (*ClientCreate)(CFAllocatorRef);
    BKIOHIDEventSystemClientRef (*ClientCreateWithType)(CFAllocatorRef, int, void *);
    void (*RegisterCB)(BKIOHIDEventSystemClientRef, void *, void *, void *);
    void (*SetQueue)(BKIOHIDEventSystemClientRef, dispatch_queue_t);
    void (*Activate)(BKIOHIDEventSystemClientRef);
    void (*Dispatch)(BKIOHIDEventSystemClientRef, BKIOHIDEventRef);
    int (*GetType)(BKIOHIDEventRef);
    int64_t (*GetInt)(BKIOHIDEventRef, int32_t);
    double (*GetFloat)(BKIOHIDEventRef, int32_t);
    uint64_t (*GetSender)(BKIOHIDEventRef);
    void (*SetInt)(BKIOHIDEventRef, int32_t, int64_t);
    void (*SetFloat)(BKIOHIDEventRef, int32_t, double);
    void (*SetSender)(BKIOHIDEventRef, uint64_t);
    void (*Append)(BKIOHIDEventRef, BKIOHIDEventRef, uint32_t);
    BKIOHIDEventRef (*CreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        uint32_t, uint32_t, double, double, double, double, double, double, uint8_t, uint8_t, uint32_t);
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
#define kBKParentBase           99
#define kBKParentIdentity       1
#define kBKChildBase            1
#define kBKChildIdentityBase    3

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
#define kBKPhaseDelayUs         50000

#define kBKFlagRange            0x01u
#define kBKFlagTouch            0x02u
#define kBKFlagPosition         0x04u

#define kBKTypeKeyExtra         15
#define kBKTypePointer          17
#define kBKTypeDigitizer        11
#define kBKTypeMove             12
#define kBKTypeBtn              32
#define kBKTypeTranslation      4
#define kBKTypeButton           2
#define kBKPtrScale             3000.0
#define kBKMoveFactor           0.0014
#define kBKDefaultFpsKey        224
#define kBKRecenter             0.38

#define kIOHIDEventTypeKeyboard                3
#define kIOHIDEventFieldKeyboardUsagePage      (3u << 16 | 0u)
#define kIOHIDEventFieldKeyboardUsage          (3u << 16 | 1u)
#define kIOHIDEventFieldKeyboardDown           (3u << 16 | 2u)
#define kIOHIDEventFieldKeyboardRepeat         (3u << 16 | 3u)

#define kBKIdxAim               70
#define kBKIdxAds               71
#define kBKIdxDir               72
#define kBKIdxCursor            40

#pragma mark - Estado

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
static NSMutableDictionary *gMaskSrc = nil;

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
static BOOL gFireSet = NO;
static BOOL gAdsSet = NO;
static double gAimX = 0.5, gAimY = 0.5;
static BOOL gAdsDown = NO;

static BOOL gDirActive = NO;
static double gDirCX = 0, gDirCY = 0;
static double gDirPX[4] = {0,0,0,0};
static double gDirPY[4] = {0,0,0,0};
static BOOL gDirHeld[4] = {NO,NO,NO,NO};
static double gDirSens = 1.0;

static double gCx = 0.5, gCy = 0.5;
static uint16_t gPrevMask = 0;
static int gPendingDir = 0;
static int gHandledUsage = -1;
static int gLastOrient = 3;
static int gEvSeen = 0;
static int gEvDump = 0;
static int gLastExtra = -1;
static uint64_t gLastExtraNs = 0;
static int gFpsMoveLog = 0;

static BOOL gCaptureArmed = NO;
static uint64_t gCaptureArmNs = 0;

static double gLastPtrX = 0, gLastPtrY = 0;
static int gLastPtrValid = 0;

static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev);

#pragma mark - Identidade por toque

// Cada toque precisa de pai, índice e identidade próprios, senão o sistema
// trata todos como o mesmo dedo e o segundo atropela o primeiro.
static uint32_t BKParentIdx(NSUInteger idx) { return (uint32_t)(kBKParentBase + (idx % 60)); }
static uint32_t BKChildIdx(NSUInteger idx)  { return (uint32_t)(kBKChildBase + (idx % 60)); }
static uint32_t BKChildId(NSUInteger idx)   { return (uint32_t)(kBKChildIdentityBase + (idx % 60)); }

#pragma mark - Tempo

static uint64_t BKNowNs(void)
{
    static mach_timebase_info_data_t tb;
    static int once = 0;
    if (!once) { mach_timebase_info(&tb); once = 1; }
    uint64_t t = mach_absolute_time();
    if (tb.denom == 0) return t;
    return t * tb.numer / tb.denom;
}

#pragma mark - Log

static void BKAppend(NSString *line)
{
    NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kBKLogPath];
    if (!fh) {
        [d writeToFile:kBKLogPath atomically:YES];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (NSException *e) {
    }
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

static void BKDumpEv(int type, BKIOHIDEventRef ev)
{
    if (!gDump || gEvDump > 200) return;
    gEvDump++;
    int f0 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 0));
    int f1 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 1));
    int f2 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 2));
    int f3 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 3));
    BKAppend([NSString stringWithFormat:@"E t=%d f=%d,%d,%d,%d", type, f0, f1, f2, f3]);
}

#pragma mark - IOKit dinâmico

static BOOL BKLoadIOKit(void)
{
    if (gIOKit) return YES;

    gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!gIOKit) gIOKit = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!gIOKit) {
        BKAppend(@"I dlopen=0");
        return NO;
    }

    gIO.ClientCreate = dlsym(gIOKit, "IOHIDEventSystemClientCreate");
    gIO.ClientCreateWithType = dlsym(gIOKit, "IOHIDEventSystemClientCreateWithType");
    gIO.RegisterCB = dlsym(gIOKit, "IOHIDEventSystemClientRegisterEventCallback");
    gIO.SetQueue = dlsym(gIOKit, "IOHIDEventSystemClientSetDispatchQueue");
    gIO.Activate = dlsym(gIOKit, "IOHIDEventSystemClientActivate");
    gIO.Dispatch = dlsym(gIOKit, "IOHIDEventSystemClientDispatchEvent");
    gIO.GetType = dlsym(gIOKit, "IOHIDEventGetType");
    gIO.GetInt = dlsym(gIOKit, "IOHIDEventGetIntegerValue");
    gIO.GetFloat = dlsym(gIOKit, "IOHIDEventGetFloatValue");
    gIO.GetSender = dlsym(gIOKit, "IOHIDEventGetSenderID");
    gIO.SetInt = dlsym(gIOKit, "IOHIDEventSetIntegerValue");
    gIO.SetFloat = dlsym(gIOKit, "IOHIDEventSetFloatValue");
    gIO.SetSender = dlsym(gIOKit, "IOHIDEventSetSenderID");
    gIO.Append = dlsym(gIOKit, "IOHIDEventAppendEvent");
    gIO.CreateDigitizer = dlsym(gIOKit, "IOHIDEventCreateDigitizerEvent");
    gIO.CreateFinger = dlsym(gIOKit, "IOHIDEventCreateDigitizerFingerEvent");

    if (!gIO.ClientCreate || !gIO.Dispatch || !gIO.CreateDigitizer || !gIO.CreateFinger
        || !gIO.GetType || !gIO.GetInt || !gIO.GetFloat || !gIO.SetInt
        || !gIO.SetFloat || !gIO.SetSender || !gIO.Append) {
        BKAppend(@"I sym=0");
        return NO;
    }

    BKAppend(@"I io=1");
    return YES;
}

// Listener: registra ANTES de fila e ativação. Tipo monitor para receber mouse.
static BKIOHIDEventSystemClientRef BKNewListen(void)
{
    BKIOHIDEventSystemClientRef c = NULL;
    if (gIO.ClientCreateWithType) c = gIO.ClientCreateWithType(kCFAllocatorDefault, 1, NULL);
    if (!c) c = gIO.ClientCreate(kCFAllocatorDefault);
    if (!c) return NULL;
    if (gIO.RegisterCB) gIO.RegisterCB(c, BKListenCB, NULL, NULL);
    if (gIO.SetQueue) gIO.SetQueue(c, dispatch_get_main_queue());
    if (gIO.Activate) gIO.Activate(c);
    return c;
}

#pragma mark - Orientação

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
    return 0;
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

static double BKClamp(double v)
{
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
}

static void BKConvInv(double vx, double vy, int orient, double *ox, double *oy)
{
    double rx = vx, ry = vy;
    switch (orient) {
        case 2: rx = 1.0 - vx; ry = 1.0 - vy; break;
        case 3: rx = 1.0 - vy; ry = vx;       break;
        case 4: rx = vy;       ry = 1.0 - vx; break;
        default: break;
    }
    *ox = BKClamp(rx);
    *oy = BKClamp(ry);
}

#pragma mark - Config

static void BKReleaseAll(void);

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
    NSDictionary *profiles = cfg[@"Profiles"];
    if ([profiles isKindOfClass:[NSDictionary class]] && [active isKindOfClass:[NSString class]]) {
        id p = profiles[active];
        if ([p isKindOfClass:[NSArray class]]) pts = p;
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

    if (pts.count > 0) {
        gPoints = pts;
        gActiveBundle = active;
    } else if (gPoints.count == 0) {
        gActiveBundle = active;
        gPoints = pts;
    }

    gEnabled = enabled && gPoints.count > 0;
    gPendingDir = 0;
    gHandledUsage = -1;
    gPrevMask = 0;
    gLastPtrValid = 0;
    gAimX = gFpsX;
    gAimY = gFpsY;

    if (!gEnabled) BKReleaseAll();

    BKStatus();
    BKAppend([NSString stringWithFormat:@"C en=%d b=%@ n=%lu key=%d fogo=%d mirar=%d",
              (int)gEnabled, gActiveBundle ?: @"-", (unsigned long)gPoints.count, gFpsKey,
              (int)gFireSet, (int)gAdsSet]);
}

#pragma mark - Toque

static void BKNotifyUserActivity(void)
{
    Class cls = objc_getClass("BKUserEventTimer");
    if (!cls) return;
    id timer = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    if (!timer) return;
    SEL s1 = @selector(userEventOccurred);
    SEL s2 = @selector(userEventOccurredOnDisplay:);
    if ([timer respondsToSelector:s1]) {
        ((void (*)(id, SEL))objc_msgSend)(timer, s1);
    } else if ([timer respondsToSelector:s2]) {
        ((void (*)(id, SEL, id))objc_msgSend)(timer, s2, nil);
    }
}

static BKIOHIDEventRef BKChild(NSUInteger idx, double x, double y, int phase)
{
    uint32_t mask = kBKFlagRange | kBKFlagTouch;
    BOOL range = YES, touch = YES;
    if (phase == kBKPhaseMoved) {
        mask = kBKFlagPosition;
    } else if (phase == kBKPhaseEnded) {
        mask = kBKFlagTouch;
        range = NO;
        touch = NO;
    }

    BKIOHIDEventRef child = gIO.CreateFinger(kCFAllocatorDefault, mach_absolute_time(),
        BKChildIdx(idx), BKChildId(idx), mask, x, y, 0.0, 0.0, 0.0,
        (uint8_t)range, (uint8_t)touch, 0);
    if (child) {
        gIO.SetFloat(child, kBKFieldMajorR, 0.04);
        gIO.SetFloat(child, kBKFieldMinorR, 0.04);
    }
    return child;
}

static void BKPost(NSUInteger idx, double x, double y, int phase)
{
    if (!gIO.Dispatch) return;
    @try {

    BKIOHIDEventRef parent = gIO.CreateDigitizer(kCFAllocatorDefault, mach_absolute_time(),
        kBKTransducerHand, BKParentIdx(idx), kBKParentIdentity, 0, 0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0);
    if (!parent) {
        BKAppend(@"! sem parent");
        return;
    }

    gIO.SetInt(parent, kBKFieldDisplayInt, 1);
    gIO.SetInt(parent, kBKFieldIsBuiltIn, 1);

    BKIOHIDEventRef child = BKChild(idx, x, y, phase);
    if (child) {
        gIO.Append(parent, child, 0);
        CFRelease(child);
    } else {
        BKAppend(@"! sem child");
    }

    gIO.SetInt(parent, kBKFieldHandMask, 0x23);
    gIO.SetInt(parent, kBKFieldRange, 1);
    gIO.SetInt(parent, kBKFieldTouch, 1);

    gIO.SetSender(parent, kBKSenderID);

    CFRetain(parent);
    dispatch_async(gSendQ, ^{
        @try {
            if (gSendClient) gIO.Dispatch(gSendClient, parent);
        } @catch (NSException *e) { }
        CFRelease(parent);
    });

    BKNotifyUserActivity();
    if (gDump) {
        BKAppend([NSString stringWithFormat:@"D i=%lu ph=%d o=%d x=%.3f y=%.3f",
                  (unsigned long)idx, phase, BKCurrentOrient(), x, y]);
    }

    } @catch (NSException *e) {
        BKAppend([NSString stringWithFormat:@"! send %@", e.reason]);
    }
}

static void BKSendLast(NSNumber *idx)
{
    NSArray *a = gCur[idx];
    if (![a isKindOfClass:[NSArray class]] || a.count < 2) return;
    BKPost([idx unsignedIntegerValue], [a[0] doubleValue], [a[1] doubleValue], kBKPhaseEnded);
}

static void BKDown(NSUInteger idx, double nx, double ny)
{
    if ([gDown[@(idx)] boolValue]) return;
    nx = BKClamp(nx);
    ny = BKClamp(ny);
    gDown[@(idx)] = @YES;
    gCur[@(idx)] = @[ @(nx), @(ny) ];
    BKPost(idx, nx, ny, kBKPhaseBegan);
}

static void BKMove(NSUInteger idx, double nx, double ny)
{
    if (![gDown[@(idx)] boolValue]) return;
    nx = BKClamp(nx);
    ny = BKClamp(ny);
    gCur[@(idx)] = @[ @(nx), @(ny) ];
    BKPost(idx, nx, ny, kBKPhaseMoved);
}

static void BKUp(NSUInteger idx)
{
    if (![gDown[@(idx)] boolValue]) return;
    gDown[@(idx)] = @NO;
    BKSendLast(@(idx));
    [gCur removeObjectForKey:@(idx)];
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
    if (ms < 120) ms = 120;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if ([gGen[@(idx)] isEqualToNumber:gen]) BKUp(idx);
    });
}

static void BKReleaseAll(void)
{
    for (NSNumber *k in gDown.allKeys) {
        if ([gDown[k] boolValue]) {
            gDown[k] = @NO;
            BKSendLast(k);
        }
    }
    [gCur removeAllObjects];
    [gGen removeAllObjects];
    for (int i = 0; i < 4; i++) gDirHeld[i] = NO;
    gDirActive = NO;
    gFps = NO;
    gAdsDown = NO;
    gAimX = gFpsX;
    gAimY = gFpsY;
}

#pragma mark - Conversão de marcador

static void BKPonto(NSDictionary *pt, double *ox, double *oy)
{
    double nx = BKClamp([pt[@"X"] doubleValue]);
    double ny = BKClamp([pt[@"Y"] doubleValue]);
    if (gRotate) BKConvInv(nx, ny, BKCurrentOrient(), &nx, &ny);
    *ox = nx;
    *oy = ny;
}

static void BKPar(NSDictionary *pt, NSString *k, double *ox, double *oy)
{
    NSString *s = pt[k];
    double nx = 0.5, ny = 0.5;
    if ([s isKindOfClass:[NSString class]]) {
        NSArray *p = [s componentsSeparatedByString:@","];
        if (p.count >= 2) {
            nx = [p[0] doubleValue];
            ny = [p[1] doubleValue];
        }
    }
    nx = BKClamp(nx);
    ny = BKClamp(ny);
    if (gRotate) BKConvInv(nx, ny, BKCurrentOrient(), &nx, &ny);
    *ox = nx;
    *oy = ny;
}

static BOOL BKPontoValido(NSDictionary *pt)
{
    double nx = [pt[@"X"] doubleValue];
    double ny = [pt[@"Y"] doubleValue];
    if (nx < 0.0 || nx > 1.0) return NO;
    if (ny < 0.0 || ny > 1.0) return NO;
    return YES;
}

#pragma mark - Analógico

static void BKHandleDir(NSDictionary *pt, int dir, BOOL down)
{
    if (dir < 0 || dir > 3) return;

    if (down) {
        if (!gDirActive) {
            gDirActive = YES;
            gDirSens = pt[@"Sens"] ? [pt[@"Sens"] doubleValue] : 1.0;
            double cx, cy;
            BKPar(pt, @"Center", &cx, &cy);
            gDirCX = cx;
            gDirCY = cy;
            for (int i = 0; i < 4; i++) {
                NSString *k = @[@"Up", @"Down", @"Left", @"Right"][i];
                BKPar(pt, k, &gDirPX[i], &gDirPY[i]);
                gDirHeld[i] = NO;
            }
            BKDown(kBKIdxDir, gDirCX, gDirCY);
        }
        gDirHeld[dir] = YES;
        double tx = (gDirPX[dir] - gDirCX) * gDirSens + gDirCX;
        double ty = (gDirPY[dir] - gDirCY) * gDirSens + gDirCY;
        BKMove(kBKIdxDir, tx, ty);
        return;
    }

    if (!gDirActive) return;
    gDirHeld[dir] = NO;
    for (int i = 0; i < 4; i++) {
        if (gDirHeld[i]) {
            double tx = (gDirPX[i] - gDirCX) * gDirSens + gDirCX;
            double ty = (gDirPY[i] - gDirCY) * gDirSens + gDirCY;
            BKMove(kBKIdxDir, tx, ty);
            return;
        }
    }
    BKMove(kBKIdxDir, gDirCX, gDirCY);
    BKUp(kBKIdxDir);
    gDirActive = NO;
}

#pragma mark - Modo 360

static void BKFpsMove(double dx, double dy)
{
    if (!gFps || (dx == 0 && dy == 0)) return;

    double nx = gAimX + dx * gFpsSens * kBKMoveFactor;
    double ny = gAimY + dy * gFpsSens * kBKMoveFactor;

    // saiu da caixa: solta e repressa na mesma coordenada, sem salto para o jogo
    if (fabs(nx - gFpsX) > kBKRecenter || fabs(ny - gFpsY) > kBKRecenter) {
        double rx = BKClamp(nx), ry = BKClamp(ny);
        BKUp(kBKIdxAim);
        gAimX = rx;
        gAimY = ry;
        double px = rx, py = ry;
        if (gRotate) BKConvInv(rx, ry, BKCurrentOrient(), &px, &py);
        BKDown(kBKIdxAim, px, py);
        return;
    }

    gAimX = nx;
    gAimY = ny;
    double px = gAimX, py = gAimY;
    if (gRotate) BKConvInv(gAimX, gAimY, BKCurrentOrient(), &px, &py);
    BKMove(kBKIdxAim, px, py);

    if (gDump && gFpsMoveLog < 30) {
        gFpsMoveLog++;
        BKAppend([NSString stringWithFormat:@"F move dx=%.2f dy=%.2f x=%.3f y=%.3f",
                  dx, dy, gAimX, gAimY]);
    }
}

// garante que o dedo da mira existe, mesmo se algo o soltou
static void BKFpsEnsure(void)
{
    if (!gFps) return;
    if ([gDown[@(kBKIdxAim)] boolValue]) return;
    double px = gAimX, py = gAimY;
    if (gRotate) BKConvInv(gAimX, gAimY, BKCurrentOrient(), &px, &py);
    BKDown(kBKIdxAim, px, py);
}

static void BKFpsToggle(void)
{
    if (gFps) {
        gFps = NO;
        BKUp(kBKIdxAim);
        if (gAdsDown) {
            gAdsDown = NO;
            BKUp(kBKIdxAds);
        }
        BKAppend(@"F off");
        BKStatus();
        return;
    }

    gFps = YES;
    gFpsMoveLog = 0;
    gAimX = gFpsX;
    gAimY = gFpsY;
    double px = gFpsX, py = gFpsY;
    if (gRotate) BKConvInv(gFpsX, gFpsY, BKCurrentOrient(), &px, &py);
    BKDown(kBKIdxAim, px, py);
    BKAppend([NSString stringWithFormat:@"F on ponto=%.3f,%.3f fogo=%.3f,%.3f(%d) mirar=%.3f,%.3f(%d)",
              gFpsX, gFpsY, gFireX, gFireY, (int)gFireSet, gAdsX, gAdsY, (int)gAdsSet]);
    BKStatus();
}

static void BKFpsFire(void)
{
    double fx = gFireX, fy = gFireY;
    if (!gFireSet) {
        fx = BKClamp(gFpsX + 0.12);
        fy = BKClamp(gFpsY + 0.30);
    }
    double px = fx, py = fy;
    if (gRotate) BKConvInv(fx, fy, BKCurrentOrient(), &px, &py);
    BKAppend([NSString stringWithFormat:@"F fire %.3f,%.3f", fx, fy]);
    BKTap(kBKIdxCursor + 1, px, py);
}

static void BKFpsAds(BOOL down)
{
    double ax = gAdsX, ay = gAdsY;
    if (!gAdsSet) {
        ax = BKClamp(gFpsX - 0.12);
        ay = BKClamp(gFpsY + 0.30);
    }
    double px = ax, py = ay;
    if (gRotate) BKConvInv(ax, ay, BKCurrentOrient(), &px, &py);
    if (down) {
        if (gAdsDown) return;
        gAdsDown = YES;
        BKAppend([NSString stringWithFormat:@"F mirar %.3f,%.3f", ax, ay]);
        BKDown(kBKIdxAds, px, py);
    } else {
        if (!gAdsDown) return;
        gAdsDown = NO;
        BKUp(kBKIdxAds);
    }
}

#pragma mark - Cursor

static void BKCursorMove(double dx, double dy)
{
    gCx = BKClamp(gCx + dx * gFollowSens * kBKMoveFactor);
    gCy = BKClamp(gCy + dy * gFollowSens * kBKMoveFactor);
}

static void BKCursorTap(void)
{
    NSUInteger idx = kBKIdxCursor;
    double px = gCx, py = gCy;
    if (gRotate) BKConvInv(gCx, gCy, BKCurrentOrient(), &px, &py);
    BKTap(idx, px, py);
}

#pragma mark - Marcadores

static void BKHandlePoint(NSDictionary *pt, NSUInteger idx, BOOL down)
{
    NSString *type = pt[@"Type"] ?: @"Tap";
    double nx, ny;
    BKPonto(pt, &nx, &ny);

    if ([type isEqualToString:@"Tap"]) {
        if (down) BKTap(idx, nx, ny);
    } else if ([type isEqualToString:@"Press"]) {
        if (down) BKDown(idx, nx, ny); else BKUp(idx);
    } else if ([type isEqualToString:@"Hold"]) {
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
            if (!BKPontoValido(pt)) continue;
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

static void BKHandleButton(int b, BOOL down)
{
    if (gFps) {
        if (b == 0) {
            if (down) BKFpsFire();
            return;
        }
        if (b == 1) {
            BKFpsAds(down);
            return;
        }
    }

    if (b == 0 && gFollowCursor && down) {
        BKCursorTap();
        return;
    }

    NSString *key = [NSString stringWithFormat:@"m:%d", b];
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
}

static void BKHandleMask(uint16_t cur)
{
    uint16_t prev = gPrevMask;
    if (cur == prev) return;
    for (int b = 0; b < 3; b++) {
        uint16_t bit = 1 << b;
        BOOL was = (prev & bit) != 0;
        BOOL now = (cur & bit) != 0;
        if (was != now) BKHandleButton(b, now);
    }
    gPrevMask = cur;
}

static void BKSourceMask(uint64_t sender, int type, int mask)
{
    if (!gMaskSrc) gMaskSrc = [NSMutableDictionary dictionary];
    if (gMaskSrc.count > 48) [gMaskSrc removeAllObjects];
    if (mask < 0) mask = 0;
    if (mask > 7) mask &= 7;

    NSString *key = [NSString stringWithFormat:@"%llu/%d", sender, type];
    if ([gMaskSrc[key] intValue] == mask) return;
    gMaskSrc[key] = @(mask);

    uint16_t all = 0;
    for (NSString *k in gMaskSrc) all |= (uint16_t)[gMaskSrc[k] intValue];
    BKHandleMask(all);
}

static void BKSourceEdge(uint64_t sender, int type, int num, BOOL down)
{
    if (num < 0 || num > 2) num = 0;
    if (!gMaskSrc) gMaskSrc = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%llu/%d", sender, type];
    int cur = (int)[gMaskSrc[key] intValue];
    int bit = 1 << num;
    if (down) cur |= bit; else cur &= ~bit;
    BKSourceMask(sender, type, cur);
}

#pragma mark - Captura

static void BKCaptureWatch(void)
{
    NSString *req = [NSString stringWithContentsOfFile:kBKCaptureReqPath
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!req.length || gCaptureArmed) return;
    [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureReqPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:kBKCaptureResPath error:nil];
    gCaptureArmed = YES;
    gCaptureArmNs = BKNowNs();
    BKAppend(@"@ arm");
}

static BOOL BKTryCapture(int type, BKIOHIDEventRef ev)
{
    if (!gCaptureArmed) return NO;
    if (BKNowNs() < gCaptureArmNs + 200000000ull) return NO;

    NSString *enc = nil;
    if (type == kIOHIDEventTypeKeyboard) {
        int page = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardUsage);
        int down = (int)gIO.GetInt(ev, kIOHIDEventFieldKeyboardDown);
        if ((page == 0 || page == 7) && down && usage >= 4 && usage <= 231) {
            enc = [NSString stringWithFormat:@"k:%d", usage];
        }
    } else if (type == kBKTypeButton || type == kBKTypeBtn) {
        int f0 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 0u));
        int f1 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 1u));
        int f2 = (int)gIO.GetInt(ev, (uint32_t)(type << 16 | 2u));
        int num = (f0 >= 0 && f0 <= 2) ? f0 : 0;
        if (f1 || f2) {
            enc = [NSString stringWithFormat:@"m:%d", num];
            BKAppend([NSString stringWithFormat:@"@ raw t=%d f=%d,%d,%d", type, f0, f1, f2]);
        }
    } else if (type == kBKTypeDigitizer) {
        int mask = (int)gIO.GetInt(ev, kBKFieldBtnMask);
        if (mask & 1) enc = @"m:0";
        else if (mask & 2) enc = @"m:1";
        else if (mask & 4) enc = @"m:2";
    }

    if (!enc) return NO;
    [enc writeToFile:kBKCaptureResPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    gCaptureArmed = NO;
    BKAppend([NSString stringWithFormat:@"@ cap %@", enc]);
    return YES;
}

#pragma mark - Testes

static const double kBKProbe[10][2] = {
    {0.50, 0.50}, {0.25, 0.30}, {0.75, 0.30}, {0.25, 0.70}, {0.75, 0.70},
    {0.50, 0.20}, {0.50, 0.80}, {0.15, 0.50}, {0.85, 0.50}, {0.50, 0.50}
};

static void BKProbe(void)
{
    BKAppend(@"P ini");
    for (int i = 0; i < 10; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * 200 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            double x = kBKProbe[i][0];
            double y = kBKProbe[i][1];
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

#pragma mark - Callback

static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    (void)target; (void)refcon; (void)queue;
    if (!ev) return;
    @try {
    int type = gIO.GetType(ev);

    uint64_t sender = gIO.GetSender ? gIO.GetSender(ev) : 0;

    if (sender == kBKSenderID) return;

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
        gPendingDir = down ? 1 : -1;
        if (gDump) BKAppend([NSString stringWithFormat:@"K %d pg=%d d=%d", usage, page, down]);
        if ((page == 0 || page == 7) && usage >= 4 && usage <= 231) {
            gHandledUsage = usage;
            if (usage == gFpsKey) {
                if (down) BKFpsToggle();
                return;
            }
            if (gEnabled && gPoints.count) BKHandleKey(usage, down != 0);
        }
    } else if (type == kBKTypeKeyExtra) {
        int usage = (int)gIO.GetInt(ev, 0);
        int dir = gPendingDir;
        gPendingDir = 0;
        if (usage <= 0) return;
        if (usage == gHandledUsage) {
            gHandledUsage = -1;
            return;
        }
        uint64_t now = BKNowNs();
        if (usage == gLastExtra && (now - gLastExtraNs) < 90000000ull) return;
        gLastExtra = usage;
        gLastExtraNs = now;
        if (gEnabled && gPoints.count && usage >= 4 && usage <= 231) {
            BKHandleKey(usage, dir > 0);
        }
    } else if (type == kBKTypeDigitizer) {
        double x = gIO.GetFloat(ev, kBKFieldX);
        double y = gIO.GetFloat(ev, kBKFieldY);
        int m = (int)gIO.GetInt(ev, kBKFieldBtnMask);

        // 0/0 = ponteiro fora: não gera delta, só reinicia a referência
        if (x == 0.0 && y == 0.0) {
            gLastPtrValid = 0;
        } else {
            double dx = 0, dy = 0;
            if (gLastPtrValid) {
                dx = (x - gLastPtrX) * kBKPtrScale;
                dy = (y - gLastPtrY) * kBKPtrScale;
                if (fabs(dx) > 900.0 || fabs(dy) > 900.0) { dx = 0; dy = 0; }
            }
            gLastPtrX = x;
            gLastPtrY = y;
            gLastPtrValid = 1;
            if (!gFps && (dx != 0.0 || dy != 0.0)) BKCursorMove(dx, dy);
        }

        BKDumpEv(type, ev);
        if (gDump) BKAppend([NSString stringWithFormat:@"M11 x=%.4f y=%.4f m=%x", x, y, m]);
        if (m >= 0 && m <= 7) BKSourceMask(sender, type, m);
    } else if (type == kBKTypeMove) {
        double dx = gIO.GetFloat(ev, (kBKTypeMove << 16 | 0u));
        double dy = gIO.GetFloat(ev, (kBKTypeMove << 16 | 1u));
        if (dx == 0.0 && dy == 0.0) {
            dx = gIO.GetFloat(ev, (kBKTypeTranslation << 16 | 0u));
            dy = gIO.GetFloat(ev, (kBKTypeTranslation << 16 | 1u));
        }
        BKDumpEv(type, ev);
        if (gDump) BKAppend([NSString stringWithFormat:@"M12 dx=%.3f dy=%.3f", dx, dy]);
        if (gFps && (dx != 0.0 || dy != 0.0)) {
            BKFpsEnsure();
            BKFpsMove(dx, dy);
        }
    } else if (type == kBKTypeButton) {
        int num = (int)gIO.GetInt(ev, (kBKTypeButton << 16 | 0u));
        int st = (int)gIO.GetInt(ev, (kBKTypeButton << 16 | 1u));
        if (st == 0) st = (int)gIO.GetInt(ev, (kBKTypeButton << 16 | 2u));
        BKDumpEv(type, ev);
        if (gDump) BKAppend([NSString stringWithFormat:@"N2 n=%d s=%d", num, st]);
        BKSourceEdge(sender, type, num, st != 0);
    } else if (type == kBKTypeBtn) {
        // campo 0 = botão, campo 1 = estado, campo 2 = contagem de cliques
        int num = (int)gIO.GetInt(ev, (kBKTypeBtn << 16 | 0u));
        int st = (int)gIO.GetInt(ev, (kBKTypeBtn << 16 | 1u));
        if (st == 0) st = (int)gIO.GetInt(ev, (kBKTypeBtn << 16 | 2u));
        BKDumpEv(type, ev);
        if (gDump) BKAppend([NSString stringWithFormat:@"N32 n=%d s=%d", num, st]);
        BKSourceEdge(sender, type, num, st != 0);
    }
    } @catch (NSException *e) {
        BKAppend([NSString stringWithFormat:@"! cb %@", e.reason]);
    }
}

#pragma mark - Init

static void BKEngineInit(void)
{
    gDown = [NSMutableDictionary dictionary];
    gGen = [NSMutableDictionary dictionary];
    gCur = [NSMutableDictionary dictionary];
    gMaskSrc = [NSMutableDictionary dictionary];
    gSendQ = dispatch_queue_create("com.wjf.ballkey.send", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(gSendQ, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));

    BKAppend(@"I init");

    if (!BKLoadIOKit()) return;

    gSendClient = gIO.ClientCreate(kCFAllocatorDefault);
    BKAppend(gSendClient ? @"I send=1" : @"I send=0");

    @try {
        gListenClient = BKNewListen();
        if (!gListenClient) {
            BKAppend(@"I client=0");
            return;
        }
        BKAppend(@"I listen=1");
    } @catch (NSException *e) {
        BKAppend([NSString stringWithFormat:@"! init %@", e.reason]);
        return;
    }

    dispatch_queue_t q = dispatch_get_main_queue();
    int t1 = 0, t2 = 0, t3 = 0;
    notify_register_dispatch(kBKNotifyReload, &t1, q, ^(int t) {
        (void)t;
        BKLoadConfig();
    });
    notify_register_dispatch(kBKNotifyTest, &t2, q, ^(int t) {
        (void)t;
        BKTestCenter();
    });
    notify_register_dispatch(kBKNotifyProbe, &t3, q, ^(int t) {
        (void)t;
        BKProbe();
    });
    BKAppend(@"I notify=1");

    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        (void)t;
        @try {
            BKCaptureWatch();
        } @catch (NSException *e) {
        }
    }];

    BKLoadConfig();

    BKAppend(@"I ready");
    BKMark(@"engine_loaded.txt");
}

%ctor {
    @autoreleasepool {
        BKMark(@"engine_ctor.txt");
        BKAppend(@"I ctor");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BKEngineInit();
        });
    }
}
