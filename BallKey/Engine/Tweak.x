#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <os/lock.h>
#import <unistd.h>
#import <stdarg.h>

typedef struct __IOHIDEvent *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;

const char BKEngineTag[] = "b38";

#define kBKSenderID 0x8000000817319372ULL
static const int kBKTypeKeyExtra = 1;
static const int kBKTypeButton = 2;
static const int kBKTypeKeyboard = 3;
static const int kBKTypeDigitizer = 11;
static const int kBKTypePointer = 17;
#define kBKFieldPtrX    0x0130
#define kBKFieldPtrY    0x0131
#define kBKFieldSpanX   0x0137
#define kBKFieldSpanY   0x0138
#define kBKFieldBtnMask 0x0203
#define kBKFieldKeyDown 0x0301
#define kBKFieldDispInt 0x0B46
#define kBKHandType 3
#define kBKMaxFinger 9
#define kBKSlotAim 10
#define kBKPressNs 60ull
#define kBKSeenMax 24
#define kBKNotifyLoad "com.wjf.ballkey.reload"
#define kBKNotifyTest "com.wjf.ballkey.test"
#define kBKNotifyCap  "com.wjf.ballkey.capture"
#define kBKOffFile   @"/var/mobile/bk_off.txt"
#define kBKSafeFile  @"/var/mobile/bk_safe.txt"
#define kBKTryFile   @"/var/mobile/bk_try.txt"
#define kBKLibDir1   @"/var/jb/usr/lib/TweakInject"
#define kBKLibDir2   @"/var/jb/Library/MobileSubstrate/DynamicLibraries"

static NSString *gBaseDir = nil;
static NSString *gLogBuf = nil;
static uint64_t gLogLast = 0;
static int gEvSeen = 0, gKeySeen = 0, gPtrSeen = 0, gLstSeen = 0;
static BOOL gReady = NO;
static BOOL gOff = NO, gSafe = NO;
static int gCapType = 0, gSendType = 0;
static void *gSeen[kBKSeenMax];
static uint64_t gSeenMs[kBKSeenMax];
static int gSeenIdx = 0;
static os_unfair_lock gSeenLock = OS_UNFAIR_LOCK_INIT;

typedef struct {
    BKIOHIDEventSystemClientRef (*ClientCreate)(CFAllocatorRef);
    BKIOHIDEventSystemClientRef (*ClientCreateType)(CFAllocatorRef, int, void *);
    void (*SetMatching)(BKIOHIDEventSystemClientRef, CFDictionaryRef);
    void (*SetQueue)(BKIOHIDEventSystemClientRef, dispatch_queue_t);
    void (*RegisterCB)(BKIOHIDEventSystemClientRef, void *, void *, void *);
    void (*Activate)(BKIOHIDEventSystemClientRef);
    void (*Dispatch)(BKIOHIDEventSystemClientRef, BKIOHIDEventRef);
    int (*GetType)(BKIOHIDEventRef);
    double (*GetFloat)(BKIOHIDEventRef, int);
    int (*GetInt)(BKIOHIDEventRef, int);
    uint64_t (*GetSender)(BKIOHIDEventRef);
    void (*SetInt)(BKIOHIDEventRef, int, int64_t);
    void (*Append)(BKIOHIDEventRef, BKIOHIDEventRef, uint32_t);
} BKIO;
static BKIO gIO;

typedef BKIOHIDEventRef (*BKFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, double, double, double, double, double, double, BOOL, uint32_t);
typedef BKIOHIDEventRef (*BKHandFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, double, double, double, double, double, double, BOOL, uint32_t);
typedef void (*BKSetInfoFn)(BKIOHIDEventRef, BKIOHIDEventSystemClientRef, BOOL,
    uint32_t, uint32_t, uint32_t, uint32_t, double, double);

static BKFingerFn fFingerEvent = NULL;
static BKHandFn fHandEvent = NULL;
static BKSetInfoFn fSetInfo = NULL;

static BKIOHIDEventSystemClientRef gSendClient = NULL;
static BKIOHIDEventSystemClientRef gPtrClient = NULL;
static BKIOHIDEventSystemClientRef gKeyClient = NULL;
static id gPtrBlock = nil, gKeyBlock = nil;
static dispatch_queue_t gSendQ = NULL;

static BOOL gEnabled = YES, gFps = NO, gCursorOn = NO;
static double gSpeed = 1.6;
static NSString *gActiveBundle = nil;
static NSDictionary *gPoints = nil;
static NSMutableDictionary *gKeyMap = nil, *gBtnMap = nil;
static double gLastPtrX = 0.0, gLastPtrY = 0.0;
static BOOL gLastPtrValid = NO;
static int gPtrMask = 0;
static uint64_t gLastKeyNs = 0, gLastBtnNs = 0;
static BOOL gCapArm = NO;
static uint64_t gCapArmNs = 0;
static NSString *gCapNonce = nil;

typedef struct { int on; double x, y; } BKAct;
static BKAct gAct[kBKSlotAim + 1];
static NSMutableDictionary *gGen = nil, *gKeyDown = nil;

static NSString *BKBase(void);
static NSString *BKPath(NSString *name);
static void BKMark(NSString *name);
static void BKAppend(NSString *fmt, ...);
static uint64_t BKNow(void);
static BOOL BKExists(NSString *p);
static int BKReadInt(NSString *p);
static void BKWriteInt(NSString *p, int n);
static void BKPtrSpan(double *w, double *h);
static void BKPtrWriteTag(char tag, double a, double b, double c, double d);
static void BKCursorAbs(double x, double y);
static void BKCursorMove(double dx, double dy);
static void BKFpsMove(double dx, double dy);
static void BKPtrButtons(int mask);
static void BKHandleKey(int usage, BOOL down);
static void BKHandleButton(int index, BOOL down);
static void BKStatus(void);
static void BKLoadConfig(void);
static void BKFrontTick(void);
static void BKCaptureWatch(void);
static void BKArmCapture(void);
static void BKOnEvent(BKIOHIDEventRef event, int type, int src);
static void BKListenCB(void *t, void *r, void *s, BKIOHIDEventRef e);
static void BKInit(void);

static uint64_t BKNow(void) { return mach_absolute_time() / 1000000ull; }

static BOOL BKExists(NSString *p)
{
    @try { return [[NSFileManager defaultManager] fileExistsAtPath:p]; }
    @catch (NSException *e) { return NO; }
}

static int BKReadInt(NSString *p)
{
    @try {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        return s ? [s intValue] : 0;
    } @catch (NSException *e) { return 0; }
}

static void BKWriteInt(NSString *p, int n)
{
    @try {
        [[NSString stringWithFormat:@"%d", n] writeToFile:p atomically:NO
                    encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static NSString *BKBase(void)
{
    if (gBaseDir) return gBaseDir;
    @try {
        NSString *probe = @"/var/mobile/.bk_w";
        if ([@"x" writeToFile:probe atomically:NO encoding:NSUTF8StringEncoding error:nil]) {
            [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
            gBaseDir = @"/var/mobile";
        } else {
            gBaseDir = @"/tmp";
        }
    } @catch (NSException *e) { gBaseDir = @"/tmp"; }
    return gBaseDir;
}

static NSString *BKPath(NSString *name) { return [BKBase() stringByAppendingPathComponent:name]; }

static void BKMark(NSString *name)
{
    @try {
        [@"" writeToFile:BKPath([@"bk_" stringByAppendingString:name])
              atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void BKAppend(NSString *fmt, ...)
{
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        @try {
            uint64_t now = BKNow();
            if (!gLogBuf || now - gLogLast > 4000) {
                gLogBuf = [NSString stringWithContentsOfFile:BKPath(@"bk_debug.log")
                                                    encoding:NSUTF8StringEncoding error:nil];
                if (!gLogBuf) gLogBuf = @"";
                if (gLogBuf.length > 60000) gLogBuf = [gLogBuf substringFromIndex:gLogBuf.length - 40000];
                gLogLast = now;
            }
            gLogBuf = [gLogBuf stringByAppendingFormat:@"[%llu] %@\n", now, msg];
            [gLogBuf writeToFile:BKPath(@"bk_debug.log") atomically:NO
                        encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) { }
    }
}

static BOOL BKInitIO(void)
{
    @try {
        void *k = RTLD_DEFAULT;
        if (!dlsym(k, "IOHIDEventSystemClientCreate")) {
            k = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        }
        if (!k) k = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
        if (!k) return NO;
        gIO.ClientCreate = (void *)dlsym(k, "IOHIDEventSystemClientCreate");
        gIO.ClientCreateType = (void *)dlsym(k, "IOHIDEventSystemClientCreateWithType");
        gIO.SetMatching = (void *)dlsym(k, "IOHIDEventSystemClientSetMatching");
        gIO.SetQueue = (void *)dlsym(k, "IOHIDEventSystemClientSetQueue");
        gIO.RegisterCB = (void *)dlsym(k, "IOHIDEventSystemClientRegisterEventCallback");
        gIO.Activate = (void *)dlsym(k, "IOHIDEventSystemClientActivate");
        gIO.Dispatch = (void *)dlsym(k, "IOHIDEventSystemClientDispatchEvent");
        gIO.GetType = (void *)dlsym(k, "IOHIDEventGetType");
        gIO.GetFloat = (void *)dlsym(k, "IOHIDEventGetFloatValue");
        gIO.GetInt = (void *)dlsym(k, "IOHIDEventGetIntegerValue");
        gIO.GetSender = (void *)dlsym(k, "IOHIDEventGetSenderID");
        gIO.SetInt = (void *)dlsym(k, "IOHIDEventSetIntegerValue");
        gIO.Append = (void *)dlsym(k, "IOHIDEventAppendEvent");
        fFingerEvent = (BKFingerFn)dlsym(k, "IOHIDEventCreateDigitizerFingerEvent");
        if (!fFingerEvent) fFingerEvent = (BKFingerFn)dlsym(k, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        fHandEvent = (BKHandFn)dlsym(k, "IOHIDEventCreateDigitizerEvent");
        fSetInfo = (BKSetInfoFn)dlsym(RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
        if (!fSetInfo) {
            void *b = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
            if (b) fSetInfo = (BKSetInfoFn)dlsym(b, "BKSHIDEventSetDigitizerInfo");
        }
    } @catch (NSException *e) { return NO; }
    return (gIO.ClientCreate != NULL && gIO.GetType != NULL && gIO.Dispatch != NULL);
}

static BKIOHIDEventSystemClientRef BKNewClient(int want, NSDictionary *match, int *got)
{
    BKIOHIDEventSystemClientRef c = NULL;
    @try {
        if (gIO.ClientCreateType && want > 0) c = gIO.ClientCreateType(kCFAllocatorDefault, want, NULL);
        if (!c && gIO.ClientCreate) c = gIO.ClientCreate(kCFAllocatorDefault);
    } @catch (NSException *e) { }
    if (!c) return NULL;
    if (got) *got = want;
    @try {
        if (match && gIO.SetMatching) gIO.SetMatching(c, (__bridge CFDictionaryRef)match);
        if (gIO.SetQueue) gIO.SetQueue(c, dispatch_get_main_queue());
        if (gIO.Activate) gIO.Activate(c);
    } @catch (NSException *e) { }
    return c;
}

static void BKSend(BKIOHIDEventRef ev)
{
    if (!ev || !gSendClient || !gIO.Dispatch || !gSendQ) return;
    dispatch_async(gSendQ, ^{
        @try { gIO.Dispatch(gSendClient, ev); } @catch (NSException *e) { }
        CFRelease(ev);
    });
}

static void BKFinger(int slot, int phase, double x, double y)
{
    if (!fFingerEvent || !gSendClient) return;
    if (slot < 0 || slot > kBKSlotAim) return;
    @try {
        uint32_t mask = 0;
        BOOL touch = YES;
        if (phase == 0) mask = 0x01;
        else if (phase == 1) mask = 0x02;
        else if (phase == 2) mask = 0x04;
        else { mask = 0x08 | 0x10; touch = NO; }

        uint64_t ts = mach_absolute_time();
        BKIOHIDEventRef finger = fFingerEvent(kCFAllocatorDefault, ts,
            (uint32_t)slot, (uint32_t)slot, mask, 0, x, y, 0.0, 1.0, 0.0, 0.0, touch, 0);
        if (!finger) return;

        if (gIO.SetInt) {
            gIO.SetInt(finger, kBKFieldDispInt, 1);
            if (fSetInfo) fSetInfo(finger, gSendClient, YES, 0, 0, 0, 0, x, y);
        }

        if (fHandEvent && gIO.Append) {
            BKIOHIDEventRef hand = fHandEvent(kCFAllocatorDefault, ts, kBKHandType,
                0, 0, mask, 0, x, y, 0.0, 1.0, 0.0, 0.0, touch, 0);
            if (hand) {
                if (gIO.SetInt) gIO.SetInt(hand, kBKFieldDispInt, 1);
                if (fSetInfo) fSetInfo(hand, gSendClient, YES, 0, 0, 0, 0, x, y);
                gIO.Append(hand, finger, 0);
                CFRelease(finger);
                BKSend(hand);
                return;
            }
        }
        BKSend(finger);
    } @catch (NSException *e) { }
}

static int BKSlotAcquire(void)
{
    for (int i = 0; i < kBKMaxFinger; i++) {
        if (!gAct[i].on) { gAct[i].on = 1; return i; }
    }
    return -1;
}

static void BKSlotPress(int slot, double x, double y)
{
    if (slot < 0) return;
    gAct[slot].x = x; gAct[slot].y = y;
    BKFinger(slot, 0, x, y);
    BKFinger(slot, 1, x, y);
}

static void BKSlotRelease(int slot)
{
    if (slot < 0 || slot > kBKSlotAim) return;
    if (!gAct[slot].on) return;
    BKFinger(slot, 3, gAct[slot].x, gAct[slot].y);
    gAct[slot].on = 0;
}

static void BKSlotMove(int slot, double x, double y)
{
    if (slot < 0 || slot > kBKSlotAim) return;
    if (!gAct[slot].on) return;
    gAct[slot].x = x; gAct[slot].y = y;
    BKFinger(slot, 2, x, y);
}

static BOOL BKSeenRecently(void *ev)
{
    uint64_t now = BKNow();
    BOOL found = NO;
    os_unfair_lock_lock(&gSeenLock);
    for (int i = 0; i < kBKSeenMax; i++) {
        if (gSeen[i] == ev && now - gSeenMs[i] < 40ull) { found = YES; break; }
    }
    if (!found) {
        gSeen[gSeenIdx] = ev; gSeenMs[gSeenIdx] = now;
        gSeenIdx = (gSeenIdx + 1) % kBKSeenMax;
    }
    os_unfair_lock_unlock(&gSeenLock);
    return found;
}

static NSDictionary *BKResolvePoints(NSDictionary *cfg, NSString *bundle)
{
    NSDictionary *profiles = [cfg objectForKey:@"Profiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) return nil;
    id arr = nil;
    if (bundle) arr = [profiles objectForKey:bundle];
    if (![arr isKindOfClass:[NSArray class]]) arr = [profiles objectForKey:@"*"];
    if (![arr isKindOfClass:[NSArray class]]) return nil;
    return [NSDictionary dictionaryWithObject:arr forKey:@"P"];
}

static void BKLoadConfig(void)
{
    @try {
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"];
        if (!cfg) return;
        gEnabled = [cfg objectForKey:@"Enabled"] ? [[cfg objectForKey:@"Enabled"] boolValue] : YES;
        gFps = [[cfg objectForKey:@"FpsMode"] boolValue];
        gCursorOn = [[cfg objectForKey:@"CursorOn"] boolValue];
        double s = [[cfg objectForKey:@"CursorSpeed"] doubleValue];
        gSpeed = (s > 0.2 && s < 8.0) ? s : 1.6;
        NSString *ab = [cfg objectForKey:@"ActiveBundle"];
        if ([ab isKindOfClass:[NSString class]]) gActiveBundle = ab;
        NSDictionary *res = BKResolvePoints(cfg, gActiveBundle);
        NSArray *arr = res ? [res objectForKey:@"P"] : nil;
        NSMutableDictionary *keys = [NSMutableDictionary dictionary];
        NSMutableDictionary *btns = [NSMutableDictionary dictionary];
        for (NSDictionary *p in arr) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            int kind = [[p objectForKey:@"Kind"] intValue];
            int code = [[p objectForKey:@"Code"] intValue];
            NSNumber *k = [NSNumber numberWithInt:code];
            if (kind == 0) [keys setObject:p forKey:k];
            else [btns setObject:p forKey:k];
        }
        gKeyMap = keys; gBtnMap = btns; gPoints = res;
    } @catch (NSException *e) { }
}

static void BKPtrSpan(double *w, double *h)
{
    double ww = 0.0, hh = 0.0;
    @try {
        UIScreen *s = [UIScreen mainScreen];
        if (s) {
            CGFloat sc = s.nativeScale > 0 ? s.nativeScale : s.scale;
            CGRect nb = s.nativeBounds;
            if (sc > 0.0 && nb.size.width > 1.0 && nb.size.height > 1.0) {
                ww = nb.size.width / sc; hh = nb.size.height / sc;
            }
        }
    } @catch (NSException *e) { }
    if (ww < 100.0 || hh < 100.0) { ww = 414.0; hh = 736.0; }
    *w = ww; *h = hh;
}

static void BKPtrWriteTag(char tag, double a, double b, double c, double d)
{
    @try {
        NSString *s = (tag == 'A')
            ? [NSString stringWithFormat:@"A %.2f %.2f %.2f %.2f", a, b, c, d]
            : [NSString stringWithFormat:@"R %.4f %.4f", a, b];
        [s writeToFile:BKPath(@"bk_ptr.txt") atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void BKCursorAbs(double x, double y)
{
    double w, h; BKPtrSpan(&w, &h);
    BKPtrWriteTag('A', x, y, w, h);
}

static void BKCursorMove(double dx, double dy) { BKPtrWriteTag('R', dx, dy, 0.0, 0.0); }

static double BKPointX(NSDictionary *p, double span) { return [[p objectForKey:@"X"] doubleValue] * span; }
static double BKPointY(NSDictionary *p, double span) { return [[p objectForKey:@"Y"] doubleValue] * span; }

static void BKFpsMove(double dx, double dy)
{
    if (!gEnabled || !gFps) return;
    @try {
        double w, h; BKPtrSpan(&w, &h);
        if (!gAct[kBKSlotAim].on) {
            gAct[kBKSlotAim].on = 1;
            gAct[kBKSlotAim].x = w * 0.5; gAct[kBKSlotAim].y = h * 0.5;
            BKFinger(kBKSlotAim, 0, gAct[kBKSlotAim].x, gAct[kBKSlotAim].y);
            BKFinger(kBKSlotAim, 1, gAct[kBKSlotAim].x, gAct[kBKSlotAim].y);
        }
        double nx = gAct[kBKSlotAim].x + dx * gSpeed;
        double ny = gAct[kBKSlotAim].y + dy * gSpeed;
        if (nx < 4.0) nx = 4.0;
        if (ny < 4.0) ny = 4.0;
        if (nx > w - 4.0) nx = w - 4.0;
        if (ny > h - 4.0) ny = h - 4.0;
        gAct[kBKSlotAim].x = nx; gAct[kBKSlotAim].y = ny;
        BKFinger(kBKSlotAim, 2, nx, ny);
    } @catch (NSException *e) { }
}

static void BKAimRecenter(void)
{
    if (!gAct[kBKSlotAim].on) return;
    double w, h; BKPtrSpan(&w, &h);
    BKSlotMove(kBKSlotAim, w * 0.5, h * 0.5);
}

static void BKPtrButtons(int mask)
{
    int diff = mask ^ gPtrMask;
    gPtrMask = mask;
    if (diff & 1) BKHandleButton(0, (mask & 1) != 0);
    if (diff & 2) BKHandleButton(1, (mask & 2) != 0);
}

static void BKPressPoint(NSDictionary *p, BOOL down, NSMutableDictionary *store, int code)
{
    NSNumber *k = [NSNumber numberWithInt:code];
    if (!down) {
        NSNumber *slotN = [store objectForKey:k];
        if (slotN) { BKSlotRelease([slotN intValue]); [store removeObjectForKey:k]; }
        return;
    }
    if ([store objectForKey:k]) return;
    double w, h; BKPtrSpan(&w, &h);
    int slot = BKSlotAcquire();
    if (slot < 0) return;
    BKSlotPress(slot, BKPointX(p, w), BKPointY(p, h));
    [store setObject:[NSNumber numberWithInt:slot] forKey:k];
}

static void BKHandleKey(int usage, BOOL down)
{
    if (!gEnabled || !gKeyMap) return;
    uint64_t now = BKNow();
    if (down && now - gLastKeyNs < 20ull) return;
    gLastKeyNs = now;
    NSDictionary *p = [gKeyMap objectForKey:[NSNumber numberWithInt:usage]];
    if (!p) return;
    BKPressPoint(p, down, gKeyDown, usage);
}

static void BKHandleButton(int index, BOOL down)
{
    if (!gEnabled) return;
    uint64_t now = BKNow();
    if (down && now - gLastBtnNs < 20ull) return;
    gLastBtnNs = now;
    if (index == 0 && gFps) {
        if (!down) return;
        NSDictionary *p = [gBtnMap objectForKey:[NSNumber numberWithInt:0]];
        if (!p) return;
        double w, h; BKPtrSpan(&w, &h);
        int slot = BKSlotAcquire();
        if (slot < 0) return;
        BKSlotPress(slot, BKPointX(p, w), BKPointY(p, h));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBKPressNs * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{ BKSlotRelease(slot); });
        return;
    }
    NSDictionary *p = [gBtnMap objectForKey:[NSNumber numberWithInt:index]];
    if (!p) return;
    if (index == 1 && down && gFps) BKAimRecenter();
    BKPressPoint(p, down, gGen, index + 100);
}

static void BKArmCapture(void)
{
    gCapNonce = [NSString stringWithFormat:@"%llu", BKNow()];
    gCapArm = YES; gCapArmNs = BKNow();
    @try {
        [gCapNonce writeToFile:BKPath(@"bk_capture_nonce.txt") atomically:NO
                      encoding:NSUTF8StringEncoding error:nil];
        [@"" writeToFile:BKPath(@"bk_capture_result.txt") atomically:NO
                encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void BKCaptureWatch(void)
{
    if (!gCapArm) return;
    if (BKNow() - gCapArmNs > 12000ull) gCapArm = NO;
}

static void BKCaptureHit(int kind, int code)
{
    if (!gCapArm) return;
    gCapArm = NO;
    @try {
        NSString *s = [NSString stringWithFormat:@"%d|%d|-|%@", kind, code,
                       gCapNonce ? gCapNonce : @"-"];
        [s writeToFile:BKPath(@"bk_capture_result.txt") atomically:NO
              encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static NSString *BKAppAt(void)
{
    @try {
        Class sbCls = objc_getClass("SpringBoard");
        if (sbCls) {
            id sb = ((id (*)(id, SEL))objc_msgSend)((id)sbCls, @selector(sharedApplication));
            if (sb) {
                SEL s = NSSelectorFromString(@"_accessibilityFrontMostApplication");
                if ([sb respondsToSelector:s]) {
                    id app = ((id (*)(id, SEL))objc_msgSend)(sb, s);
                    if (app) {
                        NSString *bid = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
                        if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
                    }
                }
            }
        }
    } @catch (NSException *e) { }
    return @"-";
}

static void BKFrontTick(void)
{
    @try {
        NSString *b = BKAppAt();
        if ([b isEqualToString:@"-"]) return;
        if (gActiveBundle && [gActiveBundle isEqualToString:b]) return;
        gActiveBundle = b;
        [[NSUserDefaults standardUserDefaults] setObject:b forKey:@"ActiveBundle"];
        BKLoadConfig();
    } @catch (NSException *e) { }
}

static NSString *BKFilterOK(void)
{
    @try {
        NSString *p = [kBKLibDir1 stringByAppendingPathComponent:@"BallKeyEngine.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d) {
            p = [kBKLibDir2 stringByAppendingPathComponent:@"BallKeyEngine.plist"];
            d = [NSDictionary dictionaryWithContentsOfFile:p];
        }
        if (!d) return @"N";
        NSDictionary *f = [d objectForKey:@"Filter"];
        NSArray *e = [f objectForKey:@"Executables"];
        if (![e isKindOfClass:[NSArray class]]) return @"N";
        BOOL sb = NO, bb = NO;
        for (NSString *s in e) {
            if ([s isEqualToString:@"SpringBoard"]) sb = YES;
            if ([s isEqualToString:@"backboardd"]) bb = YES;
        }
        if (sb && bb) return @"SB+BB";
        if (sb) return @"SB";
        if (bb) return @"BB";
    } @catch (NSException *e) { }
    return @"N";
}

static void BKStatus(void)
{
    @try {
        NSString *s = [NSString stringWithFormat:
            @"e%d k%d p%d m%d a=%@ o%d ct=%d/%d plf=%@ sf=%d",
            gEvSeen, gKeySeen, gPtrSeen, gPtrMask, BKAppAt(),
            gAct[kBKSlotAim].on, gCapType, gSendType, BKFilterOK(), gSafe ? 1 : 0];
        [s writeToFile:BKPath(@"bk_engine_status.txt") atomically:NO
              encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void BKOnEvent(BKIOHIDEventRef event, int type, int src)
{
    (void)src;
    @try {
        if (type == kBKTypePointer) {
            gPtrSeen++;
            double x = gIO.GetFloat(event, kBKFieldPtrX);
            double y = gIO.GetFloat(event, kBKFieldPtrY);
            double sx = gIO.GetFloat(event, kBKFieldSpanX);
            double sy = gIO.GetFloat(event, kBKFieldSpanY);
            if (sx > 1.0 && sy > 1.0) {
                if (gCursorOn) BKCursorAbs(x, y);
                if (gFps && gLastPtrValid) {
                    double w, h; BKPtrSpan(&w, &h);
                    BKFpsMove((x - gLastPtrX) * w / sx, (y - gLastPtrY) * h / sy);
                }
                gLastPtrX = x; gLastPtrY = y; gLastPtrValid = YES;
            } else if (gLastPtrValid) {
                double dx = x - gLastPtrX;
                double dy = y - gLastPtrY;
                gLastPtrX = x; gLastPtrY = y;
                if (dx != 0.0 || dy != 0.0) {
                    if (gCursorOn) BKCursorMove(dx, dy);
                    if (gFps) BKFpsMove(dx, dy);
                }
            } else {
                gLastPtrX = x; gLastPtrY = y; gLastPtrValid = YES;
            }
            int mask = gIO.GetInt(event, kBKFieldBtnMask);
            if (mask != gPtrMask) BKPtrButtons(mask);
            return;
        }
        if (type == kBKTypeButton) {
            int idx = gIO.GetInt(event, (kBKTypeButton << 16) | 3u);
            BKHandleButton(0, idx != 0);
            BKCaptureHit(1, idx != 0 ? 1 : 0);
            return;
        }
        if (type == kBKTypeKeyboard || type == kBKTypeKeyExtra) {
            int usage = gIO.GetInt(event, 0x0700);
            if (usage <= 0) return;
            BOOL down = gIO.GetInt(event, kBKFieldKeyDown) != 0;
            gKeySeen++;
            BKHandleKey(usage, down);
            if (down) BKCaptureHit(0, usage);
            return;
        }
    } @catch (NSException *e) { }
}

static void BKListenCB(void *t, void *r, void *s, BKIOHIDEventRef e)
{
    (void)t; (void)r; (void)s;
    @try {
        if (!gIO.GetType || !e || !gReady) return;
        int type = gIO.GetType(e);
        if (type == kBKTypeDigitizer) return;
        if (gIO.GetSender && gIO.GetSender(e) == kBKSenderID) return;
        if (BKSeenRecently(e)) return;
        gLstSeen++; gEvSeen++;
        if (!pthread_main_np()) {
            CFRetain(e);
            dispatch_async(dispatch_get_main_queue(), ^{
                @try { BKOnEvent(e, type, 0); } @catch (NSException *x) { }
                CFRelease(e);
            });
            return;
        }
        BKOnEvent(e, type, 0);
    } @catch (NSException *e2) { }
}

static BKIOHIDEventSystemClientRef BKNewListen(NSDictionary *match, id __strong *keep, int *got)
{
    BKIOHIDEventSystemClientRef c = BKNewClient(1, match, got);
    if (!c) return NULL;
    @try {
        if (gIO.RegisterCB) {
            void (^cb)(void *, void *, void *, BKIOHIDEventRef) =
                ^(void *t, void *r, void *s, BKIOHIDEventRef e) { BKListenCB(t, r, s, e); };
            *keep = [cb copy];
            gIO.RegisterCB(c, (__bridge void *)*keep, NULL, NULL);
        }
    } @catch (NSException *e) { }
    return c;
}

static void BKInit(void)
{
    @try {
        gGen = [NSMutableDictionary dictionary];
        gKeyDown = [NSMutableDictionary dictionary];
        gSendQ = dispatch_queue_create("com.wjf.ballkey.send", DISPATCH_QUEUE_SERIAL);

        if (!BKInitIO()) { BKAppend(@"! io"); BKStatus(); return; }
        BKMark(@"engine_io.txt");

        gSendClient = BKNewClient(2, nil, &gSendType);
        if (!gSendClient) gSendClient = BKNewClient(0, nil, &gSendType);
        BKAppend(@"I send=%d", gSendType);

        static int nt1 = 0, nt2 = 0, nt3 = 0;
        notify_register_dispatch(kBKNotifyLoad, &nt1, dispatch_get_main_queue(),
            ^(int t) { (void)t; BKLoadConfig(); });
        notify_register_dispatch(kBKNotifyTest, &nt2, dispatch_get_main_queue(),
            ^(int t) { (void)t; BKStatus(); });
        notify_register_dispatch(kBKNotifyCap, &nt3, dispatch_get_main_queue(),
            ^(int t) { (void)t; BKArmCapture(); });

        BKLoadConfig();

        if (gSafe) {
            BKAppend(@"I safe sem captura");
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    gPtrClient = BKNewListen(@{ @"PrimaryUsagePage": @1 }, &gPtrBlock, &gCapType);
                    gKeyClient = BKNewListen(@{ @"PrimaryUsagePage": @7 }, &gKeyBlock, &gCapType);
                    BKAppend(@"I cap=%d p=%d k=%d", gCapType,
                              gPtrClient ? 1 : 0, gKeyClient ? 1 : 0);
                    if (gPtrClient || gKeyClient) BKMark(@"engine_listen.txt");
                    gReady = YES;
                } @catch (NSException *e) { }
            });
        }

        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                       dispatch_get_main_queue());
        if (src) {
            dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 250ull * NSEC_PER_MSEC),
                                      250ull * NSEC_PER_MSEC, 50ull * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(src, ^{
                @try {
                    static int tick = 0;
                    tick++;
                    BKCaptureWatch();
                    if (tick == 80) {
                        BKWriteInt(kBKTryFile, 0);
                        if (gSafe) {
                            [[NSFileManager defaultManager] removeItemAtPath:kBKSafeFile error:nil];
                            gSafe = NO;
                        }
                        BKMark(@"engine_ok.txt");
                    }
                    if (tick % 4 == 0) BKStatus();
                    if (tick % 30 == 0) BKLoadConfig();
                    if (tick % 5 == 0) BKFrontTick();
                } @catch (NSException *e) { }
            });
            dispatch_resume(src);
        }

        BKAppend(@"I ready");
        BKMark(@"engine_ready.txt");
        BKStatus();
    } @catch (NSException *e) {
        BKAppend(@"! init %@", e.reason);
    }
}

__attribute__((constructor)) static void BKInitC(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try {
                BKMark(@"engine_ctor.txt");
                int n = BKReadInt(kBKTryFile) + 1;
                BKWriteInt(kBKTryFile, n);
                gOff = BKExists(kBKOffFile);
                if (n > 3) {
                    [@"" writeToFile:kBKSafeFile atomically:NO encoding:NSUTF8StringEncoding error:nil];
                }
                gSafe = BKExists(kBKSafeFile);
                BKAppend(@"I boot n=%d off=%d safe=%d", n, gOff, gSafe);

                if (gOff) { BKMark(@"engine_off.txt"); BKStatus(); return; }

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)((gSafe ? 2000 : 900) * NSEC_PER_MSEC)),
                    dispatch_get_main_queue(), ^{
                        @try { BKInit(); } @catch (NSException *e) { }
                    });
            } @catch (NSException *e) {
                BKAppend(@"! ctor %@", e.reason);
            }
        }
    });
}
