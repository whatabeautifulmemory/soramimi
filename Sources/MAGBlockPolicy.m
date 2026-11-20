//
//  MAGBlockPolicy.m
//  Soramimi
//

#import "MAGBlockPolicy.h"

#import <math.h>

const NSTimeInterval MAGBlockCorrelationWindowSeconds = 15.0;

@implementation MAGBlockDecision

+ (instancetype)blockDecisionWithReason:(NSString *)reason automatic:(BOOL)automatic {
    MAGBlockDecision *decision = [[MAGBlockDecision alloc] init];
    decision->_block = YES;
    decision->_automatic = automatic;
    decision->_reason = [reason copy];
    return decision;
}

+ (instancetype)allowDecisionWithReason:(NSString *)reason {
    MAGBlockDecision *decision = [[MAGBlockDecision alloc] init];
    decision->_block = NO;
    decision->_automatic = NO;
    decision->_reason = [reason copy];
    return decision;
}

@end

@implementation MAGBlockPolicy

+ (MAGBlockDecision *)decisionForPolicy:(MAGBlockPolicyMode)policy
                  secondsSinceLastTrigger:(NSTimeInterval)secondsSinceTrigger
                           triggerCause:(MAGLaunchTriggerCause)cause {
    BOOL triggered = isfinite(secondsSinceTrigger) && secondsSinceTrigger >= 0.0 &&
                     secondsSinceTrigger <= MAGBlockCorrelationWindowSeconds;

    if (triggered) {
        NSString *causeText = [self descriptionForTriggerCause:cause];
        NSString *reason = [NSString stringWithFormat:@"automatic launch %.0f s after %@",
                                                      secondsSinceTrigger, causeText];
        return [MAGBlockDecision blockDecisionWithReason:reason automatic:YES];
    }

    if (policy == MAGBlockPolicyModeAlways) {
        return [MAGBlockDecision blockDecisionWithReason:@"Always Block policy" automatic:NO];
    }

    return [MAGBlockDecision allowDecisionWithReason:
                               @"Smart Block: no system launch trigger observed (allowed as a manual launch)"];
}

+ (NSString *)descriptionForTriggerCause:(MAGLaunchTriggerCause)cause {
    switch (cause) {
        case MAGLaunchTriggerCauseAudioDeviceChange:
            return @"an audio output device change (Bluetooth connect/reconnect)";
        case MAGLaunchTriggerCauseSystemWake:
            return @"system wake";
        case MAGLaunchTriggerCauseNone:
        default:
            return @"an unknown system event";
    }
}

@end
