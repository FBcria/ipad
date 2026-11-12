#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, BKCurve)   { BKCurveLinear = 0, BKCurveSoft, BKCurveFast };
typedef NS_ENUM(NSInteger, BKRecenter){ BKRecenterManual = 0, BKRecenterAuto, BKRecenterOnRelease };
typedef NS_ENUM(NSInteger, BKFireMode){ BKFireModeSingle = 0, BKFireModeRepeat, BKFireModeMultiply };
typedef NS_ENUM(NSInteger, BKTapMode) { BKTapModeFixed = 0, BKTapModeHold, BKTapModeToggle };
typedef NS_ENUM(NSInteger, BKJoyCenter){ BKJoyCenterAverage = 0, BKJoyCenterFixed, BKJoyCenterRandom };

extern NSString *const kCursor, *const kSens, *const kCurve, *const kSmooth, *const kYRatio;
extern NSString *const kFovCircle, *const kLockRadius, *const kRecenter, *const kHideCursor;
extern NSString *const kCursorSize, *const kMarkSize, *const kMarkOpacity, *const kMarkLabels;
extern NSString *const kSnapGrid, *const kShowMarks, *const kFireMode, *const kTapMode;
extern NSString *const kRepeatCount, *const kHoldAim, *const kNormDiag, *const kJoySpeed;
extern NSString *const kJoyCenter, *const kRepeatDelay, *const kMenuOpacity, *const kUiScale;
extern NSString *const kAutoProfile;

@interface BKCore : NSObject
+ (instancetype)shared;

- (void)load;
- (void)save;
- (void)resetDefaults;

- (BOOL)boolForKey:(NSString *)k def:(BOOL)d;
- (void)setBool:(BOOL)v forKey:(NSString *)k;
- (double)doubleForKey:(NSString *)k def:(double)d;
- (void)setDouble:(double)v forKey:(NSString *)k;
- (NSInteger)intForKey:(NSString *)k def:(NSInteger)d;
- (void)setInt:(NSInteger)v forKey:(NSString *)k;

- (NSMutableArray *)marks;
- (void)setMarks:(NSArray *)a;

- (NSArray<NSString *> *)profileNames;
- (void)saveProfile:(NSString *)name;
- (void)loadProfile:(NSString *)name;
- (void)deleteProfile:(NSString *)name;

@property (nonatomic, copy) void (^onChange)(NSString *key);
@end
