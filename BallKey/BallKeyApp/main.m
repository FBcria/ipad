// BallKey 6.0 - instalador e ativador
#import <UIKit/UIKit.h>

static NSString *const kNotePanel = @"com.wjf.ballkey.panel";
static NSString *const kNoteGame  = @"com.wjf.ballkey.panelgame";

static BOOL BKInstalled(void)
{
    NSArray *paths = @[@"/var/jb/Library/MobileSubstrate/DynamicLibraries/BallKey.plist",
                       @"/var/jb/usr/lib/libBallKey.dylib",
                       @"/Library/MobileSubstrate/DynamicLibraries/BallKey.plist"];
    for (NSString *p in paths)
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return YES;
    return NO;
}

static void BKPost(NSString *name)
{
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name, NULL, NULL, YES);
}

@interface BKVC : UIViewController
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *bPanel, *bGame, *bInstall, *bUrl;
@end

@implementation BKVC

- (UIButton *)mkBtn:(NSString *)title color:(UIColor *)c action:(SEL)a
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = c;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.layer.cornerRadius = 13;
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.12 alpha:1];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(20, 84, 335, 34)];
    t.text = @"BallKey 6.0";
    t.textColor = UIColor.whiteColor;
    t.font = [UIFont boldSystemFontOfSize:26];
    t.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:t];

    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(20, 118, 335, 20)];
    s.text = @"tweak de SpringBoard  -  martidev333";
    s.textColor = UIColor.grayColor;
    s.font = [UIFont systemFontOfSize:12];
    s.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:s];

    self.bGame = [self mkBtn:@"ABRIR PAINEL + FREE FIRE" color:[UIColor colorWithRed:1 green:0.45 blue:0.1 alpha:1] action:@selector(openGame:)];
    self.bGame.frame = CGRectMake(24, 170, 327, 54);
    [self.view addSubview:self.bGame];

    self.bPanel = [self mkBtn:@"SÓ O PAINEL" color:[UIColor colorWithRed:0.18 green:0.24 blue:0.36 alpha:1] action:@selector(openPanel:)];
    self.bPanel.frame = CGRectMake(24, 234, 327, 50);
    [self.view addSubview:self.bPanel];

    self.bInstall = [self mkBtn:@"INSTALAR TWEAK (.deb)" color:[UIColor colorWithRed:0.2 green:0.55 blue:0.35 alpha:1] action:@selector(install:)];
    self.bInstall.frame = CGRectMake(24, 300, 327, 50);
    [self.view addSubview:self.bInstall];

    self.bUrl = [self mkBtn:@"ENVIAR DEB PRO TROLLSTORE" color:[UIColor colorWithRed:0.35 green:0.3 blue:0.6 alpha:1] action:@selector(openTroll:)];
    self.bUrl.frame = CGRectMake(24, 360, 327, 46);
    [self.view addSubview:self.bUrl];

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, 424, 327, 120)];
    self.status.textColor = UIColor.lightGrayColor;
    self.status.font = [UIFont systemFontOfSize:12];
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.status];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    BOOL ok = BKInstalled();
    self.status.text = ok
        ? @"Tweak instalado. Use os botões acima.\nSe o painel não abrir, dê respring."
        : @"Tweak NÃO instalado.\nToque em INSTALAR TWEAK, escolha TrollStore e dê respring depois.";
    self.bInstall.enabled = !ok;
    self.bInstall.alpha = ok ? 0.4 : 1.0;
}

- (void)openPanel:(id)s
{
    if (!BKInstalled()) { self.status.text = @"Instale o tweak primeiro."; return; }
    BKPost(kNotePanel);
    self.status.text = @"Painel enviado.";
}

- (void)openGame:(id)s
{
    if (!BKInstalled()) { self.status.text = @"Instale o tweak primeiro."; return; }
    BKPost(kNoteGame);
    self.status.text = @"Abrindo painel e jogo...";
}

- (NSString *)debInBundle
{
    return [[[NSBundle mainBundle] pathsForResourcesOfType:@"deb" inDirectory:nil] firstObject];
}

- (NSString *)stageDeb
{
    NSString *src = [self debInBundle];
    if (!src) return nil;
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:[src lastPathComponent]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:nil];
    if (![fm copyItemAtPath:src toPath:dst error:nil]) return nil;
    return dst;
}

- (void)install:(id)s
{
    NSString *deb = [self stageDeb];
    if (!deb) { self.status.text = @"deb não encontrado no bundle."; return; }
    UIActivityViewController *a = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:deb]] applicationActivities:nil];
    a.popoverPresentationController.sourceView = self.bInstall;
    a.popoverPresentationController.sourceRect = self.bInstall.bounds;
    [self presentViewController:a animated:YES completion:nil];
    self.status.text = @"Escolha TrollStore na folha. Depois dê respring.";
}

- (void)openTroll:(id)s
{
    NSString *deb = [self stageDeb];
    if (!deb) { self.status.text = @"deb não encontrado no bundle."; return; }
    NSString *u = [@"apple-magnifier://install?url=file://" stringByAppendingString:
        [deb stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:u] options:@{} completionHandler:nil];
}

@end

@interface BKDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation BKDelegate
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o
{
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[BKVC new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char **argv)
{
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"BKDelegate"); }
}
