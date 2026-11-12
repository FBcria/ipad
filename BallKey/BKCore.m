#import "BKCore.h"

NSString *const kCursor=@"cursor", *const kSens=@"sens", *const kCurve=@"curve",
 *const kSmooth=@"smooth", *const kYRatio=@"yRatio", *const kFovCircle=@"fovCircle",
 *const kLockRadius=@"lockRadius", *const kRecenter=@"recenter", *const kHideCursor=@"hideCursor",
 *const kCursorSize=@"cursorSize", *const kMarkSize=@"markSize", *const kMarkOpacity=@"markOpacity",
 *const kMarkLabels=@"markLabels", *const kSnapGrid=@"snapGrid", *const kShowMarks=@"showMarks",
 *const kFireMode=@"fireMode", *const kTapMode=@"tapMode", *const kRepeatCount=@"repeatCount",
 *const kHoldAim=@"holdAim", *const kNormDiag=@"normDiag", *const kJoySpeed=@"joySpeed",
 *const kJoyCenter=@"joyCenter", *const kRepeatDelay=@"repeatDelay", *const kMenuOpacity=@"menuOpacity",
 *const kUiScale=@"uiScale", *const kAutoProfile=@"autoProfile";

static NSDictionary *BKDefaults(void)
{
    return @{kCursor:@NO, kSens:@1.7, kCurve:@(BKCurveSoft), kSmooth:@35, kYRatio:@100,
             kFovCircle:@YES, kLockRadius:@70, kRecenter:@(BKRecenterOnRelease), kHideCursor:@YES,
             kCursorSize:@48, kMarkSize:@76, kMarkOpacity:@30, kMarkLabels:@YES, kSnapGrid:@NO,
             kShowMarks:@NO, kFireMode:@(BKFireModeSingle), kTapMode:@(BKTapModeHold),
             kRepeatCount:@4, kHoldAim:@YES, kNormDiag:@YES, kJoySpeed:@7,
             kJoyCenter:@(BKJoyCenterAverage), kRepeatDelay:@60, kMenuOpacity:@96,
             kUiScale:@100, kAutoProfile:@YES};
}

static NSDictionary *BKDefaultMarks(void)
{
    return @{@"marks": @[
        @{@"t":@"Dir",@"x":@0.15,@"y":@0.58,@"c":@26}, @{@"t":@"Dir",@"x":@0.06,@"y":@0.72,@"c":@4},
        @{@"t":@"Dir",@"x":@0.15,@"y":@0.86,@"c":@22}, @{@"t":@"Dir",@"x":@0.24,@"y":@0.72,@"c":@7},
        @{@"t":@"Fire",@"x":@0.87,@"y":@0.80,@"c":@1}, @{@"t":@"Ads",@"x":@0.87,@"y":@0.62,@"c":@2},
        @{@"t":@"Fps",@"x":@0.60,@"y":@0.50,@"c":@225}, @{@"t":@"Press",@"x":@0.74,@"y":@0.88,@"c":@21},
        @{@"t":@"Tap",@"x":@0.78,@"y":@0.74,@"c":@44}]};
}

@implementation BKCore
{
    NSMutableDictionary *_s;
    NSMutableArray *_marks;
    NSString *_base, *_cfg;
}

+ (instancetype)shared
{
    static BKCore *g; static dispatch_once_t o;
    dispatch_once(&o, ^{ g = [BKCore new]; });
    return g;
}

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    _base = [[d firstObject] stringByAppendingPathComponent:@"BallKey"];
    [NSFileManager.defaultManager createDirectoryAtPath:_base withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    _cfg = [_base stringByAppendingPathComponent:@"settings.plist"];
    _s = [NSMutableDictionary dictionary];
    _marks = [NSMutableArray array];
    [self load];
    return self;
}

- (void)load
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:_cfg];
    [_s removeAllObjects];
    [_s addEntriesFromDictionary:BKDefaults()];
    if ([d[@"settings"] isKindOfClass:[NSDictionary class]]) [_s addEntriesFromDictionary:d[@"settings"]];
    [_marks removeAllObjects];
    NSArray *a = d[@"marks"];
    if ([a isKindOfClass:[NSArray class]])
        for (NSDictionary *m in a)
            if ([m isKindOfClass:[NSDictionary class]])
                [_marks addObject:[NSMutableDictionary dictionaryWithDictionary:m]];
    if (!_marks.count)
        for (NSDictionary *m in BKDefaultMarks()[@"marks"])
            [_marks addObject:[NSMutableDictionary dictionaryWithDictionary:m]];
}

- (void)save
{
    [_s writeToFile:_cfg atomically:YES];
    [@{@"marks":_marks} writeToFile:_cfg atomically:YES];
    // settings + marks in one file
    NSDictionary *all = @{@"settings":_s, @"marks":_marks};
    [all writeToFile:_cfg atomically:YES];
}

- (void)resetDefaults
{
    [_s removeAllObjects];
    [_s addEntriesFromDictionary:BKDefaults()];
    [_marks removeAllObjects];
    for (NSDictionary *m in BKDefaultMarks()[@"marks"])
        [_marks addObject:[NSMutableDictionary dictionaryWithDictionary:m]];
    [self save];
}

- (BOOL)boolForKey:(NSString *)k def:(BOOL)d
{ id v = _s[k]; return v ? [v boolValue] : d; }
- (void)setBool:(BOOL)v forKey:(NSString *)k
{ _s[k] = @(v); [self save]; if (self.onChange) self.onChange(k); }

- (double)doubleForKey:(NSString *)k def:(double)d
{ id v = _s[k]; return v ? [v doubleValue] : d; }
- (void)setDouble:(double)v forKey:(NSString *)k
{ _s[k] = @(v); [self save]; if (self.onChange) self.onChange(k); }

- (NSInteger)intForKey:(NSString *)k def:(NSInteger)d
{ id v = _s[k]; return v ? [v integerValue] : d; }
- (void)setInt:(NSInteger)v forKey:(NSString *)k
{ _s[k] = @(v); [self save]; if (self.onChange) self.onChange(k); }

- (NSMutableArray *)marks { return _marks; }
- (void)setMarks:(NSArray *)a
{ [_marks removeAllObjects]; [_marks addObjectsFromArray:a]; [self save]; }

- (NSString *)profilesPath { return [_base stringByAppendingPathComponent:@"profiles"]; }

- (NSArray<NSString *> *)profileNames
{
    NSArray *a = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[self profilesPath] error:nil];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in a)
        if ([f.pathExtension isEqualToString:@"plist"]) [out addObject:f.stringByDeletingPathExtension];
    return [out sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)saveProfile:(NSString *)name
{
    if (!name.length) return;
    NSString *dir = [self profilesPath];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"settings":_s, @"marks":_marks} writeToFile:
        [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]] atomically:YES];
}

- (void)loadProfile:(NSString *)name
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        [[self profilesPath] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]]];
    if (!d) return;
    [_s removeAllObjects];
    [_s addEntriesFromDictionary:BKDefaults()];
    if ([d[@"settings"] isKindOfClass:[NSDictionary class]]) [_s addEntriesFromDictionary:d[@"settings"]];
    [_marks removeAllObjects];
    for (NSDictionary *m in d[@"marks"])
        [_marks addObject:[NSMutableDictionary dictionaryWithDictionary:m]];
    [self save];
    if (self.onChange) self.onChange(@"*");
}

- (void)deleteProfile:(NSString *)name
{
    [NSFileManager.defaultManager removeItemAtPath:
        [[self profilesPath] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]] error:nil];
}
@end
