//
//  MAGReplacementLauncher.h
//  Soramimi
//
//  Optional replacement action after Apple Music / iTunes was blocked.
//  The user can point it at an application bundle or at an http(s) URL.
//  Launching is de-duplicated (an already-running app is activated instead of
//  being launched a second time) and rate-limited to avoid launch storms.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const MAGReplacementErrorDomain;

typedef NS_ENUM(NSInteger, MAGReplacementErrorCode) {
    MAGReplacementErrorInvalidApplication = 1,
    MAGReplacementErrorInvalidURL = 2,
    MAGReplacementErrorBlockedTarget = 3,
};

@interface MAGReplacementLauncher : NSObject

@property (nonatomic) BOOL enabled;
@property (nonatomic, readonly, copy, nullable) NSString *applicationPath;
@property (nonatomic, readonly, copy, nullable) NSString *URLString;
@property (nonatomic, readonly, copy, nullable) NSString *lastErrorText;
@property (nonatomic, readonly) BOOL hasTarget;

- (BOOL)setApplicationPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setURLString:(NSString *)URLString error:(NSError *_Nullable *_Nullable)error;
- (void)clearTarget;
- (NSString *)displayName;

/// Launches (or activates) the configured target, subject to the launch cooldown.
- (void)launchIfNeeded;

@end

NS_ASSUME_NONNULL_END
