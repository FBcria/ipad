#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <os/lock.h>
#import <math.h>

typedef void *BKIOHIDEventSystemClientRef;
typedef void *BKIOHIDEventRef;

typedef struct {
    BKIOHIDEventSystemClientRef (*ClientCreate)(CFAllocatorRef);
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

#define kBKBuildTag             @"b30"
#define kBKPrefDomain           CFSTR("com.wjf.ballkey")
#define kBKConfigFile           "/var/mobile/Library/Preferences/com.wjf.ballkey.plist"
#define kBKNotifyReload         "com.wjf.ballkey.reload"
#define kBKNotifyTest           "com.wjf.ballkey.test"
#define kBKNotifyProbe          "com.wjf.ballkey.probe"
#define kBKNotifyClose          "com.wjf.ballkey.close"
#define kBKNotifyCapture        "com.wjf.ballkey.capture"
#define kBKNotifyCapRes         "com.wjf.ballkey.capres"
#define kBKNotifyDir            "com.wjf.ballkey.appdir"

#define kBKTransducerHand       0x23
#define kBKSenderID             0x8000000817319372ull
#define kBKMaxFinger            10

#define kBKFieldBtnMask         (11u << 16 | 3u)
#define kBKFieldHandMask        (11u << 16 | 7u)
#define kBKFieldMajorR          0xb0014u
#define kBKFieldMinorR          0xb0015u
#define kBKFieldDisplayInt      0xb0019u
#define kBKFieldIsBuiltIn       0x4u

#define kBKFieldPtrX            (17u << 16 | 0u)
#define kBKFieldPtrY            (17u << 16 | 1u)
#define kBKFieldPtrBtn          (17u << 16 | 2u)

#define kBKFlagRange            0x01u
#define kBKFlagTouch            0x02u
#define kBKFlagPosition         0x04u
#define kBKFlagIdentity         0x20u

#define kBKTypeButton           2
#define kBKTypeKeyboard         3
#define kBKTypeDigitizer        11
#define kBKTypeKeyExtra         15
#define kBKTypePointer          17

#define kBKDefaultFpsKey        224
#define kBKCtrlRight            228
#define kBKUsageBtnBase         64
#define kBKMaxBtn               3

#define kBKMoveFactor           0.0015
#define kBKMoveDead             0.35
#define kBKMoveDedupNs          3000000ull
#define kBKEdge                 0.06
#define kBKPressNs              (60ull * NSEC_PER_MSEC)
#define kBKBtnLockNs            100000000ull
#define kBKCapArmNs             90000000ull
#define kBKCapLifeNs            8000000000ull

#define kBKIdxAim               70
#define kBKIdxAds               71
#define kBKIdxDir               72
#define kBKIdxFogo              73
#define kBKIdxCursor            40

#define kBKSeenMax              24
#define kBKSeenWindowMs         20

static void *gIOKit = NULL;
static BKIO gIO;
static BKIOHIDEventSystemClientRef gSendClient = NULL;
static dispatch_queue_t gSendQ = NULL;
static NSString *gBaseDir = nil;
static NSArray *gPoints = nil;
static BOOL gEnabled = NO;
static NSString *gActiveBundle = nil;
static BOOL gInApp = NO;
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
static double gFireX = 0.86, gFireY = 0.62;
static double gAdsX = 0.95, gAdsY = 0.50;
static double gAimX = 0.5, gAimY = 0.5;
static int gAimSlot = 0;
static BOOL gFogoDown = NO, gAdsDown = NO, gDirActive = NO;
static double gDirSens = 1.0;
static BOOL gAimB = NO;
static double gCx = 0.5, gCy = 0.5;
static int gPtrAbsMode = 0;
static BOOL gLastPtrValid = NO;
static double gLastPtrX = 0.0, gLastPtrY = 0.0;
static int gPtrMask = 0;
static uint64_t gLastMoveNs = 0;
static double gLastMdx = 0.0, gLastMdy = 0.0;
static BOOL gCapArm = NO;
static uint64_t gCapArmNs = 0;
static NSString *gCapNonce = nil;
static uint64_t gLastKeyNs = 0;
static uint64_t gLastBtnNs = 0;
static int gEvSeen = 0;
static int gKeySeen = 0;
static int gPtrSeen = 0;
static int gLstSeen = 0;
static NSString *gLogBuf = nil;
static uint64_t gLogLast = 0;
static NSString *gHookLib = @"-";

typedef struct { int on; double x, y; } BKAct;
static BKAct gAct[kBKMaxFinger + 1];
static int gSlotOwner[kBKMaxFinger + 1];
static NSMutableSet *gEnding = nil;
static int gPending = 0;
static int gSched = 0;

static void BKMove(NSUInteger idx, double nx, double ny);
static void BKStatus(void);
static void BKLoadConfig(void);
static void BKOnEventRaw(BKIOHIDEventRef event, int src);
static void BKPtrWrite(void);
static void BKPtrWriteTag(char tag, double a, double b, double c, double d);
static void BKPtrSpan(double *w, double *h);
static void BKCursorAbs(double x, double y);
static void BKCursorMove(double dx, double dy);
static void BKFpsMove(double dx, double dy);
static void BKPtrButtons(int mask);
static void BKHandleKey(int usage, BOOL down);
static void BKHandleButton(int b, BOOL down);
static NSString *BKPath(NSString *name);
static void BKGCStart(void);
static void BKGCStop(void);

static uint64_t BKNow(void) { return mach_absolute_time() / 1000000ull; }

static NSString *BKBase(void)
{
    if (gBaseDir) return gBaseDir;
    NSString *probe = @"/var/mobile/.bk_w";
    BOOL ok = [@"x" writeToFile:probe atomically:NO encoding:NSUTF8StringEncoding error:nil];
    if (ok) {
        [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
        gBaseDir = @"/var/mobile/";
    } else {
        NSString *d = NSTemporaryDirectory();
        if (!d.length) d = @"/tmp/";
        gBaseDir = [d hasSuffix:@"/"] ? d : [d stringByAppendingString:@"/"];
        CFPreferencesSetAppValue(CFSTR("AppDir"), (__bridge CFStringRef)gBaseDir, kBKPrefDomain);
        CFPreferencesAppSynchronize(kBKPrefDomain);
        notify_post(kBKNotifyDir);
    }
    return gBaseDir;
}

static NSString *BKPath(NSString *name) { return [BKBase() stringByAppendingString:name]; }

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
        NSString *p = BKPath(@"bk_debug.log");
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) { [out writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
        @try { [fh seekToEndOfFile]; [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        @catch (NSException *e) { }
    });
}

static void BKAppendD(NSString *s) { if (gDump) BKAppend(s); }

static void BKMark(NSString *name)
{
    [[NSString stringWithFormat:@"%.0f", (double)BKNow()]
        writeToFile:BKPath([@"bk_" stringByAppendingString:name])
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
    id timer = ((id (*)(id, SEL))objc_msgSend)(c, @selector(sharedInstance));
    if (!timer) return;
    SEL s1 = @selector(userEventOccurred);
    if ([timer respondsToSelector:s1]) ((void (*)(id, SEL))objc_msgSend)(timer, s1);
}

static int BKCurrentOrient(void)
{
    if (gOrientOverride > 0) return gOrientOverride;

    Class appCls = objc_getClass("UIApplication");
    if (appCls) {
        id app = ((id (*)(id, SEL))objc_msgSend)(appCls, @selector(sharedApplication));
        if (app) {
            SEL sb = @selector(statusBarOrientation);
            if ([app respondsToSelector:sb]) {
                int o = (int)((int (*)(id, SEL))objc_msgSend)(app, sb);
                if (o >= 1 && o <= 4) return o;
            }
        }
    }

    Class sbCls = objc_getClass("SpringBoard");
    if (sbCls) {
        id sba = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
        if (sba) {
            SEL sel = @selector(_frontMostAppOrientation);
            if ([sba respondsToSelector:sel]) {
                int o = (int)((int (*)(id, SEL))objc_msgSend)(sba, sel);
                if (o >= 1 && o <= 4) return o;
            }
        }
    }

    Class devCls = objc_getClass("UIDevice");
    if (devCls) {
        id dev = ((id (*)(id, SEL))objc_msgSend)(devCls, @selector(currentDevice));
        if (dev) {
            int o = (int)((int (*)(id, SEL))objc_msgSend)(dev, @selector(orientation));
            if (o >= 1 && o <= 4) return o;
        }
    }
    return 3;
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
        if (s >= kBKMaxFinger - 1) continue;
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
    gIO.SetInt(hand, (11u << 16 | 9u), anyDown ? 1 : 0);
    gIO.SetSender(hand, kBKSenderID);

    CFRetain(hand);
    dispatch_async(gSendQ, ^{
        @try { gIO.Dispatch(gSendClient, hand); } @catch (NSException *e) { }
        CFRelease(hand);
    });
    BKNotifyUserActivity();
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

static BOOL BKInitIO(void)
{
    gIOKit = dlopen("libIOKit.dylib", RTLD_LAZY);
    if (!gIOKit) gIOKit = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!gIOKit) { BKAppend(@"I io=0"); return NO; }
    gIO.ClientCreate = dlsym(gIOKit, "IOHIDEventSystemClientCreate");
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
    BKMark(@"engine_io.txt");
    return YES;
}

#pragma mark - Hooks

typedef void (*BKMSHookFunction)(void *sym, void *rep, void **res);
typedef void (*BKMSHookMessageEx)(Class cls, SEL sel, void *rep, void **res);

static BKMSHookFunction gMSHookFunction = NULL;
static BKMSHookMessageEx gMSHookMessageEx = NULL;
static void (*origDispatch)(BKIOHIDEventSystemClientRef, BKIOHIDEventRef) = NULL;
static BOOL (*origHandleEvent)(id, SEL, BKIOHIDEventRef, id) = NULL;
static void (*origEnqueueHID)(id, SEL, BKIOHIDEventRef) = NULL;
static void (*origDistribute)(id, SEL, BKIOHIDEventRef) = NULL;
static int gHookDispatch = 0;
static int gHookHandle = 0;
static int gHookEnqueue = 0;
static int gHookDistribute = 0;
static int gHookSelf = 0;
static BOOL gMarkDispatch = NO;
static BOOL gMarkHandle = NO;
static BOOL gMarkEnqueue = NO;
static BOOL gMarkDistribute = NO;
static BOOL gHooksReady = NO;

static void *gSeen[kBKSeenMax];
static uint64_t gSeenMs[kBKSeenMax];
static int gSeenIdx = 0;
static os_unfair_lock gSeenLock = OS_UNFAIR_LOCK_INIT;

static BOOL BKSeenRecently(void *ev)
{
    uint64_t now = BKNow();
    BOOL found = NO;
    os_unfair_lock_lock(&gSeenLock);
    for (int i = 0; i < kBKSeenMax; i++) {
        if (gSeen[i] == ev && (now - gSeenMs[i]) < kBKSeenWindowMs) { found = YES; break; }
    }
    if (!found) {
        gSeen[gSeenIdx] = ev;
        gSeenMs[gSeenIdx] = now;
        gSeenIdx = (gSeenIdx + 1) % kBKSeenMax;
    }
    os_unfair_lock_unlock(&gSeenLock);
    return found;
}

static void *BKSubstrateSym(const char *name)
{
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) { gHookLib = @"dflt"; return p; }

    static void *h = NULL;
    if (!h) {
        const char *paths[] = {
            "libellekit.dylib",
            "libsubstrate.dylib",
            "libhooker.dylib",
            "libsubstitute.dylib",
            "/usr/lib/libellekit.dylib",
            "/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            "/var/jb/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libhooker.dylib"
        };
        for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]) && !h; i++) {
            h = dlopen(paths[i], RTLD_LAZY);
            if (h) gHookLib = @(paths[i]);
        }
    }
    if (!h) return NULL;
    return dlsym(h, name);
}

static void BKHookDispatch(BKIOHIDEventSystemClientRef c, BKIOHIDEventRef e)
{
    if (e && gIO.GetSender && gIO.GetSender(e) == kBKSenderID) gHookSelf++;
    else BKOnEventRaw(e, 1);
    if (origDispatch) origDispatch(c, e);
}

static BOOL BKHookHandleEvent(id self, SEL cmd, BKIOHIDEventRef e, id ne)
{
    BKOnEventRaw(e, 2);
    if (origHandleEvent) return origHandleEvent(self, cmd, e, ne);
    return YES;
}

static void BKHookEnqueue(id self, SEL cmd, BKIOHIDEventRef e)
{
    BKOnEventRaw(e, 3);
    if (origEnqueueHID) origEnqueueHID(self, cmd, e);
}

static void BKHookDistribute(id self, SEL cmd, BKIOHIDEventRef e)
{
    BKOnEventRaw(e, 4);
    if (origDistribute) origDistribute(self, cmd, e);
}

static void BKInstallHooks(void)
{
    gMSHookFunction = (BKMSHookFunction)BKSubstrateSym("MSHookFunction");
    gMSHookMessageEx = (BKMSHookMessageEx)BKSubstrateSym("MSHookMessageEx");

    NSMutableString *rep = [NSMutableString string];

    if (gMSHookFunction && gIO.Dispatch) {
        gMSHookFunction((void *)gIO.Dispatch, (void *)BKHookDispatch, (void **)&origDispatch);
        [rep appendString:@"d"];
    }

    Class appCls = objc_getClass("UIApplication");
    if (gMSHookMessageEx && appCls) {
        SEL s1 = @selector(_enqueueHIDEvent:);
        Method m1 = class_getInstanceMethod(appCls, s1);
        if (m1) {
            gMSHookMessageEx(appCls, s1, (void *)BKHookEnqueue, (void **)&origEnqueueHID);
            [rep appendString:@"e"];
        }
        SEL s2 = @selector(handleEvent:withNewEvent:);
        Method m2 = class_getInstanceMethod(appCls, s2);
        if (m2) {
            gMSHookMessageEx(appCls, s2, (void *)BKHookHandleEvent, (void **)&origHandleEvent);
            [rep appendString:@"h"];
        }
    }

    Class delCls = objc_getClass("BKSHIDEventDeliveryManager");
    if (gMSHookMessageEx && delCls) {
        SEL s3 = @selector(distributeEvent:);
        Method m3 = class_getInstanceMethod(delCls, s3);
        if (m3) {
            gMSHookMessageEx(delCls, s3, (void *)BKHookDistribute, (void **)&origDistribute);
            [rep appendString:@"b"];
        }
    }

    gHooksReady = YES;
    NSString *line = [NSString stringWithFormat:@"v=%@ hl=%@ msf=%d msm=%d rep=%@",
        kBKBuildTag, gHookLib, gMSHookFunction ? 1 : 0, gMSHookMessageEx ? 1 : 0,
        rep.length ? rep : @"-"];
    BKAppend([NSString stringWithFormat:@"H %@", line]);
    [line writeToFile:BKPath(@"bk_hooks.txt")
          atomically:NO encoding:NSUTF8StringEncoding error:nil];
    if (!rep.length) BKMark(@"nohook.txt");
}

static void BKOnEvent(BKIOHIDEventRef event, int type, int src)
{
    @try {
        if (src == 1) {
            gHookDispatch++;
            if (!gMarkDispatch) { gMarkDispatch = YES; BKMark(@"hook_dispatch.txt"); }
        } else if (src == 2) {
            gHookHandle++;
            if (!gMarkHandle) { gMarkHandle = YES; BKMark(@"hook_handle.txt"); }
        } else if (src == 3) {
            gHookEnqueue++;
            if (!gMarkEnqueue) { gMarkEnqueue = YES; BKMark(@"hook_enqueue.txt"); }
        } else if (src == 4) {
            gHookDistribute++;
            if (!gMarkDistribute) { gMarkDistribute = YES; BKMark(@"hook_distribute.txt"); }
        }

        if (type == kBKTypePointer) {
            gPtrSeen++;
            double x = gIO.GetFloat(event, kBKFieldPtrX);
            double y = gIO.GetFloat(event, kBKFieldPtrY);
            if (gPtrAbsMode == 0) gPtrAbsMode = (x > 1.5 || y > 1.5) ? 1 : 2;
            if (gLastPtrValid) {
                double dx = x - gLastPtrX;
                double dy = y - gLastPtrY;
                if (fabs(dx) < 9000 && fabs(dy) < 9000) {
                    if (gFps) BKFpsMove(dx, dy);
                    else if (gCursorOn) {
                        if (gPtrAbsMode == 1) BKCursorAbs(x, y);
                        else BKCursorMove(dx, dy);
                    }
                }
            }
            gLastPtrX = x; gLastPtrY = y; gLastPtrValid = YES;
            BKPtrButtons((int)gIO.GetInt(event, kBKFieldPtrBtn));
            BKAppendD([NSString stringWithFormat:@"P%d x=%.1f y=%.1f m=%d ab=%d",
                src, x, y, gPtrMask, gPtrAbsMode]);
            return;
        }

        if (type == kBKTypeKeyExtra || type == kBKTypeKeyboard) {
            gKeySeen++;
            int page = gIO.GetInt(event, (3u << 16 | 0u));
            int usage = gIO.GetInt(event, (3u << 16 | 1u));
            int down = gIO.GetInt(event, (3u << 16 | 2u));
            BKAppendD([NSString stringWithFormat:@"K%d pg=%d u=%d d=%d", src, page, usage, down]);
            if (page != 7 && page != 0) return;
            BKHandleKey(usage, down != 0);
            return;
        }

        if (type == kBKTypeButton) {
            int usage = gIO.GetInt(event, kBKFieldBtnMask);
            int b = usage - kBKUsageBtnBase;
            if (b < 0 || b >= kBKMaxBtn) return;
            BKHandleButton(b, gIO.GetInt(event, (kBKTypeButton << 16 | 3u)) != 0);
            return;
        }
    } @catch (NSException *e) { }
}

static void BKOnEventRaw(BKIOHIDEventRef event, int src)
{
    if (!event || !gIO.GetType || !gHooksReady) return;
    @try {
        if (gIO.GetSender && gIO.GetSender(event) == kBKSenderID) return;
        if (BKSeenRecently(event)) return;
        int type = gIO.GetType(event);
        if (type == kBKTypeDigitizer) return;
        gEvSeen++;
        if (!pthread_main_np()) {
            CFRetain(event);
            dispatch_async(dispatch_get_main_queue(), ^{
                BKOnEvent(event, type, src);
                CFRelease(event);
            });
            return;
        }
        BKOnEvent(event, type, src);
    } @catch (NSException *e) { }
}

#pragma mark - GameController

static id gGCMouse = nil;
static id gGCKbd = nil;
static BOOL gGCOn = NO;

static void BKGCStart(void)
{
    if (gGCOn) return;
    gGCOn = YES;

    @try {
        Class mCls = objc_getClass("GCMouse");
        if (mCls) {
            SEL cur = NSSelectorFromString(@"current");
            if ([mCls respondsToSelector:cur]) {
                id m = ((id (*)(id, SEL))objc_msgSend)(mCls, cur);
                if (m) {
                    gGCMouse = m;
                    void (^mv)(id, CGFloat, CGFloat) = ^(id mm, CGFloat dx, CGFloat dy) {
                        (void)mm;
                        if (gFps) BKFpsMove(dx, dy);
                        else if (gCursorOn) BKCursorMove(dx, dy);
                    };
                    ((void (*)(id, SEL, id))objc_msgSend)(m, NSSelectorFromString(@"setMouseMovedHandler:"), mv);

                    id lb = ((id (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"leftButton"));
                    if (lb) {
                        void (^bh)(id, float, float, float) = ^(id b, float v, float p, float t) {
                            (void)b; (void)p; (void)t;
                            BKHandleButton(0, v > 0.5f);
                        };
                        ((void (*)(id, SEL, id, id))objc_msgSend)(lb, @selector(setValue:forKey:),
                            bh, @"pressedChangedHandler");
                    }
                    id rb = ((id (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"rightButton"));
                    if (rb) {
                        void (^bh)(id, float, float, float) = ^(id b, float v, float p, float t) {
                            (void)b; (void)p; (void)t;
                            BKHandleButton(1, v > 0.5f);
                        };
                        ((void (*)(id, SEL, id, id))objc_msgSend)(rb, @selector(setValue:forKey:),
                            bh, @"pressedChangedHandler");
                    }
                    BKAppend(@"G mouse=1");
                }
            }
        }

        Class kCls = objc_getClass("GCKeyboard");
        if (kCls) {
            SEL ck = NSSelectorFromString(@"coalescedKeyboard");
            if ([kCls respondsToSelector:ck]) {
                id k = ((id (*)(id, SEL))objc_msgSend)(kCls, ck);
                if (k) {
                    id ki = ((id (*)(id, SEL))objc_msgSend)(k, NSSelectorFromString(@"keyboardInput"));
                    if (ki) {
                        gGCKbd = k;
                        void (^kh)(id, id, long, BOOL) = ^(id kb, id key, long code, BOOL pressed) {
                            (void)kb; (void)key;
                            BKHandleKey((int)code, pressed);
                        };
                        ((void (*)(id, SEL, id))objc_msgSend)(ki,
                            NSSelectorFromString(@"setKeyChangedHandler:"), kh);
                        BKAppend(@"G kbd=1");
                    }
                }
            }
        }
    } @catch (NSException *e) {
        BKAppend([NSString stringWithFormat:@"! gc %@", e.reason]);
    }

    BKMark(@"gc_on.txt");
    BKStatus();
}

static void BKGCStop(void)
{
    if (!gGCOn) return;
    gGCOn = NO;
    @try {
        if (gGCMouse) {
            ((void (*)(id, SEL, id))objc_msgSend)(gGCMouse,
                NSSelectorFromString(@"setMouseMovedHandler:"), nil);
        }
    } @catch (NSException *e) { }
    BKAppend(@"G off");
}

#pragma mark - Ponteiro e FPS

static void BKPtrSpan(double *w, double *h)
{
    double ww = 0.0, hh = 0.0;
    @try {
        UIScreen *s = [UIScreen mainScreen];
        CGFloat sc = s.nativeScale > 0 ? s.nativeScale : s.scale;
        CGRect nb = s.nativeBounds;
        if (sc > 0.0 && nb.size.width > 1.0 && nb.size.height > 1.0) {
            ww = nb.size.width / sc;
            hh = nb.size.height / sc;
        }
    } @catch (NSException *e) { }
    if (ww < 100.0 || hh < 100.0) { ww = 414.0; hh = 736.0; }
    *w = ww; *h = hh;
}

static void BKPtrWriteTag(char tag, double a, double b, double c, double d)
{
    NSString *s = (tag == 'A')
        ? [NSString stringWithFormat:@"A %.2f %.2f %.2f %.2f", a, b, c, d]
        : [NSString stringWithFormat:@"R %.4f %.4f", a, b];
    [s writeToFile:BKPath(@"bk_ptr.txt") atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static void BKPtrWrite(void)
{
    BKPtrWriteTag('R', gCx, gCy, 0.0, 0.0);
}

static void BKCursorAbs(double x, double y)
{
    double w, h;
    BKPtrSpan(&w, &h);
    gCx = BKClamp(x / w);
    gCy = BKClamp(y / h);
    BKPtrWriteTag('A', x, y, w, h);
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
    BKTap(kBKIdxCursor, gCx, gCy);
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

static void BKAimRecenter(int fromSlot, double cx, double cy)
{
    int toSlot = gAimB ? (kBKMaxFinger - 1) : kBKMaxFinger;
    gAimB = !gAimB;
    if (fromSlot == toSlot) { BKSlotMove(fromSlot, cx, cy); return; }
    if (fromSlot > 0) { BKSlotUp(fromSlot); gSlotOwner[fromSlot] = 0; }
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

    double nx = BKClamp(gAimX + dx * gFpsSens * kBKMoveFactor);
    double ny = BKClamp(gAimY + dy * gFpsSens * kBKMoveFactor);

    double px, py;
    int o = BKCurrentOrient();
    if (gRotate) BKConvInv(nx, ny, o, &px, &py);
    else { px = nx; py = ny; }

    gAimX = nx; gAimY = ny;
    BKSlotMove(gAimSlot, px, py);

    if (px < kBKEdge || px > 1.0 - kBKEdge || py < kBKEdge || py > 1.0 - kBKEdge) {
        BKAimRecenter(gAimSlot, 0.5, 0.5);
        gAimX = 0.5; gAimY = 0.5;
        gAimSlot = [gSlotOf[@(kBKIdxAim)] intValue];
        BKAppendD([NSString stringWithFormat:@"F borda dedo=%d", gAimSlot]);
    }
}

static void BKFpsEnsure(void)
{
    if (!gFps) return;
    if (gAimSlot && gAct[gAimSlot].on) return;
    gAimX = 0.5; gAimY = 0.5;
    BKDown(kBKIdxAim, 0.5, 0.5);
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
    gCx = 0.5; gCy = 0.5;
    BKPtrWrite();
    BKAppend(@"F off");
    notify_post("com.wjf.ballkey.fps_off");
}

#pragma mark - Estado

static void BKStatus(void)
{
    NSString *s = [NSString stringWithFormat:@"v%@ e%d k%d p%d m%lu l%d h%d.%d.%d.%d s%d g%d hl:%@\na=%@ o%d\n",
        kBKBuildTag, (int)gEnabled, gKeySeen, gPtrSeen, (unsigned long)gPoints.count, gLstSeen,
        gHookDispatch, gHookHandle, gHookEnqueue, gHookDistribute, gHookSelf, (int)gGCOn,
        gHookLib, gActiveBundle ?: @"-", BKCurrentOrient()];
    [s writeToFile:BKPath(@"bk_status.txt") atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static NSArray *BKResolvePoints(NSDictionary *cfg, NSString *bundle)
{
    NSDictionary *profiles = cfg[@"Profiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) return nil;
    if ([bundle isKindOfClass:[NSString class]] && bundle.length) {
        id p = profiles[bundle];
        if ([p isKindOfClass:[NSArray class]]) return p;
    }
    id w = profiles[@"*"];
    if ([w isKindOfClass:[NSArray class]]) return w;
    if (profiles.count == 1) {
        id p = [[profiles allValues] firstObject];
        if ([p isKindOfClass:[NSArray class]]) return p;
    }
    return nil;
}

static NSDictionary *BKReadCfg(void)
{
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("Config"), kBKPrefDomain);
    if (v) {
        NSDictionary *d = (__bridge_transfer NSDictionary *)v;
        if ([d isKindOfClass:[NSDictionary class]]) return d;
    }
    return [NSDictionary dictionaryWithContentsOfFile:@(kBKConfigFile)];
}

static void BKLoadConfig(void)
{
    NSDictionary *cfg = BKReadCfg();
    if (![cfg isKindOfClass:[NSDictionary class]]) cfg = @{};
    BOOL enabled = [cfg[@"Enabled"] boolValue];

    if ([cfg[@"Rotate"] isKindOfClass:[NSNumber class]]) gRotate = [cfg[@"Rotate"] boolValue];
    if ([cfg[@"FollowCursor"] isKindOfClass:[NSNumber class]]) gFollowCursor = [cfg[@"FollowCursor"] boolValue];
    if ([cfg[@"CursorOn"] isKindOfClass:[NSNumber class]]) gCursorOn = [cfg[@"CursorOn"] boolValue];
    if ([cfg[@"FollowSens"] isKindOfClass:[NSNumber class]]) gFollowSens = [cfg[@"FollowSens"] doubleValue];
    if ([cfg[@"OrientOverride"] isKindOfClass:[NSNumber class]]) gOrientOverride = [cfg[@"OrientOverride"] intValue];
    if ([cfg[@"Dump"] isKindOfClass:[NSNumber class]]) gDump = [cfg[@"Dump"] boolValue];
    if ([cfg[@"FpsSens"] isKindOfClass:[NSNumber class]]) gFpsSens = [cfg[@"FpsSens"] doubleValue];
    if ([cfg[@"FpsKey"] isKindOfClass:[NSNumber class]]) gFpsKey = [cfg[@"FpsKey"] intValue];
    if ([cfg[@"FireX"] isKindOfClass:[NSNumber class]]) gFireX = [cfg[@"FireX"] doubleValue];
    if ([cfg[@"FireY"] isKindOfClass:[NSNumber class]]) gFireY = [cfg[@"FireY"] doubleValue];
    if ([cfg[@"AdsX"] isKindOfClass:[NSNumber class]]) gAdsX = [cfg[@"AdsX"] doubleValue];
    if ([cfg[@"AdsY"] isKindOfClass:[NSNumber class]]) gAdsY = [cfg[@"AdsY"] doubleValue];

    if (gFpsSens <= 0) gFpsSens = 1.0;
    if (gFollowSens <= 0) gFollowSens = 1.0;

    BOOL wasEnabled = gEnabled;
    gEnabled = enabled;

    NSString *own = [[NSBundle mainBundle] bundleIdentifier];
    if (!own.length || [own isEqualToString:@"com.apple.springboard"]
        || [own isEqualToString:@"com.apple.backboardd"]) {
        gInApp = NO;
        own = [cfg[@"ActiveBundle"] isKindOfClass:[NSString class]] ? cfg[@"ActiveBundle"] : nil;
    } else {
        gInApp = YES;
    }
    gActiveBundle = own;
    gPoints = BKResolvePoints(cfg, own);

    if (gInApp && own.length) {
        [own writeToFile:BKPath(@"bk_app.txt")
              atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }

    if (!enabled && wasEnabled) { BKReleaseAll(); if (gFps) BKFpsOff(); }
    if (enabled && gPoints.count) BKMark(@"engine_armed.txt");
    BKAppend([NSString stringWithFormat:@"L en=%d app=%@ pts=%lu app=%d",
        (int)enabled, own ?: @"-", (unsigned long)gPoints.count, (int)gInApp]);
    BKStatus();
}

#pragma mark - Captura de tecla

static void BKCaptureWrite(NSString *key)
{
    if (!gCapArm || !gCapNonce) return;
    gCapArm = NO;
    NSString *s = [NSString stringWithFormat:@"%@|%@", gCapNonce, key];
    [s writeToFile:BKPath(@"bk_capture_result.txt")
        atomically:NO encoding:NSUTF8StringEncoding error:nil];
    notify_post(kBKNotifyCapRes);
    BKAppend([NSString stringWithFormat:@"C res=%@", key]);
}

static void BKArmCapture(void)
{
    NSString *req = [NSString stringWithContentsOfFile:BKPath(@"bk_capture.txt")
        encoding:NSUTF8StringEncoding error:nil];
    req = [req stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (req.length < 3) { BKAppend(@"C sem nonce"); return; }
    gCapNonce = req;
    gCapArm = YES;
    gCapArmNs = BKNow();
    [@"" writeToFile:BKPath(@"bk_capture_result.txt")
        atomically:NO encoding:NSUTF8StringEncoding error:nil];
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

#pragma mark - Roteamento

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

static void BKPtrButtons(int mask)
{
    if (mask == gPtrMask) return;
    int diff = mask ^ gPtrMask;
    gPtrMask = mask;
    if (diff & 1) BKHandleButton(0, (mask & 1) != 0);
    if (diff & 2) BKHandleButton(1, (mask & 2) != 0);
}

#pragma mark - Testes

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

static void BKSelfTest(void)
{
    if (!gSendClient || !gIO.CreateDigitizer || !gIO.Dispatch) return;
    BKIOHIDEventRef ev = gIO.CreateDigitizer(kCFAllocatorDefault, mach_absolute_time(),
        kBKTransducerHand, 0, 0, kBKFlagPosition, 0, 0.5, 0.5, 0.0, 0.0, 0.0, 0, 0, 0);
    if (!ev) return;
    gIO.SetSender(ev, kBKSenderID);
    gIO.Dispatch(gSendClient, ev);
    CFRelease(ev);
}

__attribute__((constructor)) static void BKInitC(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
        BKBase();
        BKMark(@"engine_ctor.txt");
        gDown = [NSMutableDictionary dictionary];
        gGen = [NSMutableDictionary dictionary];
        gSlotOf = [NSMutableDictionary dictionary];
        gKeyDown = [NSMutableDictionary dictionary];
        gEnding = [NSMutableSet set];
        gSendQ = dispatch_queue_create("com.wjf.ballkey.send", DISPATCH_QUEUE_SERIAL);

        if (!BKInitIO()) { BKStatus(); return; }

        gSendClient = gIO.ClientCreate(kCFAllocatorDefault);
        BKAppend(gSendClient ? @"I send=1" : @"I send=0");

        @try { BKInstallHooks(); }
        @catch (NSException *e) { BKAppend([NSString stringWithFormat:@"! hooks %@", e.reason]); }

        dispatch_queue_t q = dispatch_get_main_queue();
        int t1 = 0, t2 = 0, t3 = 0, t4 = 0;
        notify_register_dispatch(kBKNotifyReload, &t1, q, ^(int t) { (void)t; BKLoadConfig(); });
        notify_register_dispatch(kBKNotifyTest, &t2, q, ^(int t) { (void)t; BKTestCenter(); });
        notify_register_dispatch(kBKNotifyProbe, &t3, q, ^(int t) { (void)t; BKProbe(); });
        notify_register_dispatch(kBKNotifyCapture, &t4, q, ^(int t) { (void)t; BKArmCapture(); });
        BKAppend(@"I notify=1");

        BKLoadConfig();

        // GameController liga sempre, sem depender de timer nem de hook.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)),
                       q, ^{ @try { BKGCStart(); } @catch (NSException *e) { } });

        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        if (src) {
            dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 150ull * NSEC_PER_MSEC),
                                      150ull * NSEC_PER_MSEC, 30ull * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(src, ^{
                @try {
                    static int tick = 0;
                    tick++;
                    BKCaptureWatch();
                    BKFpsEnsure();
                    if (tick == 14) BKSelfTest();
                    if (tick == 20 && !gGCOn) BKGCStart();
                    if (tick == 70 && gEvSeen == 0) BKMark(@"hook_none.txt");
                    if (tick % 6 == 0) BKStatus();
                } @catch (NSException *e) { }
            });
            dispatch_resume(src);
        }

        BKAppend(@"I ready");
        BKMark(@"engine_ready.txt");
        BKStatus();
        }
    });
}
