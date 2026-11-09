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
    void (*Schedule)(BKIOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    void (*Unschedule)(BKIOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    void (*Activate)(BKIOHIDEventSystemClientRef);
    void (*Dispatch)(BKIOHIDEventSystemClientRef, BKIOHIDEventRef);
    int (*GetType)(BKIOHIDEventRef);
    int64_t (*GetInt)(BKIOHIDEventRef, int32_t);
    double (*GetFloat)(BKIOHIDEventRef, int32_t);
    void (*SetIntOpt)(BKIOHIDEventRef, int32_t, int64_t, uint32_t);
    void (*SetFloat)(BKIOHIDEventRef, int32_t, double);
    void (*SetSender)(BKIOHIDEventRef, uint64_t);
    void (*Append)(BKIOHIDEventRef, BKIOHIDEventRef);
    BKIOHIDEventRef (*CreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        uint32_t, uint32_t, double, double, double, double, double, uint8_t, uint8_t, uint32_t);
    BKIOHIDEventRef (*CreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        double, double, double, double, double, double, double, double, double, double,
        uint8_t, uint8_t, uint32_t);
} BKIO;

#define kBKConfigPath           @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKStatusPath           @"/var/mobile/bk_status.txt"
#define kBKLogPath              @"/var/mobile/bk_debug.log"
#define kBKNotifyReload         "com.wjf.ballkey.reload"
#define kBKNotifyTest           "com.wjf.ballkey.test"
#define kBKNotifyProbe          "com.wjf.ballkey.probe"

#define kBKTransducerHand       3
#define kBKFieldX               (11u << 16 | 0u)
#define kBKFieldY               (11u << 16 | 1u)
#define kBKFieldTouchPhase      (11u << 16 | 26u)
#define kBKFieldBuiltIn         22
#define kBKFieldDisplayInt      25
#define kBKSetOpt               0xF0000000u
#define kBKSenderID             0xDEFACEDBEEFFECE5ull
#define kBKClientTypeMonitor    1
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
#define kIOHIDDigitizerEventRange              0x01u
#define kIOHIDDigitizerEventPosition           0x04u
#define kIOHIDEventFieldDigitizerEventMask     (11u << 16 | 7u)
#define kIOHIDEventFieldDigitizerRange         (11u << 16 | 8u)
#define kIOHIDEventFieldDigitizerTouch         (11u << 16 | 9u)

#define kBKIdxAim               70
#define kBKIdxAds               71
#define kBKIdxDir               72
#define kBKIdxCursor            40

#pragma mark - Estado

static void *gIOKit = NULL;
static BKIO gIO;

static BKIOHIDEventSystemClientRef gListenClient = NULL;
static BKIOHIDEventSystemClientRef gSendClient = NULL;
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

static void BKSendLast(NSNumber *idx);

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

#pragma mark - IOKit dinâmico

static BOOL BKLoadIOKit(void)
{
    if (gIOKit) return YES;

    gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!gIOKit) gIOKit = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!gIOKit) gIOKit = dlopen("IOKit", RTLD_LAZY);
    if (!gIOKit) {
        BKAppend(@"I dlopen=0");
        return NO;
    }

    gIO.ClientCreate = dlsym(gIOKit, "IOHIDEventSystemClientCreate");
    gIO.ClientCreateWithType = dlsym(gIOKit, "IOHIDEventSystemClientCreateWithType");
    gIO.RegisterCB = dlsym(gIOKit, "IOHIDEventSystemClientRegisterEventCallback");
    gIO.SetQueue = dlsym(gIOKit, "IOHIDEventSystemClientSetDispatchQueue");
    gIO.Schedule = dlsym(gIOKit, "IOHIDEventSystemClientScheduleWithRunLoop");
    gIO.Unschedule = dlsym(gIOKit, "IOHIDEventSystemClientUnscheduleWithRunLoop");
    gIO.Activate = dlsym(gIOKit, "IOHIDEventSystemClientActivate");
    gIO.Dispatch = dlsym(gIOKit, "IOHIDEventSystemClientDispatchEvent");
    gIO.GetType = dlsym(gIOKit, "IOHIDEventGetType");
    gIO.GetInt = dlsym(gIOKit, "IOHIDEventGetIntegerValue");
    gIO.GetFloat = dlsym(gIOKit, "IOHIDEventGetFloatValue");
    gIO.SetIntOpt = dlsym(gIOKit, "IOHIDEventSetIntegerValueWithOptions");
    gIO.SetFloat = dlsym(gIOKit, "IOHIDEventSetFloatValue");
    gIO.SetSender = dlsym(gIOKit, "IOHIDEventSetSenderID");
    gIO.Append = dlsym(gIOKit, "IOHIDEventAppendEvent");
    gIO.CreateDigitizer = dlsym(gIOKit, "IOHIDEventCreateDigitizerEvent");
    gIO.CreateFinger = dlsym(gIOKit, "IOHIDEventCreateDigitizerFingerEventWithQuality");

    if (!gIO.ClientCreate || !gIO.Dispatch || !gIO.CreateDigitizer || !gIO.CreateFinger
        || !gIO.GetType || !gIO.GetInt || !gIO.GetFloat || !gIO.SetIntOpt) {
        BKAppend(@"I sym=0");
        return NO;
    }

    BKAppend(@"I io=1");
    return YES;
}

static BKIOHIDEventSystemClientRef BKNewClient(void)
{
    BKIOHIDEventSystemClientRef c = NULL;
    if (gIO.ClientCreateWithType) {
        c = gIO.ClientCreateWithType(kCFAllocatorDefault, kBKClientTypeMonitor, NULL);
    }
    if (!c && gIO.ClientCreate) c = gIO.ClientCreate(kCFAllocatorDefault);
    return c;
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
    if ([cfg[@"FpsSens"] isKindOfClass:[NSNumber class]]) gFpsSens = [cfg[@"FpsSens"] doubleValue];
    if ([cfg[@"FpsX"] isKindOfClass:[NSNumber class]]) gFpsX = [cfg[@"FpsX"] doubleValue];
    if ([cfg[@"FpsY"] isKindOfClass:[NSNumber class]]) gFpsY = [cfg[@"FpsY"] doubleValue];
    if ([cfg[@"FireX"] isKindOfClass:[NSNumber class]]) gFireX = [cfg[@"FireX"] doubleValue];
    if ([cfg[@"FireY"] isKindOfClass:[NSNumber class]]) gFireY = [cfg[@"FireY"] doubleValue];
    if ([cfg[@"AdsX"] isKindOfClass:[NSNumber class]]) gAdsX = [cfg[@"AdsX"] doubleValue];
    if ([cfg[@"AdsY"] isKindOfClass:[NSNumber class]]) gAdsY = [cfg[@"AdsY"] doubleValue];

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
    BKAppend([NSString stringWithFormat:@"C en=%d b=%@ n=%lu key=%d",
              (int)gEnabled, gActiveBundle ?: @"-", (unsigned long)gPoints.count, gFpsKey]);
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

static void BKSend(double nx, double ny, int phase, NSUInteger idx)
{
    if (!gIO.Dispatch) return;
    @try {

    if (!gSendClient) {
        gSendClient = BKNewClient();
        if (!gSendClient) return;
    }

    double rx = BKClamp(nx);
    double ry = BKClamp(ny);

    uint64_t ab = mach_absolute_time();
    uint32_t index = (uint32_t)(idx + 1);
    uint32_t ident = (uint32_t)(idx + 101);

    BKIOHIDEventRef hand = gIO.CreateDigitizer(kCFAllocatorDefault, ab,
        kBKTransducerHand, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return;

    gIO.SetIntOpt(hand, kBKFieldDisplayInt, 1, kBKSetOpt);
    gIO.SetIntOpt(hand, kBKFieldBuiltIn, 1, kBKSetOpt);

    int mask;
    int touch;
    if (phase == 0) {
        mask = kIOHIDDigitizerEventPosition;
        touch = 1;
    } else {
        mask = kIOHIDDigitizerEventRange;
        touch = (phase == 1) ? 1 : 0;
    }

    BKIOHIDEventRef finger = gIO.CreateFinger(kCFAllocatorDefault, ab,
        index, ident, (uint32_t)mask, rx, ry, 0, 0, 0, 0, 0, 0, 0, 0,
        (uint8_t)touch, (uint8_t)touch, 0);
    if (finger) {
        gIO.SetIntOpt(finger, kBKFieldDisplayInt, 1, kBKSetOpt);
        if (gIO.SetFloat) {
            gIO.SetFloat(finger, kBKFieldX, rx);
            gIO.SetFloat(finger, kBKFieldY, ry);
        }
        gIO.SetIntOpt(finger, kBKFieldTouchPhase, phase, kBKSetOpt);
        if (gIO.Append) gIO.Append(hand, finger);
        CFRelease(finger);
    }

    gIO.SetIntOpt(hand, kIOHIDEventFieldDigitizerEventMask, mask, kBKSetOpt);
    gIO.SetIntOpt(hand, kIOHIDEventFieldDigitizerRange, touch, kBKSetOpt);
    gIO.SetIntOpt(hand, kIOHIDEventFieldDigitizerTouch, touch, kBKSetOpt);
    if (gIO.SetSender) gIO.SetSender(hand, kBKSenderID);
    gIO.Dispatch(gSendClient, hand);
    CFRelease(hand);

    BKNotifyUserActivity();
    if (gDump) {
        BKAppend([NSString stringWithFormat:@"D ph=%d o=%d x=%.3f y=%.3f", phase,
                  BKCurrentOrient(), rx, ry]);
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
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
            if (gDump) BKAppend([NSString stringWithFormat:@"B %@ dir=%d d=%d", key, d, (int)down]);
            return;
        }
    }

    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        if ([pt[@"Type"] isEqualToString:@"Dir"]) continue;
        NSString *k = pt[@"Key"];
        if (![k isKindOfClass:[NSString class]] || ![k isEqualToString:key]) continue;
        BKHandlePoint(pt, i, down);
        if (gDump) BKAppend([NSString stringWithFormat:@"B %@ hit=1", key]);
        return;
    }
    if (gDump) BKAppend([NSString stringWithFormat:@"B %@ hit=0", key]);
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
        if (gDump) BKAppend([NSString stringWithFormat:@"B %@ hit=1", key]);
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

static const double kBKProbe[5][2] = {
    {0.5, 0.5}, {0.2, 0.2}, {0.8, 0.2}, {0.2, 0.8}, {0.8, 0.8}
};

static void BKProbe(void)
{
    for (int i = 0; i < 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * 1200 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            double x = kBKProbe[i][0];
            double y = kBKProbe[i][1];
            double px = x, py = y;
            if (gRotate) BKConvInv(x, y, BKCurrentOrient(), &px, &py);
            BKTap(90 + (NSUInteger)i, px, py);
        });
    }
}

static void BKTestCenter(void)
{
    double px = 0.5, py = 0.5;
    if (gRotate) BKConvInv(0.5, 0.5, BKCurrentOrient(), &px, &py);
    BKAppend([NSString stringWithFormat:@"T pn=%.3f,%.3f", px, py]);
    BKTap(kBKIdxCursor + 9, px, py);
}

#pragma mark - Callback

static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    (void)target; (void)refcon; (void)queue;
    if (!ev) return;
    @try {
    int type = gIO.GetType(ev);
    if (gEvSeen < 25) {
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

    BKAppend(@"I init");
    BKMark(@"engine_ctor.txt");

    if (!BKLoadIOKit()) return;

    gListenClient = BKNewClient();
    if (!gListenClient) {
        BKAppend(@"I client=0");
        return;
    }

    @try {
        if (gIO.RegisterCB) gIO.RegisterCB(gListenClient, BKListenCB, NULL, NULL);
        if (gIO.Schedule) {
            gIO.Schedule(gListenClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
            BKAppend(@"I sched=runloop");
        } else if (gIO.SetQueue) {
            gIO.SetQueue(gListenClient, dispatch_get_main_queue());
            BKAppend(@"I sched=queue");
        }
        if (gIO.Activate) gIO.Activate(gListenClient);
        BKAppend(@"I tipo=monitor");
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

    BKLoadConfig();

    BKAppend(@"I ready");
    BKMark(@"engine_loaded.txt");
}

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            BKEngineInit();
        });
    }
}

%dtor {
    @autoreleasepool {
        if (gListenClient && gIO.Unschedule) {
            gIO.Unschedule(gListenClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        }
    }
}
