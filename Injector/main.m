#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#define BK_CONFIG "/var/mobile/Documents/ballkey.json"

@interface BKPassWindow : UIWindow @end
@implementation BKPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self) ? nil : v;
}
@end

static AVAudioPlayer *gSilence;

static void BKKeepAlive(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance;
    [s setCategory:AVAudioSessionCategoryPlayback
       withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [s setActive:YES error:nil];

    uint32_t n = 8000, riff = 36 + n, chunk = 16, rate = 8000;
    uint16_t fmt = 1, ch = 1, align = 1, bits = 8;
    NSMutableData *d = [NSMutableData data];
    [d appendBytes:"RIFF" length:4];      [d appendBytes:&riff length:4];
    [d appendBytes:"WAVEfmt " length:8];  [d appendBytes:&chunk length:4];
    [d appendBytes:&fmt length:2];        [d appendBytes:&ch length:2];
    [d appendBytes:&rate length:4];       [d appendBytes:&rate length:4];
    [d appendBytes:&align length:2];      [d appendBytes:&bits length:2];
    [d appendBytes:"data" length:4];      [d appendBytes:&n length:4];
    uint8_t z = 128;
    for (uint32_t i = 0; i < n; i++) [d appendBytes:&z length:1];

    gSilence = [[AVAudioPlayer alloc] initWithData:d error:nil];
    gSilence.numberOfLoops = -1;
    [gSilence play];
}

@interface BKAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *status;
@end

@implementation BKAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[BKPassWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.windowLevel = UIWindowLevelAlert + 1;
    self.window.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    BKKeepAlive();

    UILabel *title = [UILabel new];
    title.text = @"BallKey";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(0, 90, UIScreen.mainScreen.bounds.size.width, 40);
    [vc.view addSubview:title];

    UILabel *hint = [UILabel new];
    hint.text = @"O painel agora aparece dentro do jogo.\nUse o botão abaixo para abrir o Free Fire.";
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = UIColor.lightGrayColor;
    hint.frame = CGRectMake(24, 140, UIScreen.mainScreen.bounds.size.width - 48, 60);
    [vc.view addSubview:hint];

    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    play.frame = CGRectMake(40, 230, UIScreen.mainScreen.bounds.size.width - 80, 52);
    play.backgroundColor = [UIColor colorWithRed:0.2 green:0.55 blue:1 alpha:1];
    play.layer.cornerRadius = 12;
    [play setTitle:@"Abrir Free Fire" forState:UIControlStateNormal];
    [play setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    play.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [play addTarget:self action:@selector(bkPlay) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:play];

    self.status = [UILabel new];
    self.status.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.status.textColor = UIColor.lightGrayColor;
    self.status.numberOfLines = 0;
    self.status.frame = CGRectMake(20, 300, UIScreen.mainScreen.bounds.size.width - 40, 200);
    [vc.view addSubview:self.status];

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)app {
    self.window.hidden = NO;
    [self bkDump];
}

- (void)bkPlay {
    NSURL *u = [NSURL URLWithString:@"freefire://"];
    if ([[UIApplication sharedApplication] canOpenURL:u])
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

- (void)bkDump {
    NSData *d = [NSData dataWithContentsOfFile:@BK_CONFIG];
    NSDictionary *root = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![root isKindOfClass:NSDictionary.class]) {
        self.status.text = @"Config ainda não existe.\nAbra o jogo uma vez para o tweak criar.";
        return;
    }
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"sensib: %.1f  |  %@\n\n", [root[@"sensitivity"] doubleValue],
                    [root[@"enabled"] boolValue] ? @"ATIVO" : @"PAUSADO"];
    for (NSDictionary *b in root[@"binds"])
        [s appendFormat:@"tecla %@ -> %.0f, %.0f\n", b[@"key"], [b[@"x"] doubleValue], [b[@"y"] doubleValue]];
    self.status.text = s;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(BKAppDelegate.class));
    }
}
