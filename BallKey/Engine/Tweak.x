#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <objc/runtime.h>
#import <math.h>

typedef struct __IOHIDEvent *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;

extern BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int, void *);
extern void IOHIDEventSystemClientRegisterEventCallback(BKIOHIDEventSystemClientRef, void *, void *, void *);
extern void IOHIDEventSystemClientSetDispatchQueue(BKIOHIDEventSystemClientRef, dispatch_queue_t);
extern void IOHIDEventSystemClientActivate(BKIOHIDEventSystemClientRef);
extern void IOHIDEventSystemClientDispatchEvent(BKIOHIDEventSystemClientRef, BKIOHIDEventRef);
extern int IOHIDEventGetType(BKIOHIDEventRef);
extern int64_t IOHIDEventGetIntegerValue(BKIOHIDEventRef, int32_t);
extern double IOHIDEventGetFloatValue(BKIOHIDEventRef, int32_t);
extern void IOHIDEventSetIntegerValueWithOptions(BKIOHIDEventRef, int32_t, int64_t, uint32_t);
extern void IOHIDEventSetFloatValue(BKIOHIDEventRef, int32_t, double);
extern void IOHIDEventSetSenderID(BKIOHIDEventRef, uint64_t);
extern void IOHIDEventAppendEvent(BKIOHIDEventRef, BKIOHIDEventRef);

extern BKIOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double,
    uint8_t, uint8_t, uint32_t);
extern BKIOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(CFAllocatorRef, uint64_t,
    uint32_t, uint32_t, uint32_t, double, double, double, double, double, double, double,
    double, double, double, uint8_t, uint8_t, uint32_t);

#define kBKConfigPath           @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKLogPath              @"/var/mobile/bk_debug.log"
#define kBKNotifyReload         "com.wjf.ballkey.reload"
#define kBKNotifyTest           "com.wjf.ballkey.test"

#define kBKTransducerHand       3
#define kBKTransducerFinger     2
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
#define kBKFpsKey               224

#define kBKIdxAim               70
#define kBKIdxAds               71
#define kBKIdxDir               72
#define kBKIdxCursor            40

#pragma mark - Estado

static BKIOHIDEventSystemClientRef gListenClient = NULL;
static BKIOHIDEventSystemClientRef gSendClient = NULL;
static NSArray *gPoints = nil;
static BOOL gEnabled = NO;
static NSString *gActiveBundle = nil;

static NSMutableDictionary *gDown = nil;
static NSMutableDictionary *gGen = nil;
static NSMutableDictionary *gCur = nil;

static BOOL gRotate = YES;
static BOOL gSpace = NO;
static BOOL gFollowCursor = NO;
static double gFollowSens = 1.0;
static int gOrientOverride = 0;
static BOOL gDump = NO;

static BOOL gFps = NO;
static double gFpsSens = 1.0;
static double gFireX = 0.83, gFireY = 0.66;
static double gAdsX = 0.95, gAdsY = 0.53;
static double gAimX = 0.5, gAimY = 0.5;
static BOOL gAdsDown = NO;

static BOOL gDirActive = NO;
static NSUInteger gDirIdx = 0;
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

static void BKSendLast(NSNumber *idx);

#pragma mark - Log

static void BKAppend(NSString *line)
{
    NSString *full = [line stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kBKLogPath];
    if (!fh) {
        [full writeToFile:kBKLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
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

// Visual -> painel
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
    if ([cfg[@"Space"] isKindOfClass:[NSNumber class]]) gSpace = [cfg[@"Space"] boolValue];
    if ([cfg[@"FollowCursor"] isKindOfClass:[NSNumber class]]) gFollowCursor = [cfg[@"FollowCursor"] boolValue];
    if ([cfg[@"FollowSens"] isKindOfClass:[NSNumber class]]) gFollowSens = [cfg[@"FollowSens"] doubleValue];
    if ([cfg[@"OrientOverride"] isKindOfClass:[NSNumber class]]) gOrientOverride = [cfg[@"OrientOverride"] intValue];
    if ([cfg[@"Dump"] isKindOfClass:[NSNumber class]]) gDump = [cfg[@"Dump"] boolValue];
    if ([cfg[@"FpsSens"] isKindOfClass:[NSNumber class]]) gFpsSens = [cfg[@"FpsSens"] doubleValue];
    if ([cfg[@"FireX"] isKindOfClass:[NSNumber class]]) gFireX = [cfg[@"FireX"] doubleValue];
    if ([cfg[@"FireY"] isKindOfClass:[NSNumber class]]) gFireY = [cfg[@"FireY"] doubleValue];
    if ([cfg[@"AdsX"] isKindOfClass:[NSNumber class]]) gAdsX = [cfg[@"AdsX"] doubleValue];
    if ([cfg[@"AdsY"] isKindOfClass:[NSNumber class]]) gAdsY = [cfg[@"AdsY"] doubleValue];

    gEnabled = enabled && pts.count > 0;
    gActiveBundle = active;
    gPoints = pts;
    gPendingDir = 0;
    gHandledUsage = -1;

    if (!gEnabled) BKReleaseAll();

    BKAppend([NSString stringWithFormat:@"C en=%d b=%@ n=%lu", (int)enabled, active ?: @"-",
              (unsigned long)pts.count]);
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

// fase: 0 move, 1 desce, 2 sobe
static void BKSend(double nx, double ny, int phase, NSUInteger idx)
{
    if (!gSendClient) {
        gSendClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, kBKClientTypeMonitor, NULL);
        if (!gSendClient) gSendClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!gSendClient) return;
    }

    double rx = BKClamp(nx);
    double ry = BKClamp(ny);

    uint64_t ab = mach_absolute_time();
    uint32_t index = (uint32_t)(idx + 1);
    uint32_t ident = (uint32_t)(idx + 101);

    BKIOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ab,
        kBKTransducerHand, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return;

    IOHIDEventSetIntegerValueWithOptions(hand, kBKFieldDisplayInt, 1, kBKSetOpt);
    IOHIDEventSetIntegerValueWithOptions(hand, kBKFieldBuiltIn, 1, kBKSetOpt);

    int mask;
    int touch;
    if (phase == 0) {
        mask = kIOHIDDigitizerEventPosition;
        touch = 1;
    } else {
        mask = kIOHIDDigitizerEventRange;
        touch = (phase == 1) ? 1 : 0;
    }

    BKIOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(kCFAllocatorDefault, ab,
        index, ident, (uint32_t)mask, rx, ry, 0, 0, 0, 0, 0, 0, 0, 0,
        (uint8_t)touch, (uint8_t)touch, 0);
    if (finger) {
        IOHIDEventSetIntegerValueWithOptions(finger, kBKFieldDisplayInt, 1, kBKSetOpt);
        IOHIDEventSetFloatValue(finger, kBKFieldX, rx);
        IOHIDEventSetFloatValue(finger, kBKFieldY, ry);
        IOHIDEventSetIntegerValueWithOptions(finger, kBKFieldTouchPhase, phase, kBKSetOpt);
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
    }

    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerEventMask, mask, kBKSetOpt);
    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerRange, touch, kBKSetOpt);
    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerTouch, touch, kBKSetOpt);
    IOHIDEventSetSenderID(hand, kBKSenderID);
    IOHIDEventSystemClientDispatchEvent(gSendClient, hand);
    CFRelease(hand);

    BKNotifyUserActivity();
    if (gDump) {
        BKAppend([NSString stringWithFormat:@"D ph=%d o=%d x=%.3f y=%.3f", phase,
                  BKCurrentOrient(), rx, ry]);
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
    BKDown(idx, nx, ny);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKUp(idx);
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
    for (int i = 0; i < 4; i++) gDirHeld[i] = NO;
    gDirActive = NO;
    gFps = NO;
    gAdsDown = NO;
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
            gDirIdx = kBKIdxDir;
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

    if (gAimX < 0.15 || gAimX > 0.85 || gAimY < 0.15 || gAimY > 0.85) {
        BKUp(kBKIdxAim);
        gAimX = 0.5;
        gAimY = 0.5;
        double px = 0.5, py = 0.5;
        if (gRotate) BKConvInv(0.5, 0.5, BKCurrentOrient(), &px, &py);
        BKDown(kBKIdxAim, px, py);
        return;
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
        return;
    }

    gFps = YES;
    gAimX = 0.5;
    gAimY = 0.5;
    double px = 0.5, py = 0.5;
    if (gRotate) BKConvInv(0.5, 0.5, BKCurrentOrient(), &px, &py);
    BKDown(kBKIdxAim, px, py);
    BKAppend(@"F on");
}

static void BKFpsFire(void)
{
    double px = gFireX, py = gFireY;
    if (gRotate) BKConvInv(gFireX, gFireY, BKCurrentOrient(), &px, &py);
    BKTap(kBKIdxCursor, px, py);
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
    if (usage == kBKFpsKey) {
        if (down) BKFpsToggle();
        return;
    }

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
            BKAppend(@"M fire");
            return;
        }
        if (b == 1) {
            BKFpsAds(down);
            BKAppend(@"M ads");
            return;
        }
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

#pragma mark - Cursor

static void BKCursorMove(double dx, double dy)
{
    gCx = BKClamp(gCx + dx * gFollowSens * kBKMoveFactor);
    gCy = BKClamp(gCy + dy * gFollowSens * kBKMoveFactor);
}

static void BKCursorTap(void)
{
    NSUInteger idx = kBKIdxCursor + (NSUInteger)(gGen.count % 8);
    double px = gCx, py = gCy;
    if (gRotate) BKConvInv(gCx, gCy, BKCurrentOrient(), &px, &py);
    BKAppend([NSString stringWithFormat:@"C vis=%.3f,%.3f pn=%.3f,%.3f", gCx, gCy, px, py]);
    BKSend(px, py, 1, idx);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKSend(px, py, 2, idx);
    });
}

#pragma mark - Probe

static const double kBKProbe[5][2] = {
    {0.5, 0.5}, {0.2, 0.2}, {0.8, 0.2}, {0.2, 0.8}, {0.8, 0.8}
};

static void BKProbe(void)
{
    BKAppend(@"P ini");
    for (int i = 0; i < 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * 1200 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            double x = kBKProbe[i][0];
            double y = kBKProbe[i][1];
            double px = x, py = y;
            if (gRotate) BKConvInv(x, y, BKCurrentOrient(), &px, &py);
            BKAppend([NSString stringWithFormat:@"P %d vis=%.3f,%.3f pn=%.3f,%.3f", i, x, y, px, py]);
            BKTap(90 + (NSUInteger)i, px, py);
            if (i == 4) BKAppend(@"P fim");
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
    if (!ev) return;
    int type = IOHIDEventGetType(ev);

    if (type == kIOHIDEventTypeKeyboard) {
        int page = (int)IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = (int)IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsage);
        int down = (int)IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardDown);
        int repeat = (int)IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardRepeat);
        if (repeat) return;
        gPendingDir = down ? 1 : -1;
        if ((page == 0 || page == 7) && usage >= 4 && usage <= 231) {
            gHandledUsage = usage;
            if (usage == 224 && down) {
                BKFpsToggle();
                return;
            }
            if (gEnabled && gPoints.count) BKHandleKey(usage, down != 0);
        }
    } else if (type == kBKTypeKeyExtra) {
        int usage = (int)IOHIDEventGetIntegerValue(ev, 0);
        int dir = gPendingDir;
        gPendingDir = 0;
        if (usage <= 0) return;
        if (usage == gHandledUsage) {
            gHandledUsage = -1;
            return;
        }
        if (gEnabled && gPoints.count && (usage >= 4 && usage <= 231)) {
            BKHandleKey(usage, dir > 0);
        }
    } else if (type == kBKTypePointer) {
        double dx = IOHIDEventGetFloatValue(ev, kBKPtrX);
        double dy = IOHIDEventGetFloatValue(ev, kBKPtrY);
        int bmask = (int)IOHIDEventGetIntegerValue(ev, kBKPtrMask);
        if (dx != 0 || dy != 0) {
            BKCursorMove(dx, dy);
            BKFpsMove(dx, dy);
        }
        if (gEnabled && gPoints.count) BKHandleMask((uint16_t)bmask);
        else gPrevMask = (uint16_t)bmask;
    }
}

#pragma mark - Init

static void BKEngineInit(void)
{
    gDown = [NSMutableDictionary dictionary];
    gGen = [NSMutableDictionary dictionary];
    gCur = [NSMutableDictionary dictionary];

    BKAppend(@"I init");

    gListenClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, kBKClientTypeMonitor, NULL);
    if (!gListenClient) gListenClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gListenClient) {
        BKAppend(@"I client=0");
        return;
    }

    IOHIDEventSystemClientRegisterEventCallback(gListenClient, BKListenCB, NULL, NULL);
    IOHIDEventSystemClientSetDispatchQueue(gListenClient, dispatch_get_main_queue
