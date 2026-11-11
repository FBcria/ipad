// BallKey/Engine/Tweak.x
// Motor do BallKey: converte HID fisico (teclado/mouse) em toque injetado.
// Roda no SpringBoard e no backboardd, que sao os processos onde os eventos
// fisicos existem de fato. O overlay cuida da interface e do config.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <os/lock.h>
#import <stdarg.h>

#pragma mark - Tipos e constantes

typedef struct __IOHIDEvent *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;

typedef void (*BKMSHookFunction)(void *sym, void *hook, void **old);
typedef void (*BKMSHookMessageEx)(Class cls, SEL sel, void *imp, void **old);

const char BKEngineTag[] = "b31";

#define kBKPrefDomain CFSTR("com.wjf.ballkey")
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

#define kBKMaxFinger 9
#define kBKSlotAim 10
#define kBKPressNs 60ull
#define kBKSeenMax 24

#pragma mark - Estado

static NSString *gBaseDir = nil;
static NSString *gLogBuf = nil;
static uint64_t gLogLast = 0;

static int gEvSeen = 0;
static int gKeySeen = 0;
static int gPtrSeen = 0;
static int gLstSeen = 0;
static int gHookSeen = 0;

static int gHookDispatch = 0;
static int gHookHandle = 0;
static int gHookEnqueue = 0;
static int gHookDistribute = 0;
static BOOL gMarkDispatch = NO, gMarkHandle = NO, gMarkEnqueue = NO, gMarkDistribute = NO;
static BOOL gHooksReady = NO;

static void *gSeen[kBKSeenMax];
static uint64_t gSeenMs[kBKSeenMax];
static int gSeenIdx = 0;
static os_unfair_lock gSeenLock = OS_UNFAIR_LOCK_INIT;

static BKMSHookFunction gMSHookFunction = NULL;
static BKMSHookMessageEx gMSHookMessageEx = NULL;

typedef struct {
    BKIOHIDEventSystemClientRef (*ClientCreate)(CFAllocatorRef);
    BKIOHIDEventSystemClientRef (*ClientCreateType)(CFAllocatorRef, int, void *);
    void (*SetMatching)(BKIOHIDEventSystemClientRef, CFDictionaryRef);
    void (*SetQueue)(BKIOHIDEventSystemClientRef, dispatch_queue_t);
    void (*ScheduleRL)(BKIOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
    void (*RegisterCB)(BKIOHIDEventSystemClientRef, void *, void *, void *);
    void (*Activate)(BKIOHIDEventSystemClientRef);
    void (*Dispatch)(BKIOHIDEventSystemClientRef, BKIOHIDEventRef);
    int (*GetType)(BKIOHIDEventRef);
    double (*GetFloat)(BKIOHIDEventRef, int);
    int (*GetInt)(BKIOHIDEventRef, int);
    uint64_t (*GetSender)(BKIOHIDEventRef);
} BKIO;

static BKIO gIO;

typedef BKIOHIDEventRef (*BKDigitizerFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
    uint32_t, uint32_t, double, double, double, double, double, double, BOOL, uint32_t);
typedef void (*BKSetDigitizerInfoFn)(BKIOHIDEventRef, BKIOHIDEventSystemClientRef, BOOL,
    uint32_t, uint32_t, uint32_t, uint32_t, double, double);

static BKDigitizerFingerFn fFingerEvent = NULL;
static BKSetDigitizerInfoFn fSetDigitizerInfo = NULL;

static BKIOHIDEventSystemClientRef gSendClient = NULL;
static BKIOHIDEventSystemClientRef gListenClient = NULL;
static id gListenBlock = nil;
static dispatch_queue_t gSendQ = NULL;

static void (*origDispatch)(BKIOHIDEventSystemClientRef, BKIOHIDEventRef) = NULL;
static BOOL (*origHandleEvent)(id, SEL, BKIOHIDEventRef, id) = NULL;
static void (*origEnqueueHID)(id, SEL, BKIOHIDEventRef) = NULL;
static void (*origDistribute)(id, SEL, BKIOHIDEventRef) = NULL;

static BOOL gEnabled = YES;
static BOOL gFps = NO;
static BOOL gCursorOn = NO;
static double gSpeed = 1.6;
static NSString *gActiveBundle = nil;

static NSDictionary *gPoints = nil;
static NSMutableDictionary *gKeyMap = nil;
static NSMutableDictionary *gBtnMap = nil;

static double gLastPtrX = 0.0, gLastPtrY = 0.0;
static BOOL gLastPtrValid = NO;
static int gPtrMask = 0;
static uint64_t gLastMoveNs = 0;
static uint64_t gLastKeyNs = 0;
static uint64_t gLastBtnNs = 0;

static BOOL gCapArm = NO;
static uint64_t gCapArmNs = 0;
static NSString *gCapNonce = nil;

typedef struct { int on; double x, y; } BKAct;
static BKAct gAct[kBKSlotAim + 1];
static int gSlotOwner[kBKSlotAim + 1];
static NSMutableSet *gEnding = nil;
static NSMutableDictionary *gGen = nil;
static NSMutableDictionary *gKeyDown = nil;

static id gGCMouse = nil;
static id gGCKbd = nil;
static id gGCLeft = nil;
static id gGCRight = nil;
static id gGCKbdIn = nil;
static BOOL gGCOn = NO;

#pragma mark - Prototipos

static NSString *BKBase(void);
static NSString *BKPath(NSString *name);
static void BKMark(NSString *name);
static void BKAppend(NSString *fmt, ...);
static uint64_t BKNow(void);
static void BKPtrSpan(double *w, double *h);
static void BKPtrWriteTag(char tag, double a, double b, double c, double d);
static void BKCursorAbs(double x, double y);
static void BKCursorMove(double dx, double dy);
static void BKFpsMove(double dx, double dy);
static void BKPtrButtons(int mask);
static void BKHandleKey(int usage, BOOL down);
static void BKHandleButton(int index, BOOL down);
static void BKGCStart(void);
static void BKGCStop(void);
static void BKOnEventRaw(BKIOHIDEventRef event, int src);
static void BKStatus(void);
static void BKLoadConfig(void);
static void BKFrontTick(void);
static void BKSelfTest(void);
static void BKCaptureWatch(void);
static void BKArmCapture(void);

#pragma mark - Base de arquivos

static uint64_t BKNow(void) { return mach_absolute_time() / 1000000ull; }

static NSString *BKBase(void)
{
    if (gBaseDir) return gBaseDir;
    NSString *probe = @"/var/mobile/.bk_w";
    BOOL ok = [@"x" writeToFile:probe atomically:NO encoding:NSUTF8StringEncoding error:nil];
    if (ok) {
        [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
        gBaseDir = @"/var/mobile";
    } else {
        gBaseDir = @"/tmp";
    }
    return gBaseDir;
}

static NSString *BKPath(NSString *name)
{
    return [BKBase() stringByAppendingPathComponent:name];
}

static void BKMark(NSString *name)
{
    NSString *p = BKPath([@"bk_" stringByAppendingString:name]);
    [@"" writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static void BKAppend(NSString *fmt, ...)
{
    @autoreleasepool {
        va_list ap;
        va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);

        uint64_t now = BKNow();
        if (!gLogBuf || now - gLogLast > 4000) {
            gLogBuf = [NSString stringWithContentsOfFile:BKPath(@"bk_debug.log")
                                                encoding:NSUTF8StringEncoding error:nil];
            if (!gLogBuf) gLogBuf = @"";
            if (gLogBuf.length > 60000) {
                gLogBuf = [gLogBuf substringFromIndex:gLogBuf.length - 40000];
            }
            gLogLast = now;
        }
        gLogBuf = [gLogBuf stringByAppendingFormat:@"[%llu] %@\n", now, msg];
        [gLogBuf writeToFile:BKPath(@"bk_debug.log") atomically:NO
                    encoding:NSUTF8StringEncoding error:nil];
    }
}

#pragma mark - Resolucao de simbolos

static void *BKIOKit(void)
{
    static void *h = NULL;
    if (!h) {
        h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    }
    return h;
}

static void *BKSubstrateSym(const char *name, NSString **from)
{
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) { if (from) *from = @"dflt"; return p; }

    static void *h = NULL;
    static const char *paths[] = {
        "/var/jb/usr/lib/libellekit.dylib",
        "/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libsubstrate.dylib",
        "/usr/lib/libsubstrate.dylib",
        "/var/jb/usr/lib/libhooker.dylib",
        "/usr/lib/libhooker.dylib",
        "/var/jb/usr/lib/libsubstitute.dylib",
        "/usr/lib/libsubstitute.dylib"
    };
    if (!h) {
        for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
            h = dlopen(paths[i], RTLD_LAZY);
            if (h) { if (from) *from = [NSString stringWithUTF8String:paths[i]]; break; }
        }
    }
    if (!h) return NULL;
    return dlsym(h, name);
}

static BOOL BKInitIO(void)
{
    void *k = BKIOKit();
    if (!k) return NO;

    gIO.ClientCreate = (void *)dlsym(k, "IOHIDEventSystemClientCreate");
    gIO.ClientCreateType = (void *)dlsym(k, "IOHIDEventSystemClientCreateWithType");
    gIO.SetMatching = (void *)dlsym(k, "IOHIDEventSystemClientSetMatching");
    gIO.SetQueue = (void *)dlsym(k, "IOHIDEventSystemClientSetQueue");
    gIO.ScheduleRL = (void *)dlsym(k, "IOHIDEventSystemClientScheduleWithRunLoop");
    gIO.RegisterCB = (void *)dlsym(k, "IOHIDEventSystemClientRegisterEventCallback");
    gIO.Activate = (void *)dlsym(k, "IOHIDEventSystemClientActivate");
    gIO.Dispatch = (void *)dlsym(k, "IOHIDEventSystemClientDispatchEvent");
    gIO.GetType = (void *)dlsym(k, "IOHIDEventGetType");
    gIO.GetFloat = (void *)dlsym(k, "IOHIDEventGetFloatValue");
    gIO.GetInt = (void *)dlsym(k, "IOHIDEventGetIntegerValue");
    gIO.GetSender = (void *)dlsym(k, "IOHIDEventGetSenderID");

    fFingerEvent = (BKDigitizerFingerFn)dlsym(k, "IOHIDEventCreateDigitizerFingerEvent");
    fSetDigitizerInfo = (BKSetDigitizerInfoFn)dlsym(RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
    if (!fSetDigitizerInfo) {
        void *b = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
        if (b) fSetDigitizerInfo = (BKSetDigitizerInfoFn)dlsym(b, "BKSHIDEventSetDigitizerInfo");
    }

    return (gIO.ClientCreate != NULL && gIO.GetType != NULL && gIO.Dispatch != NULL);
}

#pragma mark - Envio de toque

static void BKSend(BKIOHIDEventRef ev)
{
    if (!ev || !gSendClient || !gIO.Dispatch) return;
    dispatch_async(gSendQ, ^{
        gIO.Dispatch(gSendClient, ev);
        CFRelease(ev);
    });
}

static void BKFinger(int slot, int phase, double x, double y)
{
    if (!fFingerEvent || !gSendClient) return;
    if (slot < 0 || slot > kBKSlotAim) return;

    uint32_t mask = 0;
    BOOL touch = YES;
    if (phase == 0) mask = 0x01;
    else if (phase == 1) mask = 0x02;
    else if (phase == 2) mask = 0x04;
    else { mask = 0x08 | 0x10; touch = NO; }

    BKIOHIDEventRef ev = fFingerEvent(kCFAllocatorDefault, mach_absolute_time(),
        (uint32_t)slot, (uint32_t)slot, mask, 0, x, y, 0.0, 1.0, 0.0, 0.0, touch, 0);
    if (!ev) return;
    if (fSetDigitizerInfo) fSetDigitizerInfo(ev, gSendClient, YES, 0, 0, 0, 0, x, y);
    BKSend(ev);
}

static int BKSlotAcquire(void)
{
    for (int i = 0; i < kBKMaxFinger; i++) {
        if (!gAct[i].on) {
            gAct[i].on = 1;
            gSlotOwner[i] = 1;
            return i;
        }
    }
    return -1;
}

static void BKSlotPress(int slot, double x, double y)
{
    if (slot < 0) return;
    gAct[slot].x = x;
    gAct[slot].y = y;
    BKFinger(slot, 0, x, y);
    BKFinger(slot, 1, x, y);
}

static void BKSlotRelease(int slot)
{
    if (slot < 0 || slot > kBKSlotAim) return;
    if (!gAct[slot].on) return;
    BKFinger(slot, 3, gAct[slot].x, gAct[slot].y);
    gAct[slot].on = 0;
    gSlotOwner[slot] = 0;
}

static void BKSlotMove(int slot, double x, double y)
{
    if (slot < 0 || slot > kBKSlotAim) return;
    if (!gAct[slot].on) return;
    gAct[slot].x = x;
    gAct[slot].y = y;
    BKFinger(slot, 2, x, y);
}

#pragma mark - Dedup

static BOOL BKSeenRecently(void *ev)
{
    uint64_t now = BKNow();
    BOOL found = NO;
    os_unfair_lock_lock(&gSeenLock);
    for (int i = 0; i < kBKSeenMax; i++) {
        if (gSeen[i] == ev && now - gSeenMs[i] < 40ull) { found = YES; break; }
    }
    if (!found) {
        gSeen[gSeenIdx] = ev;
        gSeenMs[gSeenIdx] = now;
        gSeenIdx = (gSeenIdx + 1) % kBKSeenMax;
    }
    os_unfair_lock_unlock(&gSeenLock);
    return found;
}

#pragma mark - Config

static NSDictionary *BKResolvePoints(NSDictionary *cfg, NSString *bundle)
{
    NSDictionary *profiles = [cfg objectForKey:@"Profiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) return nil;
    id arr = nil;
    if (bundle) arr = [profiles objectForKey:bundle];
    if (![arr isKindOfClass:[NSArray class]]) {
        arr = [profiles objectForKey:@"*"];
    }
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
        if ([ab isKindOfClass:[NSString class]]) {
            gActiveBundle = ab;
        }

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
        gKeyMap = keys;
        gBtnMap = btns;
        gPoints = res;
    } @catch (NSException *e) { }
}

#pragma mark - Ponteiro, cursor e FPS

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
    [s writeToFile:BKPath(@"bk_ptr.txt") atomically:NO
          encoding:NSUTF8StringEncoding error:nil];
}

static void BKCursorAbs(double x, double y)
{
    double w, h;
    BKPtrSpan(&w, &h);
    BKPtrWriteTag('A', x, y, w, h);
}

static void BKCursorMove(double dx, double dy)
{
    BKPtrWriteTag('R', dx, dy);
}

static double BKPointX(NSDictionary *p, double span)
{
    return [[p objectForKey:@"X"] doubleValue] * span;
}

static double BKPointY(NSDictionary *p, double span)
{
    return [[p objectForKey:@"Y"] doubleValue] * span;
}

static void BKFpsMove(double dx, double dy)
{
    if (!gEnabled || !gFps) return;
    double w, h;
    BKPtrSpan(&w, &h);

    if (!gAct[kBKSlotAim].on) {
        gAct[kBKSlotAim].on = 1;
        gSlotOwner[kBKSlotAim] = 1;
        gAct[kBKSlotAim].x = w * 0.5;
        gAct[kBKSlotAim].y = h * 0.5;
        BKFinger(kBKSlotAim, 0, gAct[kBKSlotAim].x, gAct[kBKSlotAim].y);
        BKFinger(kBKSlotAim, 1, gAct[kBKSlotAim].x, gAct[kBKSlotAim].y);
    }

    double nx = gAct[kBKSlotAim].x + dx * gSpeed;
    double ny = gAct[kBKSlotAim].y + dy * gSpeed;
    if (nx < 4.0) nx = 4.0;
    if (ny < 4.0) ny = 4.0;
    if (nx > w - 4.0) nx = w - 4.0;
    if (ny > h - 4.0) ny = h - 4.0;

    gAct[kBKSlotAim].x = nx;
    gAct[kBKSlotAim].y = ny;
    BKFinger(kBKSlotAim, 2, nx, ny);
}

static void BKAimRecenter(void)
{
    if (!gAct[kBKSlotAim].on) return;
    double w, h;
    BKPtrSpan(&w, &h);
    BKSlotMove(kBKSlotAim, w * 0.5, h * 0.5);
}

static void BKPtrButtons(int mask)
{
    int diff = mask ^ gPtrMask;
    gPtrMask = mask;
    if (diff & 1) BKHandleButton(0, (mask & 1) != 0);
    if (diff & 2) BKHandleButton(1, (mask & 2) != 0);
}

#pragma mark - Teclas e botoes

static void BKPressPoint(NSDictionary *p, BOOL down, NSMutableDictionary *store, int code)
{
    NSNumber *k = [NSNumber numberWithInt:code];

    if (!down) {
        NSNumber *slotN = [store objectForKey:k];
        if (slotN) {
            BKSlotRelease([slotN intValue]);
            [store removeObjectForKey:k];
        }
        return;
    }

    if ([store objectForKey:k]) return;

    double w, h;
    BKPtrSpan(&w, &h);
    double x = BKPointX(p, w);
    double y = BKPointY(p, h);

    int slot = BKSlotAcquire();
    if (slot < 0) return;
    BKSlotPress(slot, x, y);
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

    if (index == 0) {
        if (gFps) {
            if (down) {
                NSDictionary *p = [gBtnMap objectForKey:[NSNumber numberWithInt:0]];
                if (p) {
                    double w, h;
                    BKPtrSpan(&w, &h);
                    int slot = BKSlotAcquire();
                    if (slot >= 0) {
                        BKSlotPress(slot, BKPointX(p, w), BKPointY(p, h));
                        gGen[[NSString stringWithFormat:@"b%d", slot]] = [NSNumber numberWithInt:slot];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBKPressNs * NSEC_PER_MSEC)),
                                       dispatch_get_main_queue(), ^{
                            BKSlotRelease(slot);
                            [gGen removeObjectForKey:[NSString stringWithFormat:@"b%d", slot]];
                        });
                    }
                }
            }
            return;
        }
    }

    NSDictionary *p = [gBtnMap objectForKey:[NSNumber numberWithInt:index]];
    if (!p) return;
    if (index == 1 && down && gFps) {
        BKAimRecenter();
    }
    BKPressPoint(p, down, gGen, index + 100);
}

#pragma mark - Captura

static void BKArmCapture(void)
{
    gCapNonce = [NSString stringWithFormat:@"%llu", BKNow()];
    gCapArm = YES;
    gCapArmNs = BKNow();
    [gCapNonce writeToFile:BKPath(@"bk_capture_nonce.txt") atomically:NO
                  encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:BKPath(@"bk_capture_result.txt") atomically:NO
            encoding:NSUTF8StringEncoding error:nil];
    BKAppend(@"C arm %@", gCapNonce);
}

static void BKCaptureWatch(void)
{
    if (!gCapArm) return;
    if (BKNow() - gCapArmNs > 12000ull) {
        gCapArm = NO;
        BKAppend(@"C timeout");
    }
}

static void BKCaptureHit(int kind, int code, NSString *extra)
{
    if (!gCapArm) return;
    gCapArm = NO;
    NSString *s = [NSString stringWithFormat:@"%d|%d|%@|%@", kind, code,
                   extra ? extra : @"-", gCapNonce ? gCapNonce : @"-"];
    [s writeToFile:BKPath(@"bk_capture_result.txt") atomically:NO
          encoding:NSUTF8StringEncoding error:nil];
    BKAppend(@"C hit %@", s);
}

#pragma mark - Status

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
    NSString *b = BKAppAt();
    if ([b isEqualToString:@"-"]) return;
    if (gActiveBundle && [gActiveBundle isEqualToString:b]) return;
    gActiveBundle = b;
    [[NSUserDefaults standardUserDefaults] setObject:b forKey:@"ActiveBundle"];
    BKLoadConfig();
}

static uint64_t BKAge(NSString *marker)
{
    NSString *p = BKPath(marker);
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    if (!a) return 0;
    NSDate *d = [a objectForKey:NSFileModificationDate];
    if (!d) return 0;
    double age = -[d timeIntervalSinceNow];
    if (age < 0.0) age = 0.0;
    return (uint64_t)age;
}

static NSString *BKSibling(void)
{
    NSString *cands[] = {
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/BallKeyEngine.dylib",
        @"/var/jb/usr/lib/BallKeyEngine.dylib",
        @"/var/mobile/BallKeyEngine.dylib"
    };
    for (int i = 0; i < 3; i++) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:cands[i]]) return cands[i];
    }
    return @"-";
}

static NSString *BKPlist(void)
{
    NSString *cands[] = {
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/BallKeyEngine.plist",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/BallKeyOverlay.plist"
    };
    for (int i = 0; i < 2; i++) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:cands[i]]) return @"S";
    }
    return @"N";
}

static NSString *BKFilterOK(void)
{
    NSString *p = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/BallKeyEngine.plist";
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    if (!d) return @"N";
    NSDictionary *f = [d objectForKey:@"Filter"];
    if (![f isKindOfClass:[NSDictionary class]]) return @"N";
    NSArray *e = [f objectForKey:@"Executables"];
    if (![e isKindOfClass:[NSArray class]]) return @"N";
    BOOL sb = NO, bb = NO;
    for (NSString *s in e) {
        if ([s isEqualToString:@"SpringBoard"]) sb = YES;
        if ([s isEqualToString:@"backboardd"]) bb = YES;
    }
    if (sb && bb) return @"S";
    if (sb || bb) return @"P";
    return @"N";
}

static NSString *BKFfApps(void)
{
    NSMutableString *m = [NSMutableString string];
    NSString *cands[] = { @"com.dts.freefireth", @"com.dts.freefiremax" };
    for (int i = 0; i < 2; i++) {
        BOOL ok = [[NSFileManager defaultManager] fileExistsAtPath:
                   [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:cands[i]]];
        if (!ok) {
            Class ws = objc_getClass("LSApplicationWorkspace");
            if (ws) {
                id w = ((id (*)(id, SEL))objc_msgSend)((id)ws, NSSelectorFromString(@"defaultWorkspace"));
                if (w) {
                    id a = ((id (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"applicationForBundleIdentifier:"));
                    ok = (a != nil);
                }
            }
        }
        if (ok) [m appendFormat:@"%@,", cands[i]];
    }
    return m.length ? m : @"-";
}

static void BKStatus(void)
{
    @try {
        NSString *s = [NSString stringWithFormat:
            @"e%d k%d p%d m%d a=%@ o%d h%d.%d.%d.%d hl=%@ g%d",
            gEvSeen, gKeySeen, gPtrSeen, gPtrMask, BKAppAt(),
            gAct[kBKSlotAim].on, gHookDispatch, gHookHandle, gHookEnqueue,
            gHookDistribute, BKSibling(), gGCOn];
        [s writeToFile:BKPath(@"bk_engine_status.txt") atomically:NO
              encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void BKSelfTest(void)
{
    NSString *hl = @"-";
    void *p = BKSubstrateSym("MSHookFunction", &hl);
    void *q = BKSubstrateSym("MSHookMessageEx", &hl);
    BKAppend(@"T hl=%@ msf=%@ msm=%@ hk=%d", hl, p ? @"1" : @"0", q ? @"1" : @"0", gHooksReady);
    BKStatus();
}

#pragma mark - Hooks

static void BKHookDispatch(BKIOHIDEventSystemClientRef c, BKIOHIDEventRef e)
{
    BKOnEventRaw(e, 1);
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
    NSString *hl = @"-";
    gMSHookFunction = (BKMSHookFunction)BKSubstrateSym("MSHookFunction", &hl);
    gMSHookMessageEx = (BKMSHookMessageEx)BKSubstrateSym("MSHookMessageEx", &hl);

    NSMutableString *rep = [NSMutableString string];

    if (gMSHookFunction && gIO.Dispatch) {
        gMSHookFunction((void *)gIO.Dispatch, (void *)BKHookDispatch, (void **)&origDispatch);
        [rep appendString:@"d"];
    }

    Class sbCls = objc_getClass("SpringBoard");
    Class appCls = objc_getClass("UIApplication");

    if (gMSHookMessageEx) {
        if (sbCls) {
            SEL s = NSSelectorFromString(@"handleEvent:withNewEvent:");
            Method m = class_getInstanceMethod(sbCls, s);
            if (m) {
                gMSHookMessageEx(sbCls, s, (void *)BKHookHandleEvent, (void **)&origHandleEvent);
                [rep appendString:@"h"];
            }
        }
        if (appCls) {
            SEL s = NSSelectorFromString(@"_enqueueHIDEvent:");
            Method m = class_getInstanceMethod(appCls, s);
            if (m) {
                gMSHookMessageEx(appCls, s, (void *)BKHookEnqueue, (void **)&origEnqueueHID);
                [rep appendString:@"e"];
            }
        }
        Class delCls = objc_getClass("BKSHIDEventDeliveryManager");
        if (delCls) {
            SEL s = NSSelectorFromString(@"distributeEvent:");
            Method m = class_getInstanceMethod(delCls, s);
            if (m) {
                gMSHookMessageEx(delCls, s, (void *)BKHookDistribute, (void **)&origDistribute);
                [rep appendString:@"b"];
            }
        }
    }

    gHooksReady = YES;
    BKAppend(@"H hooks=%@ hl=%@", rep.length ? rep : @"-", hl);
    [[NSString stringWithFormat:@"hl=%@ hooks=%@", hl, rep.length ? rep : @"-"]
        writeToFile:BKPath(@"bk_hooks.txt") atomically:NO
         encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - GameController

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
                    ((void (*)(id, SEL, id))objc_msgSend)(m,
                        NSSelectorFromString(@"setMouseMovedHandler:"), mv);

                    id lb = ((id (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"leftButton"));
                    if (lb) {
                        gGCLeft = lb;
                        void (^bh)(id, float, float, float) = ^(id b, float v, float p, float t) {
                            (void)b; (void)p; (void)t;
                            BKHandleButton(0, v > 0.5f);
                        };
                        ((void (*)(id, SEL, id, id))objc_msgSend)(lb,
                            @selector(setValue:forKey:), bh, @"pressedChangedHandler");
                    }
                    id rb = ((id (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"rightButton"));
                    if (rb) {
                        gGCRight = rb;
                        void (^bh)(id, float, float, float) = ^(id b, float v, float p, float t) {
                            (void)b; (void)p; (void)t;
                            BKHandleButton(1, v > 0.5f);
                        };
                        ((void (*)(id, SEL, id, id))objc_msgSend)(rb,
                            @selector(setValue:forKey:), bh, @"pressedChangedHandler");
                    }
                    BKAppend(@"G mouse=1");
                }
            }
        }

        Class kCls = objc_getClass("GCKeyboard");
        if (kCls) {
            SEL co = NSSelectorFromString(@"coalescedKeyboard");
            if ([kCls respondsToSelector:co]) {
                id k = ((id (*)(id, SEL))objc_msgSend)(kCls, co);
                if (k) {
                    id ki = ((id (*)(id, SEL))objc_msgSend)(k, NSSelectorFromString(@"keyboardInput"));
                    if (ki) {
                        gGCKbd = k;
                        gGCKbdIn = ki;
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
        BKAppend(@"! gc %@", e.reason);
    }

    BKMark(@"gc_on.txt");
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
        if (gGCLeft) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(gGCLeft,
                @selector(setValue:forKey:), nil, @"pressedChangedHandler");
        }
        if (gGCRight) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(gGCRight,
                @selector(setValue:forKey:), nil, @"pressedChangedHandler");
        }
        if (gGCKbdIn) {
            ((void (*)(id, SEL, id))objc_msgSend)(gGCKbdIn,
                NSSelectorFromString(@"setKeyChangedHandler:"), nil);
        }
    } @catch (NSException *e) { }
    BKAppend(@"G off");
}

#pragma mark - Processamento

static void BKOnEvent(BKIOHIDEventRef event, int type, int src)
{
    @try {
        if (type == kBKTypePointer) {
            gPtrSeen++;
            double x = gIO.GetFloat(event, kBKFieldPtrX);
            double y = gIO.GetFloat(event, kBKFieldPtrY);
            double sx = gIO.GetFloat(event, kBKFieldSpanX);
            double sy = gIO.GetFloat(event, kBKFieldSpanY);

            if (sx > 1.0 && sy > 1.0) {
                if (gCursorOn) BKCursorAbs(x, y);
                if (gFps) {
                    double w, h;
                    BKPtrSpan(&w, &h);
                    if (gLastPtrValid) {
                        BKFpsMove((x - gLastPtrX) * w / sx, (y - gLastPtrY) * h / sy);
                    }
                }
                gLastPtrX = x;
                gLastPtrY = y;
                gLastPtrValid = YES;
            } else if (gLastPtrValid) {
                double dx = x - gLastPtrX;
                double dy = y - gLastPtrY;
                gLastPtrX = x;
                gLastPtrY = y;
                if (dx != 0.0 || dy != 0.0) {
                    if (gCursorOn) BKCursorMove(dx, dy);
                    if (gFps) BKFpsMove(dx, dy);
                }
            } else {
                gLastPtrX = x;
                gLastPtrY = y;
                gLastPtrValid = YES;
            }

            int mask = gIO.GetInt(event, kBKFieldBtnMask);
            if (mask != gPtrMask) BKPtrButtons(mask);
            return;
        }

        if (type == kBKTypeButton) {
            int idx = gIO.GetInt(event, (kBKTypeButton << 16) | 3u);
            BOOL down = (idx != 0);
            BKHandleButton(0, down);
            BKCaptureHit(1, down ? 1 : 0, @"btn");
            return;
        }

        if (type == kBKTypeKeyboard || type == kBKTypeKeyExtra) {
            int usage = gIO.GetInt(event, 0x0700);
            if (usage <= 0) return;
            BOOL down = gIO.GetInt(event, kBKFieldKeyDown) != 0;
            gKeySeen++;
            BKHandleKey(usage, down);
            if (down) BKCaptureHit(0, usage, @"key");
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
        gHookSeen++;
        if (src == 1) { gHookDispatch++; if (!gMarkDispatch) { gMarkDispatch = YES; BKMark(@"hook_dispatch.txt"); } }
        if (src == 2) { gHookHandle++; if (!gMarkHandle) { gMarkHandle = YES; BKMark(@"hook_handle.txt"); } }
        if (src == 3) { gHookEnqueue++; if (!gMarkEnqueue) { gMarkEnqueue = YES; BKMark(@"hook_enqueue.txt"); } }
        if (src == 4) { gHookDistribute++; if (!gMarkDistribute) { gMarkDistribute = YES; BKMark(@"hook_distribute.txt"); } }

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

static void BKListenCB(void *target, void *refcon, void *service, BKIOHIDEventRef event)
{
    (void)target; (void)refcon; (void)service;
    @try {
        if (!gIO.GetType || !event) return;
        int type = gIO.GetType(event);
        if (type == kBKTypeDigitizer) return;
        if (gIO.GetSender && gIO.GetSender(event) == kBKSenderID) return;
        if (BKSeenRecently(event)) return;
        gLstSeen++;
        gEvSeen++;
        if (!gMarkDispatch) { gMarkDispatch = YES; BKMark(@"hook_listen.txt"); }

        if (!pthread_main_np()) {
            CFRetain(event);
            dispatch_async(dispatch_get_main_queue(), ^{
                BKOnEvent(event, type, 0);
                CFRelease(event);
            });
            return;
        }
        BKOnEvent(event, type, 0);
    } @catch (NSException *e) { }
}

static BKIOHIDEventSystemClientRef BKNewListen(void)
{
    BKIOHIDEventSystemClientRef c = NULL;
    if (gIO.ClientCreateType) c = gIO.ClientCreateType(kCFAllocatorDefault, 2, NULL);
    if (!c && gIO.ClientCreate) {
        c = gIO.ClientCreate(kCFAllocatorDefault);
        if (c && gIO.SetMatching) {
            NSDictionary *m = @{ @"PrimaryUsagePage": @1 };
            gIO.SetMatching(c, (__bridge CFDictionaryRef)m);
        }
    }
    if (!c) return NULL;
    if (gIO.SetQueue) gIO.SetQueue(c, dispatch_get_main_queue());
    else if (gIO.ScheduleRL) gIO.ScheduleRL(c, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    if (gIO.RegisterCB) gIO.RegisterCB(c, (void *)BKListenCB, NULL, NULL);
    if (gIO.Activate) gIO.Activate(c);
    return c;
}

#pragma mark - Inicializacao

__attribute__((constructor)) static void BKInitC(void)
{
    BKMark(@"engine_ctor.txt");
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
        gEnding = [NSMutableSet set];
        gGen = [NSMutableDictionary dictionary];
        gKeyDown = [NSMutableDictionary dictionary];
        gSendQ = dispatch_queue_create("com.wjf.ballkey.send", DISPATCH_QUEUE_SERIAL);

        if (!BKInitIO()) { BKAppend(@"! io"); BKStatus(); return; }
        BKMark(@"engine_io.txt");

        gSendClient = gIO.ClientCreate(kCFAllocatorDefault);
        BKAppend(gSendClient ? @"I send=1" : @"I send=0");

        @try {
            gListenClient = BKNewListen();
            if (!gListenClient) BKAppend(@"! listen");
            else BKMark(@"engine_listen.txt");
        } @catch (NSException *e) { }

        BKLoadConfig();
        BKInstallHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{ @try { BKGCStart(); } @catch (NSException *e) { } });

        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                       dispatch_get_main_queue());
        if (src) {
            dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 150ull * NSEC_PER_MSEC),
                                      150ull * NSEC_PER_MSEC, 30ull * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(src, ^{
                @try {
                    static int tick = 0;
                    tick++;
                    BKCaptureWatch();
                    if (tick == 14) BKSelfTest();
                    if (tick == 20 && !gGCOn) BKGCStart();
                    if (tick == 90 && gHookSeen > 0 && gGCOn) BKGCStop();
                    if (tick == 70 && gEvSeen == 0) BKMark(@"hook_none.txt");
                    if (tick % 6 == 0) BKStatus();
                    if (tick % 40 == 0) BKLoadConfig();
                    if (tick % 5 == 0) BKFrontTick();
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
