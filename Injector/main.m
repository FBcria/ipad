#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach-o/dyld_images.h>
#import <sys/sysctl.h>
#import <dlfcn.h>

static NSString *const kDir   = @"/var/mobile/Library/Caches/ballkey";
static NSString *const kDylib = @"/var/mobile/Library/Caches/ballkey/libballkey.dylib";

// Release com o asset libballkey.dylib anexado. Se não houver release, cai no raw do repo.
static NSString *const kURLRelease = @"https://github.com/FBcria/ipad/releases/latest/download/libballkey.dylib";
static NSString *const kURLRaw     = @"https://raw.githubusercontent.com/FBcria/ipad/main/BallKey/libballkey.dylib";
static NSString *const kBundleFF   = @"com.dts.freefireth";
static NSString *const kBundleMax  = @"com.dts.freefiremax";

#pragma mark - PID

static pid_t BKFindPID(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return 0;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return 0; }
    pid_t found = 0;
    size_t n = size / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < n; i++) {
        const char *name = procs[i].kp_proc.p_comm;
        if (!strcmp(name, "FreeFire") || !strcmp(name, "FreeFireMAX")) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}

#pragma mark - Injeção

static uint64_t BKRemoteAddress(task_t task, uint64_t localAddr) {
    struct task_dyld_info dyldInfo = {0};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count) != KERN_SUCCESS) return 0;

    struct dyld_all_image_infos *remote = (struct dyld_all_image_infos *)dyldInfo.all_image_info_addr;
    struct dyld_all_image_infos local = {0};
    mach_vm_size_t readSize = 0;
    if (mach_vm_read_overwrite(task, (mach_vm_address_t)remote, sizeof(local),
                               (mach_vm_address_t)&local, &readSize) != KERN_SUCCESS) return 0;

    uint64_t targetDyld = (uint64_t)local.dyldImageLoadAddress;
    uint64_t ourSlide = (uint64_t)_dyld_get_image_vmaddr_slide(0);
    uint64_t unslidDyld = (uint64_t)_dyld_get_image_header(0) - ourSlide;
    if (!targetDyld || !unslidDyld) return 0;

    return localAddr + (uint64_t)((int64_t)targetDyld - (int64_t)unslidDyld);
}

static kern_return_t BKInject(pid_t pid, const char *path, NSString **err) {
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        *err = [NSString stringWithFormat:@"task_for_pid falhou (0x%x). O Free Fire foi instalado pelo TrollStore?", kr];
        return kr;
    }

    uint64_t dlopenAddr = BKRemoteAddress(task, (uint64_t)dlsym(RTLD_DEFAULT, "dlopen"));
    uint64_t exitAddr   = BKRemoteAddress(task, (uint64_t)dlsym(RTLD_DEFAULT, "pthread_exit"));
    if (!dlopenAddr || !exitAddr) {
        mach_port_deallocate(mach_task_self(), task);
        *err = @"não resolvi os símbolos no alvo";
        return KERN_FAILURE;
    }

    size_t pathLen = strlen(path) + 1;
    vm_size_t pageSize = 0x4000;
    mach_vm_address_t code = 0, stack = 0;

    kr = mach_vm_allocate(task, &code, pageSize * 2, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), task); *err = @"mach_vm_allocate (código)"; return kr; }
    kr = mach_vm_allocate(task, &stack, pageSize * 2, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { mach_vm_deallocate(task, code, pageSize * 2); mach_port_deallocate(mach_task_self(), task); *err = @"mach_vm_allocate (pilha)"; return kr; }

    mach_vm_address_t pathAddr = code + 0x100;
    kr = mach_vm_write(task, pathAddr, (vm_offset_t)path, (mach_msg_type_number_t)pathLen);
    if (kr != KERN_SUCCESS) { *err = @"mach_vm_write (caminho)"; goto fail; }

    uint32_t stub[] = { 0x58000100, 0xD2800041, 0x58000110, 0xD63F0200,
                        0xD2800000, 0x580000F0, 0xD63F0200, 0x14000000 };
    uint64_t literals[] = { (uint64_t)pathAddr, dlopenAddr, exitAddr };

    kr = mach_vm_write(task, code, (vm_offset_t)stub, sizeof(stub));
    if (kr != KERN_SUCCESS) { *err = @"mach_vm_write (stub)"; goto fail; }
    kr = mach_vm_write(task, code + 0x20, (vm_offset_t)literals, sizeof(literals));
    if (kr != KERN_SUCCESS) { *err = @"mach_vm_write (literais)"; goto fail; }

    mach_vm_protect(task, code, pageSize * 2, FALSE, VM_PROT_READ | VM_PROT_EXECUTE | VM_PROT_WRITE);
    mach_vm_protect(task, stack, pageSize * 2, FALSE, VM_PROT_READ | VM_PROT_WRITE);

    arm_thread_state64_t state = {0};
    state.__pc = code;
    state.__sp = (stack + pageSize * 2 - 0x100) & ~0xFULL;
    state.__lr = 0;

    thread_act_t thread = MACH_PORT_NULL;
    kr = thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &thread);
    if (kr != KERN_SUCCESS) { *err = [NSString stringWithFormat:@"thread_create_running (0x%x)", kr]; goto fail; }

    mach_port_deallocate(mach_task_self(), task);
    return KERN_SUCCESS;

fail:
    mach_vm_deallocate(task, code, pageSize * 2);
    mach_vm_deallocate(task, stack, pageSize * 2);
    mach_port_deallocate(mach_task_self(), task);
    return kr;
}

#pragma mark - Download

static BOOL BKDownloadDylib(NSString **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDate *mod = [fm attributesOfItemAtPath:kDylib error:nil][NSFileModificationDate];
    if (mod && -[mod timeIntervalSinceNow] < 60 * 60 * 12) return YES;

    for (NSString *u in @[kURLRelease, kURLRaw]) {
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:u]];
        if (data.length > 4096 && [data writeToFile:kDylib atomically:YES]) return YES;
    }
    *err = @"download do dylib falhou";
    return NO;
}

#pragma mark - UI

@interface BKVC : UIViewController
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *start;
@property (nonatomic, strong) NSTimer *poll;
@end

@implementation BKVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1];

    UILabel *title = [UILabel new];
    title.text = @"BALLKEY";
    title.font = [UIFont boldSystemFontOfSize:30];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    self.status.font = [UIFont systemFontOfSize:14];
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.status];

    self.start = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.start setTitle:@"START" forState:UIControlStateNormal];
    [self.start setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.start.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.start.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1];
    self.start.layer.cornerRadius = 12;
    self.start.translatesAutoresizingMaskIntoConstraints = NO;
    [self.start addTarget:self action:@selector(startTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.start];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:40],
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.status.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.start.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.start.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.start.widthAnchor constraintEqualToConstant:220],
        [self.start.heightAnchor constraintEqualToConstant:64],
    ]];

    self.poll = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [self refresh];
}

- (void)refresh {
    if (!self.start.enabled && !self.status.text.length) return;
    pid_t pid = BKFindPID();
    BOOL have = [[NSFileManager defaultManager] fileExistsAtPath:kDylib];
    self.status.text = pid
        ? [NSString stringWithFormat:@"Jogo aberto (PID %d).\nDylib %@.", pid, have ? @"em cache" : @"será baixada"]
        : @"Jogo fechado.\nAbra o Free Fire, volte aqui e toque em START.";
    self.start.enabled = pid != 0;
    self.start.alpha = pid ? 1.0 : 0.45;
}

- (void)startTapped {
    pid_t pid = BKFindPID();
    if (!pid) { [self refresh]; return; }
    self.start.enabled = NO;
    self.status.text = @"Preparando...";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        if (!BKDownloadDylib(&err)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.text = err; self.start.enabled = YES;
            });
            return;
        }
        kern_return_t kr = BKInject(pid, kDylib.fileSystemRepresentation, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (kr == KERN_SUCCESS) {
                self.status.text = @"Injetado. Voltando ao jogo...";
                [self performSelector:@selector(backToGame) withObject:nil afterDelay:0.8];
            } else {
                self.status.text = err ?: @"falhou";
                self.start.enabled = YES;
            }
        });
    });
}

- (void)backToGame {
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [ws performSelector:@selector(defaultWorkspace)];
    if (!workspace) return;
    NSString *target = BKFindPID() ? kBundleFF : kBundleMax;
    if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)])
        [workspace performSelector:@selector(openApplicationWithBundleID:) withObject:target];
}

@end

@interface BKDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation BKDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    (void)app; (void)opts;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[BKVC new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"BKDelegate"); }
}
