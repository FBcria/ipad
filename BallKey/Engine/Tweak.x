// BallKey Engine — injetado no SpringBoard.
// Escuta teclado/mouse via HID e sintetiza toques de dedo reais
// (pacote hand + finger, BuiltIn, senderID — linhagem SimulateTouch).

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
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
void IOHIDEventSystemClientDispatchEvent(BKIOHIDEventSystemClientRef client, BKIOHIDEventRef event);
void IOHIDEventSystemClientSetMatching(BKIOHIDEventSystemClientRef client, CFTypeRef match);
void IOHIDEventSystemClientRegisterEventCallback(BKIOHIDEventSystemClientRef client, BKHIDEventCB callback, void *target, void *refcon);
void IOHIDEventSystemClientScheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
void IOHIDEventSystemClientUnscheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);

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
#define kBKTypeKeyExtra         15
#define kBKTypePointer          17
#define kBKPtrX                 (17u << 16 | 1u)
#define kBKPtrY                 (17u << 16 | 2u)
#define kBKPtrMask              (17u << 16 | 4u)
#define kBKMoveFactor           0.000977f

#pragma mark - Estado

static BKIOHIDEventSystemClientRef gListenClient = NULL;
static BKIOHIDEventSystemClientRef gSendClient = NULL;
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

static void BKSendLast(NSNumber *idx);

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

#pragma mark - Config

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
    gEnabled = enabled && pts.count > 0;
    gActiveBundle = active;
    gPoints = pts;
    gPendingDir = 0;
    gHandledUsage = -1;
    if (!gEnabled) {
        for (NSNumber *k in gDown.allKeys) {
            if ([gDown[k] boolValue]) {
                gDown[k] = @NO;
                BKSendLast(k);
            }
        }
        gDirDown = NO;
    }
}

#pragma mark - Toque

static float BKClamp(float v)
{
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
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
        gSendClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!gSendClient) return;
    }

    uint64_t ab = mach_absolute_time();
    uint32_t index = (uint32_t)(idx + 1);
    uint32_t ident = (uint32_t)(idx + 101);

    BKIOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ab, kBKTransducerHand,
        0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return;

    IOHIDEventSetIntegerValueWithOptions(hand, kBKFieldDisplayInt, 1, kBKSetOpt);
    IOHIDEventSetIntegerValueWithOptions(hand, kBKFieldBuiltIn, 1, kBKSetOpt);

    int mask;
    int touch;
    if (phase == 0) {
        mask = kIOHIDDigitizerEventPosition;
        touch = 1;
    } else {
        mask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition;
        touch = (phase == 2) ? 0 : 1;
    }

    BKIOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(kCFAllocatorDefault, ab,
        index, ident, (uint32_t)mask, nx, ny, 0, 0, 0, 0, 0, 0, 0, 0,
        (uint8_t)touch, (uint8_t)touch, 0);
    if (finger) {
        IOHIDEventSetIntegerValueWithOptions(finger, kBKFieldDisplayInt, 1, kBKSetOpt);
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
    BKAppend([NSString stringWithFormat:@"D ph=%d i=%lu x=%.3f y=%.3f", phase, (unsigned long)idx, nx, ny]);
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

#pragma mark - Ações

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
        if (down) BKTap(idx, nx, ny);
    } else if ([type isEqualToString:@"Press"]) {
        if (down) BKDown(idx, nx, ny); else BKUp(idx);
    } else if ([type isEqualToString:@"Hold"]) {
        if (down) BKHold(idx, nx, ny, pt[@"HoldMs"] ? [pt[@"HoldMs"] intValue] : 400);
    }
}

static void BKHandleMove(float dx, float dy)
{
    if (!gDirDown || (dx == 0 && dy == 0)) return;
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
    BKAppend([NSString stringWithFormat:@"B %@ b=%@ pts=%lu hit=%d",
              key, gActiveBundle ?: @"-", (unsigned long)gPoints.count, hit]);
}

static void BKHandleButton(int b, BOOL down)
{
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
    BKAppend([NSString stringWithFormat:@"B %@ b=%@ pts=%lu hit=%d",
              key, gActiveBundle ?: @"-", (unsigned long)gPoints.count, hit]);
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

static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    if (!ev) return;
    if (!gEnabled || gPoints.count == 0) return;

    int type = IOHIDEventGetType(ev);

    if (type == kIOHIDEventTypeKeyboard) {
        int page = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsage);
        int down = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardDown);
        int repeat = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardRepeat);
        if (repeat) return;
        gPendingDir = down ? 1 : -1;
        if ((page == 0 || page == 7) && usage >= 4 && usage <= 231) {
            gHandledUsage = usage;
            BKHandleKey(usage, down != 0);
        }
    } else if (type == kBKTypeKeyExtra) {
        int usage = IOHIDEventGetIntegerValue(ev, 0);
        int dir = gPendingDir;
        gPendingDir = 0;
        if (usage <= 0) return;
        if (usage == gHandledUsage) {
            gHandledUsage = -1;
            return;
        }
        gHandledUsage = -1;
        BKHandleKey(usage, dir > 0);
    } else if (type == kIOHIDEventTypeMouse) {
        float dx = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldMouseX);
        float dy = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldMouseY);
        int bmask = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldMouseButtonMask);
        if (dx != 0 || dy != 0) BKHandleMove(dx, dy);
        BKHandleMask((uint16_t)bmask);
    } else if (type == kIOHIDEventTypeButton) {
        int num = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonNumber);
        int click = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonClickCount);
        int idx = (num >= 1) ? (num - 1) : num;
        if (idx >= 0 && idx <= 2) BKHandleButton(idx, click > 0);
    } else if (type == kBKTypePointer) {
        int mx = IOHIDEventGetIntegerValue(ev, kBKPtrX);
        int my = IOHIDEventGetIntegerValue(ev, kBKPtrY);
        int bmask = IOHIDEventGetIntegerValue(ev, kBKPtrMask);
        if (mx != 0 || my != 0) BKHandleMove((float)mx, (float)my);
        if (bmask >= 0 && bmask <= 7) BKHandleMask((uint16_t)bmask);
        BKAppend([NSString stringWithFormat:@"P f0=%d f1=%d f2=%d f3=%d f4=%d f5=%d",
                  IOHIDEventGetIntegerValue(ev, (17u << 16 | 0u)),
                  IOHIDEventGetIntegerValue(ev, (17u << 16 | 1u)),
                  IOHIDEventGetIntegerValue(ev, (17u << 16 | 2u)),
                  IOHIDEventGetIntegerValue(ev, (17u << 16 | 3u)),
                  IOHIDEventGetIntegerValue(ev, (17u << 16 | 4u)),
                  IOHIDEventGetIntegerValue(ev, (17u << 16 | 5u))]);
    }
}

#pragma mark - Init

static void BKEngineInit(void)
{
    gDown = [NSMutableDictionary dictionary];
    gGen = [NSMutableDictionary dictionary];
    gCur = [NSMutableDictionary dictionary];

    gListenClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gListenClient) return;

    NSArray *matching = @[
        @{ @"DeviceUsagePage": @1, @"DeviceUsage": @6 },
        @{ @"DeviceUsagePage": @1, @"DeviceUsage": @2 },
        @{ @"DeviceUsagePage": @1, @"DeviceUsage": @1 },
        @{ @"DeviceUsagePage": @9, @"DeviceUsage": @1 },
    ];
    IOHIDEventSystemClientSetMatching(gListenClient, (__bridge CFTypeRef)matching);
    IOHIDEventSystemClientRegisterEventCallback(gListenClient, BKListenCB, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(gListenClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    int token = 0;
    notify_register_dispatch(kBKNotifyReload, &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        BKLoadConfig();
    });

    BKLoadConfig();

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
            IOHIDEventSystemClientUnscheduleWithRunLoop(gListenClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
            CFRelease(gListenClient);
            gListenClient = NULL;
        }
    }
}
