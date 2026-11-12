// BallKey 6.0 - ativador
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <string.h>

static NSString *const kNotePanel = @"com.wjf.ballkey.panel";
static NSString *const kNoteOff   = @"com.wjf.ballkey.off";
static NSString *const kState     = @"/var/mobile/Documents/BallKey/enabled";
static NSString *const kLog       = @"/var/mobile/Documents/BallKey/ballkey.log";
static NSString *const kAlive     = @"/var/mobile/Documents/BallKey/alive";
static NSString *const kDir       = @"/var/mobile/Documents/BallKey";

static void BKMark(NSString *s)
{
    NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!p) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    [s writeToFile:[p stringByAppendingPathComponent:@"boot.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL BKLoaded(void)
{
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:kAlive error:nil];
    if (!a) return NO;
    NSDate *d = a[NSFileModificationDate];
    return d && (-[d timeIntervalSinceNow]) < 60;
}

static BOOL BKGameRunning(void)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0) return NO;
    struct kinfo_proc *buf = malloc(sz);
    if (!buf) return NO;
    if (sysctl(mib, 4, buf, &sz, NULL, 0) != 0) { free(buf); return NO; }
    BOOL found = NO;
    int n = (int)(sz / sizeof(struct kinfo_proc));
    for (int i = 0; i < n && !found; i++) {
        char *nm = buf[i].kp_proc.p_comm;
        if (strstr(nm, "FreeFire") || strstr(nm, "freefire")) found = YES;
    }
    free(buf);
    return found;
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
@property (nonatomic, strong) UIDocumentInteractionController *doc;
@end

@implementation BKVC

- (void)viewDidLoad
{
    [super viewDidLoad];
    BKMark(@"viewDidLoad");
    self.view.backgroundColor = UIColor.blackColor;

    self.caption = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, self.view.bounds.size.width - 40, 40)];
    self.caption.text = @"BallKey";
    self.caption.textColor = UIColor.whiteColor;
    self.caption.font = [UIFont boldSystemFontOfSize:30];
    self.caption.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.caption];

    self.big = [UIButton buttonWithType:UIButtonTypeSystem];
    self.big.bounds = CGRectMake(0, 0, 180, 180);
    self.big.center = CGPointMake(self.view.bounds.size.width / 2, 240);
    self.big.layer.cornerRadius = 90;
    self.big.layer.borderWidth = 3;
    self.big.titleLabel.font = [UIFont boldSystemFontOfSize:23];
    [self.big addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.big];

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(20, 350, self.view.bounds.size.width - 40,
                    self.view.bounds.size.height - 350 - 170)];
    self.status.textColor = UIColor.lightGrayColor;
    self.status.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
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

- (NSString *)logTail
{
    NSString *s = [NSString stringWithContentsOfFile:kLog encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return @"sem log";
    NSArray *l = [s componentsSeparatedByString:@"\n"];
    NSMutableArray *o = [NSMutableArray array];
    for (NSInteger i = MAX(0, (NSInteger)l.count - 2); i < (NSInteger)l.count; i++)
        if ([l[i] length]) [o addObject:l[i]];
    return o.count ? [o componentsJoinedByString:@"\n"] : @"sem log";
}

- (void)paint
{
    BOOL on = BKActive();
    BOOL loaded = BKLoaded();
    BOOL running = BKGameRunning();
    BOOL can = on || (loaded && running);

    UIColor *c = on ? [UIColor colorWithRed:1 green:0.42 blue:0.17 alpha:1]
                    : [UIColor colorWithRed:0.35 green:0.9 blue:0.55 alpha:1];
    [self.big setTitle:(on ? @"DESATIVAR" : @"ATIVAR") forState:UIControlStateNormal];
    [self.big setTitleColor:c forState:UIControlStateNormal];
    self.big.layer.borderColor = c.CGColor;
    self.big.backgroundColor = [c colorWithAlphaComponent:0.10];
    self.big.enabled = can;
    self.big.alpha = can ? 1.0 : 0.30;

    NSString *msg;
    if (!loaded) msg = @"Tweak não carregado.\nReinstale com o Sileo e dê respring.";
    else if (!running && !on) msg = @"Abra o Free Fire primeiro.\nPode deixá-lo em segundo plano e voltar aqui.";
    else if (on) msg = @"Ativo.\nVolte para o Free Fire e jogue.";
    else msg = @"Pronto. Toque em ATIVAR.";

    self.status.text = [NSString stringWithFormat:@"%@\n\n--- tweak ---\n%@", msg, [self logTail]];
}

- (void)toggle:(id)s
{
    if (BKActive()) {
        BKPost(kNoteOff);
        self.status.text = @"Desativado.";
    } else {
        BKPost(kNotePanel);
        self.status.text = @"Ativado. Volte para o Free Fire.";
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self paint]; });
}

- (NSString *)debInBundle
{
    return [[[NSBundle mainBundle] pathsForResourcesOfType:@"deb" inDirectory:nil] firstObject];
}

- (void)install:(id)s
{
    NSString *src = [self debInBundle];
    if (!src) { self.status.text = @"deb não encontrado no bundle."; return; }

    [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [kDir stringByAppendingPathComponent:[src lastPathComponent]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:nil];
    if (![fm copyItemAtPath:src toPath:dst error:nil]) { self.status.text = @"falha ao copiar o deb."; return; }

    self.doc = [UIDocumentInteractionController interactionControllerWithURL:[NSURL fileURLWithPath:dst]];
    BOOL ok = [self.doc presentOpenInMenuFromRect:self.big.frame inView:self.view animated:YES];
    self.status.text = ok
        ? [NSString stringWithFormat:@"Escolha Sileo (ou Filza).\nArquivo em:\n%@", dst]
        : [NSString stringWithFormat:@"Nenhum app para abrir deb.\nInstale o Sileo ou pegue o arquivo em:\n%@", dst];
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
