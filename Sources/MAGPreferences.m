//
//  MAGPreferences.m
//  Soramimi
//

#import "MAGPreferences.h"

NSString *const MAGPreferencesDidChangeNotification = @"MAGPreferencesDidChangeNotification";

const double MAGPreferencesMinimumLevelDB = -120.0;
const double MAGPreferencesMaximumLevelDB = -40.0;
const double MAGPreferencesDefaultLevelDB = -100.0;

static NSString *const kKeyKeepAliveEnabled = @"KeepAliveEnabled";
static NSString *const kKeyKeepAliveLevelDB = @"KeepAliveLevelDB";
static NSString *const kKeyWakePingEnabled = @"WakePingEnabled";
static NSString *const kKeyWakePingIntervalSeconds = @"WakePingIntervalSeconds";
static NSString *const kKeyWakePingLevelDB = @"WakePingLevelDB";
static NSString *const kKeyMusicBlockerEnabled = @"MusicBlockerEnabled";
static NSString *const kKeyITunesBlockerEnabled = @"ITunesBlockerEnabled";
static NSString *const kKeyBlockingPolicy = @"BlockingPolicy";
static NSString *const kKeyReplacementEnabled = @"ReplacementEnabled";
static NSString *const kKeyReplacementKind = @"ReplacementKind";
static NSString *const kKeyReplacementValue = @"ReplacementValue";
static NSString *const kDefaultPreferencesDomain = @"local.soramimi";

@interface MAGPreferences ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@end

@implementation MAGPreferences

+ (instancetype)sharedPreferences {
    static MAGPreferences *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[MAGPreferences alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [NSUserDefaults standardUserDefaults];
        // Registering defaults means "first launch" behaves exactly like the SRS:
        // everything OFF and the signal level at -100 dBFS.
        [_defaults registerDefaults:@{
            kKeyKeepAliveEnabled : @NO,
            kKeyKeepAliveLevelDB : @(MAGPreferencesDefaultLevelDB),
            kKeyWakePingEnabled : @YES,
            kKeyWakePingIntervalSeconds : @300.0,
            kKeyWakePingLevelDB : @(-18.0),
            kKeyMusicBlockerEnabled : @NO,
            kKeyITunesBlockerEnabled : @NO,
            kKeyBlockingPolicy : @(MAGBlockPolicyModeAlways),
            kKeyReplacementEnabled : @NO,
        }];
    }
    return self;
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:MAGPreferencesDidChangeNotification
                                                        object:self];
}

#pragma mark - Keep-alive

- (BOOL)keepAliveEnabled {
    return [self.defaults boolForKey:kKeyKeepAliveEnabled];
}

- (void)setKeepAliveEnabled:(BOOL)keepAliveEnabled {
    [self.defaults setBool:keepAliveEnabled forKey:kKeyKeepAliveEnabled];
    [self notifyChanged];
}

- (double)keepAliveLevelDB {
    double level = [self.defaults doubleForKey:kKeyKeepAliveLevelDB];
    if (level > MAGPreferencesMaximumLevelDB || level < MAGPreferencesMinimumLevelDB) {
        level = MAGPreferencesDefaultLevelDB;
    }
    return level;
}

- (void)setKeepAliveLevelDB:(double)keepAliveLevelDB {
    double clamped = MAX(MAGPreferencesMinimumLevelDB, MIN(MAGPreferencesMaximumLevelDB, keepAliveLevelDB));
    [self.defaults setDouble:clamped forKey:kKeyKeepAliveLevelDB];
    [self notifyChanged];
}

#pragma mark - Blocking

- (BOOL)musicBlockerEnabled {
    return [self.defaults boolForKey:kKeyMusicBlockerEnabled];
}

- (void)setMusicBlockerEnabled:(BOOL)musicBlockerEnabled {
    [self.defaults setBool:musicBlockerEnabled forKey:kKeyMusicBlockerEnabled];
    [self notifyChanged];
}

- (BOOL)iTunesBlockerEnabled {
    return [self.defaults boolForKey:kKeyITunesBlockerEnabled];
}

- (void)setITunesBlockerEnabled:(BOOL)iTunesBlockerEnabled {
    [self.defaults setBool:iTunesBlockerEnabled forKey:kKeyITunesBlockerEnabled];
    [self notifyChanged];
}

- (BOOL)wakePingEnabled {
    return [self.defaults boolForKey:kKeyWakePingEnabled];
}

- (void)setWakePingEnabled:(BOOL)wakePingEnabled {
    [self.defaults setBool:wakePingEnabled forKey:kKeyWakePingEnabled];
    [self notifyChanged];
}

- (double)wakePingIntervalSeconds {
    double value = [self.defaults doubleForKey:kKeyWakePingIntervalSeconds];
    if (value < 60.0 || value > 1800.0) {
        value = 300.0;
    }
    return value;
}

- (void)setWakePingIntervalSeconds:(double)wakePingIntervalSeconds {
    double clamped = MAX(60.0, MIN(1800.0, wakePingIntervalSeconds));
    [self.defaults setDouble:clamped forKey:kKeyWakePingIntervalSeconds];
    [self notifyChanged];
}

- (double)wakePingLevelDB {
    double value = [self.defaults doubleForKey:kKeyWakePingLevelDB];
    if (value < -40.0 || value > -6.0) {
        value = -18.0;
    }
    return value;
}

- (void)setWakePingLevelDB:(double)wakePingLevelDB {
    double clamped = MAX(-40.0, MIN(-6.0, wakePingLevelDB));
    [self.defaults setDouble:clamped forKey:kKeyWakePingLevelDB];
    [self notifyChanged];
}

- (MAGBlockPolicyMode)blockingPolicy {
    NSInteger raw = [self.defaults integerForKey:kKeyBlockingPolicy];
    if (raw != MAGBlockPolicyModeAlways && raw != MAGBlockPolicyModeSmart) {
        return MAGBlockPolicyModeAlways;
    }
    return (MAGBlockPolicyMode)raw;
}

- (void)setBlockingPolicy:(MAGBlockPolicyMode)blockingPolicy {
    [self.defaults setInteger:blockingPolicy forKey:kKeyBlockingPolicy];
    [self notifyChanged];
}

#pragma mark - Replacement

- (BOOL)replacementEnabled {
    return [self.defaults boolForKey:kKeyReplacementEnabled];
}

- (void)setReplacementEnabled:(BOOL)replacementEnabled {
    [self.defaults setBool:replacementEnabled forKey:kKeyReplacementEnabled];
    [self notifyChanged];
}

- (NSString *)replacementKind {
    return [self.defaults stringForKey:kKeyReplacementKind];
}

- (void)setReplacementKind:(NSString *)replacementKind {
    if (replacementKind.length > 0) {
        [self.defaults setObject:replacementKind forKey:kKeyReplacementKind];
    } else {
        [self.defaults removeObjectForKey:kKeyReplacementKind];
    }
    [self notifyChanged];
}

- (NSString *)replacementValue {
    return [self.defaults stringForKey:kKeyReplacementValue];
}

- (void)setReplacementValue:(NSString *)replacementValue {
    if (replacementValue.length > 0) {
        [self.defaults setObject:replacementValue forKey:kKeyReplacementValue];
    } else {
        [self.defaults removeObjectForKey:kKeyReplacementValue];
    }
    [self notifyChanged];
}

#pragma mark - Diagnostics

- (NSDictionary<NSString *, id> *)dumpState {
    return @{
        @"keepAliveEnabled" : @(self.keepAliveEnabled),
        @"keepAliveLevelDB" : @(self.keepAliveLevelDB),
        @"wakePingEnabled" : @(self.wakePingEnabled),
        @"wakePingIntervalSeconds" : @(self.wakePingIntervalSeconds),
        @"wakePingLevelDB" : @(self.wakePingLevelDB),
        @"musicBlockerEnabled" : @(self.musicBlockerEnabled),
        @"iTunesBlockerEnabled" : @(self.iTunesBlockerEnabled),
        @"blockingPolicy" : self.blockingPolicy == MAGBlockPolicyModeAlways ? @"always" : @"smart",
        @"replacementEnabled" : @(self.replacementEnabled),
        @"replacementKind" : self.replacementKind ?: [NSNull null],
        @"replacementValue" : self.replacementValue ?: [NSNull null],
    };
}

- (void)resetAll {
    NSString *domain = [[NSBundle mainBundle] bundleIdentifier] ?: kDefaultPreferencesDomain;
    [self.defaults removePersistentDomainForName:domain];
    [self.defaults synchronize];
    [self notifyChanged];
}

@end
