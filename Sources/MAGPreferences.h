//
//  MAGPreferences.h
//  Soramimi
//
//  Typed wrapper around NSUserDefaults. Every user-visible option is stored here
//  so the rest of the app never touches raw default keys.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MAGBlockPolicyMode) {
    MAGBlockPolicyModeAlways = 0, // block every launch of the configured apps
    MAGBlockPolicyModeSmart = 1,  // block only launches that look system-initiated
};

/// Posted on the main thread after any stored preference changes.
extern NSString *const MAGPreferencesDidChangeNotification;

/// Level bounds (dBFS). The documented default is -100 dBFS. The bounds are safety
/// limits only: whether a given level survives the output path depends on the
/// device's PCM format (integer paths quantize tiny signals to zero), which the UI
/// detects and warns about. Levels above the upper bound are not offered because
/// they would no longer be reliably inaudible.
extern const double MAGPreferencesMinimumLevelDB; // -120
extern const double MAGPreferencesMaximumLevelDB; //  -40
extern const double MAGPreferencesDefaultLevelDB; // -100

@interface MAGPreferences : NSObject

+ (instancetype)sharedPreferences;

@property (nonatomic) BOOL keepAliveEnabled;
@property (nonatomic) double keepAliveLevelDB;

/// Periodic "wake ping": a short, near-ultrasonic burst that resets the standby
/// timer of speakers (e.g. Marshall) which ignore a continuous near-silent stream.
@property (nonatomic) BOOL wakePingEnabled;
@property (nonatomic) double wakePingIntervalSeconds;
@property (nonatomic) double wakePingLevelDB;
@property (nonatomic) BOOL musicBlockerEnabled;
@property (nonatomic) BOOL iTunesBlockerEnabled;
@property (nonatomic) MAGBlockPolicyMode blockingPolicy;
@property (nonatomic) BOOL replacementEnabled;
/// Either @"app" or @"url" (or nil when nothing has been chosen yet).
@property (nonatomic, copy, nullable) NSString *replacementKind;
/// Filesystem path of the .app bundle, or an http(s) URL string, matching replacementKind.
@property (nonatomic, copy, nullable) NSString *replacementValue;

/// Human-readable snapshot for --dump-state and diagnostics. Contains only the
/// app's own settings; note that it may include the user-chosen replacement app
/// path or URL.
- (NSDictionary<NSString *, id> *)dumpState;

/// Removes the persistent defaults domain for this app.
- (void)resetAll;

@end

NS_ASSUME_NONNULL_END
