// BallKey/Engine/Tweak.x
// Motor de toque. Sem logos: constructor C no fim do arquivo.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <os/lock.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

#define kBKTypeKey          3
#define kBKTypeDigitizer    11
#define kBKTypeMove         12
#define kBKTypePointer      17
#define kBKTypeButton       2
#define kBKTypeBtn          32

#define kBKFieldKeyPage     ((kBKTypeKey << 16) | 0)
#define kBKFieldKeyUsage    ((kBKTypeKey << 16) | 1)
#define kBKFieldKeyDown     ((kBKTypeKey << 16) | 2)
#define kBKFieldKeyRepeat   ((kBKTypeKey << 16) | 3)

#define kBKFieldBtnMask     ((kBKTypeDigitizer << 16) | 3)
#define kBKFieldX           ((kBKTypeDigitizer << 16) | 0)
#define kBKFieldY           ((kBKTypeDigitizer << 16) | 1)

#define kBKSenderId         0x8000000817319372ULL

#define kBKParentBase       99
#define kBKChildBase        1
#define kBKChildIdentityBase 3

#define kBKIdxCursor        40
#define kBKIdxMira          70
#define kBKIdxAds           71
#define kBKIdxDir           72
#define kBKIdxFogo          73
#define kBKIdxMirar         74

#define kBKPhBegan          0x03
#define kBKPhMoved          0x04
#define kBKPhEnded          0x02

#define kBKBtnLockNs        100000000ULL
#define kBKKey3GraceNs      80000000ULL
#define kBKTravaGuardNs     250000000ULL
#define kBKMoveDedupNs      4000000ULL
#define kBKCapIgnoreNs      120000000ULL
#define kBKRelDedupNs       180000000ULL
#define kBKTapNs            45

#define kBKMoveFactor       0.0015
#define kBKBoxR             0.08
#define kBKAnchorX          0.5
#define kBKAnchorY          0.5
#define kBKCursorMinX       0.06
#define kBKCursorMaxX       0.94
#define kBKCursorMinY       0.08
#define kBKCursorMaxY       0.92

#define kBKPageBtn          12
#define kBKUsageBtnBase     64
#define kBKMaxBtn           3

#define kBKKeyTrava         224
#define kBKKeyTravaAlt      228
#define kBKKeyRun           225

static NSString *const kBKNotifyReload = @"com.wjf.ballkey.reload";
static NSString *const kBKNotifyTest   = @"com.wjf.ballkey.test";
static NSString *const kBKNotifyProbe  = @"com.wjf.ballkey.probe";
static NSString *const kBKNotifyClose  = @"com.wjf.ballkey.close";

// ---------------------------------------------------------------- estado

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static IOHIDEventSystemClientRef gClient = NULL;
static void *gHid = NULL;
static BOOL gReady = NO;

static NSMutableDictionary *gCfg = nil;
static NSString *gBundle = @"";
static BOOL gHasProfile = NO;

static BOOL gEnabled = YES;
static BOOL gTrava = NO;
static BOOL gFps = NO;
static BOOL gCap = NO;
static BOOL gDump = NO;

static int gOrient = 1;
static uint64_t gLastKey3 = 0;
static uint64_t gLastTrava = 0;
static uint64_t gLastMove = 0;
static uint64_t gLastRel = 0;
static uint64_t gCapIgnore = 0;

static BOOL gSlotDown[3] = {NO, NO, NO};
static double gSlotX[3] = {0, 0, 0};
static double gSlotY[3] = {0, 0, 0};

static BOOL gBtnDown[3] = {NO, NO, NO};
static uint64_t gBtnNs[3] = {0, 0, 0};

static double gCurX = kBKAnchorX;
static double gCurY = kBKAnchorY;

static int gCapKey = -1;
static int gCapSel = kBKIdxFogo;
static NSString *gCapBundle = nil;

static id gOverlay = nil;

static void BKReleaseAll(void);
static void BKHIDCallback(void *target, void *refcon, void *sender, IOHIDEventRef event);

// ---------------------------------------------------------------- utilidades

static uint64_t BKNow(void) {
    static mach_timebase_info_data_t tb;
    static BOOL once = NO;
    if (!once) { mach_timebase_info(&tb); once = YES; }
    return mach_absolute_time() * tb.numer / tb.denom;
}

static NSString *BKRoot(void) {
    static NSString *root = nil;
    if (root) return root;
    NSArray *cand = @[
        @"/var/mobile/Containers/Shared/AppGroup/.jbroot-C4160B2A6F5AE523/",
        @"/private/var/mobile/Containers/Shared/AppGroup/.jbroot-C4160B2A6F5AE523/",
        @"/var/jb/var/mobile/",
        @"/var/mobile/",
        NSTemporaryDirectory()
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in cand) {
        if ([fm isWritableFileAtPath:p]) { root = p; break; }
    }
    if (!root) root = NSTemporaryDirectory();
    return root;
}

static NSString *BKPath(NSString *name) {
    return [BKRoot() stringByAppendingString:name];
}

static void BKLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    static NSDateFormatter *df = nil;
    static BOOL once = NO;
    if (!once) {
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        once = YES;
    }

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], s];
    NSString *p = BKPath(@"bk_debug.log");
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) {
        [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (NSException *e) { }
    [fh closeFile];
}

static void BKMark(NSString *name) {
    [@"1" writeToFile:BKPath(name) atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BKStatus(void) {
    NSString *s = [NSString stringWithFormat:@"en=%d trava=%d fps=%d cap=%d b=%@ n=%lu\n",
                   gEnabled ? 1 : 0, gTrava ? 1 : 0, gFps ? 1 : 0, gCap ? 1 : 0,
                   gBundle, (unsigned long)[gCfg[@"apps"][gBundle][@"pts"] count]];
    [s writeToFile:BKPath(@"bk_status.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static double BKClamp(double v) {
    if (v < 0) return 0;
    if (v > 1) return 1;
    return v;
}

static BOOL BKPontoValido(double x, double y) {
    if (x != x || y != y) return NO;
    if (x < 0.0 || x > 1.0) return NO;
    if (y < 0.0 || y > 1.0) return NO;
    return YES;
}

// ---------------------------------------------------------------- orientação

static int BKFrontOrientation(void) {
    Class sb = objc_getClass("SpringBoard");
    if (sb) {
        SEL sel = @selector(sharedApplication);
        if ([sb respondsToSelector:sel]) {
            id app = ((id (*)(id, SEL))objc_msgSend)(sb, sel);
            SEL s2 = @selector(_frontMostAppOrientation);
            if (app && [app respondsToSelector:s2]) {
                int o = (int)((int (*)(id, SEL))objc_msgSend)(app, s2);
                if (o >= 1 && o <= 4) return o;
            }
        }
    }
    return 0;
}

static int BKDeviceOrientation(void) {
    Class c = objc_getClass("UIDevice");
    if (!c) return 0;
    id d = ((id (*)(id, SEL))objc_msgSend)(c, @selector(currentDevice));
    if (!d) return 0;
    int o = (int)((int (*)(id, SEL))objc_msgSend)(d, @selector(orientation));
    return (o >= 1 && o <= 4) ? o : 0;
}

static int BKOr(void) {
    int o = BKFrontOrientation();
    if (o) { gOrient = o; return o; }
    o = BKDeviceOrientation();
    if (o) { gOrient = o; return o; }
    if (gOrient >= 1 && gOrient <= 4) return gOrient;
    return 1;
}

// paisagem esquerda e direita são 180° entre si: 3 = (1-y, x), 4 = (y, 1-x)
static void BKConv(double x, double y, int o, double *ox, double *oy) {
    double rx = x, ry = y;
    switch (o) {
        case 2: rx = 1.0 - x; ry = 1.0 - y; break;
        case 3: rx = 1.0 - y; ry = x;       break;
        case 4: rx = y;       ry = 1.0 - x; break;
        default: break;
    }
    *ox = BKClamp(rx);
    *oy = BKClamp(ry);
}

static void BKConvInv(double vx, double vy, int o, double *ox, double *oy) {
    double rx = vx, ry = vy;
    switch (o) {
        case 2: rx = 1.0 - vx; ry = 1.0 - vy; break;
        case 3: rx = vy;       ry = 1.0 - vx; break;
        case 4: rx = 1.0 - vy; ry = vx;       break;
        default: break;
    }
    *ox = BKClamp(rx);
    *oy = BKClamp(ry);
}

// ---------------------------------------------------------------- injeção

typedef IOHIDEventRef (*BKCreateFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                          uint32_t, double, double, double, double, double,
                                          uint32_t, uint32_t, uint32_t);
typedef int32_t (*BKGetIntFn)(IOHIDEventRef, uint32_t);
typedef uint32_t (*BKGetTypeFn)(IOHIDEventRef);
typedef void (*BKDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*BKSetSenderFn)(IOHIDEventRef, uint64_t);

static BKCreateFingerFn bkCreate = NULL;
static BKGetIntFn bkGetInt = NULL;
static BKGetTypeFn bkGetType = NULL;
static BKDispatchFn bkDispatch = NULL;
static BKSetSenderFn bkSetSender = NULL;

static void BKInject(int phase, int slot, double x, double y) {
    if (!gClient || !gReady || !bkCreate || !bkDispatch) return;

    double dx, dy;
    BKConv(x, y, BKOr(), &dx, &dy);

    int ph = kBKPhMoved;
    if (phase == 1) ph = kBKPhBegan;
    else if (phase == 3) ph = kBKPhEnded;

    IOHIDEventRef ev = bkCreate(kCFAllocatorDefault, 0,
                                (uint32_t)slot,
                                (uint32_t)(kBKChildIdentityBase + slot),
                                (uint32_t)ph, dx, dy, 0.0, 1.0, 0.0, 1, 1, 0);
    if (!ev) return;

    if (bkSetSender) bkSetSender(ev, kBKSenderId);
    bkDispatch(gClient, ev);
    CFRelease(ev);

    if (gDump) BKLog(@"D ph=%d s=%d o=%d x=%.3f y=%.3f", phase, slot, gOrient, dx, dy);
}

static void BKSlotPress(int slot, double x, double y) {
    if (gSlotDown[slot]) return;
    gSlotDown[slot] = YES;
    gSlotX[slot] = x;
    gSlotY[slot] = y;
    BKInject(1, slot, x, y);
}

static void BKSlotMove(int slot, double x, double y) {
    if (!gSlotDown[slot]) return;
    if (fabs(x - gSlotX[slot]) < 0.0005 && fabs(y - gSlotY[slot]) < 0.0005) return;
    gSlotX[slot] = x;
    gSlotY[slot] = y;
    BKInject(2, slot, x, y);
}

static void BKSlotRelease(int slot) {
    if (!gSlotDown[slot]) return;
    gSlotDown[slot] = NO;
    BKInject(3, slot, gSlotX[slot], gSlotY[slot]);
}

static void BKSlotReleaseAll(void) {
    for (int i = 1; i <= 2; i++) BKSlotRelease(i);
}

static void BKTapAt(int slot, double x, double y) {
    BKSlotPress(slot, x, y);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kBKTapNs * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        BKSlotRelease(slot);
    });
}

// ---------------------------------------------------------------- configuração

static NSMutableDictionary *BKApp(void) {
    if (!gCfg) gCfg = [NSMutableDictionary dictionary];
    NSMutableDictionary *apps = gCfg[@"apps"];
    if (![apps isKindOfClass:[NSMutableDictionary class]]) {
        apps = [NSMutableDictionary dictionary];
        gCfg[@"apps"] = apps;
    }
    NSMutableDictionary *a = apps[gBundle];
    if (![a isKindOfClass:[NSMutableDictionary class]]) {
        a = [NSMutableDictionary dictionary];
        apps[gBundle] = a;
    }
    if (![a[@"pts"] isKindOfClass:[NSMutableDictionary class]]) a[@"pts"] = [NSMutableDictionary dictionary];
    if (![a[@"keys"] isKindOfClass:[NSMutableDictionary class]]) a[@"keys"] = [NSMutableDictionary dictionary];
    return a;
}

static NSMutableDictionary *BKPts(void) { return BKApp()[@"pts"]; }
static NSMutableDictionary *BKKeys(void) { return BKApp()[@"keys"]; }

static void BKLoadConfig(void) {
    gHasProfile = NO;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:BKPath(@"com.wjf.ballkey.plist")];
    gCfg = d ? [d mutableCopy] : [NSMutableDictionary dictionary];

    // chave ausente conta como ligado: era o que deixava en=0 em tudo
    gEnabled = gCfg[@"enabled"] ? [gCfg[@"enabled"] boolValue] : YES;

    NSDictionary *apps = gCfg[@"apps"];
    if ([apps isKindOfClass:[NSDictionary class]] && apps[gBundle]) gHasProfile = YES;

    BKLog(@"C en=%d b=%@ n=%lu key=%d", gEnabled ? 1 : 0, gBundle,
          (unsigned long)[gCfg[@"apps"][gBundle][@"pts"] count], [gCfg[@"key"] intValue]);
}

static void BKSaveConfig(void) {
    if (!gCfg) return;
    gCfg[@"enabled"] = @(gEnabled);
    [gCfg writeToFile:BKPath(@"com.wjf.ballkey.plist") atomically:YES];
    BKLog(@"ov save: %lu marcadores em %@",
          (unsigned long)[gCfg[@"apps"][gBundle][@"pts"] count], gBundle);
    BKStatus();
}

static void BKPonto(int idx, double x, double y) {
    if (!BKPontoValido(x, y)) return;
    BKPts()[[@(idx) stringValue]] = [NSString stringWithFormat:@"%.4f,%.4f", x, y];
}

static BOOL BKGetPonto(int idx, double *x, double *y) {
    NSString *s = BKPts()[[@(idx) stringValue]];
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSArray *p = [s componentsSeparatedByString:@","];
    if (p.count < 2) return NO;
    double px = [p[0] doubleValue], py = [p[1] doubleValue];
    if (!BKPontoValido(px, py)) return NO;
    *x = px; *y = py;
    return YES;
}

static int BKIdxDaTecla(NSString *enc) {
    NSDictionary *keys = BKKeys();
    for (NSString *k in keys) {
        if ([keys[k] isEqualToString:enc]) return [k intValue];
    }
    return -1;
}

// ---------------------------------------------------------------- FPS

static void BKFpsOn(void) {
    if (gFps) return;
    gFps = YES;
    gCurX = kBKAnchorX;
    gCurY = kBKAnchorY;
    BKSlotPress(1, gCurX, gCurY);
    BKLog(@"F on centro");
    BKStatus();
}

static void BKFpsOff(void) {
    if (!gFps) return;
    gFps = NO;
    BKSlotRelease(1);
    gCurX = kBKAnchorX;
    gCurY = kBKAnchorY;
    BKLog(@"F off");
    BKStatus();
}

static void BKFpsMove(double dx, double dy) {
    if (!gFps) return;

    double nx = gCurX + dx * kBKMoveFactor;
    double ny = gCurY + dy * kBKMoveFactor;

    double lo = kBKAnchorX - kBKBoxR, hi = kBKAnchorX + kBKBoxR;
    double lo2 = kBKAnchorY - kBKBoxR, hi2 = kBKAnchorY + kBKBoxR;

    BOOL bateu = NO;
    if (nx < lo) { nx = lo; bateu = YES; }
    if (nx > hi) { nx = hi; bateu = YES; }
    if (ny < lo2) { ny = lo2; bateu = YES; }
    if (ny > hi2) { ny = hi2; bateu = YES; }

    if (bateu) {
        gCurX = kBKAnchorX;
        gCurY = kBKAnchorY;
        BKSlotRelease(1);
        BKSlotPress(1, gCurX, gCurY);
        BKLog(@"F recuo");
        return;
    }

    gCurX = nx;
    gCurY = ny;
    BKSlotMove(1, nx, ny);
}

// ---------------------------------------------------------------- cursor

static void BKCursorMove(double dx, double dy) {
    gCurX = BKClamp(gCurX + dx * kBKMoveFactor);
    gCurY = BKClamp(gCurY + dy * kBKMoveFactor);
    if (gCurX < kBKCursorMinX) gCurX = kBKCursorMinX;
    if (gCurX > kBKCursorMaxX) gCurX = kBKCursorMaxX;
    if (gCurY < kBKCursorMinY) gCurY = kBKCursorMinY;
    if (gCurY > kBKCursorMaxY) gCurY = kBKCursorMaxY;
}

// ---------------------------------------------------------------- botões

static void BKHandleButton(int b, BOOL down) {
    if (down) {
        uint64_t now = BKNow();
        if (gBtnDown[b]) return;
        if (now - gBtnNs[b] < kBKBtnLockNs) return;
        gBtnDown[b] = YES;
        gBtnNs[b] = now;

        if (gCap) {
            int alvo = (gCapKey > 0) ? gCapKey : gCapSel;
            if (gCapKey > 0) {
                BKKeys()[[@(alvo) stringValue]] = [NSString stringWithFormat:@"k:%d", gCapKey];
            }
            BKPonto(alvo, gCurX, gCurY);
            BKLog(@"B m:%d cap=%d x=%.3f y=%.3f", b, alvo, gCurX, gCurY);
            BKSaveConfig();
            gCapKey = -1;
            gCap = NO;
            gCapIgnore = BKNow() + kBKCapIgnoreNs;
            BKTapAt(2, gCurX, gCurY);
            return;
        }

        if (gFps) {
            if (b == 0) {
                double fx, fy;
                if (BKGetPonto(kBKIdxFogo, &fx, &fy)) {
                    BKTapAt(2, fx, fy);
                    BKLog(@"B m:0 fogo %.3f,%.3f", fx, fy);
                } else {
                    BKLog(@"B m:0 fogo sem ponto");
                }
                return;
            }
            if (b == 1) {
                double ax, ay;
                if (BKGetPonto(kBKIdxMirar, &ax, &ay)) {
                    BKSlotPress(2, ax, ay);
                    BKLog(@"B m:1 mirar %.3f,%.3f", ax, ay);
                }
                return;
            }
        }

        NSString *enc = [NSString stringWithFormat:@"m:%d", b];
        int idx = BKIdxDaTecla(enc);
        if (idx >= 0) {
            double px, py;
            if (BKGetPonto(idx, &px, &py)) {
                BKTapAt(2, px, py);
                BKLog(@"B %@ hit=%d", enc, idx);
                return;
            }
        }
        BKTapAt(2, gCurX, gCurY);
        BKLog(@"B %@ hit=0", enc);
        return;
    }

    if (!gBtnDown[b]) {
        BKLog(@"B m:%d orfao", b);
        return;
    }
    gBtnDown[b] = NO;
    BKSlotRelease(2);
}

// ---------------------------------------------------------------- teclas

static void BKHandleKey(int usage, BOOL down) {
    if (!down) {
        if (usage == kBKKeyRun) BKSlotRelease(3);
        return;
    }

    if (gCap) {
        gCapKey = usage;
        BKLog(@"armar=k:%d alvo=%d", usage, gCapSel);
        return;
    }

    if (usage == kBKKeyTrava || usage == kBKKeyTravaAlt) {
        uint64_t now = BKNow();
        if (now - gLastTrava < kBKTravaGuardNs) return;
        gLastTrava = now;
        gTrava = !gTrava;
        if (gTrava) BKFpsOn(); else BKFpsOff();
        BKLog(@"F trava=%d", gTrava ? 1 : 0);
        return;
    }

    if (usage == kBKKeyRun) {
        double dx, dy;
        if (BKGetPonto(kBKIdxDir, &dx, &dy)) BKSlotPress(3, dx, dy);
        else BKSlotPress(3, 0.10, 0.80);
        return;
    }

    NSString *enc = [NSString stringWithFormat:@"k:%d", usage];
    int idx = BKIdxDaTecla(enc);
    if (idx < 0) {
        BKLog(@"K %d hit=0", usage);
        return;
    }

    double px, py;
    if (!BKGetPonto(idx, &px, &py)) {
        BKLog(@"K %d sem ponto", usage);
        return;
    }
    BKTapAt(2, px, py);
    BKLog(@"K %d hit=%d", usage, idx);
}

// ---------------------------------------------------------------- captura

static void BKCaptureWatch(void) {
    if (gCap) return;
    NSString *req = [NSString stringWithContentsOfFile:BKPath(@"bk_capture_req.txt")
                                             encoding:NSUTF8StringEncoding error:nil];
    if (!req.length) return;
    [[NSFileManager defaultManager] removeItemAtPath:BKPath(@"bk_capture_req.txt") error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:BKPath(@"bk_capture_result.txt") error:nil];

    NSArray *p = [req componentsSeparatedByString:@"|"];
    gCapSel = [p[0] intValue];
    if (p.count > 1 && [p[1] length]) {
        gCapBundle = p[1];
        gBundle = gCapBundle;
        BKLoadConfig();
    }
    gCapKey = -1;
    gCap = YES;
    gCapIgnore = BKNow() + kBKCapIgnoreNs;
    BKLog(@"@ arm alvo=%d b=%@", gCapSel, gBundle);
}

static void BKCaptureDone(int idx) {
    NSString *s = [NSString stringWithFormat:@"%d|%.4f,%.4f", idx, gCurX, gCurY];
    [s writeToFile:BKPath(@"bk_capture_result.txt") atomically:YES
          encoding:NSUTF8StringEncoding error:nil];
}

// ---------------------------------------------------------------- despejo

static void BKDump(IOHIDEventRef ev, uint32_t type, uint64_t sender) {
    if (!gDump) return;
    int f0 = bkGetInt ? bkGetInt(ev, (type << 16) | 0) : 0;
    int f1 = bkGetInt ? bkGetInt(ev, (type << 16) | 1) : 0;
    int f2 = bkGetInt ? bkGetInt(ev, (type << 16) | 2) : 0;
    int f3 = bkGetInt ? bkGetInt(ev, (type << 16) | 3) : 0;
    BKLog(@"E t=%u s=%llu f=%d,%d,%d,%d", type, sender, f0, f1, f2, f3);
}

// ---------------------------------------------------------------- callback

static void BKHIDCallback(void *target, void *refcon, void *sender, IOHIDEventRef ev) {
    @autoreleasepool {
        if (!ev || !bkGetType) return;
        uint32_t type = bkGetType(ev);

        if (type == kBKTypeKey) {
            int page = bkGetInt ? bkGetInt(ev, kBKFieldKeyPage) : 0;
            int usage = bkGetInt ? bkGetInt(ev, kBKFieldKeyUsage) : 0;
            int down = bkGetInt ? bkGetInt(ev, kBKFieldKeyDown) : 0;
            int rep = bkGetInt ? bkGetInt(ev, kBKFieldKeyRepeat) : 0;

            if (page == kBKPageBtn && usage >= kBKUsageBtnBase &&
                usage < kBKUsageBtnBase + kBKMaxBtn) {
                BKHandleButton(usage - kBKUsageBtnBase, down != 0);
                return;
            }

            if ((page == 0 || page == 7) && usage >= 4 && usage <= 231) {
                if (rep && down) return;
                BKLog(@"K %d d=%d", usage, down);
                BKHandleKey(usage, down != 0);
            }
            return;
        }

        if (type == kBKTypePointer) {
            int f0 = bkGetInt ? bkGetInt(ev, (type << 16) | 0) : 0;
            int f1 = bkGetInt ? bkGetInt(ev, (type << 16) | 1) : 0;
            int f3 = bkGetInt ? bkGetInt(ev, (type << 16) | 3) : 0;

            if (f3 == 1) { BKHandleButton(0, YES); return; }
            if (f3 == 2) { BKHandleButton(0, NO); return; }
            if (f0 == 0 && f1 == 0) return;

            uint64_t now = BKNow();
            if (now - gLastMove < kBKMoveDedupNs) return;
            gLastMove = now;

            if (gCap && now > gCapIgnore) { BKCursorMove(f0, f1); return; }
            if (gFps) BKFpsMove(f0, f1); else BKCursorMove(f0, f1);
            return;
        }

        if (type == kBKTypeMove) {
            int f0 = bkGetInt ? bkGetInt(ev, (type << 16) | 0) : 0;
            int f1 = bkGetInt ? bkGetInt(ev, (type << 16) | 1) : 0;
            if (f0 == 0 && f1 == 0) return;

            uint64_t now = BKNow();
            if (now - gLastMove < kBKMoveDedupNs) return;
            gLastMove = now;

            if (gFps) BKFpsMove(f0, f1); else BKCursorMove(f0, f1);
            return;
        }

        if (type == kBKTypeButton || type == kBKTypeBtn) {
            int num = bkGetInt ? bkGetInt(ev, (type << 16) | 0) : 0;
            int st = bkGetInt ? bkGetInt(ev, (type << 16) | 1) : 0;
            if (num < 0 || num > 2) num = 0;
            BKHandleButton(num, st != 0);
            return;
        }

        BKDump(ev, type, 0);
    }
}

// ---------------------------------------------------------------- ciclo

static void BKFrontApp(void) {
    NSString *b = nil;
    Class ls = NSClassFromString(@"LSApplicationWorkspace");
    if (ls) {
        id ws = [ls performSelector:@selector(defaultWorkspace)];
        if (ws) {
            NSArray *apps = [ws performSelector:@selector(runningApplications)];
            for (id a in apps) {
                id at = [a performSelector:@selector(applicationType)];
                if ([at isEqual:@(1)]) {
                    b = [a performSelector:@selector(bundleIdentifier)];
                    break;
                }
            }
        }
    }
    if (!b.length) b = [NSBundle mainBundle].bundleIdentifier;
    if (!b.length) return;
    if (![b isEqualToString:gBundle]) {
        gBundle = b;
        BKLoadConfig();
        if (gOverlay) [(id)gOverlay performSelector:@selector(atualizar)];
    }
}

static void BKReload(void) {
    BKFrontApp();
    BKLoadConfig();
    BKLog(@"ov reload b=%@", gBundle);
    if (gOverlay) [(id)gOverlay performSelector:@selector(atualizar)];
}

static void BKNotifySetup(void) {
    int token = 0;
    notify_register_dispatch(kBKNotifyReload.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        BKReload();
    });
    notify_register_dispatch(kBKNotifyTest.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        BKLog(@"ov test");
        BKTapAt(2, gCurX, gCurY);
    });
    notify_register_dispatch(kBKNotifyProbe.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        BKFrontApp();
        BKLog(@"ov probe b=%@ n=%lu", gBundle,
              (unsigned long)[gCfg[@"apps"][gBundle][@"pts"] count]);
    });
    notify_register_dispatch(kBKNotifyClose.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        if (gOverlay) [(id)gOverlay performSelector:@selector(fechar)];
    });
}

// ---------------------------------------------------------------- overlay

@interface BKOverlay : NSObject
- (void)iniciar;
- (void)atualizar;
- (void)fechar;
@end

@implementation BKOverlay {
    UIWindow *_win;
    UIView *_ball;
    UIView *_panel;
    UILabel *_status;
    UIScrollView *_lista;
    NSTimer *_timer;
    BOOL _aberto;
}

- (UIWindow *)janela {
    if (_win) return _win;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [[UIViewController alloc] init];
    w.hidden = NO;
    _win = w;
    return w;
}

- (void)iniciar {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)1200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [self montarBola];
        self->_timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            [self atualizar];
        }];
        [self atualizar];
    });
}

- (void)montarBola {
    UIWindow *w = [self janela];
    if (_ball) return;
    _ball = [[UIView alloc] initWithFrame:CGRectMake(20, 120, 48, 48)];
    _ball.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _ball.layer.cornerRadius = 24;
    _ball.layer.borderWidth = 1;
    _ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
    UILabel *l = [[UILabel alloc] initWithFrame:_ball.bounds];
    l.text = @"BK";
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont boldSystemFontOfSize:15];
    [_ball addSubview:l];
    [w addSubview:_ball];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(abrir)];
    [_ball addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(arrastarBola:)];
    [_ball addGestureRecognizer:pan];
}

- (void)arrastarBola:(UIPanGestureRecognizer *)g {
    CGPoint p = [g translationInView:_ball.superview];
    CGPoint c = _ball.center;
    c.x += p.x;
    c.y += p.y;
    _ball.center = c;
    [g setTranslation:CGPointZero inView:_ball.superview];
}

- (void)abrir {
    if (_aberto) { [self fechar]; return; }
    _aberto = YES;
    [self montarPainel];
    [self atualizar];
}

- (void)montarPainel {
    UIWindow *w = [self janela];
    CGFloat larg = 250, alt = 420;
    if (_panel) [_panel removeFromSuperview];
    _panel = [[UIView alloc] initWithFrame:CGRectMake(w.bounds.size.width - larg - 10, 90, larg, alt)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    _panel.layer.cornerRadius = 12;

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, larg - 24, 20)];
    t.text = @"BallKey";
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:16];
    [_panel addSubview:t];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(12, 32, larg - 24, 34)];
    _status.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    _status.font = [UIFont systemFontOfSize:11];
    _status.numberOfLines = 2;
    [_panel addSubview:_status];

    _lista = [[UIScrollView alloc] initWithFrame:CGRectMake(8, 70, larg - 16, alt - 170)];
    _lista.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    _lista.layer.cornerRadius = 8;
    [_panel addSubview:_lista];

    NSArray *nomes = @[@"Adicionar alvo", @"Limpar direção", @"Limpar tudo",
                       @"FPS", @"Dump", @"Fechar"];
    CGFloat y = alt - 94;
    for (NSUInteger i = 0; i < nomes.count; i++) {
        CGFloat x = 10 + (i % 2) * 120;
        if (i % 2 == 0 && i) y += 30;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(x, y, 110, 26);
        [b setTitle:nomes[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
        b.layer.cornerRadius = 6;
        b.titleLabel.font = [UIFont systemFontOfSize:11];
        b.tag = 100 + (int)i;
        [b addTarget:self action:@selector(acao:) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:b];
    }

    [w addSubview:_panel];
}

- (void)acao:(UIButton *)b {
    NSInteger i = b.tag - 100;
    NSMutableDictionary *a = BKApp();

    if (i == 0) {
        NSInteger max = -1;
        for (NSString *k in a[@"pts"]) {
            NSInteger v = [k integerValue];
            if (v > max && v < 70) max = v;
        }
        NSInteger novo = (max < 0) ? 0 : max + 1;
        BKPonto((int)novo, gCurX, gCurY);
        BKSaveConfig();
        [self armar:(int)novo];
        return;
    }
    if (i == 1) {
        [a[@"pts"] removeObjectForKey:[@(kBKIdxDir) stringValue]];
        BKSaveConfig();
        [self atualizar];
        return;
    }
    if (i == 2) {
        [a[@"pts"] removeAllObjects];
        [a[@"keys"] removeAllObjects];
        BKSaveConfig();
        BKLog(@"ov limpar: tudo");
        [self atualizar];
        return;
    }
    if (i == 3) {
        gTrava = !gTrava;
        if (gTrava) BKFpsOn(); else BKFpsOff();
        [self atualizar];
        return;
    }
    if (i == 4) {
        gDump = !gDump;
        BKLog(@"ov dump=%d", gDump ? 1 : 0);
        [self atualizar];
        return;
    }
    [self fechar];
}

- (void)armar:(int)idx {
    NSString *b = gBundle.length ? gBundle : @"";
    NSString *req = [NSString stringWithFormat:@"%d|%@", idx, b];
    [req writeToFile:BKPath(@"bk_capture_req.txt") atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    gCap = YES;
    gCapSel = idx;
    [self atualizar];
}

- (void)atualizar {
    if (!_aberto || !_panel) return;

    NSString *res = [NSString stringWithContentsOfFile:BKPath(@"bk_capture_result.txt")
                                             encoding:NSUTF8StringEncoding error:nil];
    if (res.length) {
        [[NSFileManager defaultManager] removeItemAtPath:BKPath(@"bk_capture_result.txt") error:nil];
        gCap = NO;
    }

    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:BKPath(@"com.wjf.ballkey.plist")];
    NSDictionary *pts = d[@"apps"][gBundle][@"pts"];
    NSDictionary *keys = d[@"apps"][gBundle][@"keys"];

    _status.text = [NSString stringWithFormat:@"b=%@\nn=%lu  trava=%d  cap=%d",
                    gBundle.length ? gBundle : @"(nenhum)",
                    (unsigned long)[pts count], gTrava ? 1 : 0, gCap ? 1 : 0];

    for (UIView *v in _lista.subviews) [v removeFromSuperview];

    NSArray *ords = [[pts allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [a integerValue] < [b integerValue] ? NSOrderedAscending : NSOrderedDescending;
    }];

    CGFloat y = 6;
    for (NSString *k in ords) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(8, y, 150, 26)];
        NSString *enc = keys[k] ?: @"?";
        l.text = [NSString stringWithFormat:@"%@  %@", k, enc];
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:12];
        [_lista addSubview:l];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(160, y, 60, 26);
        [b setTitle:@"Alvo" forState:UIControlStateNormal];
        b.backgroundColor = ([k intValue] == gCapSel) ? [UIColor orangeColor]
                                                     : [UIColor colorWithWhite:0.3 alpha:1];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:11];
        b.tag = 1000 + [k intValue];
        [b addTarget:self action:@selector(alvo:) forControlEvents:UIControlEventTouchUpInside];
        [_lista addSubview:b];

        y += 30;
    }
    _lista.contentSize = CGSizeMake(_lista.bounds.size.width, y);
}

- (void)alvo:(UIButton *)b {
    [self armar:(int)(b.tag - 1000)];
}

- (void)fechar {
    _aberto = NO;
    [_panel removeFromSuperview];
    _panel = nil;
    _lista = nil;
    _status = nil;
}

@end

// ---------------------------------------------------------------- inicialização

static void BKInit(void) {
    gHid = dlopen("/usr/lib/libIOHID.dylib", RTLD_LAZY);
    if (!gHid) gHid = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    BKLog(@"I hid=%d", gHid ? 1 : 0);
    if (!gHid) return;

    bkGetInt = (BKGetIntFn)dlsym(gHid, "IOHIDEventGetIntegerValue");
    bkGetType = (BKGetTypeFn)dlsym(gHid, "IOHIDEventGetType");
    bkDispatch = (BKDispatchFn)dlsym(gHid, "IOHIDEventSystemClientDispatchEvent");
    bkSetSender = (BKSetSenderFn)dlsym(gHid, "IOHIDEventSetSenderID");
    bkCreate = (BKCreateFingerFn)dlsym(gHid, "IOHIDEventCreateDigitizerFingerEvent");
    if (!bkGetInt || !bkGetType) { BKLog(@"E sem leitura"); return; }

    typedef IOHIDEventSystemClientRef (*BKCreateClientFn)(CFAllocatorRef);
    BKCreateClientFn create = (BKCreateClientFn)dlsym(gHid, "IOHIDEventSystemClientCreate");
    if (!create) { BKLog(@"E sem client"); return; }
    gClient = create(kCFAllocatorDefault);
    if (!gClient) { BKLog(@"E client nulo"); return; }

    typedef void (*BKRegisterFn)(IOHIDEventSystemClientRef, void *, void *, void *);
    BKRegisterFn reg = (BKRegisterFn)dlsym(gHid,
                                           "IOHIDEventSystemClientRegisterEventCallback");
    if (reg) {
        reg(gClient, (void *)BKHIDCallback, NULL, NULL);
        BKLog(@"I listen=1");
    }

    typedef void (*BKStartFn)(IOHIDEventSystemClientRef, CFStringRef);
    BKStartFn start = (BKStartFn)dlsym(gHid, "IOHIDEventSystemClientScheduleWithRunLoop");
    if (start) start(gClient, CFRunLoopGetMain());
    else {
        typedef void (*BKStart2Fn)(IOHIDEventSystemClientRef, dispatch_queue_t);
        BKStart2Fn s2 = (BKStart2Fn)dlsym(gHid, "IOHIDEventSystemClientStartQueue");
        if (s2) s2(gClient, dispatch_get_main_queue());
    }

    gReady = YES;
    BKMark(@"engine_loaded.txt");
    BKLog(@"I ready");

    BKNotifySetup();

    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        BKOverlay *ov = [[BKOverlay alloc] init];
        gOverlay = ov;
        [ov iniciar];
    }

    [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer *t) {
        BKCaptureWatch();
    }];
}

__attribute__((constructor)) static void BKInitCtor(void) {
    @autoreleasepool {
        BKMark(@"engine_ctor.txt");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)900 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            @try { BKInit(); }
            @catch (NSException *e) { BKLog(@"E init %@", e.reason); }
        });
    }
}
