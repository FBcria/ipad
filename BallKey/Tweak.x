// BallKey — mapeador teclado/mouse -> toque
// Painel desenhado DENTRO do processo do jogo (não some ao trocar de app)

#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDEvent.h>
#import <mach/mach_time.h>

#define BK_CONFIG "/var/mobile/Documents/ballkey.json"

@interface UIApplication (BKPrivate)
- (void)_enqueueHIDEvent:(IOHIDEventRef)event;
@end

#pragma mark - Estado

static NSMutableArray<NSMutableDictionary *> *gBinds;
static NSMutableDictionary<NSNumber *, NSNumber *> *gHeld;   // key -> finger
static UIWindow *gHUD;
static UIView *gPanel;
static UIView *gPointer;
static UIView *gRootView;
static UILabel *gStatus;
static UIStackView *gStack;

static BOOL gEnabled = YES;
static BOOL gPanelOpen = YES;
static BOOL gMouseLook = YES;
static CGFloat gSensitivity = 1.6;

static NSMutableDictionary *gCapture;
static BOOL gCapturePos = NO;
static uint32_t gFinger = 1;
static CGPoint gPointerPos;

#pragma mark - Toque

static void BKInject(CGPoint p, BOOL down, uint32_t finger) {
    IOHIDEventRef ev = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        kIOHIDDigitizerTransducerTypeHand, 0, finger, 0,
        down ? kIOHIDDigitizerEventTouch : 0, down, 0,
        p.x, p.y, 0, 0, 0, 0, 0);
    if (!ev) return;
    IOHIDEventSetIntegerValue(ev, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    [[UIApplication sharedApplication] _enqueueHIDEvent:ev];
    CFRelease(ev);
}

static void BKDown(NSDictionary *b) {
    NSNumber *k = @([b[@"key"] intValue]);
    if (gHeld[k]) return;
    uint32_t f = gFinger++;
    gHeld[k] = @(f);
    BKInject(CGPointMake([b[@"x"] doubleValue], [b[@"y"] doubleValue]), YES, f);
}

static void BKUp(NSDictionary *b) {
    NSNumber *k = @([b[@"key"] intValue]);
    NSNumber *f = gHeld[k];
    if (!f) return;
    BKInject(CGPointMake([b[@"x"] doubleValue], [b[@"y"] doubleValue]), NO, f.unsignedIntValue);
    [gHeld removeObjectForKey:k];
}

static void BKReleaseAll(void) {
    for (NSNumber *k in gHeld.allKeys) {
        NSNumber *f = gHeld[k];
        for (NSDictionary *b in gBinds) {
            if ([b[@"key"] intValue] == k.intValue) {
                BKInject(CGPointMake([b[@"x"] doubleValue], [b[@"y"] doubleValue]), NO, f.unsignedIntValue);
                break;
            }
        }
    }
    [gHeld removeAllObjects];
}

#pragma mark - Config

static void BKLoad(void) {
    NSData *d = [NSData dataWithContentsOfFile:@BK_CONFIG];
    NSDictionary *root = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([root isKindOfClass:NSDictionary.class]) {
        id b = root[@"binds"];
        gBinds = [b isKindOfClass:NSArray.class] ? [b mutableCopy] : [NSMutableArray array];
        if (root[@"sensitivity"]) gSensitivity = [root[@"sensitivity"] doubleValue];
        if (root[@"enabled"]) gEnabled = [root[@"enabled"] boolValue];
        if (root[@"panelOpen"]) gPanelOpen = [root[@"panelOpen"] boolValue];
    } else if (!gBinds) {
        gBinds = [NSMutableArray array];
    }
}

static void BKSave(void) {
    NSDictionary *root = @{ @"binds": gBinds,
                            @"sensitivity": @(gSensitivity),
                            @"enabled": @(gEnabled),
                            @"panelOpen": @(gPanelOpen) };
    NSData *d = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents"
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [d writeToFile:@BK_CONFIG atomically:YES];
}

#pragma mark - Nomes de tecla

static NSString *BKKeyName(int code) {
    if (code >= 4 && code <= 29) return [NSString stringWithFormat:@"%c", 'A' + (code - 4)];
    if (code >= 30 && code <= 38) return [NSString stringWithFormat:@"%d", code - 29];
    if (code == 39) return @"0";
    switch (code) {
        case 40: return @"Enter";
        case 41: return @"Esc";
        case 42: return @"Back";
        case 43: return @"Tab";
        case 44: return @"Espaço";
        case 225: return @"Shift";
        case 224: return @"Ctrl";
        case 226: return @"Alt";
        case 227: return @"Cmd";
        case 79: return @"→";
        case 80: return @"←";
        case 81: return @"↓";
        case 82: return @"↑";
        default: return [NSString stringWithFormat:@"#%d", code];
    }
}

#pragma mark - UI

static void BKRefresh(void) {
    for (UIView *v in gStack.arrangedSubviews) { [gStack removeArrangedSubview:v]; [v removeFromSuperview]; }

    if (gBinds.count == 0) {
        UILabel *l = [UILabel new];
        l.text = @"Nenhum bind.\nToque em + e pressione uma tecla.";
        l.numberOfLines = 0;
        l.font = [UIFont systemFontOfSize:11];
        l.textColor = UIColor.lightGrayColor;
        [gStack addArrangedSubview:l];
    }

    for (NSMutableDictionary *b in gBinds) {
        UIView *row = [UIView new];
        row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
        row.layer.cornerRadius = 6;

        UILabel *k = [UILabel new];
        k.text = BKKeyName([b[@"key"] intValue]);
        k.font = [UIFont boldSystemFontOfSize:12];
        k.textColor = UIColor.whiteColor;
        k.frame = CGRectMake(8, 6, 70, 18);
        [row addSubview:k];

        UILabel *p = [UILabel new];
        p.text = [NSString stringWithFormat:@"%.0f, %.0f", [b[@"x"] doubleValue], [b[@"y"] doubleValue]];
        p.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
        p.textColor = UIColor.lightGrayColor;
        p.frame = CGRectMake(80, 6, 100, 18);
        [row addSubview:p];

        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        del.frame = CGRectMake(190, 2, 30, 26);
        [del setTitle:@"×" forState:UIControlStateNormal];
        del.tag = [gBinds indexOfObject:b];
        [del addTarget:(id)gHUD.rootViewController action:@selector(bkDelete:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:del];

        row.frame = CGRectMake(0, 0, 220, 30);
        [gStack addArrangedSubview:row];
    }

    gStatus.text = gEnabled ? @"ATIVO" : @"PAUSADO";
    gStatus.textColor = gEnabled ? [UIColor colorWithRed:0.3 green:0.9 blue:0.5 alpha:1] : UIColor.systemOrangeColor;
}

static void BKTogglePanel(void) {
    gPanelOpen = !gPanelOpen;
    gPanel.hidden = !gPanelOpen;
    BKSave();
}

#pragma mark - Instalação do HUD

static void BKInstallHUD(void) {
    if (gHUD) { gHUD.hidden = NO; return; }

    UIWindow *w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelAlert - 1;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;
    gHUD = w;
    gRootView = vc.view;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:(id)w.rootViewController
                                                                         action:@selector(bkTap:)];
    tap.cancelsTouchesInView = NO;
    [gRootView addGestureRecognizer:tap];

    // ponteiro do mouse
    gPointer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 14)];
    gPointer.backgroundColor = [UIColor colorWithRed:1 green:0.2 blue:0.3 alpha:0.85];
    gPointer.layer.cornerRadius = 7;
    gPointer.userInteractionEnabled = NO;
    gPointer.hidden = YES;
    [gRootView addSubview:gPointer];
    gPointerPos = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                              UIScreen.mainScreen.bounds.size.height / 2);

    // painel
    gPanel = [[UIView alloc] initWithFrame:CGRectMake(16, 60, 260, 340)];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.88];
    gPanel.layer.cornerRadius = 12;
    gPanel.layer.borderWidth = 1;
    gPanel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    [gRootView addSubview:gPanel];

    UILabel *title = [UILabel new];
    title.text = @"BallKey";
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textColor = UIColor.whiteColor;
    title.frame = CGRectMake(14, 12, 120, 20);
    [gPanel addSubview:title];

    gStatus = [UILabel new];
    gStatus.font = [UIFont boldSystemFontOfSize:11];
    gStatus.frame = CGRectMake(14, 32, 120, 16);
    [gPanel addSubview:gStatus];

    UIButton *power = [UIButton buttonWithType:UIButtonTypeSystem];
    power.frame = CGRectMake(150, 8, 100, 30);
    [power setTitle:@"Ligar/Desligar" forState:UIControlStateNormal];
    power.titleLabel.font = [UIFont systemFontOfSize:11];
    [power addTarget:(id)w.rootViewController action:@selector(bkPower:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:power];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(228, 6, 26, 26);
    [close setTitle:@"–" forState:UIControlStateNormal];
    [close addTarget:(id)w.rootViewController action:@selector(bkToggle:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:close];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(14, 52, 110, 30);
    [add setTitle:@"+ bind" forState:UIControlStateNormal];
    [add addTarget:(id)w.rootViewController action:@selector(bkAdd:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:add];

    UIButton *sens = [UIButton buttonWithType:UIButtonTypeSystem];
    sens.frame = CGRectMake(130, 52, 116, 30);
    [sens setTitle:@"Sensib. 1.6" forState:UIControlStateNormal];
    sens.titleLabel.font = [UIFont systemFontOfSize:11];
    [sens addTarget:(id)w.rootViewController action:@selector(bkSens:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:sens];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(14, 90, 232, 236)];
    sv.alwaysBounceVertical = YES;
    [gPanel addSubview:sv];

    gStack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 232, 0)];
    gStack.axis = UILayoutConstraintAxisVertical;
    gStack.spacing = 6;
    [sv addSubview:gStack];

    [w makeKeyAndVisible];
    w.hidden = NO;
    BKRefresh();
}

#pragma mark - Handlers

@interface BKRoot : UIViewController
@end

@implementation BKRoot

- (void)bkTap:(UITapGestureRecognizer *)g {
    if (!gCapturePos || !gCapture) return;
    CGPoint p = [g locationInView:gRootView];
    gCapture[@"x"] = @(p.x);
    gCapture[@"y"] = @(p.y);
    gCapturePos = NO;
    gCapture = nil;
    BKSave();
    BKRefresh();
}

- (void)bkAdd:(UIButton *)b {
    NSMutableDictionary *nb = [@{ @"key": @(0), @"x": @(0), @"y": @(0) } mutableCopy];
    [gBinds addObject:nb];
    gCapture = nb;
    gCapturePos = NO;
    BKSave();
    BKRefresh();
}

- (void)bkDelete:(UIButton *)b {
    if (b.tag < (NSInteger)gBinds.count) {
        [gBinds removeObjectAtIndex:b.tag];
        BKSave();
        BKRefresh();
    }
}

- (void)bkPower:(UIButton *)b {
    gEnabled = !gEnabled;
    if (!gEnabled) BKReleaseAll();
    BKSave();
    BKRefresh();
}

- (void)bkToggle:(UIButton *)b { BKTogglePanel(); }

- (void)bkSens:(UIButton *)b {
    gSensitivity = gSensitivity >= 4.0 ? 0.6 : gSensitivity + 0.4;
    [(UIButton *)b setTitle:[NSString stringWithFormat:@"Sensib. %.1f", gSensitivity] forState:UIControlStateNormal];
    BKSave();
}

@end

#pragma mark - Entrada

static void BKKeyEvent(GCKeyCode code, BOOL pressed) {
    int c = (int)code;

    if (pressed && gCapture) {
        gCapture[@"key"] = @(c);
        gCapturePos = YES;
        BKRefresh();
        return;
    }

    if (!gEnabled) return;

    for (NSDictionary *b in gBinds) {
        if ([b[@"key"] intValue] != c) continue;
        if ([b[@"x"] doubleValue] == 0 && [b[@"y"] doubleValue] == 0) break;
        pressed ? BKDown(b) : BKUp(b);
        break;
    }
}

static void BKInstallInput(void) {
    GCKeyboard *kb = GCKeyboard.coalescedKeyboard;
    if (kb) {
        kb.keyboardInput.keyboardInputHandler = ^(GCKeyboardInput *k, GCControllerButtonInput *btn,
                                                  GCKeyCode code, BOOL pressed) {
            BKKeyEvent(code, pressed);
        };
    }

    GCMouse *m = GCMouse.current;
    if (m) {
        m.mouseInput.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) {
            if (!gEnabled) return;
            CGSize s = UIScreen.mainScreen.bounds.size;
            gPointerPos.x += dx * gSensitivity;
            gPointerPos.y += dy * gSensitivity;
            gPointerPos.x = MAX(0, MIN(s.width, gPointerPos.x));
            gPointerPos.y = MAX(0, MIN(s.height, gPointerPos.y));
            gPointer.hidden = NO;
            gPointer.center = gPointerPos;
        };
        m.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *btn, float v, BOOL pressed) {
            if (!gEnabled) return;
            BKInject(gPointerPos, pressed, 999);
        };
        m.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *btn, float v, BOOL pressed) {
            if (pressed) BKTogglePanel();
        };
    }
}

#pragma mark - Ciclo de vida

%ctor {
    BKLoad();
    gHeld = [NSMutableDictionary dictionary];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BKInstallHUD();
            BKInstallInput();
        });
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gHUD.hidden = NO;
            BKRefresh();
        });
    }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        BKReleaseAll();
    }];
    [nc addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ BKInstallInput(); });
    }];
}
