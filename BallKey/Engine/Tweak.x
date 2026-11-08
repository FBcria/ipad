// BallKey Engine — injetado no backboardd.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDEventTypes.h>
#import <notify.h>
#import <mach/mach_time.h>
#import "BKConfig.h"

typedef struct __IOHIDEvent *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;
typedef void (*BKHIDEventCB)(void *target, void *refcon, void *queue, BKIOHIDEventRef event);

#define kBKFieldIsDisplayIntegrated (11u << 16 | 25u)

extern BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator, int type, CFDictionaryRef props);
extern void IOHIDEventSystemClientRegisterEventCallback(BKIOHIDEventSystemClientRef client, BKHIDEventCB cb, void *target, void *refcon);
extern void IOHIDEventSystemClientScheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
extern void IOHIDEventSystemClientUnscheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
extern Boolean IOHIDEventSystemClientDispatchEvent(BKIOHIDEventSystemClientRef client, BKIOHIDEventRef event);
extern BKIOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp, uint32_t type,
                                                      uint32_t index, uint32_t identity, uint32_t eventMask,
                                                      uint32_t buttonMask, double x, double y, double z,
                                                      double tipPressure, double barrelPressure,
                                                      Boolean range, Boolean touch, uint32_t options);
extern void IOHIDEventSetIntegerValue(BKIOHIDEventRef event, uint32_t field, int value);
extern int IOHIDEventGetType(BKIOHIDEventRef event);
extern int IOHIDEventGetIntegerValue(BKIOHIDEventRef event, uint32_t field);
extern double IOHIDEventGetFloatValue(BKIOHIDEventRef event, uint32_t field);

static dispatch_queue_t gIOQ;
static BKIOHIDEventSystemClientRef gClient = NULL;
static NSDictionary *gCfg = @{};
static BOOL gEnabled = YES;
static NSString *gActiveBundle = nil;
static uint32_t gLastMask = 0;
static int gFinger = 2;
static int gNotifyToken = 0;

typedef struct {
    BOOL active;
    int finger;
    CGPoint base;
    CGPoint cur;
    double radius;
    double sens;
    NSString *enc;
    NSString *type;
} BKAct;

#define kBKMaxAct 8
static BKAct gActs[kBKMaxAct];

static void BKLoadCfg(void)
{
    dispatch_sync(gIOQ, ^{
        NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
        gCfg = c ?: @{};
        gEnabled = gCfg[@"Enabled"] ? [gCfg[@"Enabled"] boolValue] : YES;
        gActiveBundle = gCfg[@"ActiveBundle"];
    });
}

static NSArray *BKProfile(void)
{
    if (!gActiveBundle.length) return nil;
    id pts = gCfg[@"Profiles"][gActiveBundle];
    return [pts isKindOfClass:[NSArray class]] ? pts : nil;
}

static NSString *BKProbe(BKIOHIDEventRef ev, int type)
{
    NSMutableString *s = [NSMutableString string];
    uint32_t base = ((uint32_t)type) << 16;
    for (uint32_t i = 0; i < 16; i++) {
        [s appendFormat:@" [%u]f=%.0f,i=%d", i,
            IOHIDEventGetFloatValue(ev, base + i),
            IOHIDEventGetIntegerValue(ev, base + i)];
    }
    return s;
}

static void BKLogRaw(BKIOHIDEventRef ev)
{
    int t = IOHIDEventGetType(ev);
    NSString *line = [NSString stringWithFormat:@"t=%d p=%d u=%d d=%d bm=%d mx=%.0f my=%.0f%@\n",
                      t,
                      IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage),
                      IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsage),
                      IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardDown),
                      IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldMouseButtonMask),
                      IOHIDEventGetFloatValue(ev, kIOHIDEventFieldMouseX),
                      IOHIDEventGetFloatValue(ev, kIOHIDEventFieldMouseY),
                      (t == 1 || t == 15 || t == 17) ? BKProbe(ev, t) : @""];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([[fm attributesOfItemAtPath:@"/var/mobile/bk_events.log" error:nil][NSFileSize] longValue] > 300000) {
        [fm removeItemAtPath:@"/var/mobile/bk_events.log" error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/bk_events.log"];
    if (!fh) {
        [line writeToFile:@"/var/mobile/bk_events.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static void BKSend(int finger, CGPoint p, BOOL down)
{
    if (!gClient) return;
    p.x = MAX(0, MIN(1, p.x));
    p.y = MAX(0, MIN(1, p.y));
    uint32_t mask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventPosition;
    if (down) mask |= kIOHIDDigitizerEventTouch;
    BKIOHIDEventRef ev = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                        kIOHIDDigitizerTransducerTypeFinger,
                                                        (uint32_t)finger, (uint32_t)finger, mask, 0,
                                                        p.x, p.y, 0, 0, 0, TRUE, down, 0);
    if (!ev) return;
    IOHIDEventSetIntegerValue(ev, kBKFieldIsDisplayIntegrated, 1);
    IOHIDEventSystemClientDispatchEvent(gClient, ev);
    CFRelease(ev);
}

static BKAct *BKFind(NSString *enc)
{
    for (int i = 0; i < kBKMaxAct; i++) {
        if (gActs[i].active && [gActs[i].enc isEqualToString:enc]) return &gActs[i];
    }
    return NULL;
}

static void BKUpFor(NSString *enc)
{
    BKAct *a = BKFind(enc);
    if (!a) return;
    BKSend(a->finger, a->cur, NO);
    a->active = NO;
    a->enc = nil;
    a->type = nil;
}

static void BKDown(NSString *enc, NSDictionary *pt)
{
    if (BKFind(enc)) return;
    int slot = -1;
    for (int i = 0; i < kBKMaxAct; i++) {
        if (!gActs[i].active) { slot = i; break; }
    }
    if (slot < 0) return;

    BKAct *a = &gActs[slot];
    a->active = YES;
    a->enc = enc;
    a->type = pt[@"Type"] ?: @"Tap";
    a->base = CGPointMake([pt[@"X"] doubleValue], [pt[@"Y"] doubleValue]);
    a->cur = a->base;
    a->radius = pt[@"Radius"] ? [pt[@"Radius"] doubleValue] : 0.12;
    a->sens = pt[@"Sens"] ? [pt[@"Sens"] doubleValue] : 1.0;
    gFinger = (gFinger >= 6) ? 2 : gFinger + 1;
    a->finger = gFinger;

    BKSend(a->finger, a->cur, YES);

    if ([a->type isEqualToString:@"Tap"]) {
        int finger = a->finger;
        CGPoint p = a->cur;
        NSString *e = enc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            BKAct *x = BKFind(e);
            if (x) {
                BKSend(finger, p, NO);
                x->active = NO;
                x->enc = nil;
                x->type = nil;
            }
        });
    } else if ([a->type isEqualToString:@"Hold"]) {
        int ms = pt[@"HoldMs"] ? [pt[@"HoldMs"] intValue] : 400;
        NSString *e = enc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            BKUpFor(e);
        });
    }
}

static void BKMoveDirs(double dx, double dy)
{
    for (int i = 0; i < kBKMaxAct; i++) {
        BKAct *a = &gActs[i];
        if (!a->active || ![a->type isEqualToString:@"Dir"]) continue;
        CGPoint p = a->cur;
        p.x = MAX(a->base.x - a->radius, MIN(a->base.x + a->radius, p.x + dx * a->sens));
        p.y = MAX(a->base.y - a->radius, MIN(a->base.y + a->radius, p.y + dy * a->sens));
        if (CGPointEqualToPoint(p, a->cur)) continue;
        a->cur = p;
        BKSend(a->finger, p, YES);
    }
}

static void BKBind(NSString *enc, BOOL down)
{
    if (!gEnabled) return;
    if (!down) { BKUpFor(enc); return; }
    NSArray *profile = BKProfile();
    if (!profile) return;
    for (NSDictionary *pt in profile) {
        NSString *key = pt[@"Key"] ?: pt[@"Button"];
        if (key && [key isEqualToString:enc]) { BKDown(enc, pt); return; }
    }
}

static void BKEvaluate(BKIOHIDEventRef ev)
{
    if (!ev) return;
    int type = IOHIDEventGetType(ev);
    if (type == kIOHIDEventTypeDigitizer) return;

    if (type == kIOHIDEventTypeKeyboard) {
        int page = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsage);
        int down = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardDown);
        if (page != 0 && page != 7) return;
        BKBind([NSString stringWithFormat:@"k:%d", usage], down != 0);
        return;
    }

    if (type == kIOHIDEventTypeButton) {
        int num = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonNumber);
        int clicks = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonClickCount);
        int idx = (num >= 1) ? num - 1 : num;
        if (idx >= 0 && idx <= 2) BKBind([NSString stringWithFormat:@"m:%d", idx], clicks > 0);
        return;
    }

    if (type == kIOHIDEventTypeMouse) {
        uint32_t mask = (uint32_t)IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldMouseButtonMask);
        for (int i = 0; i < 3; i++) {
            uint32_t bit = 1u << i;
            if ((mask & bit) != (gLastMask & bit)) BKBind([NSString stringWithFormat:@"m:%d", i], (mask & bit) != 0);
        }
        gLastMask = mask;

        static double lx = 0, ly = 0;
        double x = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldMouseX);
        double y = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldMouseY);
        if (lx != 0 || ly != 0) BKMoveDirs((x - lx) / 4.0, (y - ly) / 4.0);
        lx = x;
        ly = y;
    }
}

static void BKCallback(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    @autoreleasepool {
        BKLogRaw(ev);
        BKEvaluate(ev);
    }
}

static void BKStart(void)
{
    gIOQ = dispatch_queue_create("com.wjf.ballkey.engine", DISPATCH_QUEUE_SERIAL);
    memset(gActs, 0, sizeof(gActs));
    BKLoadCfg();
    notify_register_dispatch(kBKNotifyReload, &gNotifyToken, dispatch_get_main_queue(), ^(int token) {
        BKLoadCfg();
    });
    gClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 1, NULL);
    if (!gClient) gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gClient) return;
    IOHIDEventSystemClientRegisterEventCallback(gClient, BKCallback, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(gClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    [@"engine" writeToFile:@"/var/mobile/bk_engine_loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BKStart();
        });
    }
}

%dtor {
    @autoreleasepool {
        if (gClient) {
            IOHIDEventSystemClientUnscheduleWithRunLoop(gClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
            CFRelease(gClient);
            gClient = NULL;
        }
    }
}
