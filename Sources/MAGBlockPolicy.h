//
//  MAGBlockPolicy.h
//  Soramimi
//
//  Pure decision logic for Apple Music / iTunes launch blocking.
//
//  macOS offers no public API that can veto another application's launch, and
//  media-key Play events can only be pre-empted with a CGEventTap, which would
//  require the user to grant Accessibility permission (explicitly out of scope in
//  the SRS). The strongest public signal is
//  NSWorkspaceWillLaunchApplicationNotification, which is delivered before the
//  launched application finishes launching (verified on macOS 27: the target
//  process is killed ~11 ms after launch and never reaches its first runloop).
//
//  Because the notification does not say *why* the application is launching, the
//  blocker correlates each launch with system events it can observe without any
//  permission: default-output-device changes (Bluetooth connects/disconnects) and
//  system wake. That correlation is what "Smart Block" uses.
//

#import <Foundation/Foundation.h>

#import "MAGPreferences.h"

NS_ASSUME_NONNULL_BEGIN

/// How long after an observed system event a launch is still considered automatic.
extern const NSTimeInterval MAGBlockCorrelationWindowSeconds; // 15 s

typedef NS_ENUM(NSInteger, MAGLaunchTriggerCause) {
    MAGLaunchTriggerCauseNone = 0,
    MAGLaunchTriggerCauseAudioDeviceChange = 1,
    MAGLaunchTriggerCauseSystemWake = 2,
};

@interface MAGBlockDecision : NSObject

@property (nonatomic, readonly) BOOL block;
@property (nonatomic, readonly, getter=isAutomatic) BOOL automatic;
@property (nonatomic, readonly, copy) NSString *reason;

+ (instancetype)blockDecisionWithReason:(NSString *)reason automatic:(BOOL)automatic;
+ (instancetype)allowDecisionWithReason:(NSString *)reason;

@end

@interface MAGBlockPolicy : NSObject

/// @param policy             Always or Smart.
/// @param secondsSinceTrigger Seconds since the last observed system event, or INFINITY if none.
/// @param cause              The kind of the last observed system event.
+ (MAGBlockDecision *)decisionForPolicy:(MAGBlockPolicyMode)policy
                  secondsSinceLastTrigger:(NSTimeInterval)secondsSinceTrigger
                           triggerCause:(MAGLaunchTriggerCause)cause;

+ (NSString *)descriptionForTriggerCause:(MAGLaunchTriggerCause)cause;

@end

NS_ASSUME_NONNULL_END
