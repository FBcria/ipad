#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>

static int gSeen = 0;

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

static int (*pGetType)(void *);

static void BKCB(void *t, void *r, void *q, void *ev)
{
    (void)t; (void)r; (void)q;
    if (!ev) return;
    @try {
        if (gSeen < 60) {
            gSeen++;
            int ty = pGetType ? pGetType(ev) : -1;
            BKAppend([NSString stringWithFormat:@"E t=%d", ty]);
        }
    } @catch (NSException *e) {
    }
}

static void BKStep2(void)
{
    BKAppend(@"S2 ini");

    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) {
        BKAppend(@"S2 dlopen=0");
        return;
    }

    void *pCreateType = dlsym(h, "IOHIDEventSystemClientCreateWithType");
    void *pCreate = dlsym(h, "IOHIDEventSystemClientCreate");
    void *pSetQueue = dlsym(h, "IOHIDEventSystemClientSetDispatchQueue");
    void *pRegister = dlsym(h, "IOHIDEventSystemClientRegisterEventCallback");
    void *pActivate = dlsym(h, "IOHIDEventSystemClientActivate");
    void *pGetTypeRaw = dlsym(h, "IOHIDEventGetType");
    pGetType = pGetTypeRaw;

    BKAppend([NSString stringWithFormat:@"S2 sym ct=%d c=%d q=%d r=%d a=%d g=%d",
              pCreateType ? 1 : 0, pCreate ? 1 : 0, pSetQueue ? 1 : 0,
              pRegister ? 1 : 0, pActivate ? 1 : 0, pGetType ? 1 : 0]);

    typedef struct __IOHIDEventSystemClient *Cl;
    Cl (*createType)(CFAllocatorRef, int, void *);
    Cl (*create)(CFAllocatorRef);
    void (*setQueue)(Cl, dispatch_queue_t);
    void (*registerCB)(Cl, void *, void *, void *);
    void (*activate)(Cl);

    createType = pCreateType;
    create = pCreate;
    setQueue = pSetQueue;
    registerCB = pRegister;
    activate = pActivate;

    Cl c = createType ? createType(kCFAllocatorDefault, 1, NULL) : NULL;
    BKAppend([NSString stringWithFormat:@"S2 createType=%d", c ? 1 : 0]);
    if (!c && create) {
        c = create(kCFAllocatorDefault);
        BKAppend([NSString stringWithFormat:@"S2 create=%d", c ? 1 : 0]);
    }
    if (!c) return;

    if (setQueue) {
        setQueue(c, dispatch_get_main_queue());
        BKAppend(@"S2 queue=1");
    }
    if (registerCB) {
        registerCB(c, BKCB, NULL, NULL);
        BKAppend(@"S2 reg=1");
    }
    if (activate) {
        activate(c);
        BKAppend(@"S2 act=1");
    }
    BKAppend(@"S2 ok");
}

%ctor {
    @autoreleasepool {
        BKMark(@"engine_ctor.txt");
        BKAppend(@"I init");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BKStep2();
        });

        BKAppend(@"I ready");
        BKMark(@"engine_loaded.txt");
    }
}
