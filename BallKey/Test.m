#import <Foundation/Foundation.h>

__attribute__((constructor)) static void T(void) {
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"test.log"];
    FILE *f = fopen(p.UTF8String, "a");
    if (f) { fputs("carregou\n", f); fclose(f); }
}
