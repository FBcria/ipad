#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;

static void *gIOKit = NULL;
static BKIOHIDEventSystemClientRef gSendClient = NULL;

static void *pCreate, *pCreateType, *pDispatch, *pCreateDigitizer, *pCreateFinger;
static void *pSetInt, *pSetFloat, *pSetSender, *pAppend, *pActivate;

static void BKAppend(NSString *line)
{
    NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/bk_debug.log"];
    if (!fh) {
        [d writeToFile:@"/var/mobile/bk_debug.log" atomically:YES];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (NSException *e) {
    }
}

static void BKMark(NSString *name)
{
    [name writeToFile:[@"/var/mobile/bk_" stringByAppendingString:name]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BKSend(double x, double y, int phase, NSUInteger idx)
{
    if (!gSendClient || !pDispatch) return;

    BKIOHIDEventRef (*createDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        uint32_t, uint32_t, double, double, double, double, double, uint8_t, uint8_t, uint32_t);
    BKIOHIDEventRef (*createFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        double, double, double, double, double, double, double, double, double, double,
        uint8_t, uint8_t, uint32_t);
    void (*setInt)(BKIOHIDEventRef, int32_t, int64_t, uint32_t);
    void (*setFloat)(BKIOHIDEventRef, int32_t, double);
    void (*setSender)(BKIOHIDEventRef, uint64_t);
    void (*append)(BKIOHIDEventRef, BKIOHIDEventRef);
    void (*dispatch)(BKIOHIDEventSystemClientRef, BKIOHIDEventRef);

    createDigitizer = pCreateDigitizer;
    createFinger = pCreateFinger;
    setInt = pSetInt;
    setFloat = pSetFloat;
    setSender = pSetSender;
    append = pAppend;
    dispatch = pDispatch;

    uint64_t ab = mach_absolute_time();
    uint32_t mask = (phase == 2) ? 0x23u : 0x67u;
    int touch = (phase == 2) ? 0 : 1;

    BKIOHIDEventRef hand = createDigitizer(kCFAllocatorDefault, ab, 3, 0, 1, 0, 0,
                                           0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return;

    setInt(hand, 25, 1, 0xF0000000u);
    setInt(hand, 22, 1, 0xF0000000u);

    BKIOHIDEventRef finger = createFinger(kCFAllocatorDefault, ab,
        (uint32_t)(idx + 1), (uint32_t)(idx + 101), mask, x, y,
        0, 0, 0, 0, 0, 0, 0, 0, (uint8_t)touch, (uint8_t)touch, 0);
    if (finger) {
        setInt(finger, 25, 1, 0xF0000000u);
        setFloat(finger, (11u << 16 | 0u), x);
        setFloat(finger, (11u << 16 | 1u), y);
        setInt(finger, (11u << 16 | 26u), phase, 0xF0000000u);
        setInt(finger, (11u << 16 | 7u), mask, 0xF0000000u);
        append(hand, finger);
        CFRelease(finger);
    }

    setInt(hand, (11u << 16 | 7u), 0x863u, 0xF0000000u);
    setInt(hand, (11u << 16 | 8u), touch, 0xF0000000u);
    setInt(hand, (11u << 16 | 9u), touch, 0xF0000000u);
    setSender(hand, 0xDEFACEDBEEFFECE5ull);
    dispatch(gSendClient, hand);
    CFRelease(hand);

    BKAppend([NSString stringWithFormat:@"D ph=%d x=%.3f y=%.3f", phase, x, y]);
}

static void BKTap(NSUInteger idx, double x, double y)
{
    BKSend(x, y, 1, idx);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BKSend(x, y, 2, idx);
    });
}

static const double kP[10][2] = {
    {0.50, 0.50}, {0.25, 0.30}, {0.75, 0.30}, {0.25, 0.70}, {0.75, 0.70},
    {0.50, 0.20}, {0.50, 0.80}, {0.15, 0.50}, {0.85, 0.50}, {0.50, 0.50}
};

static void BKProbe(void)
{
    BKAppend(@"P ini");
    for (int i = 0; i < 10; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * 150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            BKTap(90 + (NSUInteger)i, kP[i][0], kP[i][1]);
            if (i == 9) BKAppend(@"P fim");
        });
    }
}

%ctor {
    @autoreleasepool {
        BKMark(@"engine_ctor.txt");
        BKAppend(@"I init");

        gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!gIOKit) {
            BKAppend(@"I dlopen=0");
            return;
        }

        pCreate = dlsym(gIOKit, "IOHIDEventSystemClientCreate");
        pCreateType = dlsym(gIOKit, "IOHIDEventSystemClientCreateWithType");
        pDispatch = dlsym(gIOKit, "IOHIDEventSystemClientDispatchEvent");
        pCreateDigitizer = dlsym(gIOKit, "IOHIDEventCreateDigitizerEvent");
        pCreateFinger = dlsym(gIOKit, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        pSetInt = dlsym(gIOKit, "IOHIDEventSetIntegerValueWithOptions");
        pSetFloat = dlsym(gIOKit, "IOHIDEventSetFloatValue");
        pSetSender = dlsym(gIOKit, "IOHIDEventSetSenderID");
        pAppend = dlsym(gIOKit, "IOHIDEventAppendEvent");
        pActivate = dlsym(gIOKit, "IOHIDEventSystemClientActivate");

        BKIOHIDEventSystemClientRef (*createType)(CFAllocatorRef, int, void *);
        BKIOHIDEventSystemClientRef (*create)(CFAllocatorRef);
        createType = pCreateType;
        create = pCreate;

        gSendClient = createType ? createType(kCFAllocatorDefault, 1, NULL) : NULL;
        if (!gSendClient && create) gSendClient = create(kCFAllocatorDefault);
        if (!gSendClient) {
            BKAppend(@"I client=0");
            return;
        }
        if (pActivate) ((void (*)(BKIOHIDEventSystemClientRef))pActivate)(gSendClient);

        int t1 = 0, t2 = 0;
        notify_register_dispatch("com.wjf.ballkey.probe", &t1, dispatch_get_main_queue(), ^(int n) {
            (void)n;
            BKProbe();
        });
        notify_register_dispatch("com.wjf.ballkey.test", &t2, dispatch_get_main_queue(), ^(int n) {
            (void)n;
            BKTap(49, 0.5, 0.5);
        });

        BKAppend(@"I ready");
        BKMark(@"engine_loaded.txt");
    }
}
