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
    void (*SetInt)(BKIOHIDEventRef, int32_t, int64_t);
    void (*SetFloat)(BKIOHIDEventRef, int32_t, double);
    void (*SetSender)(BKIOHIDEventRef, uint64_t);
    void (*Append)(BKIOHIDEventRef, BKIOHIDEventRef);
    BKIOHIDEventRef (*CreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        uint32_t, uint32_t, double, double, double, double, double, uint8_t, uint8_t, uint32_t);
    BKIOHIDEventRef (*CreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        double, double, double, double, double, uint8_t, uint8_t, uint32_t);
} BKIO;

#define kBKConfigPath           @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKStatusPath           @"/var/mobile/bk_status.txt"
#define kBKLogPath              @"/var/mobile/bk_debug.log"
#define kBKNotifyReload         "com.wjf.ballkey.reload"
#define kBKNotifyTest           "com.wjf.ballkey.test"
#define kBKNotifyProbe          "com.wjf.ballkey.probe"
#define kBKNotifyClose          "com.wjf.ballkey.close"

#define kBKTransducerFinger     0x22
#define kBKTransducerHand       0x23
#define kBKFieldX               (11u << 16 | 0u)
#define kBKFieldY               (11u << 16 | 1u)
#define kBKFieldPressure        (11u << 16 | 10u)
#define kBKFieldEventMask       (11u << 16 | 7u)
#define kBKFieldIsBuiltIn       4
#define kBKFieldDisplayInt      25
#define kBKSenderID             0x8000000817319372ull
#define kBKOptAbsolute          1u

#define kBKFlagRange            0x01u
#define kBKFlagTouch            0x02u
#define kBKFlagPosition         0x04u
#define kBKMaskDown             (kBKFlagRange | kBKFlagTouch | kBKFlagPosition)
#define kBKMaskMove             (kBKFlagPosition)
#define kBKMaskUp               (kBKFlagRange | kBKFlagTouch)

#define kBKTypeKeyExtra         15
#define kBKTypePointer          17
#define kBKPtrX                 (17u << 16 | 0u)
#define kBKPtrY                 (17u << 16 | 1u)
#define kBKPtrMask              (17u << 16 | 3u)
#define kBKMoveFactor           0.000977
#define kBKDefaultFpsKey        224

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
static int gBackend = 0;
static int gMode = 0;
static NSArray *gPoints = nil;
static BOOL gEnabled = NO;
static NSString *gActiveBundle = nil;

static NSMutableDictionary *gDown = nil;
static NSMutableDictionary *gGen = nil;
static NSMutableDictionary *gCur = nil;

static BOOL gRotate = YES;
static BOOL gFollowCursor = NO;
static double gFollowSens = 1.0;
static int gOrientOverride = 0;
static BOOL gDump = NO;
static BOOL gUseSender = NO;
static BOOL gUseBuiltIn = YES;

static BOOL gFps = NO;
static double gFpsSens = 1.0;
static int gFpsKey = kBKDefaultFpsKey;
static double gFpsX = 0.5, gFpsY = 0.5;
static double gFireX = 0.83, gFireY = 0.66;
static double gAdsX = 0.95, gAdsY = 0.53;
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
static int gLastExtra = -1;
static uint64_t gLastExtraNs = 0;

static void BKSendLast(NSNumber *idx);
static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev);

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
    NSString *s = [NSString stringWithFormat:@"ativo=%d marcadores=%lu app=%@ trava=%d tecla=%d sensi=%.2f ev=%d via=%d modo=%d",
                   (int)gEnabled, (unsigned long)gPoints.count, gActiveBundle ?: @"-",
                   (int)gFps, gFpsKey, gFpsSens, gEvSeen, gBackend, gMode];
    [s writeToFile:kBKStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
    gIO.SetInt = dlsym(gIOKit, "IOHIDEventSetIntegerValue");
    gIO.SetFloat = dlsym(gIOKit, "IOHIDEventSetFloatValue");
    gIO.SetSender = dlsym(gIOKit, "IOHIDEventSetSenderID");
    gIO.Append = dlsym(gIOKit, "IOHIDEventAppendEvent");
    gIO.CreateDigitizer = dlsym(gIOKit, "IOHIDEventCreateDigitizerEvent");
    gIO.CreateFinger = dlsym(gIOKit, "IOHIDEventCreateDigitizerFingerEvent");

    if (!gIO.ClientCreate || !gIO.Dispatch || !gIO.CreateDigitizer || !gIO.CreateFinger
        || !gIO.GetType || !gIO.GetInt || !gIO.GetFloat || !gIO.SetInt) {
        BKAppend(@"I sym=0");
        return NO;
    }

    BKAppend(@"I io=1");
    return YES;
}

static BKIOHIDEventSystemClientRef BKClientNew(void)
{
    BKIOHIDEventSystemClientRef c = NULL;
    if (gIO.ClientCreateWithType) {
        c = gIO.ClientCreateWithType(kCFAllocatorDefault, 1, NULL);
    }
    if (!c && gIO.ClientCreate) c = gIO.ClientCreate(kCFAllocatorDefault);
    return c;
}

// Listener: registra ANTES de fila e ativação
static BKIOHIDEventSystemClientRef BKNewListen(void)
{
    BKIOHIDEventSystemClientRef c = BKClientNew();
    if (!c) return NULL;
    if (gIO.RegisterCB) gIO.RegisterCB(c, BKListenCB, NULL, NULL);
    if (gIO.SetQueue) gIO.SetQueue(c, dispatch_get_main_queue());
    if (gIO.Activate) gIO.Activate(c);
    return c;
}

static BKIOHIDEventSystemClientRef BKNewSend(int type)
{
    BKIOHIDEventSystemClientRef c = NULL;
    if (gIO.ClientCreateWithType && type > 0) {
        c = gIO.ClientCreateWithType(kCFAllocatorDefault, type, NULL);
        if (c) {
            BKAppend([NSString stringWithFormat:@"I sendtype=%d", type]);
            return c;
        }
        BKAppend([NSString stringWithFormat:@"I sendtype=%d falhou", type]);
    }
    if (gIO.ClientCreate) {
        c = gIO.ClientCreate(kCFAllocatorDefault);
        if (c) BKAppend(@"I sendtype=-1");
    }
    return c;
}

static void BKEnqueueHID(BKIOHIDEventRef ev)
{
    static Class appCls = NULL;
    static SEL sel = NULL;
    static int warned = 0;
    if (!appCls) {
        appCls = objc_getClass("UIApplication");
        sel = @selector(_enqueueHIDEvent:);
    }
    if (!appCls) return;
    id app = ((id (*)(id, SEL))objc_msgSend)(appCls, @selector(sharedApplication));
    if (!app) return;
    if (![app respondsToSelector:sel]) {
        if (!warned) { warned = 1; BKAppend(@"! sem _enqueueHIDEvent"); }
        return;
    }
    ((void (*)(id, SEL, BKIOHIDEventRef))objc_msgSend)(app, sel, ev);
}

#pragma mark - Orientação

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
    int d = BKDeviceOrientation();
    if (d >= 1 && d <= 4) { gLastOrient = d; return d; }
    return gLastOrient ? gLastOrient : 1;
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
    if ([cfg[@"Sender"] isKindOfClass:[NSNumber class]]) gUseSender = [cfg[@"Sender"] boolValue];
    if ([cfg[@"BuiltIn"] isKindOfClass:[NSNumber class]]) gUseBuiltIn = [cfg[@"BuiltIn"] boolValue];
    if ([cfg[@"FpsSens"] isKindOfClass:[NSNumber class]]) gFpsSens = [cfg[@"FpsSens"] doubleValue];
    if ([cfg[@"FpsX"] isKindOfClass:[NSNumber class]]) gFpsX = [cfg[@"FpsX"] doubleValue];
    if ([cfg[@"FpsY"] isKindOfClass:[NSNumber class]]) gFpsY = [cfg[@"FpsY"] doubleValue];
    if ([cfg[@"FireX"] isKindOfClass:[NSNumber class]]) gFireX = [cfg[@"FireX"] doubleValue];
    if ([cfg[@"FireY"] isKindOfClass:[NSNumber class]]) gFireY = [cfg[@"FireY"] doubleValue];
    if ([cfg[@"AdsX"] isKindOfClass:[NSNumber class]]) gAdsX = [cfg[@"AdsX"] doubleValue];
    if ([cfg[@"AdsY"] isKindOfClass:[NSNumber class]]) gAdsY = [cfg[@"AdsY"] doubleValue];

    int bk = [cfg[@"Backend"] isKindOfClass:[NSNumber class]] ? [cfg[@"Backend"] intValue] : 0;
    if (bk < 0 || bk > 3) bk = 0;
    if (bk != gBackend) {
        gBackend = bk;
        gSendClient = NULL;
        BKAppend([NSString stringWithFormat:@"B via=%d", bk]);
    }

    int md = [cfg[@"Mode"] isKindOfClass:[NSNumber class]] ? [cfg[@"Mode"] intValue] : 0;
    if (md < 0 || md > 3) md = 0;
    if (md != gMode) {
        gMode = md;
        BKAppend([NSString stringWithFormat:@"B modo=%d", md]);
    }

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
    gAimX = gFpsX;
    gAimY = gFpsY;

    if (!gEnabled) BKReleaseAll();

    BKStatus();
    BKAppend([NSString stringWithFormat:@"C en=%d b=%@ n=%lu key=%d snd=%d bi=%d via=%d modo=%d",
              (int)gEnabled, gActiveBundle ?: @"-", (unsigned long)gPoints.count,
              gFpsKey, (int)gUseSender, (int)gUseBuiltIn, gBackend, gMode]);
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

static void BKPush(BKIOHIDEventRef ev)
{
    CFRetain(ev);
    if (gBackend == 3) {
        dispatch_async(gSendQ, ^{
            @try { BKEnqueueHID(ev); } @catch (NSException *e) { }
            CFRelease(ev);
        });
        return;
    }
    if (!gSendClient) {
        gSendClient = BKNewSend(gBackend + 1);
        if (!gSendClient && gListenClient) {
            gSendClient = gListenClient;
            BKAppend(@"I send=listen");
        }
    }
    dispatch_async(gSendQ, ^{
        @try {
            if (gSendClient) gIO.Dispatch(gSendClient, ev);
        } @catch (NSException *e) { }
        CFRelease(ev);
    });
}

static void BKSend(double nx, double ny, int phase, NSUInteger idx)
{
    if (!gIO.Dispatch) return;
    @try {

    double rx = BKClamp(nx);
    double ry = BKClamp(ny);

    BOOL touching = (phase != 2);
    uint32_t mask = (phase == 2) ? kBKMaskUp : (phase == 1 ? kBKMaskDown : kBKMaskMove);
    double press = touching ? 1.0 : 0.0;
    uint64_t ab = mach_absolute_time();
    uint32_t ident = (uint32_t)(idx + 1);

    BKIOHIDEventRef finger = gIO.CreateFinger(kCFAllocatorDefault, ab,
        0, ident, mask, rx, ry, 0.0, press, 0.0,
        (uint8_t)touching, (uint8_t)touching, 0);
    if (!finger) {
        BKAppend(@"! send sem finger");
        return;
    }
    gIO.SetInt(finger, kBKFieldDisplayInt, 1);
    gIO.SetInt(finger, kBKFieldEventMask, mask);
    if (gIO.SetFloat) {
        gIO.SetFloat(finger, kBKFieldX, rx);
        gIO.SetFloat(finger, kBKFieldY, ry);
        gIO.SetFloat(finger, kBKFieldPressure, press);
    }

    if (gMode == 1) {
        if (gUseSender && gIO.SetSender) gIO.SetSender(finger, kBKSenderID);
        BKPush(finger);
        CFRelease(finger);
        if (gDump) BKAppend([NSString stringWithFormat:@"D ph=%d x=%.3f y=%.3f m=%x so=%d",
                             phase, rx, ry, mask, gMode]);
        BKNotifyUserActivity();
        return;
    }

    uint32_t ttype = (gMode == 2) ? kBKTransducerFinger : kBKTransducerHand;
    uint32_t opts = (gMode == 3) ? kBKOptAbsolute : 0;

    BKIOHIDEventRef hand = gIO.CreateDigitizer(kCFAllocatorDefault, ab,
        ttype, 0, 0, mask, 0, rx, ry, 0.0, press, 0.0,
        (uint8_t)touching, (uint8_t)touching, opts);
    if (!hand) {
        BKAppend(@"! send sem hand");
        CFRelease(finger);
        return;
    }

    gIO.SetInt(hand, kBKFieldDisplayInt, 1);
    if (gUseBuiltIn) gIO.SetInt(hand, kBKFieldIsBuiltIn, 1);

    if (gIO.Append) gIO.Append(hand, finger);
    CFRelease(finger);

    if (gUseSender && gIO.SetSender) gIO.SetSender(hand, kBKSenderID);
    BKPush(hand);
    CFRelease(hand);

    BKNotifyUserActivity();
    if (gDump) {
        BKAppend([NSString stringWithFormat:@"D ph=%d o=%d x=%.3f y=%.3f m=%x t=%x so=%d", phase,
                  BKCurrentOrient(), rx, ry, mask, ttype, gMode]);
    }

    } @catch (NSException *e) {
        BKAppend([NSString stringWithFormat:@"! send %@", e.reason]);
    }
}

static void BKSendLast(NSNumber *idx)
{
    NSArray *a = gCur[idx];
    if (![a isKindOfClass:[NSArray class]] || a.count < 2) return;
    BKSend([a[0] doubleValue], [a[1] doubleValue], 2, [idx unsignedIntegerValue]);
}

static void BKDown(NSUInteger idx, double nx, double ny)
{
    if ([gDown[@(idx)] boolValue]) return;
    nx = BKClamp(nx);
    ny = BKClamp(ny);
    gDown[@(idx)] = @YES;
    gCur[@(idx)] = @[ @(nx), @(ny) ];
    BKSend(nx, ny, 1, idx);
}

static void BKMove(NSUInteger idx, double nx, double ny)
{
    if (![gDown[@(idx)] boolValue]) return;
    nx = BKClamp(nx);
    ny = BKClamp(ny);
    gCur[@(idx)] = @[ @(nx), @(ny) ];
    BKSend(nx, ny, 0, idx);
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if ([gGen[@(idx)] isEqualToNumber:gen]) BKUp(idx);
    });
}

static void BKHold(NSUInteger idx, double nx, double ny, int ms)
{
    BKDown(idx, nx, ny);
    NSNumber *gen = @([gGen[@(idx)] intValue] + 1);
    gGen[@(idx)] = gen;
    if (ms < 60) ms = 60;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
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
    double nx = [pt[@"X"] doubleValue];
    double ny = [pt[@"Y"] doubleValue];
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
    if (gRotate) BKConvInv(nx, ny, BKCurrentOrient(), &nx, &ny);
    *ox = nx;
    *oy = ny;
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
    gAimX += dx * gFpsSens * kBKMoveFactor;
    gAimY += dy * gFpsSens * kBKMoveFactor;

    if (fabs(gAimX - gFpsX) > 0.33 || fabs(gAimY - gFpsY) > 0.33) {
        BKUp(kBKIdxAim);
        double cxp = gFpsX, cyp = gFpsY;
        if (gRotate) BKConvInv(gFpsX, gFpsY, BKCurrentOrient(), &cxp, &cyp);
        BKDown(kBKIdxAim, cxp, cyp);
        gAimX = BKClamp(gFpsX + dx * gFpsSens * kBKMoveFactor);
        gAimY = BKClamp(gFpsY + dy * gFpsSens * kBKMoveFactor);
    }

    double px = gAimX, py = gAimY;
    if (gRotate) BKConvInv(gAimX, gAimY, BKCurrentOrient(), &px, &py);
    BKMove(kBKIdxAim, px, py);
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
    gAimX = gFpsX;
    gAimY = gFpsY;
    double px = gFpsX, py = gFpsY;
    if (gRotate) BKConvInv(gFpsX, gFpsY, BKCurrentOrient(), &px, &py);
    BKDown(kBKIdxAim, px, py);
    BKAppend(@"F on");
    BKStatus();
}

static void BKFpsFire(void)
{
    double px = gFireX, py = gFireY;
    if (gRotate) BKConvInv(gFireX, gFireY, BKCurrentOrient(), &px, &py);
    BKTap(kBKIdxCursor + 1, px, py);
}

static void BKFpsAds(BOOL down)
{
    double px = gAdsX, py = gAdsY;
    if (gRotate) BKConvInv(gAdsX, gAdsY, BKCurrentOrient(), &px, &py);
    if (down) {
        if (gAdsDown) return;
        gAdsDown = YES;
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
    BKDown(idx, px, py);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKUp(idx);
    });
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
            BKHandleDir(pt, d, down);
            BKAppend([NSString stringWithFormat:@"B %@ dir=%d d=%d", key, d, (int)down]);
            return;
        }
    }

    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        if ([pt[@"Type"] isEqualToString:@"Dir"]) continue;
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
    for (int b = 0; b < 3; b++) {
        uint16_t bit = 1 << b;
        BOOL was = (prev & bit) != 0;
        BOOL now = (cur & bit) != 0;
        if (was != now) BKHandleButton(b, now);
    }
    gPrevMask = cur;
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * 150 * NSEC_PER_MSEC),
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
        int64_t d = (int64_t)(900 + i * 500) * NSEC_PER_MSEC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d), dispatch_get_main_queue(), ^{
            double px = 0.5, py = 0.5;
            if (gRotate) BKConvInv(0.5, 0.5, BKCurrentOrient(), &px, &py);
            BKAppend([NSString stringWithFormat:@"T %d pn=%.3f,%.3f v=%d so=%d", i, px, py, gBackend, gMode]);
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
    if (gEvSeen < 40) {
        gEvSeen++;
        BKAppend([NSString stringWithFormat:@"E t=%d", type]);
    }

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
    } else if (type == kBKTypePointer) {
        double dx = gIO.GetFloat(ev, kBKPtrX);
        double dy = gIO.GetFloat(ev, kBKPtrY);
        int bmask = (int)gIO.GetInt(ev, kBKPtrMask);
        if (dx != 0 || dy != 0) {
            BKCursorMove(dx, dy);
            BKFpsMove(dx, dy);
        }
        if (gEnabled && gPoints.count) BKHandleMask((uint16_t)bmask);
        else gPrevMask = (uint16_t)bmask;
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
    gSendQ = dispatch_queue_create("com.wjf.ballkey.send", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(gSendQ, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));

    BKAppend(@"I init");

    if (!BKLoadIOKit()) return;

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
