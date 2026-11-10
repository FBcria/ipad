// BallKey/Engine/Tweak.x

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <math.h>

#define kBKFieldBtnMask             ((11 << 16) | 3)
#define kBKSenderId                 0x8000000817319372ULL

#define kBKTypeDigitizer            11
#define kBKTypePointer              17
#define kBKTypeButton               2
#define kBKTypeBtn                  32
#define kBKTypeKeyExtra             15
#define kBKTypeKey                  3
#define kBKTypeKeyAlt               1

#define kBKFieldKeyPage             ((kBKTypeKey << 16) | 0)
#define kBKFieldKeyUsage            ((kBKTypeKey << 16) | 1)
#define kBKFieldKeyDown             ((kBKTypeKey << 16) | 2)

#define kBKChildIdentityBase        3

#define kBKIdxCursor                40
#define kBKIdxMira                  70
#define kBKIdxAds                   71
#define kBKIdxDir                   72
#define kBKIdxFogo                  73
#define kBKIdxMirar                 74

#define kBKPhBegan                  0x03
#define kBKPhMoved                  0x04
#define kBKPhEnded                  0x02

#define kBKTravaGuardNs             250000000ULL
#define kBKMoveDedupNs              4000000ULL
#define kBKMoveDead                 0.4
#define kBKMoveFactor               0.0015
#define kBKBoxR                     0.08
#define kBKAnchorX                  0.5
#define kBKAnchorY                  0.5
#define kBKCursorMinX               0.06
#define kBKCursorMaxX               0.94
#define kBKCursorMinY               0.08
#define kBKCursorMaxY               0.92
#define kBKTapNs                    45000000ULL

#define kBKKeyTrava                 224
#define kBKKeyRun                   225
#define kBKKeyTravaAlt              228

static NSString *const kBKNotifyReload = @"com.wjf.ballkey.reload";
static NSString *const kBKNotifyClose  = @"com.wjf.ballkey.close";

static IOHIDEventSystemClientRef gClient = NULL;
static void *gHid = NULL;
static BOOL gReady = NO;

static NSMutableDictionary *gCfg = nil;
static NSString *gBundle = @"";
static BOOL gHasProfile = NO;

static BOOL gTrava = NO;
static BOOL gFps = NO;
static BOOL gCap = NO;
static BOOL gDump = NO;

static int gOrient = 1;
static uint64_t gLastTrava = 0;
static uint64_t gLastMove = 0;

static BOOL gDown[4] = {NO, NO, NO, NO};
static double gSx[4] = {0, 0, 0, 0};
static double gSy[4] = {0, 0, 0, 0};

static double gCurX = kBKAnchorX;
static double gCurY = kBKAnchorY;
static int gCapKey = -1;

static id gOverlay = nil;

static uint64_t BKNow(void) {
    static mach_timebase_info_data_t tb;
    static BOOL once = NO;
    if (!once) { mach_timebase_info(&tb); once = YES; }
    return mach_absolute_time() * tb.numer / tb.denom;
}

static NSString *BKRoot(void) {
    static NSString *root = nil;
    if (root) return root;
    NSArray *c = @[
        @"/var/mobile/Containers/Shared/AppGroup/.jbroot-C4160B2A6F5AE523/",
        @"/private/var/mobile/Containers/Shared/AppGroup/.jbroot-C4160B2A6F5AE523/",
        @"/var/jb/var/mobile/", @"/var/mobile/", NSTemporaryDirectory()
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in c) if ([fm isWritableFileAtPath:p]) { root = p; break; }
    if (!root) root = NSTemporaryDirectory();
    return root;
}

static NSString *BKPath(NSString *n) { return [BKRoot() stringByAppendingString:n]; }

static void BKLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], s];
    NSString *p = BKPath(@"bk_debug.log");
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) { [d writeToFile:p atomically:YES]; return; }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; } @catch (__unused NSException *e) {}
}

static double BKClampD(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

static BOOL BKPontoValido(double x, double y) {
    if (isnan(x) || isnan(y)) return NO;
    if (x <= 0.0 || x >= 1.0 || y <= 0.0 || y >= 1.0) return NO;
    return YES;
}

static int BKOr(void) {
    UIInterfaceOrientation o = [UIApplication sharedApplication].statusBarOrientation;
    int v = (int)o;
    if (v >= 1 && v <= 4) gOrient = v;
    return gOrient;
}

static void BKConv(double x, double y, int o, double *ox, double *oy) {
    switch (o) {
        case 2:  *ox = 1.0 - x; *oy = 1.0 - y; break;
        case 3:  *ox = y;       *oy = 1.0 - x; break;
        case 4:  *ox = 1.0 - y; *oy = x;       break;
        default: *ox = x;       *oy = y;       break;
    }
}

static void BKConvInv(double x, double y, int o, double *ox, double *oy) {
    switch (o) {
        case 2:  *ox = 1.0 - x; *oy = 1.0 - y; break;
        case 3:  *ox = 1.0 - y; *oy = x;       break;
        case 4:  *ox = y;       *oy = 1.0 - x; break;
        default: *ox = x;       *oy = y;       break;
    }
}

typedef IOHIDEventRef (*BKCreateFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                          uint32_t, double, double, double, double,
                                          double, BOOL, BOOL, uint32_t);

static void BKInject(int phase, int slot, double x, double y) {
    if (!gClient || !gReady) return;
    double dx, dy;
    BKConv(x, y, BKOr(), &dx, &dy);

    static BKCreateFingerFn create = NULL;
    if (!create) create = (BKCreateFingerFn)dlsym(gHid, "IOHIDEventCreateDigitizerFingerEvent");
    if (!create) return;

    int ph = (phase == 1) ? kBKPhBegan : (phase == 3 ? kBKPhEnded : kBKPhMoved);
    IOHIDEventRef ev = create(kCFAllocatorDefault, 0, (uint32_t)slot,
                              (uint32_t)(kBKChildIdentityBase + slot),
                              2, dx, dy, 0.0, 1.0, 0.0, 1, 1, 0);
    if (!ev) return;
    IOHIDEventSetSenderID(ev, kBKSenderId);
    IOHIDEventSystemClientDispatchEvent(gClient, ev);
    CFRelease(ev);
    if (gDump) BKLog(@"D ph=%d s=%d o=%d x=%.3f y=%.3f", phase, slot, gOrient, dx, dy);
}

static void BKPress(int slot, double x, double y) {
    if (gDown[slot]) return;
    gDown[slot] = YES; gSx[slot] = x; gSy[slot] = y;
    BKInject(1, slot, x, y);
}

static void BKMove(int slot, double x, double y) {
    if (!gDown[slot]) return;
    gSx[slot] = x; gSy[slot] = y;
    BKInject(2, slot, x, y);
}

static void BKRelease(int slot) {
    if (!gDown[slot]) return;
    gDown[slot] = NO;
    BKInject(3, slot, gSx[slot], gSy[slot]);
}

static void BKReleaseAll(void) { for (int i = 1; i <= 3; i++) BKRelease(i); }

static void BKTap(int slot, double x, double y) {
    BKPress(slot, x, y);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kBKTapNs),
                   dispatch_get_main_queue(), ^{ BKRelease(slot); });
}

static NSMutableDictionary *BKApp(void) {
    if (!gCfg) gCfg = [NSMutableDictionary dictionary];
    NSMutableDictionary *apps = gCfg[@"apps"];
    if (!apps) { apps = [NSMutableDictionary dictionary]; gCfg[@"apps"] = apps; }
    NSMutableDictionary *a = apps[gBundle];
    if (!a) { a = [NSMutableDictionary dictionary]; apps[gBundle] = a; }
    NSMutableDictionary *p = a[@"pts"];
    if (!p) { p = [NSMutableDictionary dictionary]; a[@"pts"] = p; }
    return a;
}

static NSMutableDictionary *BKPts(void) { return BKApp()[@"pts"]; }

static void BKLoadConfig(void) {
    gHasProfile = NO;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:BKPath(@"com.wjf.ballkey.plist")];
    gCfg = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
    NSDictionary *apps = gCfg[@"apps"];
    if (apps && [apps isKindOfClass:[NSDictionary class]] && apps[gBundle]) gHasProfile = YES;
    BKLog(@"C b=%@ n=%lu key=%d", gBundle, (unsigned long)[BKPts() count], [gCfg[@"key"] intValue]);
}

static void BKSaveConfig(void) {
    if (!gCfg) return;
    [gCfg writeToFile:BKPath(@"com.wjf.ballkey.plist") atomically:YES];
    BKLog(@"ov save: %lu", (unsigned long)[BKPts() count]);
}

static void BKPonto(int key, double x, double y) {
    if (!BKPontoValido(x, y)) return;
    gHasProfile = YES;
    BKPts()[ [@(key) stringValue] ] = [NSString stringWithFormat:@"%.4f,%.4f", x, y];
}

static BOOL BKGetPonto(int key, double *x, double *y) {
    NSString *s = BKPts()[ [@(key) stringValue] ];
    if (!s) return NO;
    NSArray *p = [s componentsSeparatedByString:@","];
    if (p.count < 2) return NO;
    double px = [p[0] doubleValue], py = [p[1] doubleValue];
    if (!BKPontoValido(px, py)) return NO;
    *x = px; *y = py;
    return YES;
}

static void BKFpsOn(void) {
    gCurX = kBKAnchorX; gCurY = kBKAnchorY;
    BKPress(1, kBKAnchorX, kBKAnchorY);
    BKLog(@"F on ancora=%.2f,%.2f caixa=%.2f", kBKAnchorX, kBKAnchorY, kBKBoxR);
}

static void BKFpsOff(void) { BKRelease(1); BKLog(@"F off"); }

static void BKFpsMove(double dx, double dy) {
    if (!gDown[1]) return;

    double lo = kBKAnchorX - kBKBoxR, hi = kBKAnchorX + kBKBoxR;
    double lo2 = kBKAnchorY - kBKBoxR, hi2 = kBKAnchorY + kBKBoxR;

    double nx = gCurX + dx * kBKMoveFactor;
    double ny = gCurY + dy * kBKMoveFactor;

    BOOL bateu = NO;
    if (nx < lo) { nx = lo; bateu = YES; }
    else if (nx > hi) { nx = hi; bateu = YES; }
    if (ny < lo2) { ny = lo2; bateu = YES; }
    else if (ny > hi2) { ny = hi2; bateu = YES; }

    if (bateu) {
        gCurX = kBKAnchorX; gCurY = kBKAnchorY;
        BKRelease(1);
        BKPress(1, gCurX, gCurY);
        BKLog(@"F recuo %.2f,%.2f", gCurX, gCurY);
        return;
    }
    gCurX = nx; gCurY = ny;
    BKMove(1, nx, ny);
}

static void BKHandleButton(int b, BOOL down) {
    if (down) {
        if (gDown[2]) return;

        if (gCap) {
            int alvo = (gCapKey > 0) ? gCapKey : (b == 0 ? kBKIdxFogo : kBKIdxMirar);
            BKPonto(alvo, gCurX, gCurY);
            gCapKey = -1;
            BKSaveConfig();
            BKTap(2, gCurX, gCurY);
            BKLog(@"B m:%d marcou k:%d em %.3f,%.3f", b, alvo, gCurX, gCurY);
            if (gOverlay) [(id)gOverlay performSelector:@selector(atualizar)];
            return;
        }

        double mx, my;
        if (BKGetPonto(b == 0 ? kBKIdxFogo : kBKIdxMirar, &mx, &my)) {
            BKPress(2, mx, my);
            BKLog(@"B m:%d fogo em %.3f,%.3f", b, mx, my);
        } else {
            BKTap(2, gCurX, gCurY);
            BKLog(@"B m:%d sem marcador, toque em %.3f,%.3f", b, gCurX, gCurY);
        }
        return;
    }
    if (!gDown[2]) return;
    BKRelease(2);
}

static void BKHandleKey(int usage, int page, BOOL down) {
    if (page != 7) return;

    if (usage == kBKKeyTrava || usage == kBKKeyTravaAlt) {
        if (!down) return;
        uint64_t now = BKNow();
        if (now - gLastTrava < kBKTravaGuardNs) return;
        gLastTrava = now;
        if (gTrava) { gTrava = NO; BKFpsOff(); }
        else { gTrava = YES; if (gFps) BKFpsOn(); }
        BKLog(@"F trava=%d", gTrava ? 1 : 0);
        if (gOverlay) [(id)gOverlay performSelector:@selector(atualizar)];
        return;
    }

    if (usage == kBKKeyRun) {
        if (down) { double rx, ry; if (BKGetPonto(kBKIdxDir, &rx, &ry)) BKPress(3, rx, ry); }
        else BKRelease(3);
        return;
    }

    if (gCap && down) {
        gCapKey = usage;
        BKLog(@"K %d armado", usage);
        if (gOverlay) [(id)gOverlay performSelector:@selector(atualizar)];
        return;
    }
}

static void BKHIDCallback(void *t, void *r, IOHIDEventRef ev, void *s) {
    if (!ev) return;
    uint32_t type = (uint32_t)IOHIDEventGetType(ev);
    if (IOHIDEventGetSenderID(ev) == kBKSenderId) return;

    switch (type) {
        case kBKTypeKey:
        case kBKTypeKeyAlt: {
            int usage = (int)IOHIDEventGetIntegerValue(ev, kBKFieldKeyUsage);
            int page  = (int)IOHIDEventGetIntegerValue(ev, kBKFieldKeyPage);
            int down  = (int)IOHIDEventGetIntegerValue(ev, kBKFieldKeyDown);
            if (!usage) return;
            if (gDump) BKLog(@"K %d pg=%d d=%d", usage, page, down);
            BKHandleKey(usage, page, down ? YES : NO);
            break;
        }
        case kBKTypePointer: {
            double dx = IOHIDEventGetFloatValue(ev, (kBKTypePointer << 16) | 0);
            double dy = IOHIDEventGetFloatValue(ev, (kBKTypePointer << 16) | 1);
            int st = (int)IOHIDEventGetIntegerValue(ev, (kBKTypePointer << 16) | 3);

            uint64_t now = BKNow();
            if (now - gLastMove < kBKMoveDedupNs) return;
            gLastMove = now;

            if (st == 1) { BKHandleButton(0, YES); }
            else if (st == 2) { BKHandleButton(0, NO); }
            else {
                if (fabs(dx) < kBKMoveDead && fabs(dy) < kBKMoveDead) return;
                if (gTrava && gFps) {
                    BKFpsMove(dx, dy);
                } else if (!gTrava) {
                    gCurX = BKClampD(gCurX + dx * kBKMoveFactor, kBKCursorMinX, kBKCursorMaxX);
                    gCurY = BKClampD(gCurY + dy * kBKMoveFactor, kBKCursorMinY, kBKCursorMaxY);
                }
            }
            break;
        }
        case kBKTypeButton:
        case kBKTypeBtn: {
            int b = (int)IOHIDEventGetIntegerValue(ev, kBKFieldBtnMask);
            int down = (int)IOHIDEventGetIntegerValue(ev, (type << 16) | 3);
            if (down) BKHandleButton(b, YES);
            else BKHandleButton(b, NO);
            break;
        }
        case kBKTypeKeyExtra: {
            int u = (int)IOHIDEventGetIntegerValue(ev, (kBKTypeKeyExtra << 16) | 0);
            if (u == 16) {
                gFps = !gFps;
                if (gFps && gTrava) BKFpsOn();
                if (!gFps) BKFpsOff();
                BKLog(@"F fps=%d", gFps ? 1 : 0);
            }
            break;
        }
        case kBKTypeDigitizer:
            if (gDump) {
                BKLog(@"M11 x=%.4f y=%.4f",
                      IOHIDEventGetFloatValue(ev, (kBKTypeDigitizer << 16) | 4),
                      IOHIDEventGetFloatValue(ev, (kBKTypeDigitizer << 16) | 5));
            }
            break;
        default: break;
    }
}

@interface BKOverlay : NSObject
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UILabel *status;
- (void)abrir;
- (void)fechar;
- (void)atualizar;
@end

@implementation BKOverlay

- (void)abrir {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.win) return;
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 1;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [[UIViewController alloc] init];

        UIView *p = [[UIView alloc] initWithFrame:CGRectMake(8, 44, w.bounds.size.width - 16, 250)];
        p.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
        p.layer.cornerRadius = 12;
        [w.rootViewController.view addSubview:p];

        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, p.bounds.size.width - 24, 20)];
        t.text = @"BallKey"; t.textColor = [UIColor whiteColor];
        t.font = [UIFont boldSystemFontOfSize:15];
        [p addSubview:t];

        UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(12, 30, p.bounds.size.width - 24, 46)];
        s.textColor = [UIColor colorWithWhite:0.85 alpha:1];
        s.font = [UIFont systemFontOfSize:11];
        s.numberOfLines = 3;
        [p addSubview:s];
        self.status = s;

        NSArray *nomes = @[@"Marcar", @"Limpar direção", @"Limpar tudo", @"FPS", @"Dump", @"Fechar"];
        CGFloat y = 82;
        for (NSUInteger i = 0; i < nomes.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            b.frame = CGRectMake(12, y, p.bounds.size.width - 24, 24);
            b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
            b.layer.cornerRadius = 6;
            [b setTitle:nomes[i] forState:UIControlStateNormal];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.tag = (NSInteger)i;
            [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
            [p addSubview:b];
            y += 27;
        }

        self.win = w; w.hidden = NO;
        [self atualizar];
    });
}

- (void)fechar {
    dispatch_async(dispatch_get_main_queue(), ^{ self.win.hidden = YES; self.win = nil; });
}

- (void)atualizar {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.status) return;
        NSString *armado = (gCapKey > 0) ? [NSString stringWithFormat:@"k:%d", gCapKey] : @"—";
        self.status.text = [NSString stringWithFormat:@"%@ | trava=%d fps=%d cap=%d | armar=%@ | %lu pts",
                            gBundle.length ? gBundle : @"?", gTrava ? 1 : 0, gFps ? 1 : 0,
                            gCap ? 1 : 0, armado, (unsigned long)[BKPts() count]];
    });
}

- (void)tap:(UIButton *)b {
    switch (b.tag) {
        case 0: gCap = !gCap; gCapKey = -1; BKLog(@"ov cap=%d", gCap ? 1 : 0); break;
        case 1: case 2:
            [BKPts() removeAllObjects]; BKSaveConfig();
            BKLog(@"ov limpar");
            break;
        case 3:
            gFps = !gFps;
            if (gFps && gTrava) BKFpsOn();
            if (!gFps) BKFpsOff();
            BKLog(@"ov fps=%d", gFps ? 1 : 0);
            break;
        case 4: gDump = !gDump; BKLog(@"ov dump=%d", gDump ? 1 : 0); break;
        default: [self fechar]; return;
    }
    [self atualizar];
}

@end

static void BKFrontApp(void) {
    NSString *b = nil;
    Class ls = NSClassFromString(@"LSApplicationWorkspace");
    if (ls) {
        id ws = [ls performSelector:@selector(defaultWorkspace)];
        NSArray *apps = [ws performSelector:@selector(runningApplications)];
        for (id a in apps) {
            if ([[a performSelector:@selector(applicationType)] isEqual:@(1)]) {
                b = [a performSelector:@selector(bundleIdentifier)];
                break;
            }
        }
    }
    if (!b.length) b = [NSBundle mainBundle].bundleIdentifier;
    if (![b isEqualToString:gBundle]) { gBundle = b ?: @""; BKLoadConfig(); }
}

static void BKInit(void) {
    gHid = dlopen("/usr/lib/libIOHID.dylib", RTLD_LAZY);
    if (!gHid) gHid = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!gHid) { BKLog(@"E hid"); return; }

    typedef IOHIDEventSystemClientRef (*BKCreateClientFn)(CFAllocatorRef);
    BKCreateClientFn create = (BKCreateClientFn)dlsym(gHid, "IOHIDEventSystemClientCreate");
    if (!create) { BKLog(@"E create"); return; }
    gClient = create(kCFAllocatorDefault);
    if (!gClient) { BKLog(@"E client"); return; }

    typedef void (*BKRegisterFn)(IOHIDEventSystemClientRef, void *, void *, void *);
    BKRegisterFn reg = (BKRegisterFn)dlsym(gHid, "IOHIDEventSystemClientRegisterEventCallback");
    if (!reg) { BKLog(@"E register"); return; }
    reg(gClient, (void *)BKHIDCallback, NULL, NULL);

    typedef void (*BKStartFn)(IOHIDEventSystemClientRef, CFStringRef);
    BKStartFn start = (BKStartFn)dlsym(gHid, "IOHIDEventSystemClientScheduleWithRunLoop");
    if (start) start(gClient, CFRunLoopGetMain());

    gReady = YES;

    int tok = 0;
    notify_register_dispatch(kBKNotifyReload.UTF8String, &tok, dispatch_get_main_queue(), ^(int x) {
        BKFrontApp(); BKLoadConfig(); BKLog(@"ov reload");
        if (gOverlay) [(id)gOverlay performSelector:@selector(atualizar)];
    });
    notify_register_dispatch(kBKNotifyClose.UTF8String, &tok, dispatch_get_main_queue(), ^(int x) {
        if (gOverlay) [(id)gOverlay performSelector:@selector(fechar)];
    });

    BKFrontApp(); BKLoadConfig();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gOverlay = [[BKOverlay alloc] init];
        [(BKOverlay *)gOverlay abrir];
        BKLog(@"I ready");
    });
}

__attribute__((constructor)) static void BKInitCtor(void) {
    BKLog(@"I ctor");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BKInit(); });
}
