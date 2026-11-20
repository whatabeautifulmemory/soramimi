//
//  MAGBlocker.h
//  Soramimi
//
//  Apple Music / iTunes launch blocker. The public-API design is described in
//  MAGBlockPolicy.h; this class does the observation, termination, loop
//  protection and replacement-app coordination.
//

#import <Foundation/Foundation.h>

#import "MAGBlockPolicy.h"
#import "MAGReplacementLauncher.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const MAGBlockedMusicBundleIdentifier; // com.apple.Music
extern NSString *const MAGBlockedITunesBundleIdentifier; // com.apple.iTunes

@class MAGBlocker;

@protocol MAGBlockerDelegate <NSObject>
- (void)blockerDidChangeState:(MAGBlocker *)blocker;
@end

@interface MAGBlocker : NSObject

@property (nonatomic, weak, nullable) id<MAGBlockerDelegate> delegate;

@property (nonatomic, readonly) BOOL musicBlockingEnabled;
@property (nonatomic, readonly) BOOL iTunesBlockingEnabled;
@property (nonatomic, readonly) MAGBlockPolicyMode policy;
@property (nonatomic, readonly) BOOL iTunesInstalled;
@property (nonatomic, readonly) NSUInteger totalBlocks;

/// Short status line for the menu, e.g. "Active (Always Block)".
@property (nonatomic, readonly, copy) NSString *statusText;
/// Last blocked launch, e.g. "11:02:13 Apple Music — Always Block policy".
@property (nonatomic, readonly, copy, nullable) NSString *lastBlockText;
@property (nonatomic, readonly, copy, nullable) NSString *lastErrorText;

@property (nonatomic, strong, readonly) MAGReplacementLauncher *replacement;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

- (void)setMusicBlockingEnabled:(BOOL)enabled;
- (void)setITunesBlockingEnabled:(BOOL)enabled;
- (void)setPolicy:(MAGBlockPolicyMode)policy;

/// Records a system event that can legitimately trigger an automatic Music launch.
- (void)noteAutomaticTrigger:(MAGLaunchTriggerCause)cause;
- (void)refresh;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
