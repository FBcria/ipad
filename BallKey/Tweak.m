#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#define LEFT   (-1)
#define RIGHT  (-2)

static UIWindow *gWin;
static UIWindow *gSelf;
static UIView *gRoot;
static UIViewController *gVC;
static UIView *gPtr;
static UIView *gPanel;
static UILabel *gStatus;
static UILabel *gDiag;
static NSMutableArray *gMarks;

static BOOL gOn = YES;
static BOOL gOpen = YES;
static BOOL gMarksOn = NO;
static BOOL gPtrOn = YES;
static BOOL gBinding = NO;
static BOOL gTouchBad = NO;
static CGFloat gSens = 1.6;
static CGPoint gP;
static int gK = 0, gM = 0, gTaps = 0;

static NSMutableDictionary *gBinds;
static uint32_t gFinger = 9;

#pragma mark - Prototipos

static void Send(CGPoint p, UITouchPhase ph);
static void Fire(NSString *k, BOOL down);
static void Diag(void);
static void Status(NSString *s);
static void Redraw(void);
static void KeyDown(int code);
static void KeyUp(int code);
static void BtnDown(int code);
static void BtnUp(int code);
static void Move(float dx, float dy);
static void Build(void);

@interface UIApplication (P)
- (UIEvent *)_touchesEvent;
@end
@interface UIEvent (P)
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)d;
- (void)_clearTouches;
@end

@interface Win : UIWindow @end
@interface Root : UIView @end
@interface Ctl : UIViewController @end
@interface Ctl (Acoes)
- (void)toggle;
- (void)onOff:(UIButton *)b;
- (void)marks:(UIButton *)b;
- (void)ptr:(UIButton *)b;
- (void)bind;
- (void)test;
- (void)sens:(UISlider *)s;
@end

#pragma mark - Toque

static void Send(CGPoint p, UITouchPhase ph) {
    if (!gWin) return;
    @try {
        UIEvent *ev = [UIApplication.sharedApplication _touchesEvent];
        if ([ev respondsToSelector:@selector(_clearTouches)]) [ev _clearTouches];
        UITouch *t = [[UITouch alloc] init];
        [t setValue:gWin forKey:@"window"];
        [t setValue:@(ph) forKey:@"phase"];
        [t setValue:@(ph == UITouchPhaseBegan ? 1 : 0) forKey:@"tapCount"];
        [t setValue:[NSValue valueWithCGPoint:p] forKey:@"locationInWindow"];
        [t setValue:@(gFinger) forKey:@"_pathIndex"];
        [t setValue:@(YES) forKey:@"_isFirstTouchForView"];
        [ev _addTouch:t forDelayedDelivery:NO];
        [UIApplication.sharedApplication sendEvent:ev];
        gTaps++;
        gTouchBad = NO;
    } @catch (NSException *e) {
        gTouchBad = YES;
    }
}

#pragma mark - Binds

static void Fire(NSString *k, BOOL down) {
    NSValue *v = gBinds[k];
    if (!v) return;
    Send(v.CGPointValue, down ? UITouchPhaseBegan : UITouchPhaseEnded);
    Diag();
}

static void KeyDown(int code) {
    gK++;
    if (gBinding) {
        gBinding = NO;
        if (code == 41) { Status(@"Bind cancelado"); Diag(); return; }
        gBinds[[NSString stringWithFormat:@"k%d", code]] = [NSValue valueWithCGPoint:gP];
        Status([NSString stringWithFormat:@"Bind k%d", code]);
        Redraw();
        Diag();
        return;
    }
    if (!gOn) return;
    if (code == 41) { gOpen = !gOpen; gSelf.hidden = !gOpen; Redraw(); return; }
    Fire([NSString stringWithFormat:@"k%d", code], YES);
    Diag();
}

static void KeyUp(int code) {
    if (!gOn || gBinding) return;
    Fire([NSString stringWithFormat:@"k%d", code], NO);
}

static void BtnDown(int code) {
    gM++;
    if (gBinding) {
        gBinding = NO;
        gBinds[[NSString stringWithFormat:@"m%d", code]] = [NSValue valueWithCGPoint:gP];
        Status([NSString stringWithFormat:@"Bind m%d", code]);
        Redraw();
        Diag();
        return;
    }
    if (!gOn) return;
    Fire([NSString stringWithFormat:@"m%d", code], YES);
}

static void BtnUp(int code) {
    if (!gOn || gBinding) return;
    Fire([NSString stringWithFormat:@"m%d", code], NO);
}

static void Move(float dx, float dy) {
    gM++;
    if (!gPtrOn || !gWin) { Diag(); return; }
    CGSize s = gWin.bounds.size;
    gP.x += dx * gSens;
    gP.y += dy * gSens;
    gP.x = MAX(8, MIN(s.width - 8, gP.x));
    gP.y = MAX(8, MIN(s.height - 8, gP.y));
    gPtr.center = gP;
    Diag();
}

#pragma mark - Painel

static void Status(NSString *s) { gStatus.text = s ?: @""; }

static void Diag(void) {
    gDiag.text = [NSString stringWithFormat:@"k%d m%d tap%d d%lu %@", gK, gM, gTaps,
                  (unsigned long)gBinds.count, gTouchBad ? @"BAD" : @"ok"];
}

static void Redraw(void) {
    for (UIView *v in gMarks) [v removeFromSuperview];
    [gMarks removeAllObjects];
    if (!gMarksOn) return;
    for (NSString *k in gBinds) {
        NSValue *v = gBinds[k];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 34, 22)];
        l.text = [k hasPrefix:@"k"] ? [k substringFromIndex:1]
                                   : ([k isEqualToString:@"m-1"] ? @"L"
                                   : ([k isEqualToString:@"m-2"] ? @"R" : @"M"));
        l.font = [UIFont boldSystemFontOfSize:11];
        l.textColor = UIColor.whiteColor;
        l.textAlignment = NSTextAlignmentCenter;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        l.layer.cornerRadius = 6;
        l.clipsToBounds = YES;
        l.center = v.CGPointValue;
        [gRoot addSubview:l];
        [gMarks addObject:l];
    }
}

static UIButton *Btn(NSString *t, CGRect f) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    b.layer.cornerRadius = 7;
    b.clipsToBounds = YES;
    return b;
}

#pragma mark - Classes

@implementation Win
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (!v || v == self || v == gRoot) return nil;
    if (!gOpen) return nil;
    return v;
}
@end

@implementation Root @end

@implementation Ctl
- (void)loadView { self.view = [[Root alloc] initWithFrame:UIScreen.mainScreen.bounds]; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self becomeFirstResponder]; }
- (void)pressesBegan:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e {
    for (UIPress *x in p) KeyDown((int)x.key.keyCode);
}
- (void)pressesEnded:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e {
    for (UIPress *x in p) KeyUp((int)x.key.keyCode);
}
@end

@implementation Ctl (Acoes)
- (void)toggle { gOpen = NO; gSelf.hidden = YES; }
- (void)onOff:(UIButton *)b { gOn = !gOn; [b setTitle:gOn ? @"Ativo" : @"Parado" forState:UIControlStateNormal]; }
- (void)marks:(UIButton *)b { gMarksOn = !gMarksOn; Redraw(); }
- (void)ptr:(UIButton *)b { gPtrOn = !gPtrOn; gPtr.hidden = !gPtrOn; }
- (void)bind { gBinding = YES; Status(@"Pressione tecla ou botao (Esc cancela)"); }
- (void)test { Send(gP, UITouchPhaseBegan); Send(gP, UITouchPhaseEnded); Diag(); }
- (void)sens:(UISlider *)s { gSens = s.value; }
@end

#pragma mark - Janela

static UIWindowScene *Scene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    return nil;
}

static void FindGame(void) {
    for (UIWindow *w in Scene().windows)
        if (w != gSelf && w.isKeyWindow) { gWin = w; break; }
}

static void Build(void) {
    UIWindowScene *sc = Scene();
    if (!sc) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)3e8), dispatch_get_main_queue(), ^{ Build(); });
        return;
    }

    gWin = nil;
    FindGame();

    gSelf = [[Win alloc] initWithWindowScene:sc];
    gSelf.frame = UIScreen.mainScreen.bounds;
    gSelf.windowLevel = 10000001;
    gSelf.backgroundColor = UIColor.clearColor;
    gVC = [Ctl new];
    gSelf.rootViewController = gVC;
    [gSelf makeKeyAndVisible];
    gRoot = gVC.view;

    gMarks = [NSMutableArray array];
    gBinds = [NSMutableDictionary dictionary];

    gPtr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    gPtr.backgroundColor = [UIColor colorWithWhite:1 alpha:0.30];
    gPtr.layer.cornerRadius = 13;
    gPtr.layer.borderWidth = 1.5;
    gPtr.layer.borderColor = UIColor.whiteColor.CGColor;
    gPtr.center = CGPointMake(120, 220);
    gP = gPtr.center;
    [gRoot addSubview:gPtr];

    CGFloat w = 250;
    gPanel = [[UIView alloc] initWithFrame:CGRectMake(12, 70, w, 210)];
    gPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    gPanel.layer.cornerRadius = 14;
    [gRoot addSubview:gPanel];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 46, 20)];
    t.text = @"MobileInput";
    t.textColor = UIColor.whiteColor;
    t.font = [UIFont boldSystemFontOfSize:14];
    [gPanel addSubview:t];

    UIButton *x = Btn(@"x", CGRectMake(w - 34, 6, 26, 26));
    [x addTarget:gVC action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:x];

    UIButton *on = Btn(@"Ativo", CGRectMake(12, 34, 70, 30));
    [on addTarget:gVC action:@selector(onOff:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:on];

    UIButton *mk = Btn(@"Marcas", CGRectMake(90, 34, 70, 30));
    [mk addTarget:gVC action:@selector(marks:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:mk];

    UIButton *pt = Btn(@"Seta", CGRectMake(168, 34, 70, 30));
    [pt addTarget:gVC action:@selector(ptr:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:pt];

    UIButton *nv = Btn(@"Novo bind", CGRectMake(12, 72, 110, 30));
    [nv addTarget:gVC action:@selector(bind) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:nv];

    UIButton *ts = Btn(@"Testar", CGRectMake(130, 72, 108, 30));
    [ts addTarget:gVC action:@selector(test) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:ts];

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(12, 108, w - 24, 30)];
    sl.minimumValue = 0.4; sl.maximumValue = 4.0; sl.value = gSens;
    [sl addTarget:gVC action:@selector(sens:) forControlEvents:UIControlEventValueChanged];
    [gPanel addSubview:sl];

    gStatus = [[UILabel alloc] initWithFrame:CGRectMake(12, 140, w - 24, 18)];
    gStatus.textColor = UIColor.systemYellowColor;
    gStatus.font = [UIFont systemFontOfSize:11];
    gStatus.text = @"Aguardando...";
    [gPanel addSubview:gStatus];

    gDiag = [[UILabel alloc] initWithFrame:CGRectMake(12, 160, w - 24, 18)];
    gDiag.textColor = UIColor.lightGrayColor;
    gDiag.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    [gPanel addSubview:gDiag];

    [gVC becomeFirstResponder];
    Diag();
    Status(@"Pronto");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)5e8), dispatch_get_main_queue(), ^{
        if (!gWin) FindGame();
        if (!gWin) Status(@"Janela do jogo nao encontrada");
    });
}

#pragma mark - GameController

static void (*oKey)(id, SEL, id);
static void (*oMove)(id, SEL, id);

static void BindBtn(GCControllerButtonInput *b, int code) {
    if (!b) return;
    b.pressedChangedHandler = ^(GCControllerButtonInput *btn, float value, BOOL pressed) {
        if (pressed) BtnDown(code); else BtnUp(code);
    };
}

static void BindMouse(GCMouseInput *m) {
    if (!m) return;
    BindBtn(m.leftButton, LEFT);
    BindBtn(m.rightButton, RIGHT);
    BindBtn(m.middleButton, -3);
    NSArray<GCControllerButtonInput *> *aux = m.auxiliaryButtons;
    for (NSUInteger i = 0; i < aux.count; i++) BindBtn(aux[i], -(int)i - 4);
}

static void nKey(id s, SEL c, id h) {
    if (oKey) oKey(s, c, h);
    if (!h) return;
    [(GCKeyboardInput *)s setKeyChangedHandler:^(GCKeyboardInput *k, GCControllerButtonInput *key, GCKeyCode code, BOOL down) {
        if (down) KeyDown((int)code); else KeyUp((int)code);
    }];
}

static void nMove(id s, SEL c, id h) {
    if (oMove) oMove(s, c, h);
    [(GCMouseInput *)s setMouseMovedHandler:^(GCMouseInput *m, float dx, float dy) { Move(dx, dy); }];
    BindMouse((GCMouseInput *)s);
}

static void Hook(Class c, SEL s, void *f, void **orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    *orig = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)f);
}

static void WatchMouse(void) {
    GCMouse *mo = GCMouse.current;
    if (mo && mo.mouseInput) BindMouse(mo.mouseInput);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)1e9), dispatch_get_main_queue(), ^{ WatchMouse(); });
}

#pragma mark - Entrada

__attribute__((constructor)) static void Start(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            Hook([GCKeyboardInput class], @selector(setKeyChangedHandler:), (void *)nKey, (void **)&oKey);
            Hook([GCMouseInput class], @selector(setMouseMovedHandler:), (void *)nMove, (void **)&oMove);
        } @catch (NSException *e) {}
        Build();
        WatchMouse();
    });
}
