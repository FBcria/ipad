// BallKey 6.0 - mapeador de teclado e mouse (SpringBoard) - martidev333
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/vm_prot.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#ifndef INDIRECT_SYMBOL_LOCAL
#define INDIRECT_SYMBOL_LOCAL 0x80000000
#endif
#ifndef INDIRECT_SYMBOL_ABS
#define INDIRECT_SYMBOL_ABS 0x40000000
#endif

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;
typedef uint64_t BKAbsTime;
typedef uint32_t IOOptionBits;
#define kFieldDigIsDisplayIntegrated 0xB0019u
#define BK_FINGERS 10
#define BK_FBASE 40
#define BK_DW 1180.0
#define BK_DH 760.0
#define BK_SBW 210.0
static CGFloat gDW = BK_DW, gDH = BK_DH, gSB = BK_SBW;
#define DW gDW
#define DH gDH
#define SBW gSB
#define BK_GAME @"com.dts.freefireth"
#define BK_GAMEMAX @"com.dts.freefiremax"
#define BK_ME @"com.wjf.ballkeyapp"
#define BK_SAFE @"/var/mobile/Documents/BallKey/safe"
#define BK_SENDER 0x8000000817319375ULL

CGSize BKSize(void);
void BKRelayout(void); void BKSetInputGated(BOOL g); void BKSetEditorOpen(BOOL open);
void BKCursorSet(BOOL on); BOOL BKCursorOn(void); void BKApplySettings(void); void BKReleaseAll(void);
NSMutableArray *BKMarks(void); void BKRedrawMarkers(void); void BKSaveMarks(void); void BKReloadMarks(void);
void BKPointerDelta(double dx, double dy); void BKButtonDown(int btn, BOOL down); void BKKeyUsage(int usage, BOOL down);
int BKSelectedMarker(void); void BKSelectMarker(int idx); void BKMenuOpen(void); void BKMenuClose(void);
void BKEditorOpenUI(void); void BKUISetCanvas(UIView *v);
UIColor *BKUIColorFor(NSString *t); NSString *BKNameFor(NSString *t); NSString *BKShortFor(NSString *t);

typedef NS_ENUM(NSInteger, BKCurve) { BKCurveLinear = 0, BKCurveSoft, BKCurveFast };
typedef NS_ENUM(NSInteger, BKRecenter) { BKRecenterManual = 0, BKRecenterAuto, BKRecenterOnRelease };
typedef NS_ENUM(NSInteger, BKFireMode) { BKFireModeSingle = 0, BKFireModeRepeat, BKFireModeMultiply };
typedef NS_ENUM(NSInteger, BKTapMode) { BKTapModeFixed = 0, BKTapModeHold, BKTapModeToggle };
typedef NS_ENUM(NSInteger, BKJoyCenter) { BKJoyCenterAverage = 0, BKJoyCenterFixed, BKJoyCenterRandom };

static NSString *const kCursor=@"cursor", *const kSens=@"sens", *const kCurve=@"curve", *const kSmooth=@"smooth",
 *const kYRatio=@"yRatio", *const kFovCircle=@"fovCircle", *const kLockRadius=@"lockRadius", *const kRecenter=@"recenter",
 *const kHideCursor=@"hideCursor", *const kCursorSize=@"cursorSize", *const kMarkSize=@"markSize",
 *const kMarkOpacity=@"markOpacity", *const kMarkLabels=@"markLabels", *const kSnapGrid=@"snapGrid",
 *const kShowMarks=@"showMarks", *const kFireMode=@"fireMode", *const kTapMode=@"tapMode",
 *const kRepeatCount=@"repeatCount", *const kHoldAim=@"holdAim", *const kNormDiag=@"normDiag",
 *const kJoySpeed=@"joySpeed", *const kJoyCenter=@"joyCenter", *const kRepeatDelay=@"repeatDelay",
 *const kMenuOpacity=@"menuOpacity", *const kUiScale=@"uiScale", *const kAutoProfile=@"autoProfile",
 *const kJoyFx=@"joyFx", *const kJoyFy=@"joyFy", *const kHideRec=@"hideRec";

@interface BKUI : NSObject
+ (void)show; + (void)hide; + (void)relayout; + (void)openEditor; + (void)closeEditor;
+ (void)editorKey:(int)usage; + (void)editorSelectionChanged;
- (void)layoutAll;
@end

@interface BKCore : NSObject
+ (instancetype)shared;
- (void)load; - (void)save; - (void)resetDefaults;
- (BOOL)boolForKey:(NSString *)k def:(BOOL)d; - (void)setBool:(BOOL)v forKey:(NSString *)k;
- (double)doubleForKey:(NSString *)k def:(double)d; - (void)setDouble:(double)v forKey:(NSString *)k;
- (NSInteger)intForKey:(NSString *)k def:(NSInteger)d; - (void)setInt:(NSInteger)v forKey:(NSString *)k;
- (NSMutableArray *)marks; - (void)setMarks:(NSArray *)a;
- (NSArray<NSString *> *)profileNames; - (void)saveProfile:(NSString *)n;
- (void)loadProfile:(NSString *)n; - (void)deleteProfile:(NSString *)n;
@property (nonatomic, copy) void (^onChange)(NSString *key);
@end

static NSDictionary *BKDefaults(void)
{
    return @{kCursor:@NO, kSens:@1.0, kCurve:@(BKCurveLinear), kSmooth:@0, kYRatio:@100, kFovCircle:@YES,
             kLockRadius:@70, kRecenter:@(BKRecenterOnRelease), kHideCursor:@NO, kCursorSize:@30, kMarkSize:@26,
             kMarkOpacity:@30, kMarkLabels:@YES, kSnapGrid:@NO, kShowMarks:@NO, kFireMode:@(BKFireModeSingle),
             kTapMode:@(BKTapModeHold), kRepeatCount:@4, kHoldAim:@YES, kNormDiag:@YES, kJoySpeed:@7,
             kJoyCenter:@(BKJoyCenterAverage), kRepeatDelay:@60, kMenuOpacity:@96, kUiScale:@100,
             kAutoProfile:@YES, kJoyFx:@0.15, kJoyFy:@0.72, kHideRec:@NO};
}

static NSArray *BKDefaultMarks(void)
{
    return @[@{@"t":@"Pad",@"x":@0.15,@"y":@0.72,@"c":@0},
             @{@"t":@"Dir",@"x":@0.15,@"y":@0.58,@"c":@26}, @{@"t":@"Dir",@"x":@0.06,@"y":@0.72,@"c":@4},
             @{@"t":@"Dir",@"x":@0.15,@"y":@0.86,@"c":@22}, @{@"t":@"Dir",@"x":@0.24,@"y":@0.72,@"c":@7},
             @{@"t":@"Fire",@"x":@0.87,@"y":@0.80,@"c":@1}, @{@"t":@"Ads",@"x":@0.87,@"y":@0.62,@"c":@2},
             @{@"t":@"Fps",@"x":@0.60,@"y":@0.50,@"c":@225}, @{@"t":@"Click",@"x":@0.74,@"y":@0.88,@"c":@21},
             @{@"t":@"Tap",@"x":@0.78,@"y":@0.74,@"c":@44}];
}

@implementation BKCore
{
    NSMutableDictionary *_s; NSMutableArray *_m; NSString *_base, *_cfg;
}
+ (instancetype)shared { static BKCore *g; static dispatch_once_t o; dispatch_once(&o, ^{ g = [BKCore new]; }); return g; }
- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _base = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
             stringByAppendingPathComponent:@"BallKey"];
    [NSFileManager.defaultManager createDirectoryAtPath:_base withIntermediateDirectories:YES attributes:nil error:nil];
    _cfg = [_base stringByAppendingPathComponent:@"settings.plist"];
    _s = [NSMutableDictionary dictionary]; _m = [NSMutableArray array];
    [self load];
    return self;
}
- (void)load
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:_cfg];
    [_s removeAllObjects]; [_s addEntriesFromDictionary:BKDefaults()];
    if ([d[@"settings"] isKindOfClass:NSDictionary.class]) [_s addEntriesFromDictionary:d[@"settings"]];
    [_m removeAllObjects];
    if ([d[@"marks"] isKindOfClass:NSArray.class])
        for (NSDictionary *x in d[@"marks"]) if ([x isKindOfClass:NSDictionary.class]) [_m addObject:[x mutableCopy]];
    if (!_m.count) for (NSDictionary *x in BKDefaultMarks()) [_m addObject:[x mutableCopy]];
}
- (void)save { [@{@"settings":_s, @"marks":_m} writeToFile:_cfg atomically:YES]; }
- (void)resetDefaults
{
    [_s removeAllObjects]; [_s addEntriesFromDictionary:BKDefaults()];
    [_m removeAllObjects]; for (NSDictionary *x in BKDefaultMarks()) [_m addObject:[x mutableCopy]];
    [self save];
}
- (BOOL)boolForKey:(NSString *)k def:(BOOL)d { id v = _s[k]; return v ? [v boolValue] : d; }
- (void)setBool:(BOOL)v forKey:(NSString *)k { _s[k] = @(v); [self save]; if (self.onChange) self.onChange(k); }
- (double)doubleForKey:(NSString *)k def:(double)d { id v = _s[k]; return v ? [v doubleValue] : d; }
- (void)setDouble:(double)v forKey:(NSString *)k { _s[k] = @(v); [self save]; if (self.onChange) self.onChange(k); }
- (NSInteger)intForKey:(NSString *)k def:(NSInteger)d { id v = _s[k]; return v ? [v integerValue] : d; }
- (void)setInt:(NSInteger)v forKey:(NSString *)k { _s[k] = @(v); [self save]; if (self.onChange) self.onChange(k); }
- (NSMutableArray *)marks { return _m; }
- (void)setMarks:(NSArray *)a { [_m removeAllObjects]; [_m addObjectsFromArray:a]; [self save]; }
- (NSString *)profilesPath { return [_base stringByAppendingPathComponent:@"profiles"]; }
- (NSArray<NSString *> *)profileNames
{
    NSMutableArray *o = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[self profilesPath] error:nil])
        if ([f.pathExtension isEqualToString:@"plist"]) [o addObject:f.stringByDeletingPathExtension];
    return [o sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}
- (void)saveProfile:(NSString *)n
{
    if (!n.length) return;
    NSString *dir = [self profilesPath];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"settings":_s, @"marks":_m} writeToFile:
        [dir stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"plist"]] atomically:YES];
}
- (void)loadProfile:(NSString *)n
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        [[self profilesPath] stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"plist"]]];
    if (!d) return;
    [_s removeAllObjects]; [_s addEntriesFromDictionary:BKDefaults()];
    if ([d[@"settings"] isKindOfClass:NSDictionary.class]) [_s addEntriesFromDictionary:d[@"settings"]];
    [_m removeAllObjects];
    for (NSDictionary *x in d[@"marks"]) [_m addObject:[x mutableCopy]];
    [self save];
    if (self.onChange) self.onChange(@"*");
}
- (void)deleteProfile:(NSString *)n
{
    [NSFileManager.defaultManager removeItemAtPath:
        [[self profilesPath] stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"plist"]] error:nil];
}
@end

static BKCore *gCore; static BKUI *gUI; static NSString *gLog;
static UIWindow *gBallWin, *gCursorWin; static UIView *gBall, *gCursor, *gCanvas;
static NSMutableArray *gMarkViews;
static BOOL gMenuOpen, gEditOpen, gCursorOn, gGated, gFps, gFpsHeld;
static BOOL gHidOk, gGcMouse, gGcKey, gCursorDown, gLastValid, gFront, gBuilt, gEnabled, gHook;
static int gFpsIdx = -1, gSelIdx = -1, gInjecting, gPtrMask;
static int gFingerOwner[BK_FINGERS]; static int gHoldKey[512];
static double gCx, gCy, gLastX, gLastY;
static double gFingerX[BK_FINGERS], gFingerY[BK_FINGERS];
static dispatch_source_t gTick, gFireTimer;
static int gFireIdx = -1, gFireTaps = 0; static BOOL gFireOn; static uint32_t gIdent = 1;

static IOHIDEventRef (*pCreateFinger)(CFAllocatorRef,BKAbsTime,uint32_t,uint32_t,uint32_t,
    IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,Boolean,Boolean,IOOptionBits);
static IOHIDEventRef (*pCreateDigitizer)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,
    uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,IOOptionBits);
static void (*pAppend)(IOHIDEventRef,IOHIDEventRef,IOOptionBits);
static void (*pSetDigitizerInfo)(IOHIDEventRef,uint32_t,Boolean,Boolean,CFStringRef,double,float);
static void (*pSetInt)(IOHIDEventRef,uint32_t,int64_t);
static void (*pSetSender)(IOHIDEventRef,uint64_t);
static int (*pGetType)(IOHIDEventRef);
static double (*pGetFloat)(IOHIDEventRef,uint32_t);
static int64_t (*pGetInt)(IOHIDEventRef,uint32_t);
static void (*origEnq)(id,SEL,IOHIDEventRef);
static IOHIDEventSystemClientRef (*pClientCreate)(CFAllocatorRef,int,CFDictionaryRef);
static void (*pSysDispatch)(IOHIDEventSystemClientRef,IOHIDEventRef);
static IOHIDEventSystemClientRef gSys;

@interface BKPassWindow : UIWindow @end
@implementation BKPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e
{
    UIView *v = [super hitTest:p withEvent:e];
    if (!v) return nil;
    if (v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface BKHostVC : UIViewController @end
@implementation BKHostVC
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; @try { if (gUI) [gUI layoutAll]; } @catch (id e) {} }
- (BOOL)prefersStatusBarHidden { return NO; }
- (BOOL)prefersHomeIndicatorAutoHidden { return NO; }
@end

static UIWindowScene *BKScene(void)
{
    @try {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive)
                return (UIWindowScene *)s;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    } @catch (id e) {}
    return nil;
}
CGSize BKSize(void)
{
    UIWindowScene *s = BKScene();
    if (s) { CGSize z = s.coordinateSpace.bounds.size; if (z.width > 1) return z; }
    return UIScreen.mainScreen.bounds.size;
}
static CGFloat BKAngle(void)
{
    UIDeviceOrientation o = UIDevice.currentDevice.orientation;
    if (o == UIDeviceOrientationLandscapeLeft) return -M_PI_2;
    return M_PI_2;
}
static void BKLog(NSString *fmt, ...)
{
    if (!gLog) return;
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *line = [NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), s];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLog];
        if (!h) [line writeToFile:gLog atomically:NO encoding:NSUTF8StringEncoding error:nil];
        else { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
    } @catch (id e) {}
}
static double BKClamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
static double BKNum(NSString *k, double d) { return [gCore doubleForKey:k def:d]; }

// ---- estado ----
static NSString *BKStateDir(void)
{
    NSString *d = nil;
    @try { d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]; }
    @catch (id e) {}
    return d.length ? [d stringByAppendingPathComponent:@"BallKey"] : @"/var/mobile/Documents/BallKey";
}
static void BKSetEnabled(BOOL on)
{
    gEnabled = on;
    @try {
        [NSFileManager.defaultManager createDirectoryAtPath:BKStateDir() withIntermediateDirectories:YES attributes:nil error:nil];
        [(on ? @"1" : @"0") writeToFile:[BKStateDir() stringByAppendingPathComponent:@"enabled"]
                             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
}
static void BKLoadEnabled(void)
{
    @try {
        NSString *s = [NSString stringWithContentsOfFile:[BKStateDir() stringByAppendingPathComponent:@"enabled"]
                                                encoding:NSUTF8StringEncoding error:nil];
        gEnabled = [s isEqualToString:@"1"];
    } @catch (id e) {}
}
static void BKAlive(void)
{
    @try {
        [NSFileManager.defaultManager createDirectoryAtPath:BKStateDir() withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSString stringWithFormat:@"%f", CFAbsoluteTimeGetCurrent()]
            writeToFile:[BKStateDir() stringByAppendingPathComponent:@"alive"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
}

// ---- ativador externo (app BallKey) ----
#define BK_NOTE_PANEL "com.wjf.ballkey.panel"
#define BK_NOTE_GAME  "com.wjf.ballkey.panelgame"
#define BK_NOTE_OFF   "com.wjf.ballkey.off"

static void BKTickFront(void);
static void BKEnsure(void);
static void BKLaunchGame(void)
{
    @try {
        Class ws = NSClassFromString(@"LSApplicationWorkspace");
        if (!ws) return;
        id w = [ws respondsToSelector:@selector(defaultWorkspace)] ? [ws performSelector:@selector(defaultWorkspace)] : nil;
        if (w && [w respondsToSelector:@selector(openApplicationWithBundleID:)])
            [w performSelector:@selector(openApplicationWithBundleID:) withObject:BK_GAME];
    } @catch (id e) {}
}
static void BKOnNotify(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info)
{
    NSString *n = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            BKLog(@"notify %@", n);
            if ([n isEqualToString:@BK_NOTE_OFF]) {
                BKSetEnabled(NO);
                BKMenuClose();
                BKReleaseAll();
                BKTickFront();
                return;
            }
            BOOL game = [n isEqualToString:@BK_NOTE_GAME];
            BKSetEnabled(YES);
            BKEnsure();
            if (gMenuOpen) BKMenuClose();
            BKMenuOpen();
            BKTickFront();
            if (game) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 340 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                BKLaunchGame();
            });
        } @catch (id e) { BKLog(@"notify fail %@", e); }
    });
}
static void BKActivatorInstall(void)
{
    @try {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, BKOnNotify,
            CFSTR(BK_NOTE_PANEL), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, BKOnNotify,
            CFSTR(BK_NOTE_GAME), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, BKOnNotify,
            CFSTR(BK_NOTE_OFF), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    } @catch (id e) {}
}
// ---- fim ativador ----

// ---- gate ----
static NSString *BKFrontApp(void)
{
    id app = nil;
    @try {
        Class c = NSClassFromString(@"SBApplicationController");
        id ctrl = c ? [c performSelector:@selector(sharedInstance)] : nil;
        if ([ctrl respondsToSelector:@selector(frontmostApplication)]) app = [ctrl performSelector:@selector(frontmostApplication)];
        if (!app) {
            Class wc = NSClassFromString(@"SBWorkspace");
            id ws = wc ? [wc performSelector:@selector(sharedInstance)] : nil;
            if ([ws respondsToSelector:@selector(frontmostApplication)]) app = [ws performSelector:@selector(frontmostApplication)];
        }
        if ([app respondsToSelector:@selector(displayIdentifier)]) return [app performSelector:@selector(displayIdentifier)];
        if ([app respondsToSelector:@selector(bundleIdentifier)]) return [app performSelector:@selector(bundleIdentifier)];
    } @catch (id e) {}
    return nil;
}
static void BKTickFront(void)
{
    @try {
        NSString *f = BKFrontApp();
        static NSString *lastF;
        if (![lastF isEqualToString:(f ?: @"")]) { lastF = (f ?: @""); BKLog(@"front %@", f.length ? f : @"nil"); }

        BOOL on = [f isEqualToString:BK_GAME] || [f isEqualToString:BK_GAMEMAX];
        BOOL mine = [f isEqualToString:BK_ME];
        if (!f.length) on = YES;
        BOOL show = gEnabled && (on || mine);
        gFront = on;
        if (gBallWin) gBallWin.hidden = !show;
        if (gCursorWin) gCursorWin.hidden = !(on && gCursorOn);
        if (!show) {
            if (gMenuOpen) BKMenuClose();
            if (gEditOpen) [BKUI closeEditor];
            BKReleaseAll();
        }
    } @catch (id e) { BKLog(@"tick fail %@", e); }
}

// ---- injecao ----
static void BKPlaceCursor(void)
{
    if (!gCursor) return;
    double h = BKNum(kCursorSize, 30);
    gCursor.frame = CGRectMake(gCx, gCy, h * 0.72, h);
    [gCursor setNeedsDisplay];
}

static int BKFingerTake(int owner)
{
    for (int i = 0; i < BK_FINGERS; i++) if (!gFingerOwner[i]) { gFingerOwner[i] = owner + 1; return BK_FBASE + i; }
    return -1;
}
static void BKFingerFree(int f) { if (f >= BK_FBASE && f < BK_FBASE + BK_FINGERS) gFingerOwner[f - BK_FBASE] = 0; }

static void BKInjectNorm(int finger, double fx, double fy, BOOL down, BOOL move)
{
    if (!pCreateFinger || !pCreateDigitizer) return;
    @try {
        uint32_t mask = move ? 4 : 3;
        Boolean rng = down, tch = down;
        uint64_t t = mach_absolute_time();

        IOHIDEventRef parent = pCreateDigitizer(kCFAllocatorDefault, t, 2, 1u << 22, 1, mask, 0,
            fx, fy, 0, 0, 0, rng, tch, 0);
        if (!parent) return;
        IOHIDEventRef sub = pCreateFinger(kCFAllocatorDefault, t, gIdent++, (uint32_t)finger, mask,
            fx, fy, 0.0, 0.0, 0.0, rng, tch, 0);
        if (!sub) { CFRelease(parent); return; }

        if (pSetInt) pSetInt(sub, kFieldDigIsDisplayIntegrated, 1);
        pAppend(parent, sub, 0);
        CFRelease(sub);
        if (pSetInt) pSetInt(parent, kFieldDigIsDisplayIntegrated, 1);
        if (pSetSender) pSetSender(parent, BK_SENDER);
        if (pSetDigitizerInfo) pSetDigitizerInfo(parent, 0, false, false, NULL, 0, 0);

        gInjecting++;
        if (gSys && pSysDispatch) pSysDispatch(gSys, parent);
        else if (origEnq) origEnq(UIApplication.sharedApplication, @selector(_enqueueHIDEvent:), parent);
        gInjecting--;
        CFRelease(parent);

        if (finger >= BK_FBASE && finger < BK_FBASE + BK_FINGERS) {
            gFingerX[finger - BK_FBASE] = fx; gFingerY[finger - BK_FBASE] = fy;
        }
    } @catch (id e) {}
}
static void BKInject(int finger, double x, double y, BOOL down, BOOL move)
{
    CGSize s = BKSize();
    if (s.width < 1 || s.height < 1) return;
    BKInjectNorm(finger, x / s.width, y / s.height, down, move);
}

static void BKTapAt(double x, double y)
{
    int f = BKFingerTake(900);
    if (f < 0) return;
    double jx = ((double)arc4random_uniform(1200) / 1000.0) - 0.6;
    double jy = ((double)arc4random_uniform(1200) / 1000.0) - 0.6;
    double px = x + jx, py = y + jy;
    BKInject(f, px, py, YES, NO);
    uint64_t hold = 40000 + arc4random_uniform(30000);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, hold * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKInject(f, px, py, NO, NO);
        BKFingerFree(f);
    });
}

void BKReleaseAll(void)
{
    @try {
        for (int i = 0; i < 512; i++) gHoldKey[i] = 0;
        if (gFireTimer) dispatch_source_set_timer(gFireTimer, DISPATCH_TIME_FOREVER, 0, 0);
        gFireOn = NO; gFireIdx = -1;
        for (int i = 0; i < BK_FINGERS; i++) {
            if (!gFingerOwner[i]) continue;
            BKInjectNorm(BK_FBASE + i, gFingerX[i], gFingerY[i], NO, NO);
            gFingerOwner[i] = 0;
        }
        if (gCursorDown) {
            BKInject(31, gCx, gCy, NO, NO);
            gCursorDown = NO;
        }
        gFps = gFpsHeld = NO;
    } @catch (id e) {}
}

void BKCursorSet(BOOL on)
{
    if (on == gCursorOn) return;
    CGSize s = BKSize();
    if (on) {
        gCx = s.width * 0.5; gCy = s.height * 0.5; gLastValid = NO; gCursorOn = YES;
        if (gCursorWin) gCursorWin.hidden = !gFront;
        BKPlaceCursor();
        BKInject(31, gCx, gCy, YES, NO); gCursorDown = YES;
    } else {
        gCursorOn = NO; gFps = gFpsHeld = NO;
        if (gCursorDown) { BKInject(31, gCx, gCy, NO, NO); gCursorDown = NO; }
        if (gCursorWin) gCursorWin.hidden = YES;
    }
    [gCore setBool:gCursorOn forKey:kCursor];
}
BOOL BKCursorOn(void) { return gCursorOn; }

static double BKCurveValue(double v)
{
    switch ([gCore intForKey:kCurve def:BKCurveLinear]) {
        case BKCurveFast: return v * (1.0 + fabs(v) * 0.35);
        case BKCurveSoft: {
            double t = BKClamp(BKNum(kSmooth, 35) / 100.0, 0.0, 1.0);
            return v * (1.0 - t) + (v * fabs(v)) * t;
        }
        default: return v;
    }
}

void BKPointerDelta(double dx, double dy)
{
    if (!gCursorOn || !gFront || !gEnabled) return;
    CGSize s = BKSize();
    double sens = BKNum(kSens, 1.0);
    dx = BKCurveValue(dx * sens);
    dy = -BKCurveValue(dy * sens * (BKNum(kYRatio, 100) / 100.0));

    if (gFps && gFpsHeld) {
        double bx = s.width * 0.5, by = s.height * 0.5;
        if (gFpsIdx >= 0 && gFpsIdx < (int)BKMarks().count) {
            bx = [BKMarks()[gFpsIdx][@"x"] doubleValue] * s.width;
            by = [BKMarks()[gFpsIdx][@"y"] doubleValue] * s.height;
        }
        double r = BKNum(kLockRadius, 70);
        double nx = gCx + dx, ny = gCy + dy, d = hypot(nx - bx, ny - by);
        if (d > r) { nx = bx + (nx - bx) / d * r; ny = by + (ny - by) / d * r; }
        gCx = BKClamp(nx, 2, s.width - 2); gCy = BKClamp(ny, 2, s.height - 2);
        if ([gCore intForKey:kRecenter def:BKRecenterOnRelease] == BKRecenterAuto && d > r) {
            gCx = bx + (gCx - bx) * 0.55; gCy = by + (gCy - by) * 0.55;
        }
    } else {
        gCx = BKClamp(gCx + dx, 2, s.width - 2);
        gCy = BKClamp(gCy + dy, 2, s.height - 2);
    }
    BKPlaceCursor();
    if (gCursorDown) {
        double n = ((double)arc4random_uniform(400) / 1000.0) - 0.2;
        BKInject(31, gCx + n, gCy - n, YES, YES);
    }
}

static void BKFireArm(void)
{
    if (!gFireOn || !gFireTimer) return;
    double ms = BKNum(kRepeatDelay, 60) * (0.88 + (arc4random_uniform(240) / 1000.0));
    dispatch_source_set_timer(gFireTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                              DISPATCH_TIME_FOREVER, 2 * NSEC_PER_MSEC);
}
static void BKFireStop(void)
{
    gFireOn = NO;
    if (gFireTimer) dispatch_source_set_timer(gFireTimer, DISPATCH_TIME_FOREVER, 0, 0);
    if ([gCore boolForKey:kHoldAim def:YES]) BKButtonDown(2, NO);
    gFireIdx = -1;
}
static void BKFireTick(void)
{
    if (!gFireOn || gFireIdx < 0 || gFireIdx >= (int)BKMarks().count) return;
    NSDictionary *m = BKMarks()[gFireIdx];
    CGSize s = BKSize();
    BKTapAt([m[@"x"] doubleValue] * s.width, [m[@"y"] doubleValue] * s.height);
    gFireTaps++;
    if ([gCore intForKey:kTapMode def:BKTapModeHold] == BKTapModeFixed &&
        gFireTaps >= [gCore intForKey:kRepeatCount def:4]) { BKFireStop(); return; }
    BKFireArm();
}
static void BKFireStart(int idx)
{
    if (gFireIdx == idx && gFireOn &&
        [gCore intForKey:kTapMode def:BKTapModeHold] == BKTapModeToggle) { BKFireStop(); return; }
    BKFireStop();
    gFireIdx = idx; gFireTaps = 0; gFireOn = YES;
    if ([gCore boolForKey:kHoldAim def:YES]) BKButtonDown(2, YES);
    NSDictionary *m = BKMarks()[idx];
    CGSize s = BKSize();
    if ([gCore intForKey:kFireMode def:BKFireModeSingle] == BKFireModeSingle) {
        BKTapAt([m[@"x"] doubleValue] * s.width, [m[@"y"] doubleValue] * s.height);
        return;
    }
    if (!gFireTimer) {
        gFireTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(gFireTimer, ^{ @try { BKFireTick(); } @catch (id e) {} });
        dispatch_resume(gFireTimer);
    }
    BKFireArm();
    if ([gCore intForKey:kTapMode def:BKTapModeHold] == BKTapModeFixed) BKFireTick();
}

static void BKMarkerPress(int idx, BOOL down)
{
    if (idx < 0 || idx >= (int)BKMarks().count) return;
    NSDictionary *m = BKMarks()[idx];
    NSString *t = m[@"t"];
    CGSize s = BKSize();
    double x = [m[@"x"] doubleValue] * s.width, y = [m[@"y"] doubleValue] * s.height;

    if ([t isEqualToString:@"Tap"] || [t isEqualToString:@"Click"]) { if (down) BKTapAt(x, y); return; }
    if ([t isEqualToString:@"Fire"]) { if (down) BKFireStart(idx); else BKFireStop(); return; }
    if ([t isEqualToString:@"Fps"]) {
        if (down) {
            gFps = YES; gFpsHeld = YES; gFpsIdx = idx; gCx = x; gCy = y;
            BKPlaceCursor();
            if (gCursorDown) BKInject(31, gCx, gCy, YES, YES);
        } else { gFpsHeld = NO; gFps = NO; }
        return;
    }
    if ([t isEqualToString:@"Pad"]) return;
    if (down) {
        int f = BKFingerTake(idx);
        if (f < 0) return;
        gHoldKey[idx] = f;
        BKInject(f, x, y, YES, NO);
    } else if (gHoldKey[idx]) {
        int f = gHoldKey[idx]; gHoldKey[idx] = 0;
        BKInject(f, x, y, NO, NO);
        BKFingerFree(f);
    }
}

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
        if (gLastValid && fabs(x) < 9000 && fabs(y) < 9000) BKPointerDelta(x - gLastX, gLastY - y);
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
    if (gGated || gMenuOpen || gEditOpen || !gFront || !gEnabled) return;
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
    if (!gFront || !gEnabled) return;
    for (int i = 0; i < (int)BKMarks().count; i++) {
        if ([BKMarks()[i][@"c"] intValue] != usage) continue;
        NSString *t = BKMarks()[i][@"t"];
        if ([t isEqualToString:@"Dir"]) {
            if (down) { if (gHoldKey[i]) return; gHoldKey[i] = 1; }
            else { if (!gHoldKey[i]) return; gHoldKey[i] = 0; }
            return;
        }
        BKMarkerPress(i, down);
        return;
    }
}

static void BKJoystick(void)
{
    int dirs[64], n = 0, pad = -1;
    double sx = 0, sy = 0;
    for (int i = 0; i < (int)BKMarks().count && n < 64; i++) {
        NSString *t = BKMarks()[i][@"t"];
        if ([t isEqualToString:@"Pad"]) { pad = i; continue; }
        if (![t isEqualToString:@"Dir"]) continue;
        dirs[n++] = i;
        sx += [BKMarks()[i][@"x"] doubleValue];
        sy += [BKMarks()[i][@"y"] doubleValue];
    }
    if (!n) return;
    BOOL any = NO;
    for (int i = 0; i < n; i++) if (gHoldKey[dirs[i]]) { any = YES; break; }
    if (!any) return;

    double bx, by;
    if (pad >= 0) { bx = [BKMarks()[pad][@"x"] doubleValue]; by = [BKMarks()[pad][@"y"] doubleValue]; }
    else if ([gCore intForKey:kJoyCenter def:BKJoyCenterAverage] == BKJoyCenterFixed) {
        bx = BKNum(kJoyFx, sx / n); by = BKNum(kJoyFy, sy / n);
    } else { bx = sx / n; by = sy / n; }
    if ([gCore intForKey:kJoyCenter def:BKJoyCenterAverage] == BKJoyCenterRandom) {
        bx += ((double)arc4random_uniform(1000) / 1000.0 - 0.5) * 0.02;
        by += ((double)arc4random_uniform(1000) / 1000.0 - 0.5) * 0.02;
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
    if (![gCore boolForKey:kNormDiag def:YES]) { vx *= 1.4142; vy *= 1.4142; }

    CGSize s = BKSize();
    double spd = BKNum(kJoySpeed, 7) * (s.width / 390.0);
    gCx = BKClamp(gCx + vx * spd, 2, s.width - 2);
    gCy = BKClamp(gCy + vy * spd, 2, s.height - 2);
    BKPlaceCursor();
    if (gCursorDown) BKInject(31, gCx, gCy, YES, YES);
}

static void BKAttachMouse(void)
{
    GCMouse *m = GCMouse.current;
    gGcMouse = (m != nil);
    if (!m) return;
    BKLog(@"gc mouse ok");
    m.mouseInput.mouseMovedHandler = ^(GCMouseInput *in, float dx, float dy) { @try { BKPointerDelta(dx, dy); } @catch (id e) {} };
    m.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { @try { BKButtonDown(1, p); } @catch (id e) {} };
    m.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { @try { BKButtonDown(2, p); } @catch (id e) {} };
    m.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { @try { BKButtonDown(3, p); } @catch (id e) {} };
}
static void BKAttachKey(void)
{
    GCKeyboard *k = [GCKeyboard coalescedKeyboard];
    gGcKey = (k != nil);
    if (!k) return;
    BKLog(@"gc key ok");
    k.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *in, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) {
        @try { BKKeyUsage((int)code, pressed); } @catch (id e) {}
    };
}
static void BKInstall(void)
{
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (h) {
        pCreateFinger = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        pCreateDigitizer = dlsym(h, "IOHIDEventCreateDigitizerEvent");
        pAppend = dlsym(h, "IOHIDEventAppendEvent");
        pSetInt = dlsym(h, "IOHIDEventSetIntegerValue");
        pSetSender = dlsym(h, "IOHIDEventSetSenderID");
        pGetType = dlsym(h, "IOHIDEventGetType");
        pGetFloat = dlsym(h, "IOHIDEventGetFloatValue");
        pGetInt = dlsym(h, "IOHIDEventGetIntegerValue");
        pClientCreate = dlsym(h, "IOHIDEventSystemClientCreateWithType");
        pSysDispatch = dlsym(h, "IOHIDEventSystemClientDispatchEvent");
    }
    void *b = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
    if (b) pSetDigitizerInfo = dlsym(b, "BKSHIDEventSetDigitizerInfo");

    if (pClientCreate) gSys = pClientCreate(kCFAllocatorDefault, 1, NULL);
    gHidOk = (pCreateFinger != NULL && pCreateDigitizer != NULL);
    BKLog(@"hid:%d sys:%d", gHidOk, gSys != NULL);
}
static void BKHook(void)
{
    if (gHook) return;
    Method m = class_getInstanceMethod(UIApplication.class, @selector(_enqueueHIDEvent:));
    if (!m) return;
    origEnq = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)BKEnq);
    gHook = YES;
    BKLog(@"hook on");
}

static UIWindow *BKWin(UIWindowLevel lv, BOOL passThrough)
{
    UIWindowScene *sc = BKScene();
    CGSize sp = UIScreen.mainScreen.bounds.size;
    UIWindow *w = sc ? [[UIWindow alloc] initWithWindowScene:sc]
                     : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (passThrough) object_setClass(w, [BKPassWindow class]);
    w.frame = CGRectMake(0, 0, sp.width, sp.height);
    w.windowLevel = lv;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [BKHostVC new];
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
- (void)bkTap:(UITapGestureRecognizer *)g { @try { BKMenuOpen(); } @catch (id e) {} }
@end

@interface BKCursorView : UIView @end
@implementation BKCursorView
- (void)drawRect:(CGRect)r
{
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIBezierPath *p = [UIBezierPath new];
    [p moveToPoint:CGPointMake(0, 0)];
    [p addLineToPoint:CGPointMake(0, h * 0.78)];
    [p addLineToPoint:CGPointMake(w * 0.30, h * 0.58)];
    [p addLineToPoint:CGPointMake(w * 0.48, h * 0.97)];
    [p addLineToPoint:CGPointMake(w * 0.66, h * 0.90)];
    [p addLineToPoint:CGPointMake(w * 0.48, h * 0.52)];
    [p addLineToPoint:CGPointMake(w * 0.80, h * 0.52)];
    [p closePath];
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetShadowWithColor(c, CGSizeMake(0.5, 1.2), 2.0, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
    CGContextSetFillColorWithColor(c, UIColor.whiteColor.CGColor);
    CGContextAddPath(c, p.CGPath);
    CGContextFillPath(c);
    CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:0.08 alpha:1].CGColor);
    CGContextSetLineWidth(c, MAX(1.0, h * 0.045));
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextAddPath(c, p.CGPath);
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
    c.x = BKClamp(c.x, 14, s.width - 14);
    c.y = BKClamp(c.y, 14, s.height - 14);
    if ([gCore boolForKey:kSnapGrid def:NO]) {
        c.x = round(c.x / (s.width / 40.0)) * (s.width / 40.0);
        c.y = round(c.y / (s.height / 24.0)) * (s.height / 24.0);
    }
    self.center = c;
    int i = (int)self.tag - 300;
    if (i >= 0 && i < (int)BKMarks().count) {
        BKMarks()[i][@"x"] = @(c.x / s.width);
        BKMarks()[i][@"y"] = @(c.y / s.height);
    }
}
- (void)bkPick:(UITapGestureRecognizer *)g { BKSelectMarker((int)self.tag - 300); }
@end

NSMutableArray *BKMarks(void) { return [gCore marks]; }
int BKSelectedMarker(void) { return gSelIdx; }
void BKSetInputGated(BOOL g) { gGated = g; }
void BKUISetCanvas(UIView *v) { gCanvas = v; }

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
    if (s.width < 1) return;
    double k = s.width / 390.0;
    BOOL labels = [gCore boolForKey:kMarkLabels def:YES];
    double d = MAX(12.0, BKNum(kMarkSize, 26) * k);

    for (int i = 0; i < (int)BKMarks().count; i++) {
        NSDictionary *m = BKMarks()[i];
        UIColor *c = BKUIColorFor(m[@"t"]);
        BOOL isPad = [m[@"t"] isEqualToString:@"Pad"];
        BKMarkView *v = [[BKMarkView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
        v.center = CGPointMake([m[@"x"] doubleValue] * s.width, [m[@"y"] doubleValue] * s.height);
        v.backgroundColor = [c colorWithAlphaComponent:isPad ? 0.10 : BKNum(kMarkOpacity, 30) / 100.0];
        v.layer.borderColor = c.CGColor;
        v.layer.borderWidth = isPad ? 1.0 : 1.5;
        v.layer.cornerRadius = d / 2;
        v.tag = 300 + i;
        UILabel *in = [UILabel new];
        in.frame = v.bounds;
        in.text = BKShortFor(m[@"t"]);
        in.textColor = UIColor.whiteColor;
        in.font = [UIFont boldSystemFontOfSize:MAX(8.0, d * 0.5)];
        in.textAlignment = NSTextAlignmentCenter;
        in.adjustsFontSizeToFitWidth = YES;
        in.userInteractionEnabled = NO;
        [v addSubview:in];
        if (labels) {
            UILabel *out = [UILabel new];
            out.text = BKNameFor(m[@"t"]);
            out.textColor = c;
            out.font = [UIFont boldSystemFontOfSize:MAX(7.0, d * 0.32)];
            out.textAlignment = NSTextAlignmentCenter;
            out.userInteractionEnabled = NO;
            out.frame = CGRectMake(d / 2 - 45, d + 1, 90, d * 0.5 + 4);
            [v addSubview:out];
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
    BKPlaceCursor();
    if (gCanvas) BKRedrawMarkers();
    [BKUI relayout];
}
void BKRelayout(void)
{
    CGSize s = BKSize();
    if (gBallWin) gBallWin.frame = CGRectMake(0, 0, s.width, s.height);
    if (gBall) gBall.center = CGPointMake(28, 44);
    if (gCursorWin) gCursorWin.frame = CGRectMake(0, 0, s.width, s.height);
    if (gCanvas) { gCanvas.frame = CGRectMake(0, 0, s.width, s.height); BKRedrawMarkers(); }
    gCx = BKClamp(gCx, 2, s.width - 2); gCy = BKClamp(gCy, 2, s.height - 2);
    BKPlaceCursor();
    [BKUI relayout];
}
void BKMenuOpen(void) { BKEnsure(); gMenuOpen = YES; [BKUI show]; BKReleaseAll(); }
void BKMenuClose(void) { gMenuOpen = NO; [BKUI hide]; }
void BKEditorOpenUI(void) { [BKUI openEditor]; }
void BKSetEditorOpen(BOOL open)
{
    if (open == gEditOpen) return;
    gEditOpen = open;
    if (!open) { gCanvas = nil; gMarkViews = nil; gSelIdx = -1; BKReleaseAll(); }
}

static UIColor *BKHex(NSUInteger h, CGFloat a)
{
    return [UIColor colorWithRed:((h >> 16) & 255) / 255.0 green:((h >> 8) & 255) / 255.0
                            blue:(h & 255) / 255.0 alpha:a];
}
#define ACC BKHex(0xFF6A2B, 1)
#define ACCD BKHex(0xFF6A2B, 0.16)
#define PANEL BKHex(0x0D1119, 1)
#define SIDE BKHex(0x070A10, 1)
#define ROW BKHex(0x141A24, 1)
#define STROK BKHex(0x1E2634, 1)
#define TXT BKHex(0xE8ECF4, 1)
#define DIM BKHex(0x8A94A6, 1)
#define OKC BKHex(0x2FD07A, 1)
#define BADC BKHex(0xFF5A5A, 1)

UIColor *BKUIColorFor(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return BKHex(0x2FA8FF, 1);
    if ([t isEqualToString:@"Click"]) return BKHex(0x35D6C8, 1);
    if ([t isEqualToString:@"Press"]) return BKHex(0x2FD07A, 1);
    if ([t isEqualToString:@"Dir"]) return BKHex(0xA06BFF, 1);
    if ([t isEqualToString:@"Pad"]) return BKHex(0x7A85A0, 1);
    if ([t isEqualToString:@"Fps"]) return BKHex(0xFF4A7A, 1);
    if ([t isEqualToString:@"Ads"]) return BKHex(0xFF9B2B, 1);
    return BKHex(0xFF5A3A, 1);
}
NSString *BKNameFor(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return @"Toque";
    if ([t isEqualToString:@"Click"]) return @"Clique";
    if ([t isEqualToString:@"Press"]) return @"Pressionar";
    if ([t isEqualToString:@"Dir"]) return @"Direcional";
    if ([t isEqualToString:@"Pad"]) return @"Centro";
    if ([t isEqualToString:@"Fps"]) return @"Fps";
    if ([t isEqualToString:@"Ads"]) return @"Mirar";
    if ([t isEqualToString:@"Fire"]) return @"Atirar";
    return t;
}
NSString *BKShortFor(NSString *t)
{
    if ([t isEqualToString:@"Tap"]) return @"T";
    if ([t isEqualToString:@"Click"]) return @"C";
    if ([t isEqualToString:@"Press"]) return @"P";
    if ([t isEqualToString:@"Dir"]) return @"D";
    if ([t isEqualToString:@"Pad"]) return @"+";
    if ([t isEqualToString:@"Fps"]) return @"F";
    if ([t isEqualToString:@"Ads"]) return @"M";
    if ([t isEqualToString:@"Fire"]) return @"A";
    return t;
}

static UIImage *BKIcon(NSString *n, CGFloat sz, UIColor *c)
{
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(sz, sz)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef g = ctx.CGContext;
        CGContextSetStrokeColorWithColor(g, c.CGColor);
        CGContextSetFillColorWithColor(g, c.CGColor);
        CGContextSetLineWidth(g, 2.2);
        CGContextSetLineCap(g, kCGLineCapRound);
        CGContextSetLineJoin(g, kCGLineJoinRound);
        CGFloat m = sz * 0.14, e = sz - m, mid = sz / 2;
        if ([n isEqualToString:@"cursor"]) {
            CGContextStrokeEllipseInRect(g, CGRectMake(m, m, e - m, e - m));
            CGContextMoveToPoint(g, mid, 1); CGContextAddLineToPoint(g, mid, m - 1);
            CGContextMoveToPoint(g, mid, e + 1); CGContextAddLineToPoint(g, mid, sz - 1);
            CGContextMoveToPoint(g, 1, mid); CGContextAddLineToPoint(g, m - 1, mid);
            CGContextMoveToPoint(g, e + 1, mid); CGContextAddLineToPoint(g, sz - 1, mid);
            CGContextStrokePath(g);
        } else if ([n isEqualToString:@"map"]) {
            CGFloat q = sz * 0.30;
            for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++)
                CGContextStrokeRect(g, CGRectMake(m + i * (q + 4), m + j * (q + 4), q, q));
        } else if ([n isEqualToString:@"keys"]) {
            CGContextStrokeRect(g, CGRectMake(m, m + 3, e - m, e - m - 6));
            for (int i = 0; i < 3; i++) CGContextFillRect(g, CGRectMake(m + 6 + i * 9, mid + 6, 5, 4));
        } else if ([n isEqualToString:@"user"]) {
            CGContextStrokeEllipseInRect(g, CGRectMake(mid - 7, m, 14, 14));
            CGContextMoveToPoint(g, m, e); CGContextAddQuadCurveToPoint(g, mid, mid + 2, e, e);
            CGContextStrokePath(g);
        } else if ([n isEqualToString:@"info"]) {
            CGContextStrokeEllipseInRect(g, CGRectMake(m, m, e - m, e - m));
            CGContextFillRect(g, CGRectMake(mid - 1.5, mid - 4, 3, 3));
            CGContextFillRect(g, CGRectMake(mid - 1.5, mid + 1, 3, 9));
        } else if ([n isEqualToString:@"x"]) {
            CGContextMoveToPoint(g, m + 2, m + 2); CGContextAddLineToPoint(g, e - 2, e - 2);
            CGContextMoveToPoint(g, e - 2, m + 2); CGContextAddLineToPoint(g, m + 2, e - 2);
            CGContextStrokePath(g);
        } else if ([n isEqualToString:@"chev"]) {
            CGContextMoveToPoint(g, mid - 5, mid - 2); CGContextAddLineToPoint(g, mid, mid + 4);
            CGContextAddLineToPoint(g, mid + 5, mid - 2); CGContextStrokePath(g);
        }
    }];
}

@interface BKToggle : UIControl
@property (nonatomic) BOOL on;
- (void)setOn:(BOOL)on animated:(BOOL)a;
@end
@implementation BKToggle
{
    UIView *_track, *_knob;
}
- (instancetype)initWithFrame:(CGRect)f
{
    if (!(self = [super initWithFrame:f])) return nil;
    _track = [[UIView alloc] initWithFrame:self.bounds];
    _track.layer.cornerRadius = f.size.height / 2;
    _track.backgroundColor = BKHex(0x232B38, 1);
    _track.userInteractionEnabled = NO;
    [self addSubview:_track];
    _knob = [[UIView alloc] initWithFrame:CGRectMake(4, 4, f.size.height - 8, f.size.height - 8)];
    _knob.layer.cornerRadius = _knob.bounds.size.height / 2;
    _knob.backgroundColor = UIColor.whiteColor;
    _knob.userInteractionEnabled = NO;
    [self addSubview:_knob];
    [self addTarget:self action:@selector(hit) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)setOn:(BOOL)on { [self setOn:on animated:NO]; }
- (void)setOn:(BOOL)on animated:(BOOL)a
{
    _on = on;
    CGRect f = _knob.frame;
    f.origin.x = on ? self.bounds.size.width - f.size.width - 4 : 4;
    void (^b)(void) = ^{
        self->_knob.frame = f;
        self->_track.backgroundColor = on ? ACC : BKHex(0x232B38, 1);
    };
    if (a) [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.6
                               options:UIViewAnimationOptionAllowUserInteraction animations:b completion:nil];
    else b();
}
- (void)hit
{
    [self setOn:!_on animated:YES];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
}
@end

@interface BKSlider : UIControl
@property (nonatomic) double min, max, value;
@end
@implementation BKSlider
{
    UIView *_track, *_fill, *_knob;
}
- (instancetype)initWithFrame:(CGRect)f
{
    if (!(self = [super initWithFrame:f])) return nil;
    _track = [[UIView alloc] initWithFrame:CGRectMake(0, f.size.height/2 - 4, f.size.width, 8)];
    _track.layer.cornerRadius = 4;
    _track.backgroundColor = BKHex(0x232B38, 1);
    _track.userInteractionEnabled = NO;
    [self addSubview:_track];
    _fill = [[UIView alloc] initWithFrame:_track.frame];
    _fill.layer.cornerRadius = 4;
    _fill.backgroundColor = ACC;
    _fill.userInteractionEnabled = NO;
    [self addSubview:_fill];
    _knob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    _knob.layer.cornerRadius = 15;
    _knob.backgroundColor = UIColor.whiteColor;
    _knob.userInteractionEnabled = NO;
    [self addSubview:_knob];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    return self;
}
- (void)setValue:(double)v { _value = v; [self layoutTracks]; }
- (void)layoutTracks
{
    CGFloat w = self.bounds.size.width;
    CGFloat t = (_max > _min) ? (CGFloat)((_value - _min) / (_max - _min)) : 0;
    _fill.frame = CGRectMake(0, self.bounds.size.height/2 - 4, MAX(8, w * t), 8);
    _knob.center = CGPointMake(MAX(15, MIN(w - 15, w * t)), self.bounds.size.height / 2);
}
- (void)drag:(UIGestureRecognizer *)g
{
    CGPoint p = [g locationInView:self];
    CGFloat t = MAX(0, MIN(1, (p.x - 15) / MAX(1, self.bounds.size.width - 30)));
    _value = _min + t * (_max - _min);
    [self layoutTracks];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
@end

@interface BKPopup : UIView
@property (nonatomic, copy) void (^onPick)(NSInteger);
- (instancetype)initWithOptions:(NSArray *)o index:(NSInteger)i width:(CGFloat)w;
@end
@implementation BKPopup
- (instancetype)initWithOptions:(NSArray *)o index:(NSInteger)i width:(CGFloat)w
{
    CGFloat h = o.count * 52 + 16;
    if (!(self = [super initWithFrame:CGRectMake(0, 0, w, h)])) return nil;
    self.backgroundColor = BKHex(0x10161F, 0.99);
    self.layer.cornerRadius = 14;
    self.layer.borderWidth = 1;
    self.layer.borderColor = STROK.CGColor;
    for (NSInteger k = 0; k < (NSInteger)o.count; k++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(8, 8 + k * 52, w - 16, 44);
        [b setTitle:o[k] forState:UIControlStateNormal];
        [b setTitleColor:(k == i ? ACC : TXT) forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:17 weight:(k == i ? UIFontWeightSemibold : UIFontWeightRegular)];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 0);
        b.backgroundColor = (k == i) ? ACCD : UIColor.clearColor;
        b.layer.cornerRadius = 9;
        b.tag = k;
        [b addTarget:self action:@selector(pick:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
    }
    return self;
}
- (void)pick:(UIButton *)b { if (self.onPick) self.onPick(b.tag); [self removeFromSuperview]; }
@end

@interface BKUI () <UIScrollViewDelegate, UIGestureRecognizerDelegate>
- (void)present; - (void)dismiss; - (void)buildChrome; - (void)tabTap:(UIControl *)c;
- (void)setTab:(NSInteger)tab animated:(BOOL)animated;
- (UILabel *)label:(NSString *)t size:(CGFloat)sz color:(UIColor *)c bold:(BOOL)b;
- (UIView *)shell:(CGFloat)h;
- (UIView *)header:(NSString *)title icon:(NSString *)icon note:(NSArray *)note host:(UIView *)host;
- (void)closeTap;
- (void)toggleRow:(NSString *)title key:(NSString *)key y:(CGFloat)y host:(UIView *)host;
- (void)tgChanged:(BKToggle *)t;
- (void)sliderRow:(NSString *)title key:(NSString *)key min:(double)mn max:(double)mx
                y:(CGFloat)y host:(UIView *)host fmt:(NSString *(^)(double))fmt;
- (void)slChanged:(BKSlider *)s;
- (void)dropRow:(NSString *)title key:(NSString *)key options:(NSArray *)opts y:(CGFloat)y host:(UIView *)host;
- (void)dropTap:(UIButton *)b;
- (void)buttonRow:(NSString *)title color:(UIColor *)c y:(CGFloat)y host:(UIView *)host action:(SEL)sel;
- (void)section:(NSString *)t y:(CGFloat)y host:(UIView *)host;
- (UIView *)buildTab:(NSInteger)tab;
- (void)openEditorTap; - (void)clearMarksTap; - (void)reloadMarksTap; - (void)centerJoyTap;
- (void)saveProfileTap; - (void)useProfileTap:(UIButton *)b; - (void)delProfileTap:(UIButton *)b;
- (void)resetTap; - (void)logTap; - (void)tickStatus; - (void)presentEditor;
- (UIButton *)miniChip:(NSString *)t color:(UIColor *)c frame:(CGRect)f;
- (UIButton *)chip:(NSString *)t color:(UIColor *)c frame:(CGRect)f;
- (void)editorAdd:(UIButton *)b; - (void)editorDelete:(UIButton *)b;
- (void)editorSave; - (void)editorCancel; - (void)dismissEditor;
- (void)editorGotKey:(int)u; - (void)refreshEditorStatus;
- (void)rebuildCanvas;
- (CGAffineTransform)fitT;
- (CGRect)stageBounds;
- (void)applyCenter;
- (void)bkDrag:(UIPanGestureRecognizer *)g;
@end

@interface BKUI ()
{
    UIWindow *_win;
    UIView *_dim, *_box, *_content, *_sidebar, *_pill, *_inner;
    UIScrollView *_scroll;
    NSMutableArray *_rows;
    UILabel *_statusLbl;
    NSInteger _tab;
    CGFloat _userScale;
    NSTimer *_statusTimer;
    CGFloat _builtW, _builtH, _fit, _topM;
    CGPoint _boxOffset, _dragStart;
}
@end

@implementation BKUI

+ (void)show { if (!gUI) gUI = [BKUI new]; [gUI present]; }
+ (void)hide { [gUI dismiss]; }
+ (void)relayout { [gUI layoutAll]; }
+ (void)openEditor { if (!gUI) gUI = [BKUI new]; [gUI presentEditor]; }
+ (void)closeEditor { [gUI dismissEditor]; }
+ (void)editorKey:(int)u { [gUI editorGotKey:u]; }
+ (void)editorSelectionChanged { [gUI refreshEditorStatus]; }

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _rows = [NSMutableArray array];
    _userScale = 1.0;
    _tab = 0;
    return self;
}

- (void)present
{
    CGSize sp = UIScreen.mainScreen.bounds.size;
    UIWindowScene *sc = BKScene();
    _win = sc ? [[UIWindow alloc] initWithWindowScene:sc]
              : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    object_setClass(_win, [BKPassWindow class]);
    _win.windowLevel = UIWindowLevelAlert + 550;
    _win.backgroundColor = UIColor.clearColor;
    _win.rootViewController = [BKHostVC new];
    _win.frame = CGRectMake(0, 0, sp.width, sp.height);
    _win.hidden = NO;
    BKSetInputGated(YES);

    _dim = [[UIView alloc] initWithFrame:_win.bounds];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _dim.userInteractionEnabled = NO;
    [_win.rootViewController.view addSubview:_dim];

    _box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, DW, DH)];
    _box.backgroundColor = PANEL;
    _box.layer.cornerRadius = 26;
    _box.layer.borderWidth = 1;
    _box.layer.borderColor = STROK.CGColor;
    _box.clipsToBounds = YES;
    [_win.rootViewController.view addSubview:_box];

    _boxOffset = CGPointZero;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(bkDrag:)];
    pan.delegate = self;
    [_box addGestureRecognizer:pan];

    _userScale = [gCore doubleForKey:kUiScale def:100];
    _tab = 0;
    _builtW = 0; _builtH = 0;
    [self layoutAll];

    _box.transform = CGAffineTransformMakeScale(_fit * 0.92, _fit * 0.92);
    _box.alpha = 0;
    _dim.alpha = 0;
    [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.9
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_box.transform = [self fitT];
        self->_box.alpha = [gCore doubleForKey:kMenuOpacity def:96] / 100.0;
        self->_dim.alpha = 1;
    } completion:nil];

    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        @try { [self tickStatus]; } @catch (id e) {}
    }];
}

- (void)dismiss
{
    [_statusTimer invalidate];
    _statusTimer = nil;
    [UIView animateWithDuration:0.2 animations:^{
        self->_box.transform = CGAffineTransformMakeScale(self->_fit * 0.94, self->_fit * 0.94);
        self->_box.alpha = 0;
        self->_dim.alpha = 0;
    } completion:^(BOOL f) {
        self->_win.hidden = YES;
        self->_win = nil;
        gUI = nil;
        BKSetInputGated(NO);
    }];
}

- (CGAffineTransform)fitT { return CGAffineTransformMakeScale(_fit, _fit); }

- (CGRect)stageBounds
{
    CGSize sp = UIScreen.mainScreen.bounds.size;
    CGFloat W = MIN(sp.width, sp.height);
    CGFloat H = MAX(sp.width, sp.height);
    if (W < 40 || H < 40) { W = 375; H = 667; }

    CGRect wf = _win.frame;
    if (fabs(wf.size.width - W) > 1 || fabs(wf.size.height - H) > 1)
        _win.frame = CGRectMake(0, 0, W, H);

    UIView *root = _win.rootViewController.view;
    if (root) {
        root.autoresizingMask = UIViewAutoresizingNone;
        root.transform = CGAffineTransformMakeRotation(BKAngle());
        root.bounds = CGRectMake(0, 0, H, W);
        root.center = CGPointMake(W / 2, H / 2);
    }
    return CGRectMake(0, 0, H, W);
}

- (void)applyCenter
{
    if (!_box || _builtW < 1) return;
    CGSize sp = UIScreen.mainScreen.bounds.size;
    CGFloat W = MIN(sp.width, sp.height), H = MAX(sp.width, sp.height);
    if (W < 40 || H < 40) return;

    CGFloat w = _builtW * _fit, h = _builtH * _fit;
    CGFloat cx = H / 2 + _boxOffset.x;
    CGFloat cy = _topM + h / 2 + _boxOffset.y;

    CGFloat loX = w / 2, hiX = H - w / 2;
    CGFloat loY = h / 2, hiY = W - h / 2;
    if (hiX > loX) cx = MIN(MAX(cx, loX), hiX);
    if (hiY > loY) cy = MIN(MAX(cy, loY), hiY);

    _box.center = CGPointMake(cx, cy);
}

- (void)bkDrag:(UIPanGestureRecognizer *)g
{
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStart = _boxOffset;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint d = [g translationInView:_box.superview];
        _boxOffset = CGPointMake(_dragStart.x + d.x, _dragStart.y + d.y);
        [self applyCenter];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g
{
    if (![g isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    CGPoint p = [g locationInView:_box];
    UIView *hit = [_box hitTest:p withEvent:nil];
    while (hit && hit != _box) {
        if ([hit isKindOfClass:UIControl.class]) return NO;
        hit = hit.superview;
    }
    return YES;
}

- (void)layoutAll
{
    if (!_win || !_box) return;

    CGRect b = [self stageBounds];
    if (b.size.width < 40 || b.size.height < 40) return;

    _dim.frame = b;

    CGFloat L = b.size.width;
    CGFloat S = b.size.height;

    CGFloat mx = MAX(16.0, L * 0.07);
    _topM = MAX(14.0, S * 0.07);
    CGFloat botM = MAX(12.0, S * 0.10);
    CGFloat aw = L - 2 * mx;
    CGFloat ah = S - _topM - botM;

    CGFloat dh = BK_DH;
    CGFloat dw = BK_DH * 1.6;
    CGFloat fit = MIN(aw / dw, ah / dh);
    if (fit <= 0.05) fit = 0.05;

    if (fabs(dw - _builtW) > 1.5 || fabs(dh - _builtH) > 1.5) {
        _builtW = dw; _builtH = dh;
        [self rebuildCanvas];
    }
    _box.bounds = CGRectMake(0, 0, dw, dh);

    _fit = fit * MIN(1.0, _userScale / 100.0);
    _box.transform = [self fitT];
    [self applyCenter];
    _box.alpha = [gCore doubleForKey:kMenuOpacity def:96] / 100.0;
}

- (void)rebuildCanvas
{
    if (!_box) return;
    gDW = _builtW;
    gDH = _builtH;
    gSB = MAX(150.0, _builtW * (BK_SBW / BK_DW));
    [_sidebar removeFromSuperview]; _sidebar = nil;
    [_content removeFromSuperview]; _content = nil;
    [_rows removeAllObjects];
    _inner = nil; _scroll = nil; _statusLbl = nil;
    _box.bounds = CGRectMake(0, 0, gDW, gDH);
    [self buildChrome];
    _tab = MAX(0, MIN(4, _tab));
    NSInteger t = _tab;
    _tab = -1;
    [self setTab:t animated:NO];
}

- (void)buildChrome
{
    _sidebar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, SBW, DH)];
    _sidebar.backgroundColor = SIDE;
    [_box addSubview:_sidebar];
    UIImageView *logo = [[UIImageView alloc] initWithImage:BKIcon(@"cursor", 30, ACC)];
    logo.frame = CGRectMake(30, 34, 30, 30);
    [_sidebar addSubview:logo];
    UILabel *brand = [UILabel new];
    brand.frame = CGRectMake(68, 36, 120, 26);
    brand.text = @"BALLKEY";
    brand.textColor = TXT;
    brand.font = [UIFont systemFontOfSize:19 weight:UIFontWeightHeavy];
    brand.alpha = 0.9;
    [_sidebar addSubview:brand];

    NSArray *names = @[@"Cursor", @"Mapa", @"Teclas", @"Perfis", @"Sobre"];
    NSArray *icons = @[@"cursor", @"map", @"keys", @"user", @"info"];
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        UIControl *c = [[UIControl alloc] initWithFrame:CGRectMake(0, 130 + i * 108, SBW, 92)];
        c.tag = i;
        [c addTarget:self action:@selector(tabTap:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *ic = [[UIImageView alloc] initWithImage:BKIcon(icons[i], 34, DIM)];
        ic.frame = CGRectMake((SBW - 34) / 2, 8, 34, 34);
        ic.tag = 10;
        [c addSubview:ic];
        UILabel *l = [UILabel new];
        l.frame = CGRectMake(0, 50, SBW, 24);
        l.text = names[i];
        l.textColor = DIM;
        l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        l.textAlignment = NSTextAlignmentCenter;
        l.tag = 11;
        [c addSubview:l];
        [_sidebar addSubview:c];
    }
    _pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 46)];
    _pill.backgroundColor = ACC;
    _pill.layer.cornerRadius = 2;
    [_sidebar addSubview:_pill];
}

- (void)tabTap:(UIControl *)c { [self setTab:c.tag animated:YES]; }

- (void)setTab:(NSInteger)tab animated:(BOOL)animated
{
    BOOL same = (tab == _tab && _content);
    _tab = tab;
    for (UIControl *c in _sidebar.subviews) {
        if (![c isKindOfClass:UIControl.class] || c == _pill) continue;
        BOOL on = (c.tag == tab);
        [UIView animateWithDuration:0.25 animations:^{
            UIImageView *iv = (UIImageView *)[c viewWithTag:10];
            iv.alpha = on ? 1 : 0.85;
            iv.tintColor = on ? ACC : DIM;
            ((UILabel *)[c viewWithTag:11]).textColor = on ? ACC : DIM;
        }];
    }
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.7
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_pill.center = CGPointMake(2, 130 + tab * 108 + 23);
    } completion:nil];
    if (same) return;

    UIView *old = _content;
    UIView *nw = [self buildTab:tab];
    nw.alpha = 0;
    nw.transform = CGAffineTransformMakeTranslation(animated ? 26 : 0, 0);
    [_box addSubview:nw];
    _content = nw;
    [UIView animateWithDuration:animated ? 0.24 : 0 animations:^{
        old.alpha = 0;
        old.transform = CGAffineTransformMakeTranslation(animated ? -26 : 0, 0);
        nw.alpha = 1;
        nw.transform = CGAffineTransformIdentity;
    } completion:^(BOOL f) { [old removeFromSuperview]; }];

    for (NSInteger i = 0; i < (NSInteger)_rows.count; i++) {
        UIView *r = _rows[i];
        r.alpha = 0;
        r.transform = CGAffineTransformMakeTranslation(14, 0);
        [UIView animateWithDuration:0.3 delay:0.03 + i * 0.028 usingSpringWithDamping:0.85
             initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            r.alpha = 1;
            r.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (UILabel *)label:(NSString *)t size:(CGFloat)sz color:(UIColor *)c bold:(BOOL)b
{
    UILabel *l = [UILabel new];
    l.text = t;
    l.textColor = c;
    l.font = [UIFont systemFontOfSize:sz weight:b ? UIFontWeightSemibold : UIFontWeightRegular];
    return l;
}
- (UIView *)shell:(CGFloat)h
{
    UIView *r = [[UIView alloc] initWithFrame:CGRectMake(0, 0, DW - SBW - 76, h)];
    r.backgroundColor = ROW;
    r.layer.cornerRadius = 14;
    [_rows addObject:r];
    return r;
}
- (UIView *)header:(NSString *)title icon:(NSString *)icon note:(NSArray *)note host:(UIView *)host
{
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, host.bounds.size.width, 150)];
    UIImageView *ic = [[UIImageView alloc] initWithImage:BKIcon(icon, 26, ACC)];
    ic.frame = CGRectMake(34, 26, 26, 26);
    [h addSubview:ic];
    UILabel *t = [self label:title size:24 color:ACC bold:YES];
    t.frame = CGRectMake(70, 22, 500, 34);
    [h addSubview:t];
    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(h.bounds.size.width - 74, 20, 42, 42);
    [x setImage:BKIcon(@"x", 22, ACC) forState:UIControlStateNormal];
    [x addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
    [h addSubview:x];
    NSMutableAttributedString *a = [NSMutableAttributedString new];
    for (NSDictionary *p in note)
        [a appendAttributedString:[[NSAttributedString alloc] initWithString:p[@"t"] attributes:@{
            NSFontAttributeName:[UIFont systemFontOfSize:16],
            NSForegroundColorAttributeName:[p[@"h"] boolValue] ? ACC : DIM}]];
    UILabel *n = [UILabel new];
    n.frame = CGRectMake(34, 74, h.bounds.size.width - 68, 62);
    n.numberOfLines = 0;
    n.attributedText = a;
    [h addSubview:n];
    return h;
}
- (void)closeTap { [BKUI hide]; }

- (void)toggleRow:(NSString *)title key:(NSString *)key y:(CGFloat)y host:(UIView *)host
{
    UIView *r = [self shell:66];
    r.frame = CGRectMake(0, y, r.bounds.size.width, 66);
    UILabel *l = [self label:title size:18 color:TXT bold:NO];
    l.frame = CGRectMake(22, 0, r.bounds.size.width - 130, 66);
    [r addSubview:l];
    BKToggle *tg = [[BKToggle alloc] initWithFrame:CGRectMake(r.bounds.size.width - 90, 16, 62, 34)];
    tg.on = [gCore boolForKey:key def:NO];
    objc_setAssociatedObject(tg, "k", key, OBJC_ASSOCIATION_RETAIN);
    [tg addTarget:self action:@selector(tgChanged:) forControlEvents:UIControlEventValueChanged];
    [r addSubview:tg];
    [host addSubview:r];
}
- (void)tgChanged:(BKToggle *)t
{
    [gCore setBool:t.on forKey:objc_getAssociatedObject(t, "k")];
    BKApplySettings();
}

- (void)sliderRow:(NSString *)title key:(NSString *)key min:(double)mn max:(double)mx
                y:(CGFloat)y host:(UIView *)host fmt:(NSString *(^)(double))fmt
{
    UIView *r = [self shell:92];
    r.frame = CGRectMake(0, y, r.bounds.size.width, 92);
    UILabel *l = [self label:title size:18 color:TXT bold:NO];
    l.frame = CGRectMake(22, 14, 420, 24);
    [r addSubview:l];
    UILabel *v = [self label:@"" size:16 color:ACC bold:YES];
    v.textAlignment = NSTextAlignmentRight;
    v.frame = CGRectMake(r.bounds.size.width - 150, 14, 128, 24);
    [r addSubview:v];
    BKSlider *s = [[BKSlider alloc] initWithFrame:CGRectMake(22, 46, r.bounds.size.width - 44, 34)];
    s.min = mn;
    s.max = mx;
    s.value = [gCore doubleForKey:key def:(mn + mx) / 2];
    v.text = fmt ? fmt(s.value) : [NSString stringWithFormat:@"%.0f", s.value];
    objc_setAssociatedObject(s, "k", key, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(s, "v", v, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(s, "f", fmt, OBJC_ASSOCIATION_COPY);
    [s addTarget:self action:@selector(slChanged:) forControlEvents:UIControlEventValueChanged];
    [r addSubview:s];
    [host addSubview:r];
}
- (void)slChanged:(BKSlider *)s
{
    UILabel *v = objc_getAssociatedObject(s, "v");
    NSString *(^f)(double) = objc_getAssociatedObject(s, "f");
    v.text = f ? f(s.value) : [NSString stringWithFormat:@"%.0f", s.value];
    [gCore setDouble:s.value forKey:objc_getAssociatedObject(s, "k")];
    BKApplySettings();
}

- (void)dropRow:(NSString *)title key:(NSString *)key options:(NSArray *)opts y:(CGFloat)y host:(UIView *)host
{
    UIView *r = [self shell:66];
    r.frame = CGRectMake(0, y, r.bounds.size.width, 66);
    UILabel *l = [self label:title size:18 color:TXT bold:NO];
    l.frame = CGRectMake(22, 0, 300, 66);
    [r addSubview:l];
    NSInteger idx = MAX(0, MIN((NSInteger)opts.count - 1, [gCore intForKey:key def:0]));
    UILabel *v = [self label:opts[idx] size:17 color:DIM bold:NO];
    v.textAlignment = NSTextAlignmentRight;
    v.frame = CGRectMake(r.bounds.size.width - 320, 0, 260, 66);
    [r addSubview:v];
    UIImageView *ch = [[UIImageView alloc] initWithImage:BKIcon(@"chev", 18, DIM)];
    ch.frame = CGRectMake(r.bounds.size.width - 46, 24, 18, 18);
    [r addSubview:ch];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = r.bounds;
    objc_setAssociatedObject(b, "k", key, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(b, "o", opts, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(b, "l", v, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(b, "r", r, OBJC_ASSOCIATION_RETAIN);
    [b addTarget:self action:@selector(dropTap:) forControlEvents:UIControlEventTouchUpInside];
    [r addSubview:b];
    [host addSubview:r];
}
- (void)dropTap:(UIButton *)b
{
    NSString *key = objc_getAssociatedObject(b, "k");
    NSArray *opts = objc_getAssociatedObject(b, "o");
    UILabel *lbl = objc_getAssociatedObject(b, "l");
    UIView *row = objc_getAssociatedObject(b, "r");
    if (!_inner) return;
    BKPopup *p = [[BKPopup alloc] initWithOptions:opts index:[gCore intForKey:key def:0] width:row.bounds.size.width];
    CGRect rf = [row convertRect:row.bounds toView:_inner];
    p.frame = CGRectMake(rf.origin.x, rf.origin.y + rf.size.height + 6, rf.size.width, p.frame.size.height);
    p.transform = CGAffineTransformMakeScale(0.97, 0.97);
    p.alpha = 0;
    [_inner addSubview:p];
    [UIView animateWithDuration:0.18 animations:^{ p.transform = CGAffineTransformIdentity; p.alpha = 1; }];
    p.onPick = ^(NSInteger i) {
        [gCore setInt:i forKey:key];
        lbl.textColor = TXT;
        [UIView transitionWithView:lbl duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ lbl.text = opts[i]; } completion:nil];
        BKApplySettings();
    };
}

- (void)buttonRow:(NSString *)title color:(UIColor *)c y:(CGFloat)y host:(UIView *)host action:(SEL)sel
{
    UIView *r = [self shell:62];
    r.frame = CGRectMake(0, y, r.bounds.size.width, 62);
    r.backgroundColor = [c colorWithAlphaComponent:0.13];
    r.layer.borderWidth = 1;
    r.layer.borderColor = [c colorWithAlphaComponent:0.55].CGColor;
    UILabel *l = [self label:title size:17 color:c bold:YES];
    l.frame = r.bounds;
    l.textAlignment = NSTextAlignmentCenter;
    [r addSubview:l];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = r.bounds;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [r addSubview:b];
    [host addSubview:r];
}
- (void)section:(NSString *)t y:(CGFloat)y host:(UIView *)host
{
    UILabel *l = [self label:t size:13 color:DIM bold:YES];
    l.frame = CGRectMake(4, y, 400, 18);
    l.alpha = 0.8;
    [host addSubview:l];
}

- (UIView *)buildTab:(NSInteger)tab
{
    [_rows removeAllObjects];
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(SBW, 0, DW - SBW, DH)];
    CGFloat y = 158;

    if (tab == 0) {
        [host addSubview:[self header:@"CURSOR" icon:@"cursor" note:@[
            @{@"t":@"O cursor segue o mouse em 1:1. ", @"h":@YES},
            @{@"t":@"Sensibilidade acima de 1.0 amplia o movimento; a suavização adiciona peso.", @"h":@NO}] host:host]];
        [self toggleRow:@"Cursor" key:kCursor y:y host:host]; y += 78;
        [self sliderRow:@"Sensibilidade" key:kSens min:0.2 max:4.0 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.2f", v]; }]; y += 104;
        [self dropRow:@"Curva" key:kCurve options:@[@"Linear", @"Suave", @"Rápida"] y:y host:host]; y += 78;
        [self sliderRow:@"Suavização" key:kSmooth min:0 max:100 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f%%", v]; }]; y += 104;
        [self sliderRow:@"Eixo Y" key:kYRatio min:50 max:150 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f%%", v]; }]; y += 104;
        [self section:@"TRAVA" y:y host:host]; y += 30;
        [self toggleRow:@"Mostrar círculo de trava" key:kFovCircle y:y host:host]; y += 78;
        [self sliderRow:@"Raio da trava" key:kLockRadius min:20 max:160 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f", v]; }]; y += 104;
        [self dropRow:@"Recentro" key:kRecenter options:@[@"Manual", @"Automático", @"Ao soltar"] y:y host:host]; y += 78;
        [self toggleRow:@"Esconder cursor" key:kHideCursor y:y host:host]; y += 78;
        [self sliderRow:@"Tamanho do cursor" key:kCursorSize min:18 max:70 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f", v]; }]; y += 104;
        [self buttonRow:@"Restaurar padrão" color:BADC y:y host:host action:@selector(resetTap)]; y += 76;
        [self buttonRow:@"Fechar" color:BADC y:y host:host action:@selector(closeTap)]; y += 76;
    } else if (tab == 1) {
        [host addSubview:[self header:@"MAPA" icon:@"map" note:@[
            @{@"t":@"Toque num marcador e aperte a tecla. ", @"h":@NO},
            @{@"t":@"Direcional", @"h":@YES},
            @{@"t":@" coloca um centro e quatro lados — atribua cada lado manualmente.", @"h":@NO}] host:host]];
        [self buttonRow:@"Abrir editor de mapa" color:ACC y:y host:host action:@selector(openEditorTap)]; y += 76;
        [self sliderRow:@"Tamanho dos marcadores" key:kMarkSize min:14 max:70 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f", v]; }]; y += 104;
        [self sliderRow:@"Opacidade dos marcadores" key:kMarkOpacity min:20 max:100 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f%%", v]; }]; y += 104;
        [self toggleRow:@"Rótulos nos marcadores" key:kMarkLabels y:y host:host]; y += 78;
        [self toggleRow:@"Grade de encaixe" key:kSnapGrid y:y host:host]; y += 78;
        [self toggleRow:@"Mostrar marcadores no jogo" key:kShowMarks y:y host:host]; y += 78;
        [self buttonRow:@"Limpar todos os marcadores" color:BADC y:y host:host action:@selector(clearMarksTap)]; y += 76;
        [self buttonRow:@"Recarregar do arquivo" color:DIM y:y host:host action:@selector(reloadMarksTap)]; y += 76;
    } else if (tab == 2) {
        [host addSubview:[self header:@"TECLAS" icon:@"keys" note:@[
            @{@"t":@"Modo de tiro ", @"h":@NO},
            @{@"t":@"Multiplicar", @"h":@YES},
            @{@"t":@" repete o toque — combine com o modo de toque para armas semi e automáticas.", @"h":@NO}] host:host]];
        [self dropRow:@"Modo de tiro" key:kFireMode options:@[@"Toque único", @"Contínuo", @"Multiplicar"] y:y host:host]; y += 78;
        [self dropRow:@"Modo de toque" key:kTapMode options:@[@"Contagem fixa", @"Repetir enquanto segura", @"Pressionar para alternar"] y:y host:host]; y += 78;
        [self sliderRow:@"Repetições" key:kRepeatCount min:2 max:10 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0fx", v]; }]; y += 104;
        [self sliderRow:@"Atraso de repetição" key:kRepeatDelay min:10 max:200 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f ms", v]; }]; y += 104;
        [self toggleRow:@"Segurar mira durante o tiro" key:kHoldAim y:y host:host]; y += 78;
        [self section:@"DIRECIONAL" y:y host:host]; y += 30;
        [self toggleRow:@"Normalizar diagonal" key:kNormDiag y:y host:host]; y += 78;
        [self sliderRow:@"Velocidade do direcional" key:kJoySpeed min:2 max:16 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.1f", v]; }]; y += 104;
        [self dropRow:@"Centro do direcional" key:kJoyCenter options:@[@"Médio", @"Fixo", @"Aleatório"] y:y host:host]; y += 78;
        [self buttonRow:@"Centralizar direcional" color:ACC y:y host:host action:@selector(centerJoyTap)]; y += 76;
    } else if (tab == 3) {
        [host addSubview:[self header:@"PERFIS" icon:@"user" note:@[
            @{@"t":@"Salve um perfil por jogo. ", @"h":@NO},
            @{@"t":@"Carregar automaticamente", @"h":@YES},
            @{@"t":@" troca o conjunto certo ao abrir o título.", @"h":@NO}] host:host]];
        [self buttonRow:@"Salvar perfil atual" color:OKC y:y host:host action:@selector(saveProfileTap)]; y += 76;
        NSArray *names = [gCore profileNames];
        if (!names.count) {
            UILabel *e = [self label:@"Nenhum perfil salvo" size:15 color:DIM bold:NO];
            e.frame = CGRectMake(6, y, 400, 22);
            [host addSubview:e];
            y += 34;
        }
        for (NSString *nm in names) {
            UIView *r = [self shell:56];
            r.frame = CGRectMake(0, y, r.bounds.size.width, 56);
            UILabel *l = [self label:nm size:17 color:TXT bold:NO];
            l.frame = CGRectMake(22, 0, r.bounds.size.width - 180, 56);
            [r addSubview:l];
            UIButton *ld = [UIButton buttonWithType:UIButtonTypeSystem];
            ld.frame = CGRectMake(r.bounds.size.width - 150, 12, 66, 32);
            [ld setTitle:@"Usar" forState:UIControlStateNormal];
            [ld setTitleColor:OKC forState:UIControlStateNormal];
            ld.backgroundColor = [OKC colorWithAlphaComponent:0.14];
            ld.layer.cornerRadius = 8;
            objc_setAssociatedObject(ld, "n", nm, OBJC_ASSOCIATION_RETAIN);
            [ld addTarget:self action:@selector(useProfileTap:) forControlEvents:UIControlEventTouchUpInside];
            [r addSubview:ld];
            UIButton *dl = [UIButton buttonWithType:UIButtonTypeSystem];
            dl.frame = CGRectMake(r.bounds.size.width - 76, 12, 54, 32);
            [dl setTitle:@"X" forState:UIControlStateNormal];
            [dl setTitleColor:BADC forState:UIControlStateNormal];
            dl.backgroundColor = [BADC colorWithAlphaComponent:0.14];
            dl.layer.cornerRadius = 8;
            objc_setAssociatedObject(dl, "n", nm, OBJC_ASSOCIATION_RETAIN);
            [dl addTarget:self action:@selector(delProfileTap:) forControlEvents:UIControlEventTouchUpInside];
            [r addSubview:dl];
            [host addSubview:r];
            y += 68;
        }
        y += 10;
        [self toggleRow:@"Carregar automaticamente" key:kAutoProfile y:y host:host]; y += 78;
        [self buttonRow:@"Restaurar padrão" color:BADC y:y host:host action:@selector(resetTap)]; y += 76;
    } else {
        [host addSubview:[self header:@"SOBRE" icon:@"info" note:@[
            @{@"t":@"Diagnóstico ao vivo e ajustes do overlay.", @"h":@NO}] host:host]];
        UIView *box = [self shell:150];
        box.frame = CGRectMake(0, y, box.bounds.size.width, 150);
        box.backgroundColor = BKHex(0x0A0E15, 1);
        _statusLbl = [self label:@"" size:13 color:DIM bold:NO];
        _statusLbl.numberOfLines = 0;
        _statusLbl.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        _statusLbl.frame = CGRectMake(20, 16, box.bounds.size.width - 40, 120);
        [box addSubview:_statusLbl];
        [host addSubview:box];
        y += 164;
        [self toggleRow:@"Esconder overlay em gravação" key:kHideRec y:y host:host]; y += 78;
        [self sliderRow:@"Opacidade do menu" key:kMenuOpacity min:40 max:100 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f%%", v]; }]; y += 104;
        [self sliderRow:@"Escala da interface" key:kUiScale min:70 max:130 y:y host:host
                    fmt:^NSString *(double v){ return [NSString stringWithFormat:@"%.0f%%", v]; }]; y += 104;
        [self buttonRow:@"Abrir log" color:DIM y:y host:host action:@selector(logTap)]; y += 76;
        [self buttonRow:@"Fechar" color:BADC y:y host:host action:@selector(closeTap)]; y += 76;
        UILabel *cr = [self label:@"BallKey 6.0  •  martidev333\nMapeador de teclado e mouse" size:13 color:DIM bold:NO];
        cr.numberOfLines = 0;
        cr.textAlignment = NSTextAlignmentCenter;
        cr.frame = CGRectMake(0, y + 6, host.bounds.size.width, 44);
        [host addSubview:cr];
        y += 60;
        [self tickStatus];
    }

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(SBW, 0, DW - SBW, DH)];
    sv.showsVerticalScrollIndicator = NO;
    sv.delegate = self;
    _scroll = sv;
    UIView *in = [[UIView alloc] initWithFrame:CGRectMake(0, 0, DW - SBW, MAX(DH, y + 40))];
    _inner = in;
    for (UIView *v in host.subviews) { [v removeFromSuperview]; [in addSubview:v]; }
    sv.contentSize = in.bounds.size;
    [sv addSubview:in];
    return sv;
}

- (void)openEditorTap
{
    [BKUI hide];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 220 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ BKEditorOpenUI(); });
}
- (void)clearMarksTap { [gCore setMarks:@[]]; BKRedrawMarkers(); [self setTab:1 animated:NO]; }
- (void)reloadMarksTap { BKReloadMarks(); [self setTab:1 animated:NO]; }

- (void)centerJoyTap
{
    NSMutableArray *d = [NSMutableArray array];
    for (NSDictionary *m in BKMarks()) if ([m[@"t"] isEqualToString:@"Dir"]) [d addObject:m];
    if (!d.count) return;
    double sx = 0, sy = 0;
    for (NSDictionary *m in d) { sx += [m[@"x"] doubleValue]; sy += [m[@"y"] doubleValue]; }
    [gCore setDouble:sx / d.count forKey:kJoyFx];
    [gCore setDouble:sy / d.count forKey:kJoyFy];
    [gCore setInt:BKJoyCenterFixed forKey:kJoyCenter];
    [self setTab:2 animated:NO];
}

- (void)saveProfileTap
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Salvar perfil"
        message:@"Nome do perfil" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"Ex.: Free Fire - rush"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Salvar" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *n = a.textFields.firstObject.text;
        if (n.length) { [gCore saveProfile:n]; [self setTab:3 animated:NO]; }
    }]];
    [_win.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)useProfileTap:(UIButton *)b
{
    [gCore loadProfile:objc_getAssociatedObject(b, "n")];
    BKApplySettings();
    [self setTab:3 animated:NO];
}
- (void)delProfileTap:(UIButton *)b
{
    [gCore deleteProfile:objc_getAssociatedObject(b, "n")];
    [self setTab:3 animated:NO];
}
- (void)resetTap
{
    [gCore resetDefaults];
    BKApplySettings();
    [self setTab:0 animated:NO];
}
- (void)logTap
{
    NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:@"BallKey/ballkey.log"];
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] ?: @"vazio";
    if (s.length > 1200) s = [s substringFromIndex:s.length - 1200];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Log" message:s
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [_win.rootViewController presentViewController:a animated:YES completion:nil];
}

- (void)tickStatus
{
    if (!_statusLbl) return;
    CGSize s = BKSize();
    _statusLbl.text = [NSString stringWithFormat:
        @"cursor     %@\nsens       %.2f\nmarcadores %lu\nmodo       %@\ntela       %.0fx%.0f\npainel     %.0fx%.0f\nescala     %.0f%%",
        BKCursorOn() ? @"LIGADO" : @"desligado", [gCore doubleForKey:kSens def:1.0],
        (unsigned long)BKMarks().count, BKCursorOn() ? @"cursor" : @"parado",
        s.width, s.height, _builtW * _fit, _builtH * _fit,
        [gCore doubleForKey:kUiScale def:100]];
    _statusLbl.textColor = BKCursorOn() ? OKC : DIM;
}

- (void)presentEditor
{
    CGSize sp = UIScreen.mainScreen.bounds.size;
    CGFloat W = MIN(sp.width, sp.height), H = MAX(sp.width, sp.height);
    CGSize s = CGSizeMake(H, W);

    UIWindowScene *sc = BKScene();
    _win = sc ? [[UIWindow alloc] initWithWindowScene:sc]
              : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _win.windowLevel = UIWindowLevelAlert + 560;
    _win.frame = CGRectMake(0, 0, W, H);
    _win.backgroundColor = UIColor.clearColor;
    _win.rootViewController = [BKHostVC new];
    _win.hidden = NO;
    BKSetEditorOpen(YES);
    BKSetInputGated(YES);

    UIView *r = _win.rootViewController.view;
    r.autoresizingMask = UIViewAutoresizingNone;
    r.transform = CGAffineTransformMakeRotation(BKAngle());
    r.bounds = CGRectMake(0, 0, s.width, s.height);
    r.center = CGPointMake(W / 2, H / 2);

    UIView *canvas = [[UIView alloc] initWithFrame:r.bounds];
    [r addSubview:canvas];
    BKUISetCanvas(canvas);
    BKRedrawMarkers();

    UIView *top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, s.width, 52)];
    top.backgroundColor = [PANEL colorWithAlphaComponent:0.94];
    [r addSubview:top];
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 51.5, s.width, 0.5)];
    line.backgroundColor = STROK;
    [top addSubview:line];

    UILabel *hint = [self label:@"Arraste os marcadores · toque e aperte a tecla" size:11 color:ACC bold:YES];
    hint.frame = CGRectMake(14, 8, s.width * 0.45, 15);
    hint.adjustsFontSizeToFitWidth = YES;
    [top addSubview:hint];
    _statusLbl = [self label:@"Nenhum marcador selecionado" size:10 color:DIM bold:NO];
    _statusLbl.frame = CGRectMake(14, 27, s.width * 0.45, 14);
    _statusLbl.adjustsFontSizeToFitWidth = YES;
    [top addSubview:_statusLbl];

    CGFloat bx = s.width - 14;
    UIButton *no = [self miniChip:@"SAIR" color:BADC frame:CGRectMake(bx - 58, 11, 58, 30)];
    [no addTarget:self action:@selector(editorCancel) forControlEvents:UIControlEventTouchUpInside];
    [top addSubview:no];
    bx -= 64;
    UIButton *ok = [self miniChip:@"SALVAR" color:OKC frame:CGRectMake(bx - 66, 11, 66, 30)];
    [ok addTarget:self action:@selector(editorSave) forControlEvents:UIControlEventTouchUpInside];
    [top addSubview:ok];
    bx -= 72;
    UIButton *del = [self miniChip:@"APAGAR" color:BADC frame:CGRectMake(bx - 68, 11, 68, 30)];
    [del addTarget:self action:@selector(editorDelete) forControlEvents:UIControlEventTouchUpInside];
    [top addSubview:del];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, s.height - 52, s.width, 52)];
    bar.backgroundColor = [PANEL colorWithAlphaComponent:0.94];
    [r addSubview:bar];
    UIView *line2 = [[UIView alloc] initWithFrame:CGRectMake(0, 0, s.width, 0.5)];
    line2.backgroundColor = STROK;
    [bar addSubview:line2];

    UIScrollView *chips = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 6, s.width, 40)];
    chips.showsHorizontalScrollIndicator = NO;
    [bar addSubview:chips];

    NSArray *names = @[@"+ Toque", @"+ Clique", @"+ Pressionar", @"+ Fps", @"+ Mirar", @"+ Atirar", @"+ Direcional"];
    NSArray *types = @[@"Tap", @"Click", @"Press", @"Fps", @"Ads", @"Fire", @"Dir"];
    CGFloat w = 84, x = 8;
    for (int i = 0; i < 7; i++) {
        UIButton *b = [self miniChip:names[i] color:BKUIColorFor(types[i]) frame:CGRectMake(x, 0, w - 6, 34)];
        b.tag = 200 + i;
        [b addTarget:self action:@selector(editorAdd:) forControlEvents:UIControlEventTouchUpInside];
        [chips addSubview:b];
        x += w;
    }
    chips.contentSize = CGSizeMake(x + 8, 34);

    top.transform = CGAffineTransformMakeTranslation(0, -52);
    bar.transform = CGAffineTransformMakeTranslation(0, 52);
    [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.6
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        top.transform = CGAffineTransformIdentity;
        bar.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (UIButton *)miniChip:(NSString *)t color:(UIColor *)c frame:(CGRect)f
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:c forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.backgroundColor = [c colorWithAlphaComponent:0.13];
    b.layer.borderWidth = 1;
    b.layer.borderColor = [c colorWithAlphaComponent:0.55].CGColor;
    b.layer.cornerRadius = 8;
    return b;
}
- (UIButton *)chip:(NSString *)t color:(UIColor *)c frame:(CGRect)f { return [self miniChip:t color:c frame:f]; }

- (void)editorAdd:(UIButton *)b
{
    NSArray *types = @[@"Tap", @"Click", @"Press", @"Fps", @"Ads", @"Fire", @"Dir"];
    NSString *type = types[b.tag - 200];
    CGSize s = gCanvas.bounds.size;
    if (s.width < 1) return;

    if ([type isEqualToString:@"Dir"]) {
        double cx = [gCore doubleForKey:kJoyFx def:0.15];
        double cy = [gCore doubleForKey:kJoyFy def:0.72];
        double rx = 0.055, ry = 0.075;
        [BKMarks() addObject:[@{@"t":@"Pad", @"x":@(cx), @"y":@(cy), @"c":@0} mutableCopy]];
        int padIdx = (int)BKMarks().count - 1;
        [BKMarks() addObject:[@{@"t":@"Dir", @"x":@(cx), @"y":@(cy - ry), @"c":@0} mutableCopy]];
        [BKMarks() addObject:[@{@"t":@"Dir", @"x":@(cx - rx), @"y":@(cy), @"c":@0} mutableCopy]];
        [BKMarks() addObject:[@{@"t":@"Dir", @"x":@(cx + rx), @"y":@(cy), @"c":@0} mutableCopy]];
        [BKMarks() addObject:[@{@"t":@"Dir", @"x":@(cx), @"y":@(cy + ry), @"c":@0} mutableCopy]];
        [gCore setDouble:cx forKey:kJoyFx];
        [gCore setDouble:cy forKey:kJoyFy];
        BKRedrawMarkers();
        BKSelectMarker(padIdx);
        return;
    }
    [BKMarks() addObject:[@{@"t":type, @"x":@0.5, @"y":@0.5, @"c":@0} mutableCopy]];
    BKRedrawMarkers();
    BKSelectMarker((int)BKMarks().count - 1);
}
- (void)editorDelete:(UIButton *)b
{
    int i = BKSelectedMarker();
    if (i < 0 || i >= (int)BKMarks().count) return;
    [BKMarks() removeObjectAtIndex:i];
    BKSelectMarker(-1);
    BKRedrawMarkers();
}
- (void)editorSave { BKSaveMarks(); [self dismissEditor]; }
- (void)editorCancel { BKReloadMarks(); [self dismissEditor]; }
- (void)dismissEditor
{
    [UIView animateWithDuration:0.22 animations:^{ _win.alpha = 0; } completion:^(BOOL f) {
        self->_win.hidden = YES;
        self->_win = nil;
        BKSetEditorOpen(NO);
        BKSetInputGated(NO);
        BKMenuOpen();
    }];
}
- (void)editorGotKey:(int)u
{
    int i = BKSelectedMarker();
    if (i < 0 || i >= (int)BKMarks().count) return;
    BKMarks()[i][@"c"] = @(u);
    _statusLbl.text = [NSString stringWithFormat:@"Tecla %d ligada em %@", u, BKNameFor(BKMarks()[i][@"t"])];
    _statusLbl.textColor = OKC;
    BKSaveMarks();
}
- (void)refreshEditorStatus
{
    if (!_statusLbl) return;
    int i = BKSelectedMarker();
    if (i < 0 || i >= (int)BKMarks().count) {
        _statusLbl.text = @"Nenhum marcador selecionado";
        _statusLbl.textColor = DIM;
        return;
    }
    _statusLbl.text = [NSString stringWithFormat:@"%@ selecionado — aperte uma tecla", BKNameFor(BKMarks()[i][@"t"])];
    _statusLbl.textColor = ACC;
}
@end

static const char *(*o_dyld_name)(uint32_t);
static const struct mach_header *(*o_dyld_hdr)(uint32_t);
static uint32_t (*o_dyld_count)(void);
static int (*o_dladdr)(const void *, Dl_info *);

static BOOL BKSelf(const char *n) { return n && strstr(n, "BallKey") != NULL; }
static uint32_t h_count(void)
{
    uint32_t c = o_dyld_count ? o_dyld_count() : 0;
    for (uint32_t i = 0; i < c; i++) if (BKSelf(o_dyld_name(i))) return c - 1;
    return c;
}
static const char *h_name(uint32_t i)
{
    uint32_t c = o_dyld_count ? o_dyld_count() : 0, j = 0;
    for (uint32_t k = 0; k < c; k++) {
        const char *n = o_dyld_name(k);
        if (BKSelf(n)) continue;
        if (j++ == i) return n;
    }
    return NULL;
}
static const struct mach_header *h_hdr(uint32_t i)
{
    uint32_t c = o_dyld_count ? o_dyld_count() : 0, j = 0;
    for (uint32_t k = 0; k < c; k++) {
        if (BKSelf(o_dyld_name(k))) continue;
        if (j++ == i) return o_dyld_hdr(k);
    }
    return NULL;
}
static int h_dladdr(const void *a, Dl_info *i)
{
    int r = o_dladdr ? o_dladdr(a, i) : 0;
    if (r && i && BKSelf(i->dli_fname)) {
        Dl_info orig;
        if (origEnq && o_dladdr((const void *)origEnq, &orig) && orig.dli_fname) i->dli_fname = orig.dli_fname;
        else i->dli_fname = "/System/Library/Frameworks/UIKit.framework/UIKit";
    }
    return r;
}

typedef struct { const char *name; void *repl; void **orig; } BKTarget;
static BKTarget gTargets[] = {
    {"_dyld_image_count", (void *)h_count, (void **)&o_dyld_count},
    {"_dyld_get_image_name", (void *)h_name, (void **)&o_dyld_name},
    {"_dyld_get_image_header", (void *)h_hdr, (void **)&o_dyld_hdr},
    {"dladdr", (void *)h_dladdr, (void **)&o_dladdr},
};
#define BK_TCOUNT (sizeof(gTargets) / sizeof(gTargets[0]))

struct bk_chain_img { uint32_t seg_count; uint32_t seg_off[1]; };
struct bk_chain_seg { uint32_t size; uint16_t page_size; uint16_t page_count;
                      uint32_t max_valid; uint16_t ptr_format; uint64_t seg_off; uint16_t page_start[1]; };
struct bk_chain_fx { uint32_t ver; uint32_t starts_off; uint32_t imports_off;
                     uint32_t symbols_off; uint32_t imports_count; uint32_t imports_format; uint32_t symbols_format; };
struct bk_import { uint32_t lib_ordinal:8, weak:1, name_off:23; };
struct bk_bind { uint64_t ordinal:24, addend:8, reserved:19, next:12, bind:1; };

static void BKPatchPtr(uint8_t *p, void *repl, void **orig)
{
    uintptr_t page = (uintptr_t)p & ~(uintptr_t)0xFFF;
    vm_protect(mach_task_self(), page, 0x1000, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (orig) *orig = *(void **)p;
    *(void **)p = repl;
}

static void BKApplyChained(const struct mach_header_64 *mh)
{
    const uint8_t *base = (const uint8_t *)mh;
    const struct load_command *lc = (const struct load_command *)(base + sizeof(*mh));
    const struct bk_chain_fx *fx = NULL;
    const uint8_t *le = NULL;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (!strcmp(sg->segname, "__LINKEDIT")) le = base + (sg->vmaddr - sg->fileoff);
        } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) {
            const struct linkedit_data_command *ld = (const struct linkedit_data_command *)lc;
            fx = (const struct bk_chain_fx *)(base + ld->dataoff);
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!fx || !le || fx->imports_format != 1) return;

    const struct bk_chain_img *img = (const struct bk_chain_img *)((const uint8_t *)fx + fx->starts_off);
    const struct bk_import *imp = (const struct bk_import *)((const uint8_t *)fx + fx->imports_off);
    const char *syms = (const char *)fx + fx->symbols_off;

    for (uint32_t s = 0; s < img->seg_count; s++) {
        if (!img->seg_off[s]) continue;
        const struct bk_chain_seg *seg = (const struct bk_chain_seg *)((const uint8_t *)img + img->seg_off[s]);
        if (!seg->page_size) continue;
        uint8_t *sb = (uint8_t *)base + seg->seg_off;
        for (uint16_t pg = 0; pg < seg->page_count; pg++) {
            uint16_t off = seg->page_start[pg];
            if (off == 0xFFFF) continue;
            uint8_t *p = sb + (uint64_t)pg * seg->page_size + off;
            for (int guard = 0; guard < 8192; guard++) {
                struct bk_bind *b = (struct bk_bind *)p;
                if (b->bind && b->ordinal < fx->imports_count) {
                    const char *nm = syms + imp[b->ordinal].name_off;
                    for (size_t t = 0; t < BK_TCOUNT; t++) {
                        if (strcmp(nm, gTargets[t].name)) continue;
                        BKPatchPtr(p, gTargets[t].repl, gTargets[t].orig);
                        break;
                    }
                }
                if (!b->next) break;
                p += b->next * 4;
            }
        }
    }
}

static void BKApplyLegacy(const struct mach_header_64 *mh)
{
    const uint8_t *base = (const uint8_t *)mh;
    const struct load_command *lc = (const struct load_command *)(base + sizeof(*mh));
    const struct symtab_command *st = NULL;
    const struct dysymtab_command *dys = NULL;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) st = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dys = (const struct dysymtab_command *)lc;
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!st || !dys) return;

    const struct nlist_64 *nl = (const struct nlist_64 *)(base + st->symoff);
    const char *str = (const char *)base + st->stroff;
    const uint32_t *ind = (const uint32_t *)(base + dys->indirectsymoff);

    const struct load_command *l2 = (const struct load_command *)((const uint8_t *)base + sizeof(*mh));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (l2->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)l2;
            const struct section_64 *sc = (const struct section_64 *)(sg + 1);
            for (uint32_t j = 0; j < sg->nsects; j++, sc++) {
                if (strcmp(sc->sectname, "__la_symbol_ptr") && strcmp(sc->sectname, "__nl_symbol_ptr")) continue;
                uint32_t n = sc->size / sizeof(void *);
                void **ptrs = (void **)(base + sc->offset);
                for (uint32_t k = 0; k < n; k++) {
                    uint32_t si = ind[sc->reserved1 + k];
                    if (si == INDIRECT_SYMBOL_LOCAL || si == INDIRECT_SYMBOL_ABS || si >= st->nsyms) continue;
                    const char *nm = str + nl[si].n_un.n_strx;
                    for (size_t t = 0; t < BK_TCOUNT; t++) {
                        if (strcmp(nm, gTargets[t].name)) continue;
                        BKPatchPtr((uint8_t *)&ptrs[k], gTargets[t].repl, gTargets[t].orig);
                        break;
                    }
                }
            }
        }
        l2 = (const struct load_command *)((const uint8_t *)l2 + l2->cmdsize);
    }
}

static void BKStealth(void)
{
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh) return;
    o_dyld_count = (uint32_t (*)(void))_dyld_image_count;
    o_dyld_name = (const char *(*)(uint32_t))_dyld_get_image_name;
    o_dyld_hdr = (const struct mach_header *(*)(uint32_t))_dyld_get_image_header;
    o_dladdr = (int (*)(const void *, Dl_info *))dladdr;

    BOOL chained = NO;
    const struct load_command *lc = (const struct load_command *)((const uint8_t *)mh + sizeof(*mh));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) { chained = YES; break; }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (chained) BKApplyChained(mh);
    else BKApplyLegacy(mh);
}

// ---- montagem sob demanda ----
static void BKEnsure(void)
{
    if (gBuilt) return;
    gBuilt = YES;
    @try {
        BKLog(@"ensure 1");
        BKInstall();
        BKLog(@"ensure 2 hid:%d sys:%d", gHidOk, gSys != NULL);

        gBallWin = BKWin(UIWindowLevelAlert + 500, YES);
        gBall = [[BKBallView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
        gBall.center = CGPointMake(28, 44);
        gBall.backgroundColor = UIColor.clearColor;
        [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gBall action:@selector(bkTap:)]];
        [gBallWin.rootViewController.view addSubview:gBall];
        BKLog(@"ensure 3 ball");

        gCursorWin = BKWin(UIWindowLevelAlert + 600, YES);
        gCursorWin.userInteractionEnabled = NO;
        double h = BKNum(kCursorSize, 30);
        gCursor = [[BKCursorView alloc] initWithFrame:CGRectMake(0, 0, h * 0.72, h)];
        gCursor.backgroundColor = UIColor.clearColor;
        [gCursorWin.rootViewController.view addSubview:gCursor];
        gCursorWin.hidden = YES;
        BKLog(@"ensure 4 cursor");

        [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { @try { BKAttachMouse(); } @catch (id e) {} }];
        [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { @try { BKAttachKey(); } @catch (id e) {} }];
        BKAttachMouse();
        BKAttachKey();
        if (!gGcMouse && !gGcKey) BKHook();
        BKLog(@"ensure 5 input hook:%d", gHook);

        void (^relay)(NSNotification *) = ^(NSNotification *n) {
            @try {
                [BKUI relayout];
                for (int i = 1; i <= 3; i++)
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 90 * NSEC_PER_MSEC)),
                                   dispatch_get_main_queue(), ^{ @try { [BKUI relayout]; } @catch (id e) {} });
                BKRelayout();
            } @catch (id e) {}
        };
        [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceOrientationDidChangeNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:relay];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:relay];

        gTick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gTick, dispatch_time(DISPATCH_TIME_NOW, 0), 16 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTick, ^{ @try { BKJoystick(); } @catch (id e) {} });
        dispatch_resume(gTick);

        [NSTimer scheduledTimerWithTimeInterval:0.7 repeats:YES block:^(NSTimer *t) { BKTickFront(); }];
        BKTickFront();
        if ([gCore boolForKey:kCursor def:NO]) BKCursorSet(YES);
        BKLog(@"ensure ok");
    } @catch (id e) { BKLog(@"ensure fail %@", e); }
}

__attribute__((constructor))
static void BKInit(void)
{
    @try {
        gCore = [BKCore shared];
        NSString *base = BKStateDir();
        [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
        gLog = [base stringByAppendingPathComponent:@"ballkey.log"];
        [@"" writeToFile:gLog atomically:NO encoding:NSUTF8StringEncoding error:nil];
        BKLog(@"ctor");
        BKLoadEnabled();
        BKAlive();
        [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer *t) { BKAlive(); }];
        BKActivatorInstall();
        BKLog(@"ctor ok enabled:%d", gEnabled);
    } @catch (id e) {}

    if (![[NSFileManager defaultManager] fileExistsAtPath:BK_SAFE])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @autoreleasepool { @try { BKStealth(); } @catch (id e) {} }
        });
}
