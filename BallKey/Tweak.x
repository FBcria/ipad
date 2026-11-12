// BallKey - mapeador de teclado e mouse para Free Fire
// martidev333
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;
typedef uint64_t BKAbsTime;
typedef uint32_t IOOptionBits;

#define kFieldDigIsDisplayIntegrated 0x000B0046u
#define kTransducerFinger 2

static NSString *gBase = nil;
static NSString *gCfg = nil;
static NSString *gLog = nil;

static NSMutableArray *gMarks = nil;
static NSMutableArray *gMarkViews = nil;

static UIWindow *gBallWin = nil;
static UIWindow *gCursorWin = nil;
static UIWindow *gMenuWin = nil;
static UIWindow *gEditWin = nil;
static UIView *gBall = nil;
static UIView *gCursor = nil;
static UIView *gCanvas = nil;
static UILabel *gStatus = nil;
static UILabel *gSel = nil;
static UILabel *gHint = nil;

static BOOL gReady = NO;
static BOOL gMenuOpen = NO;
static BOOL gEditOpen = NO;
static BOOL gCursorOn = NO;
static BOOL gFps = NO;
static BOOL gFpsHeld = NO;
static BOOL gHidOk = NO;
static BOOL gGcMouse = NO;
static BOOL gGcKey = NO;
static BOOL gCursorDown = NO;
static int gFpsIdx = -1;
static int gSelIdx = -1;
static int gInjecting = 0;
static int gHookSeen = 0;
static int gPtrSeen = 0;
static int gKeySeen = 0;
static int gInjSeen = 0;

static double gSens = 1.7;
static double gCx = 0.0, gCy = 0.0;
static double gLastX = 0.0, gLastY = 0.0;
static BOOL gLastValid = NO;
static int gPtrMask = 0;

static int gHoldKey[256];
static double gDirX = 0.0, gDirY = 0.0;
static int gDirCount = 0;
static dispatch_source_t gTick = NULL;

static IOHIDEventRef (*pCreateFinger)(CFAllocatorRef, BKAbsTime, uint32_t, uint32_t, uint32_t,
                                      IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                      Boolean, Boolean, IOOptionBits) = NULL;
static void (*pSetInt)(IOHIDEventRef, uint32_t, int64_t) = NULL;
static int (*pGetType)(IOHIDEventRef) = NULL;
static double (*pGetFloat)(IOHIDEventRef, uint32_t) = NULL;
static int64_t (*pGetInt)(IOHIDEventRef, uint32_t) = NULL;
static void (*origEnq)(id, SEL, IOHIDEventRef) = NULL;

static void BKLog(NSString *fmt, ...);
static void BKStatus(void);
static void BKSave(void);
static void BKLoad(void);
static void BKRedraw(void);
static void BKCursorSet(BOOL on);
static void BKCursorPaint(void);
static void BKPtrDelta(double dx, double dy);
static void BKKey(int usage, BOOL down);
static void BKButton(int btn, BOOL down);
static void BKMarkerPress(int idx, BOOL down);
static void BKReleaseAll(void);
static void BKInject(int finger, double x, double y, BOOL down, BOOL move);
static void BKBuildBall(void);
static void BKBuildCursor(void);
static void BKOpenMenu(void);
static void BKCloseMenu(void);
static void BKOpenEdit(void);
static void BKCloseEdit(void);
static void BKInstall(void);
static void BKCaptureStart(void);

@interface BKEdit : NSObject
+ (void)add:(UIButton *)b;
+ (void)del:(UIButton *)b;
+ (void)done:(UIButton *)b;
+ (void)cancel:(UIButton *)b;
+ (void)key:(int)usage;
@end

static NSString *BKPath(NSString *name)
{
    return [gBase stringByAppendingPathComponent:name];
}

static void BKLog(NSString *fmt, ...)
{
    if (!gLog) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                      CFAbsoluteTimeGetCurrent(), s];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLog];
    if (!h) {
        [line writeToFile:gLog atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        @try { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
        @catch (NSException *e) { }
    }
}

static double BKClamp(double v, double lo, double hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static CGSize BKSize(void)
{
    if (gBallWin) return gBallWin.bounds.size;
    return UIScreen.mainScreen.bounds.size;
}

#pragma mark - Config

static NSDictionary *BKDefaultMarks(void)
{
    return @{
        @"marks": @[
            @{@"t": @"Dir",  @"x": @0.15, @"y": @0.58, @"c": @26},
            @{@"t": @"Dir",  @"x": @0.06, @"y": @0.72, @"c": @4},
            @{@"t": @"Dir",  @"x": @0.15, @"y": @0.86, @"c": @22},
            @{@"t": @"Dir",  @"x": @0.24, @"y": @0.72, @"c": @7},
            @{@"t": @"Fire", @"x": @0.87, @"y": @0.80, @"c": @1},
            @{@"t": @"Ads",  @"x": @0.87, @"y": @0.62, @"c": @2},
            @{@"t": @"Fps",  @"x": @0.60, @"y": @0.50, @"c": @225},
            @{@"t": @"Press",@"x": @0.74, @"y": @0.88, @"c": @21},
            @{@"t": @"Tap",  @"x": @0.78, @"y": @0.74, @"c": @44}
        ]
    };
}

static void BKLoad(void)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:gCfg];
    if (!d) d = BKDefaultMarks();
    NSArray *a = d[@"marks"];
    gMarks = [NSMutableArray array];
    if ([a isKindOfClass:[NSArray class]]) {
        for (NSDictionary *m in a) {
            if (![m isKindOfClass:[NSDictionary class]]) continue;
            [gMarks addObject:[NSMutableDictionary dictionaryWithDictionary:m]];
        }
    }
    if (gMarks.count == 0) {
        for (NSDictionary *m in BKDefaultMarks()[@"marks"]) {
            [gMarks addObject:[NSMutableDictionary dictionaryWithDictionary:m]];
        }
    }
}

static void BKSave(void)
{
    NSDictionary *d = @{@"marks": gMarks};
    [d writeToFile:gCfg atomically:YES];
}

static NSString *BKName(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return @"Tocar";
    if ([t isEqualToString:@"Press"]) return @"Pressionar";
    if ([t isEqualToString:@"Dir"]) return @"Direção";
    if ([t isEqualToString:@"Fps"]) return @"Trava";
    if ([t isEqualToString:@"Ads"]) return @"Mirar";
    if ([t isEqualToString:@"Fire"]) return @"Atirar";
    return t;
}

static UIColor *BKColor(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return [UIColor colorWithRed:0.00 green:0.70 blue:1.00 alpha:1];
    if ([t isEqualToString:@"Press"]) return [UIColor colorWithRed:0.00 green:0.90 blue:0.45 alpha:1];
    if ([t isEqualToString:@"Dir"]) return [UIColor colorWithRed:0.65 green:0.40 blue:1.00 alpha:1];
    if ([t isEqualToString:@"Fps"]) return [UIColor colorWithRed:1.00 green:0.20 blue:0.45 alpha:1];
    if ([t isEqualToString:@"Ads"]) return [UIColor colorWithRed:1.00 green:0.62 blue:0.00 alpha:1];
    return [UIColor colorWithRed:1.00 green:0.30 blue:0.20 alpha:1];
}

#pragma mark - Injeção

static void BKInject(int finger, double x, double y, BOOL down, BOOL move)
{
    if (!pCreateFinger || !origEnq) return;
    uint32_t mask = move ? 4 : 3;
    IOHIDEventRef ev = pCreateFinger(kCFAllocatorDefault, mach_absolute_time(),
                                     kTransducerFinger,
                                     (uint32_t)finger, (uint32_t)finger,
                                     mask, x, y, 0.0, down ? 1.0 : 0.0, 0.0,
                                     down ? 1 : 0, down ? 1 : 0, 0);
    if (!ev) return;
    if (pSetInt) pSetInt(ev, kFieldDigIsDisplayIntegrated, 1);
    gInjecting++;
    @try { origEnq(UIApplication.sharedApplication, @selector(_enqueueHIDEvent:), ev); }
    @catch (NSException *e) { }
    gInjecting--;
    gInjSeen++;
    CFRelease(ev);
}

static void BKTap(int finger, double x, double y)
{
    BKInject(finger, x, y, YES, NO);
    BKInject(finger, x, y, YES, YES);
    BKInject(finger, x, y, NO, NO);
}

#pragma mark - Cursor

static void BKCursorPaint(void)
{
    if (!gCursorWin || !gCursor) return;
    gCursorWin.hidden = !gCursorOn;
    if (gCursorOn) gCursorWin.center = CGPointMake(gCx, gCy);
}

static void BKCursorSet(BOOL on)
{
    if (on == gCursorOn) return;
    CGSize s = BKSize();
    if (on) {
        gCx = s.width * 0.5;
        gCy = s.height * 0.5;
        gLastValid = NO;
        gCursorOn = YES;
        if (gCursorWin) gCursorWin.hidden = NO;
        BKCursorPaint();
        BKInject(31, gCx, gCy, YES, NO);
        gCursorDown = YES;
        BKLog(@"cursor on %.1f %.1f", gCx, gCy);
    } else {
        gCursorOn = NO;
        gFps = NO;
        gFpsHeld = NO;
        if (gCursorDown) { BKInject(31, gCx, gCy, NO, NO); gCursorDown = NO; }
        BKCursorPaint();
        BKLog(@"cursor off");
    }
}

static void BKPtrDelta(double dx, double dy)
{
    CGSize s = BKSize();
    gPtrSeen++;

    if (gFps && gFpsHeld) {
        double bx = s.width * 0.5, by = s.height * 0.5;
        if (gFpsIdx >= 0 && gFpsIdx < (int)gMarks.count) {
            bx = [gMarks[gFpsIdx][@"x"] doubleValue] * s.width;
            by = [gMarks[gFpsIdx][@"y"] doubleValue] * s.height;
        }
        gCx = BKClamp(gCx + dx * gSens * 0.45, bx - 70, bx + 70);
        gCy = BKClamp(gCy + dy * gSens * 0.45, by - 70, by + 70);
    } else if (gCursorOn) {
        gCx = BKClamp(gCx + dx * gSens, 4, s.width - 4);
        gCy = BKClamp(gCy + dy * gSens, 4, s.height - 4);
    } else {
        return;
    }

    if (gCursorWin) gCursorWin.center = CGPointMake(gCx, gCy);
    if (gCursorDown) BKInject(31, gCx, gCy, YES, YES);
}

#pragma mark - Ações

static void BKMarkerPress(int idx, BOOL down)
{
    if (idx < 0 || idx >= (int)gMarks.count) return;
    NSDictionary *m = gMarks[idx];
    NSString *t = m[@"t"];
    CGSize s = BKSize();
    double x = [m[@"x"] doubleValue] * s.width;
    double y = [m[@"y"] doubleValue] * s.height;

    if ([t isEqualToString:@"Tap"]) {
        if (down) BKTap(32 + (idx % 8), x, y);
    } else if ([t isEqualToString:@"Press"]) {
        BKInject(32 + (idx % 8), x, y, down, NO);
    } else if ([t isEqualToString:@"Ads"]) {
        BKInject(32 + (idx % 8), x, y, down, NO);
    } else if ([t isEqualToString:@"Fire"]) {
        BKInject(32 + (idx % 8), x, y, down, NO);
    } else if ([t isEqualToString:@"Fps"]) {
        if (down) {
            gFps = YES;
            gFpsHeld = YES;
            gFpsIdx = idx;
            gCx = x;
            gCy = y;
            BKCursorPaint();
            if (gCursorDown) BKInject(31, gCx, gCy, YES, YES);
        } else {
            gFpsHeld = NO;
            gFps = NO;
        }
    }
}

static void BKKey(int usage, BOOL down)
{
    gKeySeen++;

    if (gEditOpen) {
        if (down) [BKEdit key:usage];
        return;
    }

    for (int i = 0; i < (int)gMarks.count; i++) {
        NSDictionary *m = gMarks[i];
        if ([m[@"c"] intValue] != usage) continue;
        NSString *t = m[@"t"];

        if ([t isEqualToString:@"Dir"]) {
            if (down) {
                if (gHoldKey[i]) break;
                gHoldKey[i] = 1;
                gDirCount++;
            } else {
                if (!gHoldKey[i]) break;
                gHoldKey[i] = 0;
                gDirCount--;
            }
            break;
        }
        if ([t isEqualToString:@"Press"] || [t isEqualToString:@"Ads"] || [t isEqualToString:@"Fire"]) {
            if (down && gHoldKey[i]) break;
            if (!down && !gHoldKey[i]) break;
            gHoldKey[i] = down ? 1 : 0;
            BKMarkerPress(i, down);
            break;
        }
        BKMarkerPress(i, down);
        break;
    }
}

static void BKButton(int btn, BOOL down)
{
    if (btn == 1) {
        if (down) BKTap(41, gCx, gCy);
        return;
    }
    if (btn == 2) {
        CGSize s = BKSize();
        for (int i = 0; i < (int)gMarks.count; i++) {
            if (![gMarks[i][@"t"] isEqualToString:@"Ads"]) continue;
            BKInject(42, [gMarks[i][@"x"] doubleValue] * s.width,
                     [gMarks[i][@"y"] doubleValue] * s.height, down, NO);
        }
    }
}

static void BKReleaseAll(void)
{
    for (int i = 0; i < 256; i++) gHoldKey[i] = 0;
    gDirCount = 0;
    gDirX = 0;
    gDirY = 0;
}

static void BKJoystick(void)
{
    if (gDirCount <= 0) return;

    double sx = 0, sy = 0;
    int n = 0;
    for (int i = 0; i < (int)gMarks.count; i++) {
        if (![gMarks[i][@"t"] isEqualToString:@"Dir"]) continue;
        sx += [gMarks[i][@"x"] doubleValue];
        sy += [gMarks[i][@"y"] doubleValue];
        n++;
    }
    if (n == 0) return;
    double bx = sx / n, by = sy / n;

    double vx = 0, vy = 0;
    for (int i = 0; i < (int)gMarks.count; i++) {
        if (!gHoldKey[i]) continue;
        if (![gMarks[i][@"t"] isEqualToString:@"Dir"]) continue;
        vx += [gMarks[i][@"x"] doubleValue] - bx;
        vy += [gMarks[i][@"y"] doubleValue] - by;
    }
    double len = sqrt(vx * vx + vy * vy);
    if (len < 0.0001) return;
    vx /= len;
    vy /= len;

    CGSize s = BKSize();
    gCx = BKClamp(gCx + vx * 7.0, 4, s.width - 4);
    gCy = BKClamp(gCy + vy * 7.0, 4, s.height - 4);
    if (gCursorWin) gCursorWin.center = CGPointMake(gCx, gCy);
    if (gCursorDown) BKInject(31, gCx, gCy, YES, YES);
}

static void BKCaptureEvent(IOHIDEventRef ev)
{
    if (!ev) return;
    int type = pGetType ? pGetType(ev) : 0;

    if (type == 3) {
        gHookSeen++;
        int usage = (int)(pGetInt ? pGetInt(ev, (uint32_t)((3 << 16) | 1)) : 0);
        int dn = (int)(pGetInt ? pGetInt(ev, (uint32_t)((3 << 16) | 2)) : 0);
        if (usage > 0) BKKey(usage, dn != 0);
        return;
    }

    if (type == 17 || type == 18) {
        gHookSeen++;
        double x = pGetFloat ? pGetFloat(ev, (uint32_t)((type << 16) | 1)) : 0;
        double y = pGetFloat ? pGetFloat(ev, (uint32_t)((type << 16) | 2)) : 0;
        int mask = (int)(pGetInt ? pGetInt(ev, (uint32_t)((type << 16) | 4)) : 0);
        if (gLastValid && fabs(x) < 9000 && fabs(y) < 9000) {
            BKPtrDelta(x - gLastX, y - gLastY);
        }
        gLastX = x;
        gLastY = y;
        gLastValid = YES;
        if (mask != gPtrMask) {
            if ((mask & 1) && !(gPtrMask & 1)) BKButton(1, YES);
            if (!(mask & 1) && (gPtrMask & 1)) BKButton(1, NO);
            if ((mask & 2) && !(gPtrMask & 2)) BKButton(2, YES);
            if (!(mask & 2) && (gPtrMask & 2)) BKButton(2, NO);
            gPtrMask = mask;
        }
    }
}

static void BKEnq(id self, SEL cmd, IOHIDEventRef ev)
{
    if (gInjecting == 0) {
        @try { BKCaptureEvent(ev); } @catch (NSException *e) { }
    }
    if (origEnq) origEnq(self, cmd, ev);
}

#pragma mark - Captura GC

static void BKAttachMouse(void)
{
    GCMouse *m = GCMouse.current;
    if (!m) { gGcMouse = NO; return; }
    gGcMouse = YES;
    BKLog(@"gc mouse ok");
    m.mouseInput.mouseMovedHandler = ^(GCMouseInput *in, float dx, float dy) {
        BKPtrDelta(dx, dy);
    };
    m.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) {
        BKButton(1, p);
    };
    m.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) {
        BKButton(2, p);
    };
    m.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) {
        BKButton(3, p);
    };
}

static void BKAttachKey(void)
{
    GCKeyboard *k = [GCKeyboard coalescedKeyboard];
    if (!k) { gGcKey = NO; return; }
    gGcKey = YES;
    BKLog(@"gc key ok");
    k.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *in, GCControllerButtonInput *key,
                                          GCKeyCode code, BOOL pressed) {
        BKKey((int)code, pressed);
    };
}

static void BKCaptureStart(void)
{
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { BKAttachMouse(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { BKAttachKey(); }];
    BKAttachMouse();
    BKAttachKey();
}

#pragma mark - Hooks

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
    if (!pCreateFinger) {
        void *d = dlopen(NULL, RTLD_LAZY);
        pCreateFinger = dlsym(d, "IOHIDEventCreateDigitizerFingerEvent");
        pSetInt = dlsym(d, "IOHIDEventSetIntegerValue");
        pGetType = dlsym(d, "IOHIDEventGetType");
        pGetFloat = dlsym(d, "IOHIDEventGetFloatValue");
        pGetInt = dlsym(d, "IOHIDEventGetIntegerValue");
    }
    gHidOk = (pCreateFinger != NULL);

    Method m = class_getInstanceMethod([UIApplication class], @selector(_enqueueHIDEvent:));
    if (m) {
        origEnq = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)BKEnq);
        BKLog(@"hook enq ok");
    } else {
        BKLog(@"hook enq fail");
    }
}

#pragma mark - Marcadores

static void BKRedraw(void)
{
    if (!gCanvas) return;
    for (UIView *v in gMarkViews) [v removeFromSuperview];
    [gMarkViews removeAllObjects];

    CGSize s = gCanvas.bounds.size;
    for (int i = 0; i < (int)gMarks.count; i++) {
        NSDictionary *m = gMarks[i];
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 76, 40)];
        v.center = CGPointMake([m[@"x"] doubleValue] * s.width, [m[@"y"] doubleValue] * s.height);
        v.backgroundColor = [BKColor(m[@"t"]) colorWithAlphaComponent:0.30];
        v.layer.borderWidth = 1.5;
        v.layer.borderColor = BKColor(m[@"t"]).CGColor;
        v.layer.cornerRadius = 8;
        v.tag = 300 + i;

        UILabel *l = [[UILabel alloc] initWithFrame:v.bounds];
        l.text = BKName(m[@"t"]);
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont boldSystemFontOfSize:12];
        l.textAlignment = NSTextAlignmentCenter;
        l.adjustsFontSizeToFitWidth = YES;
        [v addSubview:l];

        UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:v
                                        action:@selector(bkPan:)];
        [v addGestureRecognizer:p];
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:v
                                        action:@selector(bkPick:)];
        [v addGestureRecognizer:t];

        [gCanvas addSubview:v];
        [gMarkViews addObject:v];
    }
    if (gSel) gSel.text = gSelIdx >= 0 ? @"Aperte uma tecla para ligar" : @"Toque num marcador";
}

#pragma mark - Views

@interface BKBallView : UIView
@end

@implementation BKBallView
- (void)drawRect:(CGRect)r
{
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(c, [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.90].CGColor);
    CGContextFillEllipseInRect(c, CGRectInset(self.bounds, 1, 1));
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:0 green:0.9 blue:1 alpha:1].CGColor);
    CGContextSetLineWidth(c, 2);
    CGContextStrokeEllipseInRect(c, CGRectInset(self.bounds, 2, 2));
    [@"BK" drawAtPoint:CGPointMake(9, 12) withAttributes:@{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName: [UIColor colorWithRed:0 green:0.9 blue:1 alpha:1]}];
}
- (void)bkTap:(UITapGestureRecognizer *)g
{
    if (gMenuOpen) BKCloseMenu();
    else BKOpenMenu();
}
@end

@interface BKCursorView : UIView
@end

@implementation BKCursorView
- (void)drawRect:(CGRect)r
{
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:0 green:1 blue:0.6 alpha:0.95].CGColor);
    CGContextSetLineWidth(c, 2);
    CGContextStrokeEllipseInRect(c, CGRectInset(self.bounds, 3, 3));
    CGContextMoveToPoint(c, self.bounds.size.width / 2, 4);
    CGContextAddLineToPoint(c, self.bounds.size.width / 2, self.bounds.size.height - 4);
    CGContextMoveToPoint(c, 4, self.bounds.size.height / 2);
    CGContextAddLineToPoint(c, self.bounds.size.width - 4, self.bounds.size.height / 2);
    CGContextStrokePath(c);
}
@end

@interface BKMarkView : UIView
@end

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
    self.center = c;
    int i = (int)self.tag - 300;
    if (i >= 0 && i < (int)gMarks.count) {
        gMarks[i][@"x"] = @(c.x / s.width);
        gMarks[i][@"y"] = @(c.y / s.height);
    }
}
- (void)bkPick:(UITapGestureRecognizer *)g
{
    gSelIdx = (int)self.tag - 300;
    for (UIView *v in gMarkViews) {
        int j = (int)v.tag - 300;
        if (j < 0 || j >= (int)gMarks.count) continue;
        v.layer.borderColor = BKColor(gMarks[j][@"t"]).CGColor;
    }
    self.layer.borderColor = UIColor.whiteColor.CGColor;
    if (gSel) gSel.text = @"Aperte uma tecla para ligar";
}
@end

#pragma mark - Menu

@interface BKMenu : NSObject
+ (void)refresh;
+ (void)toggleCursor:(UIButton *)b;
+ (void)sensChanged:(UISlider *)s;
+ (void)openEdit:(UIButton *)b;
+ (void)close:(UIButton *)b;
+ (void)reset:(UIButton *)b;
@end

@implementation BKMenu

+ (void)refresh
{
    if (!gStatus) return;
    gStatus.text = [NSString stringWithFormat:
        @"hk:%@ inj:%@ ptr:%d key:%d cap:%d gc:%d%d\nmodo:%@ sens:%.1f",
        gHidOk ? @"S" : @"N", origEnq ? @"S" : @"N",
        gPtrSeen, gKeySeen, gHookSeen, (int)gGcMouse, (int)gGcKey,
        gCursorOn ? @"CURSOR" : (gFps ? @"TRAVA" : @"-"), gSens];
    gStatus.textColor = gCursorOn ? [UIColor colorWithRed:0 green:1 blue:0.6 alpha:1]
                                  : [UIColor colorWithRed:0 green:0.9 blue:1 alpha:1];
}

+ (void)toggleCursor:(UIButton *)b
{
    BKCursorSet(!gCursorOn);
    [b setTitle:(gCursorOn ? @"CURSOR LIGADO" : @"CURSOR DESLIGADO") forState:UIControlStateNormal];
    [BKMenu refresh];
}

+ (void)sensChanged:(UISlider *)s
{
    gSens = s.value;
    [BKMenu refresh];
}

+ (void)openEdit:(UIButton *)b
{
    BKCloseMenu();
    BKOpenEdit();
}

+ (void)close:(UIButton *)b
{
    BKCloseMenu();
}

+ (void)reset:(UIButton *)b
{
    [gMarks removeAllObjects];
    for (NSDictionary *m in BKDefaultMarks()[@"marks"]) {
        [gMarks addObject:[NSMutableDictionary dictionaryWithDictionary:m]];
    }
    BKSave();
    [BKMenu refresh];
}

@end

#pragma mark - Editor

@implementation BKEdit

+ (void)add:(UIButton *)b
{
    NSArray *types = @[@"Tap", @"Press", @"Dir", @"Fps", @"Ads", @"Fire"];
    [gMarks addObject:[NSMutableDictionary dictionaryWithDictionary:
        @{@"t": types[b.tag - 200], @"x": @(0.5), @"y": @(0.5), @"c": @0}]];
    gSelIdx = (int)gMarks.count - 1;
    BKRedraw();
}

+ (void)del:(UIButton *)b
{
    if (gSelIdx < 0 || gSelIdx >= (int)gMarks.count) return;
    [gMarks removeObjectAtIndex:gSelIdx];
    gSelIdx = -1;
    BKRedraw();
}

+ (void)done:(UIButton *)b
{
    BKSave();
    BKCloseEdit();
}

+ (void)cancel:(UIButton *)b
{
    BKLoad();
    BKCloseEdit();
}

+ (void)key:(int)usage
{
    if (gSelIdx < 0 || gSelIdx >= (int)gMarks.count) return;
    gMarks[gSelIdx][@"c"] = @(usage);
    if (gSel) gSel.text = [NSString stringWithFormat:@"Tecla %d ligada", usage];
}

@end

#pragma mark - Janelas

static UIWindow *BKMakeWindow(CGRect f, UIWindowLevel lv)
{
    UIWindow *w = [[UIWindow alloc] initWithFrame:f];
    w.windowLevel = lv;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [[UIViewController alloc] init];
    w.rootViewController.view.backgroundColor = UIColor.clearColor;
    w.hidden = NO;
    return w;
}

static UILabel *BKMakeLabel(CGRect f, CGFloat size, UIColor *c)
{
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.textColor = c;
    l.font = [UIFont boldSystemFontOfSize:size];
    l.numberOfLines = 0;
    return l;
}

static UIButton *BKMakeBtn(NSString *title, CGRect f, UIColor *c)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:c forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.backgroundColor = [c colorWithAlphaComponent:0.12];
    b.layer.borderWidth = 1;
    b.layer.borderColor = [c colorWithAlphaComponent:0.7].CGColor;
    b.layer.cornerRadius = 8;
    return b;
}

static void BKBuildBall(void)
{
    gBallWin = BKMakeWindow(CGRectMake(0, 40, 60, 60), UIWindowLevelAlert + 200);
    gBall = [[BKBallView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
    gBall.backgroundColor = UIColor.clearColor;
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gBall
                                       action:@selector(bkTap:)]];
    [gBallWin.rootViewController.view addSubview:gBall];
}

static void BKBuildCursor(void)
{
    gCursorWin = BKMakeWindow(CGRectMake(0, 0, 48, 48), UIWindowLevelAlert + 300);
    gCursorWin.userInteractionEnabled = NO;
    gCursor = [[BKCursorView alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    gCursor.backgroundColor = UIColor.clearColor;
    [gCursorWin.rootViewController.view addSubview:gCursor];
    gCursorWin.hidden = YES;
}

static void BKOpenMenu(void)
{
    if (gMenuOpen) return;
    gMenuOpen = YES;
    CGSize s = BKSize();

    gMenuWin = BKMakeWindow(CGRectMake(0, 0, s.width, s.height), UIWindowLevelAlert + 100);
    UIView *r = gMenuWin.rootViewController.view;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(14, s.height * 0.5 - 200, s.width - 28, 400)];
    panel.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.07 alpha:0.96];
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithRed:0 green:0.9 blue:1 alpha:0.5].CGColor;
    panel.layer.cornerRadius = 14;
    [r addSubview:panel];

    UILabel *t = BKMakeLabel(CGRectMake(14, 12, panel.bounds.size.width - 28, 26), 17,
                             [UIColor colorWithRed:0 green:0.9 blue:1 alpha:1]);
    t.text = @"Mapeador de Teclado e Mouse";
    t.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:t];

    gStatus = BKMakeLabel(CGRectMake(14, 44, panel.bounds.size.width - 28, 52), 12,
                          [UIColor colorWithRed:0 green:0.9 blue:1 alpha:1]);
    [panel addSubview:gStatus];

    UIButton *c = BKMakeBtn(@"CURSOR DESLIGADO", CGRectMake(14, 104, panel.bounds.size.width - 28, 44),
                            [UIColor colorWithRed:0 green:1 blue:0.6 alpha:1]);
    [c addTarget:[BKMenu class] action:@selector(toggleCursor:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:c];

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(14, 156, panel.bounds.size.width - 28, 30)];
    sl.minimumValue = 0.4;
    sl.maximumValue = 4.0;
    sl.value = gSens;
    sl.tintColor = [UIColor colorWithRed:0 green:0.9 blue:1 alpha:1];
    [sl addTarget:[BKMenu class] action:@selector(sensChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:sl];

    UIButton *m = BKMakeBtn(@"MAPEAR BOTÕES", CGRectMake(14, 196, panel.bounds.size.width - 28, 44),
                            [UIColor colorWithRed:0.65 green:0.40 blue:1 alpha:1]);
    [m addTarget:[BKMenu class] action:@selector(openEdit:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:m];

    UIButton *rs = BKMakeBtn(@"RESTAURAR PADRÃO", CGRectMake(14, 248, panel.bounds.size.width - 28, 40),
                             [UIColor colorWithRed:1 green:0.62 blue:0 alpha:1]);
    [rs addTarget:[BKMenu class] action:@selector(reset:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:rs];

    UILabel *cr = BKMakeLabel(CGRectMake(14, 300, panel.bounds.size.width - 28, 40), 11, UIColor.grayColor);
    cr.text = @"martidev333  -  BallKey\nEsquerdo: atirar   Direito: mirar   Shift: trava";
    cr.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:cr];

    UIButton *f = BKMakeBtn(@"FECHAR", CGRectMake(14, 346, panel.bounds.size.width - 28, 42),
                            [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1]);
    [f addTarget:[BKMenu class] action:@selector(close:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:f];

    [BKMenu refresh];
}

static void BKCloseMenu(void)
{
    if (!gMenuOpen) return;
    gMenuOpen = NO;
    gMenuWin.hidden = YES;
    gMenuWin = nil;
    gStatus = nil;
    BKReleaseAll();
}

static void BKOpenEdit(void)
{
    if (gEditOpen) return;
    gEditOpen = YES;
    gSelIdx = -1;
    CGSize s = BKSize();

    gEditWin = BKMakeWindow(CGRectMake(0, 0, s.width, s.height), UIWindowLevelAlert + 150);
    UIView *r = gEditWin.rootViewController.view;

    gCanvas = [[UIView alloc] initWithFrame:CGRectMake(0, 0, s.width, s.height)];
    gCanvas.backgroundColor = UIColor.clearColor;
    [r addSubview:gCanvas];
    gMarkViews = [NSMutableArray array];

    UIView *top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, s.width, 136)];
    top.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.07 alpha:0.94];
    [r addSubview:top];

    gHint = BKMakeLabel(CGRectMake(10, 6, s.width - 20, 34), 13,
                        [UIColor colorWithRed:0 green:0.9 blue:1 alpha:1]);
    gHint.text = @"Arraste os marcadores. Toque para escolher e apertar a tecla.";
    gHint.numberOfLines = 2;
    [top addSubview:gHint];

    gSel = BKMakeLabel(CGRectMake(10, 44, s.width - 150, 32), 12, UIColor.lightGrayColor);
    [top addSubview:gSel];

    UIButton *ok = BKMakeBtn(@"SALVAR", CGRectMake(s.width - 132, 8, 60, 34),
                             [UIColor colorWithRed:0 green:1 blue:0.6 alpha:1]);
    [ok addTarget:[BKEdit class] action:@selector(done:) forControlEvents:UIControlEventTouchUpInside];
    [top addSubview:ok];

    UIButton *no = BKMakeBtn(@"SAIR", CGRectMake(s.width - 66, 8, 56, 34),
                             [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1]);
    [no addTarget:[BKEdit class] action:@selector(cancel:) forControlEvents:UIControlEventTouchUpInside];
    [top addSubview:no];

    UIButton *dl = BKMakeBtn(@"APAGAR", CGRectMake(10, 96, 80, 34),
                             [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1]);
    [dl addTarget:[BKEdit class] action:@selector(del:) forControlEvents:UIControlEventTouchUpInside];
    [top addSubview:dl];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, s.height - 62, s.width, 62)];
    bar.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.07 alpha:0.94];
    [r addSubview:bar];

    NSArray *names = @[@"+ Tocar", @"+ Pressionar", @"+ Direção", @"+ Trava", @"+ Mirar", @"+ Atirar"];
    NSArray *types = @[@"Tap", @"Press", @"Dir", @"Fps", @"Ads", @"Fire"];
    CGFloat w = (s.width - 20) / 6.0;
    for (int i = 0; i < 6; i++) {
        UIButton *b = BKMakeBtn(names[i], CGRectMake(10 + w * i, s.height - 54, w - 4, 44),
                                BKColor(types[i]));
        b.tag = 200 + i;
        [b addTarget:[BKEdit class] action:@selector(add:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
    }

    BKRedraw();
}

static void BKCloseEdit(void)
{
    if (!gEditOpen) return;
    gEditOpen = NO;
    gEditWin.hidden = YES;
    gEditWin = nil;
    gCanvas = nil;
    gMarkViews = nil;
    gSel = nil;
    gHint = nil;
    gSelIdx = -1;
    BKReleaseAll();
}

#pragma mark - Boot

static void BKTick(void)
{
    @try { BKJoystick(); } @catch (NSException *e) { }
}

static void BKStatus(void)
{
    NSString *s = [NSString stringWithFormat:@"hk:%@ inj:%@ key:%d ptr:%d cap:%d gc:%d%d injn:%d",
                   gHidOk ? @"S" : @"N", origEnq ? @"S" : @"N",
                   gKeySeen, gPtrSeen, gHookSeen, (int)gGcMouse, (int)gGcKey, gInjSeen];
    [s writeToFile:BKPath(@"status.txt") atomically:NO encoding:NSUTF8StringEncoding error:nil];
    BKLog(@"status %@", s);
}

static void BKStart(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    gBase = [[d firstObject] stringByAppendingPathComponent:@"BallKey"];
    [fm createDirectoryAtPath:gBase withIntermediateDirectories:YES attributes:nil error:nil];
    gCfg = BKPath(@"marks.plist");
    gLog = BKPath(@"ballkey.log");
    [@"" writeToFile:gLog atomically:NO encoding:NSUTF8StringEncoding error:nil];
    BKLog(@"boot v3");

    BKLoad();
    BKBuildBall();
    BKBuildCursor();
    BKInstall();
    BKCaptureStart();
    BKStatus();

    gTick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gTick, dispatch_time(DISPATCH_TIME_NOW, 0),
                              16 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTick, ^{ BKTick(); });
    dispatch_resume(gTick);

    gReady = YES;
}

__attribute__((constructor))
static void BKInit(void)
{
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (![bid isEqualToString:@"com.dts.freefireth"] &&
        ![bid isEqualToString:@"com.dts.freefiremax"]) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { BKStart(); }
        @catch (NSException *e) { }
    });
}
