#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdarg.h>

typedef struct __IOHIDEvent *BKIOHIDEventRef;

const char BKTag[] = "a1";

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
#define kBKTagBall 9001

#define kBKNeon  [UIColor colorWithRed:0.15 green:0.98 blue:0.85 alpha:1.0]
#define kBKNeon2 [UIColor colorWithRed:0.45 green:0.35 blue:1.00 alpha:1.0]
#define kBKHot   [UIColor colorWithRed:1.00 green:0.22 blue:0.55 alpha:1.0]
#define kBKRed   [UIColor colorWithRed:1.00 green:0.30 blue:0.30 alpha:1.0]
#define kBKDim   [UIColor colorWithRed:0.70 green:0.80 blue:0.85 alpha:1.0]
#define kBKPanel [UIColor colorWithRed:0.02 green:0.04 blue:0.07 alpha:0.96]

@interface UIApplication (BKPrivate)
- (void)_enqueueHIDEvent:(BKIOHIDEventRef)ev;
@end

@interface BKRootView : UIView
@property (nonatomic) BOOL blocksAll;
@end

@implementation BKRootView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e
{
    UIView *v = [super hitTest:p withEvent:e];
    if (!v || v == self) return self.blocksAll ? self : nil;
    if (self.blocksAll) return v;
    UIView *w = v;
    while (w) {
        if (w.tag == kBKTagBall) return v;
        w = w.superview;
    }
    return nil;
}
@end

@interface BKRootVC : UIViewController
@end

@implementation BKRootVC
- (void)loadView
{
    self.view = [[BKRootView alloc] initWithFrame:[UIScreen mainScreen].bounds];
}
@end

@interface BKUI : NSObject
- (void)dragMarker:(UIPanGestureRecognizer *)g;
- (void)killMarker:(UILongPressGestureRecognizer *)g;
- (void)dragBall:(UIPanGestureRecognizer *)g;
- (void)tapBall:(UITapGestureRecognizer *)g;
- (void)toggle:(UIButton *)b;
- (void)cursor:(UIButton *)b;
- (void)fps:(UIButton *)b;
- (void)map:(UIButton *)b;
- (void)test:(UIButton *)b;
- (void)close:(UIButton *)b;
- (void)capture:(UIButton *)b;
- (void)save:(UIButton *)b;
- (void)done:(UIButton *)b;
- (void)kindKeys:(UIButton *)b;
- (void)kindBtns:(UIButton *)b;
@end

static UIWindow *gBallWin = nil;
static UIWindow *gMenuWin = nil;
static UIWindow *gEditWin = nil;
static UIWindow *gCursorWin = nil;
static UIView *gBall = nil;
static UIView *gCursor = nil;
static UILabel *gStatusLabel = nil;
static UILabel *gEditTitle = nil;
static UIView *gEditCanvas = nil;
static BKUI *gUI = nil;
static BOOL gMenuOpen = NO;
static BOOL gBallDone = NO, gCursorDone = NO, gHookDone = NO;
static BOOL gInj = NO;
static int gEvSeen = 0, gKeySeen = 0, gPtrSeen = 0;
static int gPtrMask = 0;
static uint64_t gLastKeyNs = 0, gLastBtnNs = 0;
static double gSpeed = 1.6;
static BOOL gEnabled = YES, gFps = NO, gCursorOn = NO;
static double gLastPtrX = 0.0, gLastPtrY = 0.0;
static BOOL gLastPtrValid = NO;
static double gCurX = 0.0, gCurY = 0.0;
static double gSpanW = 414.0, gSpanH = 736.0;
static BOOL gCurValid = NO;
static int gCapState = 0;
static NSString *gBaseDir = nil;
static NSString *gEditKind = @"key";
static void *gSeen[kBKSeenMax];
static uint64_t gSeenMs[kBKSeenMax];
static int gSeenIdx = 0;
static os_unfair_lock gSeenLock = OS_UNFAIR_LOCK_INIT;

static void (*origEnqueue)(id, SEL, BKIOHIDEventRef) = NULL;
static void (*fDispatch)(void *, BKIOHIDEventRef) = NULL;
static void (*fSetInt)(BKIOHIDEventRef, int, int64_t) = NULL;
static int (*fGetType)(BKIOHIDEventRef) = NULL;
static double (*fGetFloat)(BKIOHIDEventRef, int) = NULL;
static int (*fGetInt)(BKIOHIDEventRef, int) = NULL;
static uint64_t (*fGetSender)(BKIOHIDEventRef) = NULL;
static BKIOHIDEventRef (*fFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, double, double, double, double, double, double, BOOL, uint32_t) = NULL;
static BKIOHIDEventRef (*fHand)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, double, double, double, double, double, double, BOOL, uint32_t) = NULL;
static void (*fAppend)(BKIOHIDEventRef, BKIOHIDEventRef, uint32_t) = NULL;

typedef struct { int on; double x, y; } BKAct;
static BKAct gAct[kBKSlotAim + 1];
static NSMutableDictionary *gKeyMap = nil, *gBtnMap = nil, *gKeyDown = nil, *gBtnDown = nil;

static NSString *BKHome(void);
static NSString *BKPath(NSString *name);
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
static void BKLoadConfig(void);
static void BKSaveConfig(NSDictionary *cfg);
static NSMutableArray *BKPoints(NSMutableDictionary *cfg);
static void BKStatus(void);
static void BKCursor(void);
static void BKRefresh(void);
static void BKOpenMenu(void);
static void BKCloseMenu(void);
static void BKOpenEditor(NSString *kind, int code);
static void BKCloseEditor(void);
static void BKRedrawMarkers(void);
static void BKAddMarker(NSString *kind, int code, double nx, double ny);
static void BKRemoveMarkerAt(int idx);
static void BKSaveMarkers(void);
static void BKCaptureRequest(void);
static void BKCapturePoll(void);
static UIWindow *BKMakeWindow(CGRect frame, CGFloat level, BOOL blocks);
static void BKBuildBall(void);
static void BKBuildCursor(void);
static void BKInstallHook(void);
static void BKInit(void);

static uint64_t BKNow(void) { return mach_absolute_time() / 1000000ull; }

static NSString *BKHome(void)
{
    if (gBaseDir) return gBaseDir;
    @try {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (a.count) gBaseDir = [a objectAtIndex:0];
    } @catch (NSException *e) { }
    if (!gBaseDir) gBaseDir = NSTemporaryDirectory();
    return gBaseDir;
}

static NSString *BKPath(NSString *name) { return [BKHome() stringByAppendingPathComponent:name]; }

static void BKAppend(NSString *fmt, ...)
{
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        @try {
            NSString *p = BKPath(@"ballkey.log");
            NSString *old = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            if (!old) old = @"";
            if (old.length > 40000) old = [old substringFromIndex:old.length - 26000];
            [([old stringByAppendingFormat:@"[%llu] %@\n", BKNow(), msg]) writeToFile:p
                        atomically:NO encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) { }
    }
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

static BOOL BKInitIO(void)
{
    @try {
        void *k = RTLD_DEFAULT;
        if (!dlsym(k, "IOHIDEventCreateDigitizerFingerEvent")) {
            k = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        }
        if (!k) return NO;
        fGetType = (void *)dlsym(k, "IOHIDEventGetType");
        fGetFloat = (void *)dlsym(k, "IOHIDEventGetFloatValue");
        fGetInt = (void *)dlsym(k, "IOHIDEventGetIntegerValue");
        fGetSender = (void *)dlsym(k, "IOHIDEventGetSenderID");
        fSetInt = (void *)dlsym(k, "IOHIDEventSetIntegerValue");
        fAppend = (void *)dlsym(k, "IOHIDEventAppendEvent");
        fDispatch = (void *)dlsym(k, "IOHIDEventSystemClientDispatchEvent");
        fFinger = (void *)dlsym(k, "IOHIDEventCreateDigitizerFingerEvent");
        if (!fFinger) fFinger = (void *)dlsym(k, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        fHand = (void *)dlsym(k, "IOHIDEventCreateDigitizerEvent");
    } @catch (NSException *e) { return NO; }
    return (fFinger != NULL && fGetType != NULL);
}

static void BKInject(BKIOHIDEventRef ev)
{
    if (!ev) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (origEnqueue) {
            gInj = YES;
            origEnqueue(app, @selector(_enqueueHIDEvent:), ev);
            gInj = NO;
        }
    } @catch (NSException *e) { }
    CFRelease(ev);
}

static void BKFinger(int slot, int phase, double x, double y)
{
    if (!fFinger) return;
    if (slot < 0 || slot > kBKSlotAim) return;
    @try {
        uint32_t mask = 0;
        BOOL touch = YES;
        if (phase == 0) mask = 0x01;
        else if (phase == 1) mask = 0x02;
        else if (phase == 2) mask = 0x04;
        else { mask = 0x08 | 0x10; touch = NO; }

        uint64_t ts = mach_absolute_time();
        BKIOHIDEventRef finger = fFinger(kCFAllocatorDefault, ts, (uint32_t)slot,
            (uint32_t)slot, mask, 0, x, y, 0.0, 1.0, 0.0, 0.0, touch, 0);
        if (!finger) return;
        if (fSetInt) fSetInt(finger, kBKFieldDispInt, 1);

        if (fHand && fAppend) {
            BKIOHIDEventRef hand = fHand(kCFAllocatorDefault, ts, kBKHandType, 0, 0,
                mask, 0, x, y, 0.0, 1.0, 0.0, 0.0, touch, 0);
            if (hand) {
                if (fSetInt) fSetInt(hand, kBKFieldDispInt, 1);
                fAppend(hand, finger, 0);
                CFRelease(finger);
                BKInject(hand);
                return;
            }
        }
        BKInject(finger);
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
        [s writeToFile:BKPath(@"ptr.txt") atomically:NO encoding:NSUTF8StringEncoding error:nil];
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
    BKPressPoint(p, down, gBtnDown, index + 100);
}

static NSMutableArray *BKPoints(NSMutableDictionary *cfg)
{
    NSMutableArray *a = [cfg objectForKey:@"Points"];
    if (![a isKindOfClass:[NSMutableArray class]]) {
        a = [NSMutableArray array];
        [cfg setObject:a forKey:@"Points"];
    }
    return a;
}

static void BKLoadConfig(void)
{
    @try {
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:BKPath(@"ballkey.plist")];
        if (!cfg) return;
        gEnabled = [cfg objectForKey:@"Enabled"] ? [[cfg objectForKey:@"Enabled"] boolValue] : YES;
        gFps = [[cfg objectForKey:@"FpsMode"] boolValue];
        gCursorOn = [[cfg objectForKey:@"CursorOn"] boolValue];
        double s = [[cfg objectForKey:@"CursorSpeed"] doubleValue];
        gSpeed = (s > 0.2 && s < 8.0) ? s : 1.6;

        NSArray *arr = [cfg objectForKey:@"Points"];
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
        gKeyMap = keys; gBtnMap = btns;
    } @catch (NSException *e) { }
}

static void BKSaveConfig(NSDictionary *cfg)
{
    @try {
        [cfg writeToFile:BKPath(@"ballkey.plist") atomically:YES];
        BKLoadConfig();
    } @catch (NSException *e) { }
}

static NSMutableDictionary *BKConfig(void)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:BKPath(@"ballkey.plist")];
    if (!d) d = [NSMutableDictionary dictionary];
    if (![d objectForKey:@"Points"]) [d setObject:[NSMutableArray array] forKey:@"Points"];
    if (![d objectForKey:@"Enabled"]) [d setObject:[NSNumber numberWithBool:YES] forKey:@"Enabled"];
    if (![d objectForKey:@"CursorSpeed"]) [d setObject:[NSNumber numberWithDouble:1.6] forKey:@"CursorSpeed"];
    return d;
}

static void BKStatus(void)
{
    @try {
        [gUI setNeedsLayout];
        if (!gStatusLabel) return;
        gStatusLabel.text = [NSString stringWithFormat:
            @"v %@  hk:%@  e%d k%d p%d  at:%@",
            [NSString stringWithUTF8String:BKTag], gHookDone ? @"S" : @"N",
            gEvSeen, gKeySeen, gPtrSeen,
            gEnabled ? @"1" : @"0"];
    } @catch (NSException *e) { }
}

static void BKCursor(void)
{
    if (!gCursorWin || !gCursor) return;
    NSString *s = [NSString stringWithContentsOfFile:BKPath(@"ptr.txt")
                                            encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return;
    NSArray *p = [s componentsSeparatedByString:@" "];
    if (p.count < 3) return;

    if ([[p objectAtIndex:0] isEqualToString:@"A"] && p.count >= 5) {
        gSpanW = [[p objectAtIndex:3] doubleValue];
        gSpanH = [[p objectAtIndex:4] doubleValue];
        gCurX = [[p objectAtIndex:1] doubleValue];
        gCurY = [[p objectAtIndex:2] doubleValue];
        gCurValid = YES;
    } else if ([[p objectAtIndex:0] isEqualToString:@"R"]) {
        double sp = gSpeed;
        if (!gCurValid) { gCurX = gSpanW * 0.5; gCurY = gSpanH * 0.5; gCurValid = YES; }
        gCurX += [[p objectAtIndex:1] doubleValue] * sp;
        gCurY += [[p objectAtIndex:2] doubleValue] * sp;
    } else {
        return;
    }

    if (gCurX < 0.0) gCurX = 0.0;
    if (gCurY < 0.0) gCurY = 0.0;
    if (gCurX > gSpanW) gCurX = gSpanW;
    if (gCurY > gSpanH) gCurY = gSpanH;
    [UIView performWithoutAnimation:^{ gCursor.center = CGPointMake(gCurX, gCurY); }];
}

static void BKRefresh(void)
{
    if (gMenuOpen) BKStatus();
    BKCursor();
    BKCapturePoll();
    if (gCursorWin) gCursorWin.hidden = !gCursorOn;
    if (gBallWin) gBallWin.hidden = NO;
}

static void BKOnEvent(BKIOHIDEventRef event, int type)
{
    @try {
        gEvSeen++;
        if (type == kBKTypePointer) {
            gPtrSeen++;
            double x = fGetFloat ? fGetFloat(event, kBKFieldPtrX) : 0.0;
            double y = fGetFloat ? fGetFloat(event, kBKFieldPtrY) : 0.0;
            double sx = fGetFloat ? fGetFloat(event, kBKFieldSpanX) : 0.0;
            double sy = fGetFloat ? fGetFloat(event, kBKFieldSpanY) : 0.0;
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
            int mask = fGetInt ? fGetInt(event, kBKFieldBtnMask) : 0;
            if (mask != gPtrMask) BKPtrButtons(mask);
            return;
        }
        if (type == kBKTypeButton) {
            int idx = fGetInt ? fGetInt(event, (kBKTypeButton << 16) | 3u) : 0;
            BKHandleButton(0, idx != 0);
            if (gCapState == 1) {
                gCapState = 0;
                BKAddMarker(@"btn", idx != 0 ? 1 : 0, 0.5, 0.5);
                if (gEditTitle) gEditTitle.text = @"botao capturado";
                BKRedrawMarkers();
            }
            return;
        }
        if (type == kBKTypeKeyboard || type == kBKTypeKeyExtra) {
            int usage = fGetInt ? fGetInt(event, 0x0700) : 0;
            if (usage <= 0) return;
            BOOL down = fGetInt ? (fGetInt(event, kBKFieldKeyDown) != 0) : NO;
            gKeySeen++;
            BKHandleKey(usage, down);
            if (down && gCapState == 1) {
                gCapState = 0;
                BKAddMarker(@"key", usage, 0.5, 0.5);
                if (gEditTitle) {
                    gEditTitle.text = [NSString stringWithFormat:@"tecla %d capturada", usage];
                }
                BKRedrawMarkers();
            }
            return;
        }
    } @catch (NSException *e) { }
}

static void BKHookEnqueue(id self, SEL cmd, BKIOHIDEventRef ev)
{
    @try {
        if (!gInj && ev && fGetType) {
            int type = fGetType(ev);
            if (type != kBKTypeDigitizer && !BKSeenRecently(ev)) {
                uint64_t snd = fGetSender ? fGetSender(ev) : 0;
                (void)snd;
                BKOnEvent(ev, type);
            }
        }
    } @catch (NSException *e) { }
    if (origEnqueue) origEnqueue(self, cmd, ev);
}

static void BKInstallHook(void)
{
    if (gHookDone) return;
    gHookDone = YES;
    @try {
        Method m = class_getInstanceMethod([UIApplication class],
                                          @selector(_enqueueHIDEvent:));
        if (m) {
            origEnqueue = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)BKHookEnqueue);
            BKAppend(@"hook ok");
        } else {
            BKAppend(@"hook ausente");
        }
    } @catch (NSException *e) {
        BKAppend(@"hook erro %@", e.reason);
    }
}

static void BKCaptureRequest(void)
{
    gCapState = 1;
    if (gEditTitle) gEditTitle.text = @"aperte a tecla ou o botao";
}

static void BKCapturePoll(void)
{
    if (gCapState == 0) return;
}

static UIButton *BKButton(NSString *title, SEL sel, UIColor *color)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.backgroundColor = [color colorWithAlphaComponent:0.12];
    b.layer.borderColor = color.CGColor;
    b.layer.borderWidth = 1.5;
    b.layer.cornerRadius = 12;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:gUI action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UIWindow *BKMakeWindow(CGRect frame, CGFloat level, BOOL blocks)
{
    UIWindow *w = [[UIWindow alloc] initWithFrame:frame];
    w.windowLevel = level;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [[BKRootVC alloc] init];
    w.rootViewController.view.frame = frame;
    if (blocks) {
        w.rootViewController.view.backgroundColor = kBKPanel;
        ((BKRootView *)w.rootViewController.view).blocksAll = YES;
    }
    return w;
}

static void BKAddMarker(NSString *kind, int code, double nx, double ny)
{
    NSMutableDictionary *cfg = BKConfig();
    NSMutableArray *arr = BKPoints(cfg);
    int k = [kind isEqualToString:@"key"] ? 0 : 1;
    for (NSDictionary *d in arr) {
        if ([[d objectForKey:@"Kind"] intValue] == k &&
            [[d objectForKey:@"Code"] intValue] == code) return;
    }
    [arr addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInt:k], @"Kind",
        [NSNumber numberWithInt:code], @"Code",
        [NSNumber numberWithDouble:nx], @"X",
        [NSNumber numberWithDouble:ny], @"Y", nil]];
    BKSaveConfig(cfg);
}

static void BKRemoveMarkerAt(int idx)
{
    NSMutableDictionary *cfg = BKConfig();
    NSMutableArray *arr = BKPoints(cfg);
    int k = [gEditKind isEqualToString:@"key"] ? 0 : 1;
    int seen = 0;
    for (int i = 0; i < (int)arr.count; i++) {
        NSDictionary *d = [arr objectAtIndex:i];
        if ([[d objectForKey:@"Kind"] intValue] != k) continue;
        if (seen == idx) { [arr removeObjectAtIndex:i]; BKSaveConfig(cfg); return; }
        seen++;
    }
}

static void BKSaveMarkers(void)
{
    if (!gEditCanvas) return;
    NSMutableDictionary *cfg = BKConfig();
    NSMutableArray *arr = BKPoints(cfg);
    int k = [gEditKind isEqualToString:@"key"] ? 0 : 1;

    for (UIView *v in gEditCanvas.subviews) {
        if (v.tag < 1000) continue;
        int idx = (int)v.tag - 1000;
        double nx = v.center.x / gEditCanvas.bounds.size.width;
        double ny = v.center.y / gEditCanvas.bounds.size.height;
        if (nx < 0.0) nx = 0.0;
        if (ny < 0.0) ny = 0.0;
        if (nx > 1.0) nx = 1.0;
        if (ny > 1.0) ny = 1.0;
        int seen = 0;
        for (int i = 0; i < (int)arr.count; i++) {
            NSMutableDictionary *d = [arr objectAtIndex:i];
            if ([[d objectForKey:@"Kind"] intValue] != k) continue;
            if (seen == idx) {
                [d setObject:[NSNumber numberWithDouble:nx] forKey:@"X"];
                [d setObject:[NSNumber numberWithDouble:ny] forKey:@"Y"];
                break;
            }
            seen++;
        }
    }
    BKSaveConfig(cfg);
}

static void BKRedrawMarkers(void)
{
    if (!gEditCanvas) return;
    for (UIView *v in gEditCanvas.subviews) {
        if (v.tag >= 1000) [v removeFromSuperview];
    }
    NSMutableDictionary *cfg = BKConfig();
    NSArray *arr = BKPoints(cfg);
    int want = [gEditKind isEqualToString:@"key"] ? 0 : 1;
    CGSize cs = gEditCanvas.bounds.size;
    int idx = 0;

    for (NSDictionary *d in arr) {
        if ([[d objectForKey:@"Kind"] intValue] != want) continue;
        double nx = [[d objectForKey:@"X"] doubleValue];
        double ny = [[d objectForKey:@"Y"] doubleValue];
        UIView *m = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 46, 46)];
        m.center = CGPointMake(nx * cs.width, ny * cs.height);
        m.backgroundColor = [kBKNeon2 colorWithAlphaComponent:0.20];
        m.layer.borderColor = kBKNeon.CGColor;
        m.layer.borderWidth = 1.5;
        m.layer.cornerRadius = 10;
        m.tag = 1000 + idx;

        UILabel *l = [[UILabel alloc] initWithFrame:m.bounds];
        l.text = [NSString stringWithFormat:@"%d", [[d objectForKey:@"Code"] intValue]];
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont boldSystemFontOfSize:13];
        l.textColor = kBKNeon;
        l.userInteractionEnabled = NO;
        [m addSubview:l];

        [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gUI
            action:@selector(dragMarker:)]];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gUI
            action:@selector(killMarker:)];
        lp.minimumPressDuration = 0.7;
        [m addGestureRecognizer:lp];
        [gEditCanvas addSubview:m];
        idx++;
    }
}

static void BKOpenMenu(void)
{
    if (gMenuOpen) return;
    gMenuOpen = YES;
    @try {
        if (!gMenuWin) gMenuWin = BKMakeWindow([UIScreen mainScreen].bounds,
                                               UIWindowLevelAlert + 2002, YES);
        UIViewController *vc = gMenuWin.rootViewController;
        for (UIView *v in vc.view.subviews) [v removeFromSuperview];

        UILabel *credits = [[UILabel alloc] init];
        credits.text = @"creditos a martidev333";
        credits.font = [UIFont systemFontOfSize:9];
        credits.textColor = [kBKDim colorWithAlphaComponent:0.75];
        credits.textAlignment = NSTextAlignmentRight;
        credits.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:credits];

        UILabel *title = [[UILabel alloc] init];
        title.text = @"Mapeador de Teclado e Mouse";
        title.numberOfLines = 2;
        title.font = [UIFont boldSystemFontOfSize:17];
        title.textColor = kBKNeon;
        title.textAlignment = NSTextAlignmentCenter;
        title.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:title];

        gStatusLabel = [[UILabel alloc] init];
        gStatusLabel.numberOfLines = 2;
        gStatusLabel.font = [UIFont systemFontOfSize:10];
        gStatusLabel.textColor = kBKDim;
        gStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:gStatusLabel];

        UIButton *bOn = BKButton(gEnabled ? @"DESATIVAR" : @"ATIVAR", @selector(toggle:), kBKNeon);
        UIButton *bCur = BKButton(gCursorOn ? @"CURSOR OFF" : @"CURSOR ON", @selector(cursor:), kBKNeon2);
        UIButton *bFps = BKButton(gFps ? @"FPS OFF" : @"FPS ON", @selector(fps:), kBKHot);
        UIButton *bMap = BKButton(@"MAPEADOR", @selector(map:), kBKNeon);
        UIButton *bTst = BKButton(@"TESTE", @selector(test:), kBKDim);
        UIButton *bCls = BKButton(@"FECHAR", @selector(close:), kBKHot);

        UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[bOn, bCur, bFps]];
        left.axis = UILayoutConstraintAxisVertical;
        left.spacing = 12;
        left.distribution = UIStackViewDistributionFillEqually;

        UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:@[bMap, bTst, bCls]];
        right.axis = UILayoutConstraintAxisVertical;
        right.spacing = 12;
        right.distribution = UIStackViewDistributionFillEqually;

        UIStackView *cols = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
        cols.axis = UILayoutConstraintAxisHorizontal;
        cols.spacing = 12;
        cols.distribution = UIStackViewDistributionFillEqually;
        cols.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:cols];

        UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [credits.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
            [credits.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
            [title.topAnchor constraintEqualToAnchor:credits.bottomAnchor constant:4],
            [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
            [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
            [gStatusLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
            [gStatusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
            [gStatusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
            [cols.topAnchor constraintEqualToAnchor:gStatusLabel.bottomAnchor constant:16],
            [cols.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
            [cols.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
            [cols.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18]
        ]];

        gMenuWin.hidden = NO;
        BKStatus();
    } @catch (NSException *e) {
        BKAppend(@"menu %@", e.reason);
    }
}

static void BKCloseMenu(void)
{
    gMenuOpen = NO;
    @try {
        if (gMenuWin) {
            gMenuWin.hidden = YES;
            for (UIView *v in gMenuWin.rootViewController.view.subviews) [v removeFromSuperview];
        }
    } @catch (NSException *e) { }
    gStatusLabel = nil;
}

static void BKOpenEditor(NSString *kind, int code)
{
    gEditKind = kind;
    gMenuOpen = NO;
    if (gMenuWin) gMenuWin.hidden = YES;
    @try {
        if (!gEditWin) gEditWin = BKMakeWindow([UIScreen mainScreen].bounds,
                                               UIWindowLevelAlert + 2003, YES);
        UIViewController *vc = gEditWin.rootViewController;
        for (UIView *v in vc.view.subviews) [v removeFromSuperview];

        gEditCanvas = [[UIView alloc] initWithFrame:vc.view.bounds];
        gEditCanvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view addSubview:gEditCanvas];

        UIView *top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, vc.view.bounds.size.width, 96)];
        top.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.10 alpha:0.95];
        top.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [vc.view addSubview:top];

        gEditTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 46, vc.view.bounds.size.width - 32, 34)];
        gEditTitle.text = @"MAPEADOR";
        gEditTitle.font = [UIFont boldSystemFontOfSize:17];
        gEditTitle.textColor = kBKNeon;
        gEditTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [top addSubview:gEditTitle];

        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, vc.view.bounds.size.height - 116,
                                                               vc.view.bounds.size.width, 116)];
        bar.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.10 alpha:0.95];
        bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [vc.view addSubview:bar];

        UIButton *kK = BKButton(@"TECLAS", @selector(kindKeys:), kBKNeon);
        kK.frame = CGRectMake(16, 12, 118, 40);
        [bar addSubview:kK];

        UIButton *kB = BKButton(@"BOTOES", @selector(kindBtns:), kBKNeon2);
        kB.frame = CGRectMake(146, 12, 118, 40);
        [bar addSubview:kB];

        UIButton *cap = BKButton(@"CAPTURAR", @selector(capture:), kBKNeon);
        cap.frame = CGRectMake(16, 62, 170, 44);
        [bar addSubview:cap];

        UIButton *save = BKButton(@"SALVAR", @selector(save:), kBKNeon2);
        save.frame = CGRectMake(196, 62, 100, 44);
        [bar addSubview:save];

        UIButton *done = BKButton(@"FECHAR", @selector(done:), kBKHot);
        done.frame = CGRectMake(306, 62, 92, 44);
        [bar addSubview:done];

        gEditWin.hidden = NO;
        BKRedrawMarkers();
    } @catch (NSException *e) {
        BKAppend(@"editor %@", e.reason);
    }
}

static void BKCloseEditor(void)
{
    BKSaveMarkers();
    @try {
        if (gEditWin) {
            gEditWin.hidden = YES;
            for (UIView *v in gEditWin.rootViewController.view.subviews) [v removeFromSuperview];
        }
    } @catch (NSException *e) { }
    gEditCanvas = nil;
    gEditTitle = nil;
}

@implementation BKUI

- (void)dragMarker:(UIPanGestureRecognizer *)g
{
    if (!gEditCanvas) return;
    UIView *v = g.view;
    CGPoint t = [g translationInView:gEditCanvas];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:gEditCanvas];
}

- (void)killMarker:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;
    BKRemoveMarkerAt((int)g.view.tag - 1000);
    BKRedrawMarkers();
}

- (void)dragBall:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:gBallWin];
    CGRect f = gBallWin.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    gBallWin.frame = f;
    [g setTranslation:CGPointZero inView:gBallWin];
}

- (void)tapBall:(UITapGestureRecognizer *)g
{
    (void)g;
    if (gMenuOpen) BKCloseMenu();
    else BKOpenMenu();
}

- (void)toggle:(UIButton *)b
{
    gEnabled = !gEnabled;
    NSMutableDictionary *cfg = BKConfig();
    [cfg setObject:[NSNumber numberWithBool:gEnabled] forKey:@"Enabled"];
    BKSaveConfig(cfg);
    [b setTitle:gEnabled ? @"DESATIVAR" : @"ATIVAR" forState:UIControlStateNormal];
}

- (void)cursor:(UIButton *)b
{
    gCursorOn = !gCursorOn;
    NSMutableDictionary *cfg = BKConfig();
    [cfg setObject:[NSNumber numberWithBool:gCursorOn] forKey:@"CursorOn"];
    BKSaveConfig(cfg);
    [b setTitle:gCursorOn ? @"CURSOR OFF" : @"CURSOR ON" forState:UIControlStateNormal];
}

- (void)fps:(UIButton *)b
{
    gFps = !gFps;
    NSMutableDictionary *cfg = BKConfig();
    [cfg setObject:[NSNumber numberWithBool:gFps] forKey:@"FpsMode"];
    BKSaveConfig(cfg);
    [b setTitle:gFps ? @"FPS OFF" : @"FPS ON" forState:UIControlStateNormal];
}

- (void)map:(UIButton *)b { (void)b; BKCloseMenu(); BKOpenEditor(@"key", 0); }
- (void)test:(UIButton *)b { (void)b; gEvSeen = 0; gKeySeen = 0; gPtrSeen = 0; BKStatus(); }
- (void)close:(UIButton *)b { (void)b; BKCloseMenu(); }
- (void)capture:(UIButton *)b { (void)b; BKCaptureRequest(); }

- (void)kindKeys:(UIButton *)b { (void)b; BKSaveMarkers(); gEditKind = @"key"; BKRedrawMarkers(); }
- (void)kindBtns:(UIButton *)b { (void)b; BKSaveMarkers(); gEditKind = @"btn"; BKRedrawMarkers(); }

- (void)save:(UIButton *)b
{
    (void)b;
    BKSaveMarkers();
    BKRedrawMarkers();
    if (gEditTitle) gEditTitle.text = @"SALVO";
}

- (void)done:(UIButton *)b { (void)b; BKCloseEditor(); }

@end

static void BKBuildBall(void)
{
    gBallWin = BKMakeWindow(CGRectMake(20, 120, 60, 60), UIWindowLevelAlert + 2000, NO);

    gBall = [[UIView alloc] initWithFrame:CGRectMake(4, 4, 52, 52)];
    gBall.tag = kBKTagBall;
    gBall.backgroundColor = [UIColor colorWithRed:0.03 green:0.07 blue:0.10 alpha:0.90];
    gBall.layer.cornerRadius = 26;
    gBall.layer.borderColor = kBKNeon.CGColor;
    gBall.layer.borderWidth = 2.0;

    UILabel *bl = [[UILabel alloc] initWithFrame:gBall.bounds];
    bl.text = @"Martin";
    bl.textAlignment = NSTextAlignmentCenter;
    bl.font = [UIFont boldSystemFontOfSize:11];
    bl.textColor = kBKNeon;
    bl.userInteractionEnabled = NO;
    [gBall addSubview:bl];

    [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gUI
        action:@selector(dragBall:)]];
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gUI
        action:@selector(tapBall:)]];

    [gBallWin.rootViewController.view addSubview:gBall];
    gBallWin.hidden = NO;
}

static void BKBuildCursor(void)
{
    gCursorWin = BKMakeWindow([UIScreen mainScreen].bounds, UIWindowLevelAlert + 2001, NO);
    gCursorWin.userInteractionEnabled = NO;

    gCursor = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    gCursor.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    gCursor.layer.cornerRadius = 9;
    gCursor.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    gCursor.layer.borderWidth = 1.5;
    [gCursorWin.rootViewController.view addSubview:gCursor];
    gCursorWin.hidden = YES;

    CGRect sb = [UIScreen mainScreen].bounds;
    gSpanW = sb.size.width;
    gSpanH = sb.size.height;
    gCurX = gSpanW * 0.5;
    gCurY = gSpanH * 0.5;
    gCurValid = YES;
}

static void BKInit(void)
{
    @try {
        gKeyDown = [NSMutableDictionary dictionary];
        gBtnDown = [NSMutableDictionary dictionary];
        gUI = [[BKUI alloc] init];
        BKAppend(@"init %s", BKTag);
        if (!BKInitIO()) { BKAppend(@"io falhou"); return; }
        BKLoadConfig();
        BKInstallHook();
        BKBuildBall();
        BKBuildCursor();
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 100ull * NSEC_PER_MSEC),
                                  100ull * NSEC_PER_MSEC, 30ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{ @try { BKRefresh(); } @catch (NSException *e) { } });
        dispatch_resume(t);
    } @catch (NSException *e) {
        BKAppend(@"init erro %@", e.reason);
    }
}

__attribute__((constructor)) static void BKInitC(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2500 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                @try { BKInit(); } @catch (NSException *e) { }
            });
        }
    });
}
