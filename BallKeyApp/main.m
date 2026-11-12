// BallKey 6.0 - ativador
#import <UIKit/UIKit.h>

static NSString *const kNotePanel = @"com.wjf.ballkey.panel";
static NSString *const kNoteGame  = @"com.wjf.ballkey.panelgame";
static NSString *const kNoteOff   = @"com.wjf.ballkey.off";
static NSString *const kState     = @"/var/mobile/Documents/BallKey/enabled";

static void BKMark(NSString *s)
{
    NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!p) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    [s writeToFile:[p stringByAppendingPathComponent:@"boot.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL BKInstalled(void)
{
    NSArray *paths = @[@"/var/jb/Library/MobileSubstrate/DynamicLibraries/BallKey.plist",
                       @"/var/jb/usr/lib/libBallKey.dylib",
                       @"/Library/MobileSubstrate/DynamicLibraries/BallKey.plist"];
    for (NSString *p in paths)
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return YES;
    return NO;
}

static BOOL BKActive(void)
{
    return [[NSString stringWithContentsOfFile:kState encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"1"];
}

static void BKPost(NSString *n)
{
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)n, NULL, NULL, YES);
}

@interface BKVC : UIViewController
@property (nonatomic, strong) UIButton *big;
@property (nonatomic, strong) UILabel *status, *caption;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation BKVC

- (void)viewDidLoad
{
    [super viewDidLoad];
    BKMark(@"viewDidLoad");
    self.view.backgroundColor = UIColor.blackColor;

    self.caption = [[UILabel alloc] initWithFrame:CGRectMake(20, 70, self.view.bounds.size.width - 40, 40)];
    self.caption.text = @"BallKey";
    self.caption.textColor = UIColor.whiteColor;
    self.caption.font = [UIFont boldSystemFontOfSize:30];
    self.caption.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.caption];

    self.big = [UIButton buttonWithType:UIButtonTypeSystem];
    self.big.bounds = CGRectMake(0, 0, 190, 190);
    self.big.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2 - 40);
    self.big.layer.cornerRadius = 95;
    self.big.layer.borderWidth = 3;
    self.big.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [self.big addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.big];

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, self.view.bounds.size.height - 230,
                    self.view.bounds.size.width - 48, 60)];
    self.status.textColor = UIColor.grayColor;
    self.status.font = [UIFont systemFontOfSize:13];
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.status];

    UIButton *inst = [UIButton buttonWithType:UIButtonTypeSystem];
    inst.frame = CGRectMake(24, self.view.bounds.size.height - 150, self.view.bounds.size.width - 48, 44);
    [inst setTitle:@"INSTALAR / REINSTALAR TWEAK" forState:UIControlStateNormal];
    [inst setTitleColor:[UIColor colorWithRed:0.2 green:0.75 blue:0.45 alpha:1] forState:UIControlStateNormal];
    inst.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    inst.layer.cornerRadius = 12;
    inst.layer.borderWidth = 1;
    inst.layer.borderColor = [[UIColor colorWithRed:0.2 green:0.75 blue:0.45 alpha:0.5] CGColor];
    [inst addTarget:self action:@selector(install:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:inst];

    UILabel *cr = [[UILabel alloc] initWithFrame:CGRectMake(20, self.view.bounds.size.height - 70,
                    self.view.bounds.size.width - 40, 20)];
    cr.text = @"martidev333  -  BallKey 6.0";
    cr.textColor = [UIColor colorWithWhite:1 alpha:0.25];
    cr.font = [UIFont systemFontOfSize:11];
    cr.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:cr];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self paint];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [self paint]; }];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)paint
{
    BOOL on = BKActive();
    UIColor *c = on ? [UIColor colorWithRed:1 green:0.42 blue:0.17 alpha:1]
                    : [UIColor colorWithRed:0.35 green:0.9 blue:0.55 alpha:1];
    [self.big setTitle:(on ? @"DESATIVAR" : @"ATIVAR") forState:UIControlStateNormal];
    [self.big setTitleColor:c forState:UIControlStateNormal];
    self.big.layer.borderColor = c.CGColor;
    self.big.backgroundColor = [c colorWithAlphaComponent:0.10];

    if (!BKInstalled()) { self.status.text = @"Tweak não instalado.\nToque em instalar abaixo."; return; }
    self.status.text = on ? @"Ativo.\nO painel está na tela do jogo." : @"Desativado.";
}

- (void)toggle:(id)s
{
    if (!BKInstalled()) { self.status.text = @"Instale o tweak primeiro."; return; }
    BOOL on = BKActive();
    if (on) {
        BKPost(kNoteOff);
        self.status.text = @"Desativado.";
    } else {
        BKPost(kNoteGame);
        self.status.text = @"Ativando e abrindo o Free Fire...";
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self paint]; });
}

- (NSString *)debInBundle
{
    return [[[NSBundle mainBundle] pathsForResourcesOfType:@"deb" inDirectory:nil] firstObject];
}

- (void)install:(id)s
{
    NSString *src = [self debInBundle];
    if (!src) { self.status.text = @"deb não encontrado no bundle."; return; }
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:[src lastPathComponent]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:nil];
    if (![fm copyItemAtPath:src toPath:dst error:nil]) { self.status.text = @"falha ao copiar."; return; }
    UIActivityViewController *a = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:dst]] applicationActivities:nil];
    a.popoverPresentationController.sourceView = self.big;
    a.popoverPresentationController.sourceRect = self.big.bounds;
    [self presentViewController:a animated:YES completion:nil];
    self.status.text = @"Escolha TrollStore e dê respring depois.";
}

@end

@interface BKDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation BKDelegate
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o
{
    BKMark(@"didFinishLaunching");
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = [BKVC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char **argv)
{
    @autoreleasepool {
        BKMark(@"main");
        return UIApplicationMain(argc, argv, nil, @"BKDelegate");
    }
}
