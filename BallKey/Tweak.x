// BallKey - mapeador de teclado e mouse - martidev333
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import "BKCore.h"
#import "BKEngine.h"
#import "BKUI.h"

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;
typedef uint64_t BKAbsTime;
typedef uint32_t IOOptionBits;
#define kFieldDigIsDisplayIntegrated 0x000B0046u
#define BK_FINGERS 10
#define BK_FBASE   40

static BKCore *gCore;
static NSString *gLog;
static UIWindow *gBallWin, *gCursorWin;
static UIView   *gBall, *gCursor, *gCanvas;
static NSMutableArray *gMarkViews;
static BOOL gMenuOpen, gEditOpen, gCursorOn, gGated, gFps, gFpsHeld;
static BOOL gHidOk, gGcMouse, gGcKey, gCursorDown, gLastValid, gInjAny;
static int  gFpsIdx = -1, gSelIdx = -1, gInjecting, gPtrMask;
static int  gFingerOwner[BK_FINGERS];
static double gCx, gCy, gLastX, gLastY;
static double gFingerX[BK_FINGERS], gFingerY[BK_FINGERS];
static int  gHoldKey[512];
static dispatch_source_t gTick, gFireTimer;
static int  gFireIdx = -1, gFireTaps = 0;
static BOOL gFireOn;
static int  gJoyFx, gJoyFy;

static IOHIDEventRef (*pCreateFinger)(CFAllocatorRef,BKAbsTime,uint32_t,uint32_t,uint32_t,
    IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,Boolean,Boolean,IOOptionBits);
static void (*pSetInt)(IOHIDEventRef,uint32_t,int64_t);
static int  (*pGetType)(IOHIDEventRef);
static double (*pGetFloat)(IOHIDEventRef,uint32_t);
static int64_t (*pGetInt)(IOHIDEventRef,uint32_t);
static void (*origEnq)(id,SEL,IOHIDEventRef);

#pragma mark - infra

static UIWindowScene *BKScene(void)
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)s;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    return nil;
}

CGSize BKSize(void)
{
    UIWindowScene *sc = BKScene();
    if (sc) return sc.coordinateSpace.bounds.size;
    return UIScreen.mainScreen.bounds.size;
}

static void BKLog(NSString *fmt, ...)
{
    if (!gLog) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), s];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLog];
    if (!h) [line writeToFile:gLog atomically:NO encoding:NSUTF8StringEncoding error:nil];
    else { @try { [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; } @catch (id e) {} }
}

static double BKClamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
static double BKNum(NSString *k, double d) { return [gCore doubleForKey:k def:d]; }

#pragma mark - finger pool

static int BKFingerTake(int owner)
{
    for (int i = 0; i < BK_FINGERS; i++) if (!gFingerOwner[i]) { gFingerOwner[i] = owner + 1; return BK_FBASE + i; }
    return -1;
}
static void BKFingerFree(int f)
{
    if (f >= BK_FBASE && f < BK_FBASE + BK_FINGERS) gFingerOwner[f - BK_FBASE] = 0;
}

#pragma mark - injection

static void BKInject(int finger, double x, double y, BOOL down, BOOL move)
{
    if (!pCreateFinger || !origEnq) return;
    uint32_t mask = move ? 4 : (down ? 3 : 0);
    IOHIDEventRef ev = pCreateFinger(kCFAllocatorDefault, mach_absolute_time(),
        (uint32_t)finger, (uint32_t)finger, mask, x, y, 0.0, down ? 1.0 : 0.0, 0.0,
        down ? 1 : 0, down ? 1 : 0, 0);
    if (!ev) return;
    if (pSetInt) pSetInt(ev, kFieldDigIsDisplayIntegrated, 1);
    gInjecting++;
    @try { origEnq(UIApplication.sharedApplication, @selector(_enqueueHIDEvent:), ev); }
    @catch (id e) {}
    gInjecting--;
    CFRelease(ev);
    if (finger >= BK_FBASE && finger < BK_FBASE + BK_FINGERS) {
        gFingerX[finger - BK_FBASE] = x; gFingerY[finger - BK_FBASE] = y;
    }
    if (down) gInjAny = YES;
}

static void BKTapAt(double x, double y)
{
    int f = BKFingerTake(900); if (f < 0) return;
    BKInject(f, x, y, YES, NO); BKInject(f, x, y, YES, YES); BKInject(f, x, y, NO, NO);
    BKFingerFree(f);
}

void BKReleaseAll(void)
{
    for (int i = 0; i < 512; i++) gHoldKey[i] = 0;
    if (gFireTimer) dispatch_source_set_timer(gFireTimer, DISPATCH_TIME_FOREVER, 0, 0);
    gFireOn = NO; gFireIdx = -1;
    for (int i = 0; i < BK_FINGERS; i++) {
        if (!gFingerOwner[i]) continue;
        BKInject(BK_FBASE + i, gFingerX[i], gFingerY[i], NO, NO);
        gFingerOwner[i] = 0;
    }
    if (gCursorDown) { BKInject(31, gCx, gCy, NO, NO); gCursorDown = NO; }
    gFps = gFpsHeld = NO;
}

#pragma mark - cursor

void BKCursorOnSet(BOOL on);
void BKCursorSet(BOOL on)
{
    if (on == gCursorOn) return;
    CGSize s = BKSize();
    if (on) {
        gCx = s.width * 0.5; gCy = s.height * 0.5; gLastValid = NO; gCursorOn = YES;
        if (gCursorWin) { gCursorWin.hidden = NO; gCursorWin.center = CGPointMake(gCx, gCy); }
        BKInject(31, gCx, gCy, YES, NO); gCursorDown = YES;
    } else {
        gCursorOn = NO; gFps = gFpsHeld = NO;
        if (gCursorDown) { BKInject(31, gCx, gCy, NO, NO); gCursorDown = NO; }
        if (gCursorWin) gCursorWin.hidden = YES;
    }
    [gCore setBool:gCursorOn forKey:kCursor];
}
BOOL BKCursorOn(void) { return gCursorOn; }

static double BKCurve(double v)
{
    switch ([gCore intForKey:kCurve def:BKCurveSoft]) {
        case BKCurveLinear: return v;
        case BKCurveFast:   return v * (1.0 + fabs(v) * 0.35);
        default: { double t = BKClamp(BKNum(kSmooth, 35) / 100.0, 0.0, 1.0);
                   return v * (1.0 - t) + (v * fabs(v)) * t; }
    }
}

void BKPointerDelta(double dx, double dy)
{
    CGSize s = BKSize();
    double sens = BKNum(kSens, 1.7) * 0.55;
    double yr = BKNum(kYRatio, 100) / 100.0;
    dx = BKCurve(dx * sens);
    dy = BKCurve(dy * sens * yr);
    if (!gCursorOn) return;

    if (gFps && gFpsHeld) {
        double bx = s.width * 0.5, by = s.height * 0.5;
        if (gFpsIdx >= 0 && gFpsIdx < (int)BKMarks().count) {
            bx = [BKMarks()[gFpsIdx][@"x"] doubleValue] * s.width;
            by = [BKMarks()[gFpsIdx][@"y"] doubleValue] * s.height;
        }
        double r = BKNum(kLockRadius, 70);
        double nx = gCx + dx, ny = gCy + dy;
        double d = hypot(nx - bx, ny - by);
        if (d > r) { nx = bx + (nx - bx) / d * r; ny = by + (ny - by) / d * r; }
        gCx = BKClamp(nx, 4, s.width - 4);
        gCy = BKClamp(ny, 4, s.height - 4);
        if ([gCore intForKey:kRecenter def:BKRecenterOnRelease] == BKRecenterAuto && d > r) {
            gCx = bx + (gCx - bx) * 0.55; gCy = by + (gCy - by) * 0.55;
        }
    } else {
        gCx = BKClamp(gCx + dx, 4, s.width - 4);
        gCy = BKClamp(gCy + dy, 4, s.height - 4);
    }
    if (gCursorWin) gCursorWin.center = CGPointMake(gCx, gCy);
    if (gCursorDown) BKInject(31, gCx, gCy, YES, YES);
}

#pragma mark - fire engine

static void BKFireStop(void)
{
    if (gFireIdx >= 0) {
        int f = BKFingerTake(gFireIdx);
        if (f >= 0) { NSDictionary *m = BKMarks()[gFireIdx];
            BKInject(f, [m[@"x"] doubleValue] * BKSize().width, [m[@"y"] doubleValue] * BKSize().height, NO, NO);
            BKFingerFree(f); }
    }
    gFireOn = NO;
    if (gFireTimer) dispatch_source_set_timer(gFireTimer, DISPATCH_TIME_FOREVER, 0, 0);
    if ([gCore boolForKey:kHoldAim def:YES]) BKButtonDown(2, NO);
}

static void BKFireTick(void)
{
    if (!gFireOn || gFireIdx < 0 || gFireIdx >= (int)BKMarks().count) return;
    NSDictionary *m = BKMarks()[gFireIdx];
    CGSize s = BKSize();
    BKTapAt([m[@"x"] doubleValue] * s.width, [m[@"y"] doubleValue] * s.height);
    gFireTaps++;
    int mode = [gCore intForKey:kTapMode def:BKTapModeHold];
    if (mode == BKTapModeFixed && gFireTaps >= [gCore intForKey:kRepeatCount def:4]) BKFireStop();
}

static void BKFireStart(int idx)
{
    if (gFireIdx == idx && gFireOn) {
        if ([gCore intForKey:kTapMode def:BKTapModeHold] == BKTapModeToggle) { BKFireStop(); return; }
    }
    BKFireStop();
    gFireIdx = idx; gFireTaps = 0; gFireOn = YES;
    if ([gCore boolForKey:kHoldAim def:YES]) BKButtonDown(2, YES);
    if ([gCore intForKey:kFireMode def:BKFireModeSingle] == BKFireModeSingle) {
        NSDictionary *m = BKMarks()[idx];
        BKTapAt([m[@"x"] doubleValue] * BKSize().width, [m[@"y"] doubleValue] * BKSize().height);
        return;
    }
    if (!gFireTimer) {
        gFireTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(gFireTimer, ^{ @try { BKFireTick(); } @catch (id e) {} });
        dispatch_resume(gFireTimer);
    }
    uint64_t ms = (uint64_t)BKNum(kRepeatDelay, 60);
    dispatch_source_set_timer(gFireTimer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                              ms * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    if ([gCore intForKey:kTapMode def:BKTapModeHold] == BKTapModeFixed) BKFireTick();
}

#pragma mark - markers

static void BKMarkerPress(int idx, BOOL down)
{
    if (idx < 0 || idx >= (int)BKMarks().count) return;
    NSDictionary *m = BKMarks()[idx];
    NSString *t = m[@"t"];
    CGSize s = BKSize();
    double x = [m[@"x"] doubleValue] * s.width, y = [m[@"y"] doubleValue] * s.height;

    if ([t isEqualToString:@"Tap"]) { if (down) BKTapAt(x, y); return; }
    if ([t isEqualToString:@"Fire"]) { if (down) BKFireStart(idx); else if (!gFireOn) BKFireStop(); return; }
    if ([t isEqualToString:@"Fps"]) {
        if (down) {
            gFps = YES; gFpsHeld = YES; gFpsIdx = idx; gCx = x; gCy = y;
            if (gCursorWin) gCursorWin.center = CGPointMake(gCx, gCy);
            if (gCursorDown) BKInject(31, gCx, gCy, YES, YES);
        } else { gFpsHeld = NO; gFps = NO; }
        return;
    }
    if (down) {
        int f = BKFingerTake(idx); if (f < 0) return;
        gFingerOwner[f - BK_FBASE] = idx + 1;
        BKInject(f, x, y, YES, NO);
        gHoldKey[idx] = f;
    } else if (gHoldKey[idx]) {
        int f = gHoldKey[idx]; gHoldKey[idx] = 0;
        BKInject(f, x, y, NO, NO);
        BKFingerFree(f);
    }
}

#pragma mark - capture

static void BKCaptureEvent(IOHIDEventRef ev)
{
    if (!ev) return;
    int type = pGetType ? pGetType(ev) : 0;
    if (type == 3) {
        int u = (int)(pGetInt ? pGetInt(ev, (uint32_t)((3 << 16) | 1)) : 0);
        int d = (int)(pGetInt ? pGetInt(ev, (uint32_t)((3 << 16) | 2)) : 0);
        if (u > 0) BKKeyUsage(u, d != 0);
        return;
    }
    if (type == 17 || type == 18) {
        double x = pGetFloat ? pGetFloat(ev, (uint32_t)((type << 16) | 1)) : 0;
        double y = pGetFloat ? pGetFloat(ev, (uint32_t)((type << 16) | 2)) : 0;
        int mask = (int)(pGetInt ? pGetInt(ev, (uint32_t)((type << 16) | 4)) : 0);
        if (gLastValid && fabs(x) < 9000 && fabs(y) < 9000) BKPointerDelta(x - gLastX, y - gLastY);
        gLastX = x; gLastY = y; gLastValid = YES;
        if (mask != gPtrMask) {
            if ((mask & 1) != (gPtrMask & 1)) BKButtonDown(1, (mask & 1) != 0);
            if ((mask & 2) != (gPtrMask & 2)) BKButtonDown(2, (mask & 2) != 0);
            gPtrMask = mask;
        }
    }
}

static void BKEnq(id self, SEL cmd, IOHIDEventRef ev)
{
    if (gInjecting == 0) @try { BKCaptureEvent(ev); } @catch (id e) {}
    if (origEnq) origEnq(self, cmd, ev);
}

void BKButtonDown(int btn, BOOL down)
{
    if (gGated || gMenuOpen || gEditOpen) return;
    if (btn == 1) { if (down) BKTapAt(gCx, gCy); return; }
    if (btn == 2) {
        CGSize s = BKSize();
        for (int i = 0; i < (int)BKMarks().count; i++) {
            if (![BKMarks()[i][@"t"] isEqualToString:@"Ads"]) continue;
            int f = BKFingerTake(i);
            if (f < 0) continue;
            double x = [BKMarks()[i][@"x"] doubleValue] * s.width;
            double y = [BKMarks()[i][@"y"] doubleValue] * s.height;
            if (down) BKInject(f, x, y, YES, NO);
            else { BKInject(f, x, y, NO, NO); BKFingerFree(f); }
        }
    }
}

void BKKeyUsage(int usage, BOOL down)
{
    if (gGated || gMenuOpen || gEditOpen) { if (gEditOpen && down) [BKUI editorKey:usage]; return; }
    for (int i = 0; i < (int)BKMarks().count; i++) {
        if ([BKMarks()[i][@"c"] intValue] != usage) continue;
        NSString *t = BKMarks()[i][@"t"];
        if ([t isEqualToString:@"Dir"]) {
            if (down) { if (gHoldKey[i]) return; gHoldKey[i] = 1; gJoyFx += 0; }
            else { if (!gHoldKey[i]) return; gHoldKey[i] = 0; }
            return;
        }
        BKMarkerPress(i, down);
        return;
    }
}

#pragma mark - joystick

static void BKJoystick(void)
{
    int dirs[64], n = 0;
    double sx = 0, sy = 0;
    for (int i = 0; i < (int)BKMarks().count && n < 64; i++) {
        if (![BKMarks()[i][@"t"] isEqualToString:@"Dir"]) continue;
        dirs[n++] = i;
        sx += [BKMarks()[i][@"x"] doubleValue];
        sy += [BKMarks()[i][@"y"] doubleValue];
    }
    if (!n) return;
    BOOL any = NO;
    for (int i = 0; i < n; i++) if (gHoldKey[dirs[i]]) { any = YES; break; }
    if (!any) return;

    double bx = sx / n, by = sy / n;
    if ([gCore intForKey:kJoyCenter def:BKJoyCenterAverage] == BKJoyCenterFixed) { bx = gJoyFx; by = gJoyFy; }
    else if ([gCore intForKey:kJoyCenter def:BKJoyCenterAverage] == BKJoyCenterRandom) {
        bx += ((double)(arc4random_uniform(1000)) / 1000.0 - 0.5) * 0.02;
        by += ((double)(arc4random_uniform(1000)) / 1000.0 - 0.5) * 0.02;
    }

    double vx = 0, vy = 0;
    for (int i = 0; i < n; i++) {
        if (!gHoldKey[dirs[i]]) continue;
        vx += [BKMarks()[dirs[i]][@"x"] doubleValue] - bx;
        vy += [BKMarks()[dirs[i]][@"y"] doubleValue] - by;
    }
    double len = hypot(vx, vy);
    if (len < 0.0001) return;
    vx /= len; vy /= len;
    if (![gCore boolForKey:kNormDiag def:YES] && (vx != 0 && vy != 0)) { vx *= 1.4142; vy *= 1.4142; }

    CGSize s = BKSize();
    double spd = BKNum(kJoySpeed, 7) * (s.width / 390.0);
    gCx = BKClamp(gCx + vx * spd, 4, s.width - 4);
    gCy = BKClamp(gCy + vy * spd, 4, s.height - 4);
    if (gCursorWin) gCursorWin.center = CGPointMake(gCx, gCy);
    if (gCursorDown) BKInject(31, gCx, gCy, YES, YES);
}

#pragma mark - devices

static void BKAttachMouse(void)
{
    GCMouse *m = GCMouse.current; gGcMouse = (m != nil);
    if (!m) return;
    BKLog(@"gc mouse ok");
    m.mouseInput.mouseMovedHandler = ^(GCMouseInput *in, float dx, float dy) { BKPointerDelta(dx, dy); };
    m.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { BKButtonDown(1, p); };
    m.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { BKButtonDown(2, p); };
    m.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { BKButtonDown(3, p); };
}

static void BKAttachKey(void)
{
    GCKeyboard *k = [GCKeyboard coalescedKeyboard]; gGcKey = (k != nil);
    if (!k) return;
    BKLog(@"gc key ok");
    k.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *in, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) {
        BKKeyUsage((int)code, pressed);
    };
}

static void BKInstall(void)
{
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (h) {
        pCreateFinger = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        pSetInt = dlsym(h, "IOHIDEventSetIntegerValue");
        pGetType = dlsym(h, "IOHIDEventGetType");
        pGetFloat = dlsym(h, "IOHIDEventGetFloatValue");
        pGetInt = dlsym(h, "IOHIDEventGetIntegerValue");
    }
    gHidOk = (pCreateFinger != NULL);
    Method m = class_getInstanceMethod(UIApplication.class, @selector(_enqueueHIDEvent:));
    if (m) { origEnq = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)BKEnq); }
}

#pragma mark - views

static UIWindow *BKWin(UIWindowLevel lv)
{
    UIWindowScene *sc = BKScene();
    UIWindow *w = sc ? [[UIWindow alloc] initWithWindowScene:sc] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.frame = CGRectMake(0, 0, BKSize().width, BKSize().height);
    w.windowLevel = lv;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = UIColor.clearColor;
    w.hidden = NO;
    return w;
}

@interface BKBallView : UIView @end
@implementation BKBallView
- (void)drawRect:(CGRect)r
{
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(c, [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.9].CGColor);
    CGContextFillEllipseInRect(c, CGRectInset(self.bounds, 1, 1));
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:1 green:0.42 blue:0.17 alpha:1].CGColor);
    CGContextSetLineWidth(c, 2);
    CGContextStrokeEllipseInRect(c, CGRectInset(self.bounds, 2, 2));
    [@"BK" drawAtPoint:CGPointMake(9, 12) withAttributes:@{
        NSFontAttributeName:[UIFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName:[UIColor colorWithRed:1 green:0.42 blue:0.17 alpha:1]}];
}
- (void)bkTap:(UITapGestureRecognizer *)g { BKMenuOpen(); }
@end

@interface BKCursorView : UIView @end
@implementation BKCursorView
- (void)drawRect:(CGRect)r
{
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:0 green:1 blue:0.6 alpha:0.95].CGColor);
    CGContextSetLineWidth(c, 2);
    CGContextStrokeEllipseInRect(c, CGRectInset(self.bounds, 3, 3));
    CGContextMoveToPoint(c, self.bounds.size.width/2, 4);
    CGContextAddLineToPoint(c, self.bounds.size.width/2, self.bounds.size.height-4);
    CGContextMoveToPoint(c, 4, self.bounds.size.height/2);
    CGContextAddLineToPoint(c, self.bounds.size.width-4, self.bounds.size.height/2);
    CGContextStrokePath(c);
}
@end

@interface BKMarkView : UIView @end
@implementation BKMarkView
- (void)bkPan:(UIPanGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGSize s = gCanvas.bounds.size;
    CGPoint d = [g translationInView:gCanvas];
    [g setTranslation:CGPointZero inView:gCanvas];
    CGPoint c = CGPointMake(self.center.x + d.x, self.center.y + d.y);
    c.x = BKClamp(c.x, 40, s.width - 40);
    c.y = BKClamp(c.y, 24, s.height - 24);
    if ([gCore boolForKey:kSnapGrid def:NO]) {
        c.x = round(c.x / (s.width / 20.0)) * (s.width / 20.0);
        c.y = round(c.y / (s.height / 12.0)) * (s.height / 12.0);
    }
    self.center = c;
    int i = (int)self.tag - 300;
    if (i >= 0 && i < (int)BKMarks().count) { BKMarks()[i][@"x"] = @(c.x / s.width); BKMarks()[i][@"y"] = @(c.y / s.height); }
}
- (void)bkPick:(UITapGestureRecognizer *)g { BKSelectMarker((int)self.tag - 300); }
@end

#pragma mark - engine api

NSMutableArray *BKMarks(void) { return [gCore marks]; }
int  BKSelectedMarker(void) { return gSelIdx; }
BOOL BKEditorOpen(void) { return gEditOpen; }
BOOL BKIsBusy(void) { return gMenuOpen || gEditOpen; }
void BKSetInputGated(BOOL g) { gGated = g; }

void BKSelectMarker(int idx)
{
    gSelIdx = idx;
    for (UIView *v in gMarkViews) {
        int j = (int)v.tag - 300;
        if (j < 0 || j >= (int)BKMarks().count) continue;
        v.layer.borderColor = BKUIColorFor(BKMarks()[j][@"t"]).CGColor;
        v.layer.borderWidth = 1.5;
    }
    if (idx >= 0) for (UIView *v in gMarkViews)
        if ((int)v.tag - 300 == idx) { v.layer.borderColor = UIColor.whiteColor.CGColor; v.layer.borderWidth = 2.5; }
    [BKUI editorSelectionChanged];
}

void BKRedrawMarkers(void)
{
    if (!gCanvas) return;
    for (UIView *v in gMarkViews) [v removeFromSuperview];
    gMarkViews = [NSMutableArray array];
    CGSize s = gCanvas.bounds.size;
    double k = s.width / 390.0;
    BOOL labels = [gCore boolForKey:kMarkLabels def:YES];
    double w = BKNum(kMarkSize, 76) * k, h = 40 * k;
    for (int i = 0; i < (int)BKMarks().count; i++) {
        NSDictionary *m = BKMarks()[i];
        BKMarkView *v = [[BKMarkView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
        v.center = CGPointMake([m[@"x"] doubleValue] * s.width, [m[@"y"] doubleValue] * s.height);
        UIColor *c = BKUIColorFor(m[@"t"]);
        v.backgroundColor = [c colorWithAlphaComponent:0.22];
        v.layer.borderColor = c.CGColor;
        v.layer.borderWidth = 1.5;
        v.layer.cornerRadius = 8 * k;
        v.tag = 300 + i;
        if (labels) {
            UILabel *l = [UILabel new];
            l.frame = v.bounds; l.text = BKNameFor(m[@"t"]);
            l.textColor = UIColor.whiteColor;
            l.font = [UIFont boldSystemFontOfSize:12 * k];
            l.textAlignment = NSTextAlignmentCenter;
            l.adjustsFontSizeToFitWidth = YES;
            [v addSubview:l];
        }
        [v addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:v action:@selector(bkPan:)]];
        [v addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:v action:@selector(bkPick:)]];
        [gCanvas addSubview:v];
        [gMarkViews addObject:v];
    }
    if (gSelIdx >= 0) BKSelectMarker(gSelIdx);
}

void BKSaveMarks(void) { [gCore save]; }
void BKReloadMarks(void) { [gCore load]; BKRedrawMarkers(); }

void BKApplySettings(void)
{
    BKCursorSet([gCore boolForKey:kCursor def:NO]);
    if (gCursorWin) {
        double d = BKNum(kCursorSize, 48);
        gCursorWin.frame = CGRectMake(0, 0, d, d);
        gCursor.frame = gCursorWin.bounds;
        gCursorWin.center = CGPointMake(gCx, gCy);
        [gCursor setNeedsDisplay];
        gCursor.alpha = [gCore boolForKey:kHideCursor def:YES] && !gCursorDown ? 0.45 : 1.0;
    }
    if (gCanvas) BKRedrawMarkers();
}

void BKRelayout(void)
{
    CGSize s = BKSize();
    if (gBallWin) gBallWin.frame = CGRectMake(0, 0, s.width, s.height);
    if (gBall) gBall.center = CGPointMake(28, 44);
    if (gCursorWin) gCursorWin.frame = CGRectMake(0, 0, BKNum(kCursorSize, 48), BKNum(kCursorSize, 48));
    if (gCanvas) { gCanvas.frame = CGRectMake(0, 0, s.width, s.height); BKRedrawMarkers(); }
    gCx = BKClamp(gCx, 4, s.width - 4); gCy = BKClamp(gCy, 4, s.height - 4);
    [BKUI relayout];
}

void BKMenuOpen(void) { [BKUI show]; gMenuOpen = YES; BKReleaseAll(); }
void BKMenuClose(void) { [BKUI hide]; gMenuOpen = NO; }
void BKEditorOpenUI(void) { [BKUI openEditor]; }

void BKSetEditorOpen(BOOL open)
{
    if (open == gEditOpen) return;
    gEditOpen = open;
    if (!open) { gCanvas = nil; gMarkViews = nil; gSelIdx = -1; BKReleaseAll(); }
}

#pragma mark - boot

static void BKStart(void)
{
    gCore = [BKCore shared];
    NSString *base = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
                      stringByAppendingPathComponent:@"BallKey"];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    gLog = [base stringByAppendingPathComponent:@"ballkey.log"];
    [@"" writeToFile:gLog atomically:NO encoding:NSUTF8StringEncoding error:nil];
    BKLog(@"boot v5");

    BKInstall();
    if (!gHidOk) { BKLog(@"hid fail"); return; }

    gBallWin = BKWin(UIWindowLevelAlert + 500);
    gBall = [[BKBallView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    gBall.center = CGPointMake(28, 44);
    gBall.backgroundColor = UIColor.clearColor;
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gBall action:@selector(bkTap:)]];
    [gBallWin.rootViewController.view addSubview:gBall];

    gCursorWin = BKWin(UIWindowLevelAlert + 600);
    gCursorWin.userInteractionEnabled = NO;
    double d = BKNum(kCursorSize, 48);
    gCursor = [[BKCursorView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
    gCursor.backgroundColor = UIColor.clearColor;
    [gCursorWin.rootViewController.view addSubview:gCursor];
    gCursorWin.hidden = YES;

    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { BKAttachMouse(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { BKAttachKey(); }];
    BKAttachMouse(); BKAttachKey();

    [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(),
                           ^{ BKRelayout(); });
        }];

    gTick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gTick, dispatch_time(DISPATCH_TIME_NOW, 0), 16 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTick, ^{ @try { BKJoystick(); } @catch (id e) {} });
    dispatch_resume(gTick);

    if ([gCore boolForKey:kCursor def:NO]) BKCursorSet(YES);
}

__attribute__((constructor))
static void BKInit(void)
{
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (![bid isEqualToString:@"com.dts.freefireth"] && ![bid isEqualToString:@"com.dts.freefiremax"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @autoreleasepool { @try { BKStart(); } @catch (id e) {} }
    });
}
