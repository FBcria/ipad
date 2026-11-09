#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>

#define kBKConfigPath @"/var/mobile/Library/Preferences/com.wjf.ballkey.plist"

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

%ctor {
    @autoreleasepool {
        BKMark(@"engine_ctor.txt");
        BKAppend(@"I init");

        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        BKAppend(h ? @"I dlopen=1" : @"I dlopen=0");

        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
        BKAppend([NSString stringWithFormat:@"I cfg=%@", cfg ? @"1" : @"0"]);

        int t = 0;
        notify_register_dispatch("com.wjf.ballkey.reload", &t, dispatch_get_main_queue(), ^(int n) {
            (void)n;
            BKAppend(@"I reload");
        });

        BKAppend(@"I ready");
        BKMark(@"engine_loaded.txt");
    }
}
