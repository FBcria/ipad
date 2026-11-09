// BallKey Engine — injetado no SpringBoard.
// Escuta teclado/mouse via HID e sintetiza toques de dedo reais
// (pacote hand + finger, BuiltIn, senderID — linhagem SimulateTouch).

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <IOKit/hid/IOHIDEventTypes.h>
#import "BKConfig.h"

#pragma mark - Externs IOKit

typedef const void *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;
typedef void (*BKHIDEventCB)(void *target, void *refcon, void *queue, BKIOHIDEventRef event);

BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator, int type, CFDictionaryRef properties);
void IOHIDEventSystemClientDispatchEvent(BKIOHIDEventSystemClientRef client, BKIOHIDEventRef event);
void IOHIDEventSystemClientRegisterEventCallback(BKIOHIDEventSystemClientRef client, BKHIDEventCB callback, void *target, void *refcon);
void IOHIDEventSystemClientSetDispatchQueue(BKIOHIDEventSystemClientRef client, dispatch_queue_t queue);
void IOHIDEventSystemClientActivate(BKIOHIDEventSystemClientRef client);

BKIOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp, uint32_t type,
    uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
    float x, float y, float z, float tipPressure, float barrelPressure,
    uint8_t range, uint8_t touch, uint32_t options);

BKIOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    float x, float y, float z, float tipPressure, float twist,
    float minorRadius, float majorRadius, float quality, float density, float irregularity,
    uint8_t range, uint8_t touch, uint32_t options);

void IOHIDEventAppendEvent(BKIOHIDEventRef event, BKIOHIDEventRef childEvent);
void IOHIDEventSetIntegerValueWithOptions(BKIOHIDEventRef event, IOHIDEventField field, int value, uint32_t options);
void IOHIDEventSetSenderID(BKIOHIDEventRef event, uint64_t senderID);
int IOHIDEventGetType(BKIOHIDEventRef event);
int IOHIDEventGetIntegerValue(BKIOHIDEventRef event, IOHIDEventField field);
float IOHIDEventGetFloatValue(BKIOHIDEventRef event, IOHIDEventField field);

#define kBKTransducerHand       3
#define kBKFieldDisplayInt      720921
#define kBKFieldBuiltIn         4
#define kBKSetOpt               0xF0000000u
#define kBKSenderID             0xDEFACEDBEEFFECE5ull
#define kBKClientTypeMonitor    1
#define kBKTypeKeyExtra         15
#define kBKTypePointer          17
#define kBKPtrX                 (17u << 16 | 0u)
#define kBKPtrY                 (17u << 16 | 1u)
#define kBKPtrMask              (17u << 16 | 3u)
#define kBKMoveFactor           0.000977f
#define kBKToggleUsage          14
#define kBKProbeUsage           19

// Ausentes no header vendorizado. Digitizer = tipo 11; Type = 4,
// IsDisplayIntegrated = 25, TouchPhase = 26.
#define kBKFieldType            ((IOHIDEventField)((11u << 16) | 4u))
#define kBKFieldTouchPhase      ((IOHIDEventField)((11u << 16) | 26u))

// Bits de mascara ausentes no header vendorizado.
#define kBKEventStop            0x08u
#define kBKEventPeak            0x10u
#define kBKEventStart           0x100u

#pragma mark - Estado

static BKIOHIDEventSystemClientRef gListenClient = NULL;
static BKIOHIDEventSystemClientRef gSendClient = NULL;
static BKIOHIDEventSystemClientRef gAltClient = NULL;
static NSArray *gPoints = nil;
static BOOL gEnabled = NO;
static NSString *gActiveBundle = nil;

static NSMutableDictionary *gDown = nil;
static NSMutableDictionary *gGen = nil;
static NSMutableDictionary *gCur = nil;

static BOOL gDirDown = NO;
static NSUInteger gDirIdx = 0;
static float gDirX = 0, gDirY = 0, gDirAX = 0, gDirAY = 0, gDirR = 0.12f, gDirS = 1.0f;

static uint16_t gPrevMask = 0;
static int gPendingDir = 0;
static int gHandledUsage = -1;

// diagnostico / calibracao
static BOOL gRotate = YES;
static BOOL gRaw = NO;
static BOOL gSpace = NO;
static BOOL gFollowCursor = YES;
static float gFollowSens = 1.0f;
static int gOrientOverride = 0;
static int gEndPhase = 0;
static BOOL gDump = YES;
static int gDumpLeft = 60;
static int gLastOrient = 0;
static float gCx = 0.5f, gCy = 0.5f;
static uint32_t gSeq = 0;
static BOOL gProbing = NO;
static int gVariant = 0;

static void BKSendLast(NSNumber *idx);
static void BKProbeRun(void);
static void BKReleaseAll(void);

#pragma mark - Log

static void BKAppend(NSString *line)
{
    NSString *path = @"/var/mobile/bk_debug.log";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *at = [fm attributesOfItemAtPath:path error:nil];
    if ([[at objectForKey:NSFileSize] longValue] > 200000) [fm removeItemAtPath:path error:nil];
    NSString *full = [line stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [full writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#pragma mark - Tela

static float BKScreenW(void)
{
    Class c = objc_getClass("UIScreen");
    if (!c) return 414.0f;
    id s = ((id (*)(id, SEL))objc_msgSend)(c, @selector(mainScreen));
    if (!s) return 414.0f;
    SEL sel = @selector(bounds);
    CGRect r;
    if ([s respondsToSelector:sel]) {
        r = ((CGRect (*)(id, SEL))objc_msgSend)(s, sel);
        return r.size.width;
    }
    return 414.0f;
}

static float BKScreenH(void)
{
    Class c = objc_getClass("UIScreen");
    if (!c) return 896.0f;
    id s = ((id (*)(id, SEL))objc_msgSend)(c, @selector(mainScreen));
    if (!s) return 896.0f;
    SEL sel = @selector(bounds);
    CGRect r;
    if ([s respondsToSelector:sel]) {
        r = ((CGRect (*)(id, SEL))objc_msgSend)(s, sel);
        return r.size.height;
    }
    return 896.0f;
}

#pragma mark - Orientacao

static int BKFrontMostOrientation(void)
{
    Class sbCls = objc_getClass("SpringBoard");
    if (!sbCls) return 0;
    id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
    if (!sb) return 0;
    SEL sel = @selector(_frontMostAppOrientation);
    if (![sb respondsToSelector:sel]) return 0;
    int o = ((int (*)(id, SEL))objc_msgSend)(sb, sel);
    if (o < 1 || o > 4) return 0;
    return o;
}

static int BKAccessibilityOrientation(void)
{
    Class sbCls = objc_getClass("SpringBoard");
    if (!sbCls) return 0;
    id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
    if (!sb) return 0;
    SEL sel = @selector(_accessibilityFrontMostApplication);
    if (![sb respondsToSelector:sel]) return 0;
    id app = ((id (*)(id, SEL))objc_msgSend)(sb, sel);
    if (!app) return 0;
    SEL osel = @selector(interfaceOrientation);
    if (![app respondsToSelector:osel]) return 0;
    int o = ((int (*)(id, SEL))objc_msgSend)(app, osel);
    if (o < 1 || o > 4) return 0;
    return o;
}

static int BKDeviceOrientation(void)
{
    Class c = objc_getClass("UIDevice");
    if (!c) return 0;
    id d = ((id (*)(id, SEL))objc_msgSend)(c, @selector(currentDevice));
    if (!d) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(d, @selector(orientation));
}

// Resolve a orientacao da interface do app em foco. Nunca cai em retrato
// cego: usa o ultimo valor bom antes de desistir.
static int BKCurrentOrient(void)
{
    if (gOrientOverride >= 1 && gOrientOverride <= 4) return gOrientOverride;

    int o = BKFrontMostOrientation();
    if (o) { gLastOrient = o; return o; }

    o = BKAccessibilityOrientation();
    if (o) { gLastOrient = o; return o; }

    int d = BKDeviceOrientation();
    if (d >= 1 && d <= 4) { gLastOrient = d; return d; }

    return gLastOrient ? gLastOrient : 1;
}

#pragma mark - Config

static void BKReleaseAll(void)
{
    for (NSNumber *k in [gDown allKeys]) {
        if ([gDown[k] boolValue]) {
            gDown[k] = @NO;
            BKSendLast(k);
        }
    }
    gDirDown = NO;
}

static void BKToggleEnabled(void)
{
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath];
    if (!cfg) cfg = [NSMutableDictionary dictionary];
    BOOL now = ![cfg[@"Enabled"] boolValue];
    if (now && (!gPoints || gPoints.count == 0)) {
        BKAppend(@"K sem marcadores");
        return;
    }
    cfg[@"Enabled"] = @(now);
    [cfg writeToFile:kBKConfigPath atomically:YES];
    gEnabled = now;
    if (!now) BKReleaseAll();
    BKAppend([NSString stringWithFormat:@"K en=%d", (int)now]);
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
    if ([cfg[@"Space"] isKindOfClass:[NSNumber class]]) gSpace = [cfg[@"Space"] boolValue];
    if ([cfg[@"FollowCursor"] isKindOfClass:[NSNumber class]]) gFollowCursor = [cfg[@"FollowCursor"] boolValue];
    if ([cfg[@"FollowSens"] isKindOfClass:[NSNumber class]]) gFollowSens = [cfg[@"FollowSens"] floatValue];
    if ([cfg[@"OrientOverride"] isKindOfClass:[NSNumber class]]) gOrientOverride = [cfg[@"OrientOverride"] intValue];
    if ([cfg[@"EndPhase"] isKindOfClass:[NSNumber class]]) gEndPhase = [cfg[@"EndPhase"] intValue];
    if ([cfg[@"Dump"] isKindOfClass:[NSNumber class]]) gDump = [cfg[@"Dump"] boolValue];
    if (gFollowSens <= 0.05f) gFollowSens = 0.05f;
    if (gFollowSens > 20.0f) gFollowSens = 20.0f;
    if (gEndPhase != 2 && gEndPhase != 3) gEndPhase = 0;

    gEnabled = enabled && pts.count > 0;
    gActiveBundle = active;
    gPoints = pts;
    gPendingDir = 0;
    gHandledUsage = -1;
    if (!gEnabled) BKReleaseAll();
    BKAppend([NSString stringWithFormat:@"C en=%d b=%@ n=%lu rot=%d sp=%d cur=%d sens=%.2f ov=%d ep=%d tela=%.0fx%.0f",
              (int)enabled, active ?: @"-", (unsigned long)pts.count,
              (int)gRotate, (int)gSpace, (int)gFollowCursor, gFollowSens, gOrientOverride, gEndPhase,
              BKScreenW(), BKScreenH()]);
}

#pragma mark - Toque

static float BKClamp(float v)
{
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
}

// Converte ponto do espaco retrato nativo para o espaco do app.
static void BKConv(float x, float y, int orient, float *ox, float *oy)
{
    float rx = x;
    float ry = y;
    switch (orient) {
        case 2: rx = 1.0f - x; ry = 1.0f - y; break;
        case 3: rx = y;        ry = 1.0f - x; break;
        case 4: rx = 1.0f - y; ry = x;        break;
        default: break;
    }
    *ox = BKClamp(rx);
    *oy = BKClamp(ry);
}

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
static void BKSend(float nx, float ny, int phase, NSUInteger idx)
{
    if (!gSendClient) {
        gSendClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, kBKClientTypeMonitor, NULL);
        if (!gSendClient) gSendClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!gSendClient) return;
    }

    uint32_t opt = kBKSetOpt;

    float rx = BKClamp(nx);
    float ry = BKClamp(ny);
    int o = BKCurrentOrient();

    if (gRotate && !gRaw) BKConv(rx, ry, o, &rx, &ry);

    if (gSpace) {
        rx = rx * BKScreenW();
        ry = ry * BKScreenH();
    }

    int wire = phase;
    if (gEndPhase) {
        if (phase == 0) wire = 2;
        else if (phase == 2) wire = gEndPhase;
    }

    // pressao e alcance reais: toque real nunca tem forca zero
    float tp = (phase == 2) ? 0.0f : 1.0f;
    int range = (phase == 2) ? 0 : 1;
    int touch = (phase == 2) ? 0 : 1;

    uint32_t fdx = (gVariant == 1 || gVariant == 5) ? 1u : (uint32_t)(idx + 1);
    uint32_t fid = (gVariant == 1 || gVariant == 5) ? 2u : (uint32_t)(idx + 101);
    int di = (gVariant == 2 || gVariant == 5) ? 1 : 0;
    float rad = (gVariant == 3 || gVariant == 5) ? 20.0f : 0.0f;
    float qual = (gVariant == 3 || gVariant == 5) ? 1.0f : 0.0f;

    int mask;
    if (phase == 0) {
        mask = kIOHIDDigitizerEventPosition;
    } else {
        mask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition;
    }
    if (gVariant == 4 || gVariant == 5) {
        if (phase == 1) mask |= (kBKEventStart | kBKEventPeak);
        else if (phase == 2) mask |= kBKEventStop;
    }

    uint64_t ab = mach_absolute_time();

    BKIOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ab, kBKTransducerHand,
        0, 1, (uint32_t)mask, 0, rx, ry, 0, tp, 0, (uint8_t)range, (uint8_t)di, 0);
    if (!hand) return;

    IOHIDEventSetIntegerValueWithOptions(hand, kBKFieldDisplayInt, 1, opt);
    IOHIDEventSetIntegerValueWithOptions(hand, kBKFieldBuiltIn, 1, opt);

    BKIOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(kCFAllocatorDefault, ab,
        fdx, fid, (uint32_t)mask, rx, ry, 0, tp, 0, rad, rad, qual, 1.0f, 0,
        (uint8_t)range, (uint8_t)touch, 0);
    if (finger) {
        IOHIDEventSetIntegerValueWithOptions(finger, kBKFieldDisplayInt, 1, opt);
        if (gEndPhase) {
            IOHIDEventSetIntegerValueWithOptions(finger, kBKFieldTouchPhase, wire, opt);
        }
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
    }

    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerEventMask, mask, opt);
    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerRange, range, opt);
    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerTouch, touch, opt);
    if (gEndPhase) {
        IOHIDEventSetIntegerValueWithOptions(hand, kBKFieldTouchPhase, wire, opt);
    }
    if (gVariant != 2) IOHIDEventSetSenderID(hand, kBKSenderID);

    BKIOHIDEventSystemClientRef cli = gSendClient;
    if (gVariant == 3) {
        if (!gAltClient) gAltClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (gAltClient) cli = gAltClient;
    }
    IOHIDEventSystemClientDispatchEvent(cli, hand);
    CFRelease(hand);

    BKNotifyUserActivity();
    BKAppend([NSString stringWithFormat:@"D v=%d ph=%d o=%d u=%d f=%d r=%d s=%d tp=%.1f x=%.3f y=%.3f X=%.3f Y=%.3f",
              gVariant, phase, o, BKDeviceOrientation(), BKFrontMostOrientation(), (int)gRaw, (int)gSpace,
              tp, rx, ry, nx, ny]);
}

static void BKSendLast(NSNumber *idx)
{
    NSArray *a = gCur[idx];
    if (![a isKindOfClass:[NSArray class]] || a.count < 2) return;
    BKSend([a[0] floatValue], [a[1] floatValue], 2, [idx unsignedIntegerValue]);
}

static void BKDown(NSUInteger idx, float nx, float ny)
{
    if ([gDown[@(idx)] boolValue]) return;
    nx = BKClamp(nx);
    ny = BKClamp(ny);
    gDown[@(idx)] = @YES;
    gCur[@(idx)] = @[ @(nx), @(ny) ];
    BKSend(nx, ny, 1, idx);
}

static void BKMove(NSUInteger idx, float nx, float ny)
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

#pragma mark - Acoes

static void BKTap(NSUInteger idx, float nx, float ny)
{
    BKDown(idx, nx, ny);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKMove(idx, nx, ny);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKUp(idx);
    });
}

// Clique no cursor virtual: identidade rotativa para nao colidir em cliques rapidos.
static void BKCursorTap(void)
{
    NSUInteger idx = 40 + (NSUInteger)(gSeq++ % 16);
    float x = gCx;
    float y = gCy;
    BKSend(x, y, 1, idx);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKSend(x, y, 0, idx);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKSend(x, y, 2, idx);
    });
}

static void BKHold(NSUInteger idx, float nx, float ny, int ms)
{
    BKDown(idx, nx, ny);
    NSNumber *gen = @([gGen[@(idx)] intValue] + 1);
    gGen[@(idx)] = gen;
    if (ms < 60) ms = 60;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if ([gGen[@(idx)] isEqualToNumber:gen]) BKUp(idx);
    });
}

static void BKHandleDir(NSDictionary *pt, NSUInteger idx, BOOL down)
{
    if (down) {
        if (gDirDown) return;
        gDirAX = BKClamp([pt[@"X"] floatValue]);
        gDirAY = BKClamp([pt[@"Y"] floatValue]);
        gDirR = pt[@"Radius"] ? [pt[@"Radius"] floatValue] : 0.12f;
        gDirS = pt[@"Sens"] ? [pt[@"Sens"] floatValue] : 1.0f;
        gDirX = gDirAX;
        gDirY = gDirAY;
        gDirIdx = idx;
        gDirDown = YES;
        BKDown(idx, gDirX, gDirY);
    } else {
        if (!gDirDown) return;
        gDirDown = NO;
        BKUp(idx);
    }
}

static void BKHandlePoint(NSDictionary *pt, NSUInteger idx, BOOL down)
{
    NSString *type = pt[@"Type"] ?: @"Tap";
    float nx = [pt[@"X"] floatValue];
    float ny = [pt[@"Y"] floatValue];
    if ([type isEqualToString:@"Tap"]) {
        if (down) {
            BKTap(idx, nx, ny);
            NSUInteger k = idx;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                BKAppend(@"T centro");
                BKTap(k, 0.5f, 0.5f);
            });
        }
    } else if ([type isEqualToString:@"Press"]) {
        if (down) BKDown(idx, nx, ny); else BKUp(idx);
    } else if ([type isEqualToString:@"Hold"]) {
        if (down) BKHold(idx, nx, ny, pt[@"HoldMs"] ? [pt[@"HoldMs"] intValue] : 400);
    } else if ([type isEqualToString:@"Probe"]) {
        if (down) BKProbeRun();
    }
}

static void BKHandleMove(float dx, float dy)
{
    if (dx == 0 && dy == 0) return;

    gCx = BKClamp(gCx + dx * gFollowSens * kBKMoveFactor);
    gCy = BKClamp(gCy + dy * gFollowSens * kBKMoveFactor);

    if (!gDirDown) return;

    gDirX += dx * gDirS * kBKMoveFactor;
    gDirY += dy * gDirS * kBKMoveFactor;
    float ddx = gDirX - gDirAX;
    float ddy = gDirY - gDirAY;
    float len = sqrtf(ddx * ddx + ddy * ddy);
    if (len > gDirR && len > 0.0001f) {
        gDirX = gDirAX + ddx / len * gDirR;
        gDirY = gDirAY + ddy / len * gDirR;
    }
    BKMove(gDirIdx, gDirX, gDirY);
}

#pragma mark - Probe

static void BKVarStep(int v, int n)
{
    if (v >= 6) {
        gVariant = 0;
        gRaw = NO;
        gSpace = NO;
        gProbing = NO;
        BKAppend(@"V fim");
        return;
    }
    if (n >= 2) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            BKVarStep(v + 1, 0);
        });
        return;
    }

    gVariant = v;
    NSUInteger idx = 90 + (NSUInteger)(v * 2 + n);
    BKAppend([NSString stringWithFormat:@"V %d n=%d", v, n]);

    BKSend(0.5f, 0.5f, 1, idx);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKSend(0.5f, 0.5f, 0, idx);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKSend(0.5f, 0.5f, 2, idx);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKVarStep(v, n + 1);
    });
}

static void BKProbeRun(void)
{
    if (gProbing) return;
    gProbing = YES;
    gRaw = YES;
    gSpace = NO;
    BKAppend([NSString stringWithFormat:@"V inicio o=%d tela=%.0fx%.0f", BKCurrentOrient(), BKScreenW(), BKScreenH()]);
    BKVarStep(0, 0);
}

#pragma mark - Mapeamento

static void BKHandleKey(int usage, BOOL down)
{
    NSString *key = [NSString stringWithFormat:@"k:%d", usage];
    BOOL hit = NO;
    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        NSString *k = pt[@"Key"];
        if (![k isKindOfClass:[NSString class]] || ![k isEqualToString:key]) continue;
        if ([pt[@"Type"] isEqualToString:@"Dir"]) BKHandleDir(pt, i, down);
        else BKHandlePoint(pt, i, down);
        hit = YES;
        break;
    }
    BKAppend([NSString stringWithFormat:@"B %@ hit=%d", key, hit]);
}

static void BKHandleButton(int b, BOOL down)
{
    if (gFollowCursor && b == 0) {
        if (down) {
            BKAppend([NSString stringWithFormat:@"B m:0 cur=1 x=%.3f y=%.3f", gCx, gCy]);
            BKCursorTap();
        }
        return;
    }

    NSString *key = [NSString stringWithFormat:@"m:%d", b];
    BOOL hit = NO;
    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        if (![pt[@"Type"] isEqualToString:@"Dir"]) continue;
        NSString *k = pt[@"Button"];
        if (![k isKindOfClass:[NSString class]] || ![k isEqualToString:key]) continue;
        BKHandleDir(pt, i, down);
        hit = YES;
        break;
    }
    if (!hit) {
        for (NSUInteger i = 0; i < gPoints.count; i++) {
            NSDictionary *pt = gPoints[i];
            if ([pt[@"Type"] isEqualToString:@"Dir"]) continue;
            NSString *k = pt[@"Key"];
            if (![k isKindOfClass:[NSString class]] || ![k isEqualToString:key]) continue;
            BKHandlePoint(pt, i, down);
            hit = YES;
            break;
        }
    }
    BKAppend([NSString stringWithFormat:@"B %@ hit=%d", key, hit]);
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

#pragma mark - Callback

static void BKDumpPointer(BKIOHIDEventRef ev)
{
    if (!gDump || gDumpLeft <= 0) return;
    gDumpLeft--;
    NSMutableString *s = [NSMutableString stringWithString:@"M"];
    for (int f = 0; f < 8; f++) {
        IOHIDEventField fld = (IOHIDEventField)((17u << 16) | (unsigned)f);
        [s appendFormat:@" %d:%.4f/%d", f,
            IOHIDEventGetFloatValue(ev, fld), IOHIDEventGetIntegerValue(ev, fld)];
    }
    BKAppend(s);
}

static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    if (!ev) return;
    int type = IOHIDEventGetType(ev);

    if (type == kIOHIDEventTypeKeyboard) {
        int page = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsage);
        int down = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardDown);
        int repeat = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardRepeat);
        if (repeat) return;

        if (usage == kBKToggleUsage && (page == 0 || page == 7)) {
            gHandledUsage = usage;
            gPendingDir = 0;
            if (down) BKToggleEnabled();
            return;
        }

        if (usage == kBKProbeUsage && (page == 0 || page == 7)) {
            gHandledUsage = usage;
            gPendingDir = 0;
            if (down) BKProbeRun();
            return;
        }

        gPendingDir = down ? 1 : -1;
        if ((page == 0 || page == 7) && usage >= 4 && usage <= 231) {
            gHandledUsage = usage;
            if (gEnabled && gPoints.count) BKHandleKey(usage, down != 0);
        }
    } else if (type == kBKTypeKeyExtra) {
        int usage = IOHIDEventGetIntegerValue(ev, 0);
        int dir = gPendingDir;
        gPendingDir = 0;
        if (usage <= 0) return;
        if (usage == kBKToggleUsage || usage == kBKProbeUsage) return;
        if (usage == gHandledUsage) {
            gHandledUsage = -1;
            return;
        }
        gHandledUsage = -1;
        if (gEnabled && gPoints.count) BKHandleKey(usage, dir > 0);
    } else if (type == kBKTypePointer) {
        float dx = IOHIDEventGetFloatValue(ev, kBKPtrX);
        float dy = IOHIDEventGetFloatValue(ev, kBKPtrY);
        int bmask = IOHIDEventGetIntegerValue(ev, kBKPtrMask);
        BKDumpPointer(ev);
        BKHandleMove(dx, dy);
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
    IOHIDEventSystemClientSetDispatchQueue(gListenClient, dispatch_get_main_queue());
    IOHIDEventSystemClientActivate(gListenClient);

    int token = 0;
    notify_register_dispatch(kBKNotifyReload, &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        BKLoadConfig();
    });

    BKLoadConfig();

    BKAppend(@"I ready");

    [@"engine" writeToFile:@"/var/mobile/bk_engine_loaded.txt"
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
        if (gListenClient) {
            IOHIDEventSystemClientSetDispatchQueue(gListenClient, NULL);
            CFRelease(gListenClient);
            gListenClient = NULL;
        }
    }
}
