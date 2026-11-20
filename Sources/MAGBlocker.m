//
//  MAGBlocker.m
//  Soramimi
//

#import "MAGBlocker.h"

#import <AppKit/AppKit.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>

NSString *const MAGBlockedMusicBundleIdentifier = @"com.apple.Music";
NSString *const MAGBlockedITunesBundleIdentifier = @"com.apple.iTunes";

/// Storm protection: if macOS re-launches a blocked app over and over, stop
/// fighting for a while and report the situation instead of spinning.
static const NSUInteger MAGBlockStormThreshold = 5;
static const NSTimeInterval MAGBlockStormWindow = 10.0;
static const NSTimeInterval MAGBlockStormCooldown = 30.0;
/// How long to wait before retrying forceTerminate / checking it worked.
static const NSTimeInterval MAGBlockVerifyDelay = 1.0;
static const NSTimeInterval MAGBlockRetryDelay = 0.4;
static const NSTimeInterval MAGBlockReplacementDelay = 0.20;
static NSInteger const MAGBlockMaximumHandledPIDs = 64;

@interface MAGBlocker ()
@property (nonatomic, readwrite) BOOL musicBlockingEnabled;
@property (nonatomic, readwrite) BOOL iTunesBlockingEnabled;
@property (nonatomic, readwrite) MAGBlockPolicyMode policy;
@property (nonatomic, readwrite) BOOL iTunesInstalled;
@property (nonatomic, readwrite) NSUInteger totalBlocks;
@property (nonatomic, copy, readwrite, nullable) NSString *lastBlockText;
@property (nonatomic, copy, readwrite, nullable) NSString *lastErrorText;
@property (nonatomic, strong, readwrite) MAGReplacementLauncher *replacement;
@property (nonatomic, strong) NSMutableArray<id> *observerTokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSDate *> *> *recentBlockDates;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *handledPIDs;
@property (nonatomic, strong, nullable) NSDate *lastTriggerDate;
@property (nonatomic) MAGLaunchTriggerCause lastTriggerCause;
@property (nonatomic, strong, nullable) NSDate *cooldownUntil;
@property (nonatomic, strong, nullable) NSDateFormatter *timeFormatter;
#ifdef MAG_TESTING
/// Verification-build only: an additional bundle identifier to treat as blocked so
/// the launch interception can be verified end-to-end without launching Apple Music.
@property (nonatomic, copy, nullable) NSString *testExtraBlockedBundleIdentifier;
#endif
@end

@implementation MAGBlocker

- (instancetype)init {
    self = [super init];
    if (self) {
        _policy = MAGBlockPolicyModeAlways;
        _replacement = [[MAGReplacementLauncher alloc] init];
        _observerTokens = [NSMutableArray array];
        _recentBlockDates = [NSMutableDictionary dictionary];
        _handledPIDs = [NSMutableSet set];
        _lastTriggerCause = MAGLaunchTriggerCauseNone;
        _timeFormatter = [[NSDateFormatter alloc] init];
        _timeFormatter.dateFormat = @"HH:mm:ss";
#ifdef MAG_TESTING
        NSString *testTarget = [[[NSProcessInfo processInfo] environment] objectForKey:@"MAG_TEST_EXTRA_BLOCKED_BUNDLE"];
        if (testTarget.length > 0) {
            _testExtraBlockedBundleIdentifier = [testTarget copy];
            fprintf(stderr, "MAG_TEST_EXTRA_BLOCKED_BUNDLE=%s\n", testTarget.UTF8String);
        }
#endif
        [self installObservers];
        [self refresh];
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

#pragma mark - State

- (void)setMusicBlockingEnabled:(BOOL)enabled {
    _musicBlockingEnabled = enabled;
    if (!enabled) {
        self.lastErrorText = nil;
    }
    [self notifyChanged];
}

- (void)setITunesBlockingEnabled:(BOOL)enabled {
    if (enabled && !self.iTunesInstalled) {
        return;
    }
    _iTunesBlockingEnabled = enabled;
    [self notifyChanged];
}

- (void)setPolicy:(MAGBlockPolicyMode)policy {
    _policy = policy;
    [self notifyChanged];
}

- (NSString *)statusText {
    if (self.cooldownUntil != nil) {
        NSTimeInterval remaining = [self.cooldownUntil timeIntervalSinceNow];
        if (remaining > 0) {
            return [NSString stringWithFormat:@"Paused (repeated relaunch detected, %.0f s)", ceil(remaining)];
        }
        self.cooldownUntil = nil;
    }
    if (self.musicBlockingEnabled || self.iTunesBlockingEnabled) {
        NSString *mode = self.policy == MAGBlockPolicyModeAlways ? @"Always Block" : @"Smart Block";
        return [NSString stringWithFormat:@"Active (%@)", mode];
    }
    return @"Inactive";
}

- (void)refresh {
    BOOL installed = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:MAGBlockedITunesBundleIdentifier] != nil;
    if (installed != self.iTunesInstalled) {
        self.iTunesInstalled = installed;
        if (!installed) {
            self.iTunesBlockingEnabled = NO;
        }
        [self notifyChanged];
    }
    if (self.cooldownUntil != nil && [self.cooldownUntil timeIntervalSinceNow] <= 0) {
        self.cooldownUntil = nil;
        self.lastErrorText = nil;
        [self notifyChanged];
    }
}

- (void)noteAutomaticTrigger:(MAGLaunchTriggerCause)cause {
    self.lastTriggerDate = [NSDate date];
    self.lastTriggerCause = cause;
}

#pragma mark - Launch observation

- (void)installObservers {
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    __weak typeof(self) weakSelf = self;
    id willLaunch = [center addObserverForName:NSWorkspaceWillLaunchApplicationNotification
                                        object:nil
                                         queue:[NSOperationQueue mainQueue]
                                    usingBlock:^(NSNotification *note) {
                                        __strong typeof(weakSelf) self = weakSelf;
                                        if (self == nil) {
                                            return;
                                        }
                                        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
                                        if (![app isKindOfClass:[NSRunningApplication class]]) {
                                            return;
                                        }
                                        [self evaluateLaunch:app phase:@"willLaunch"];
                                    }];
    id didLaunch = [center addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                                       object:nil
                                        queue:[NSOperationQueue mainQueue]
                                   usingBlock:^(NSNotification *note) {
                                       __strong typeof(weakSelf) self = weakSelf;
                                       if (self == nil) {
                                           return;
                                       }
                                       NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
                                       if (![app isKindOfClass:[NSRunningApplication class]]) {
                                           return;
                                       }
                                       [self evaluateLaunch:app phase:@"didLaunch"];
                                   }];
    [self.observerTokens addObject:willLaunch];
    [self.observerTokens addObject:didLaunch];
}

- (BOOL)isTargetBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) {
        return NO;
    }
    if (self.musicBlockingEnabled && [bundleIdentifier isEqualToString:MAGBlockedMusicBundleIdentifier]) {
        return YES;
    }
    if (self.iTunesBlockingEnabled && [bundleIdentifier isEqualToString:MAGBlockedITunesBundleIdentifier]) {
        return YES;
    }
#ifdef MAG_TESTING
    if (self.testExtraBlockedBundleIdentifier.length > 0 &&
        [bundleIdentifier isEqualToString:self.testExtraBlockedBundleIdentifier]) {
        return YES;
    }
#endif
    return NO;
}

- (NSTimeInterval)secondsSinceLastTrigger {
    if (self.lastTriggerDate == nil) {
        return INFINITY;
    }
    return [self.lastTriggerDate timeIntervalSinceNow] * -1.0;
}

- (void)evaluateLaunch:(NSRunningApplication *)app phase:(NSString *)phase {
    NSString *bundleIdentifier = app.bundleIdentifier;
    if (![self isTargetBundleIdentifier:bundleIdentifier] || app.terminated) {
        return;
    }
    NSNumber *pidNumber = @(app.processIdentifier);
    if ([self.handledPIDs containsObject:pidNumber]) {
        return;
    }
    self.handledPIDs = [self.handledPIDs mutableCopy];
    [self.handledPIDs addObject:pidNumber];
    if (self.handledPIDs.count > (NSUInteger)MAGBlockMaximumHandledPIDs) {
        // Keep memory bounded; the newest PIDs are what matter for burst protection.
        NSMutableArray<NSNumber *> *kept = [[self.handledPIDs allObjects] mutableCopy];
        [kept sortUsingSelector:@selector(compare:)];
        [kept removeObjectsInRange:NSMakeRange(0, kept.count - (NSUInteger)MAGBlockMaximumHandledPIDs)];
        self.handledPIDs = [NSMutableSet setWithArray:kept];
    }

    MAGBlockDecision *decision = [MAGBlockPolicy decisionForPolicy:self.policy
                                           secondsSinceLastTrigger:[self secondsSinceLastTrigger]
                                                    triggerCause:self.lastTriggerCause];
    if (!decision.block) {
        (void)phase;
        return;
    }

    if (self.cooldownUntil != nil && [self.cooldownUntil timeIntervalSinceNow] > 0) {
        self.lastErrorText = @"Blocking paused after repeated relaunches of the blocked app.";
        [self notifyChanged];
        return;
    }

    [self blockApplication:app bundleIdentifier:bundleIdentifier reason:decision.reason automatic:decision.isAutomatic];
}

- (void)blockApplication:(NSRunningApplication *)app
        bundleIdentifier:(NSString *)bundleIdentifier
                  reason:(NSString *)reason
               automatic:(BOOL)automatic {
    self.totalBlocks += 1;
    NSDate *now = [NSDate date];
    NSString *displayName = [self displayNameForBundleIdentifier:bundleIdentifier];
    self.lastBlockText = [NSString stringWithFormat:@"%@ %@ — %@", [self.timeFormatter stringFromDate:now],
                                                    displayName, reason];
    self.lastErrorText = nil;

    [self recordBlockForBundleIdentifier:bundleIdentifier atDate:now];
#ifdef MAG_TESTING
    if (getenv("MAG_TEST_VERBOSE") != NULL) {
        fprintf(stderr, "MAG_BLOCKED %s pid=%d reason=%s automatic=%d\n", bundleIdentifier.UTF8String,
                app.processIdentifier, reason.UTF8String, automatic ? 1 : 0);
        fflush(stderr);
    }
#endif

    BOOL terminated = [app forceTerminate];
    __weak typeof(self) weakSelf = self;
    if (!terminated) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAGBlockRetryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           __strong typeof(weakSelf) self = weakSelf;
                           if (self == nil || app.terminated) {
                               return;
                           }
                           if (![app forceTerminate]) {
                               self.lastErrorText =
                                   [NSString stringWithFormat:@"Could not block %@ (terminate failed)", displayName];
                               [self notifyChanged];
                           }
                       });
    }

    // Verify shortly after: macOS normally allows the termination well before the
    // target's first runloop turn, but fall back to a second attempt if not.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAGBlockVerifyDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self == nil || app.terminated) {
                           return;
                       }
                       if (![app forceTerminate]) {
                           self.lastErrorText = [NSString stringWithFormat:@"%@ is still running after blocking attempt",
                                                                           displayName];
                           [self notifyChanged];
                       }
                   });

    if (automatic || self.policy == MAGBlockPolicyModeAlways) {
        [self scheduleReplacementAfterBlock];
    }
    [self notifyChanged];
}

- (void)scheduleReplacementAfterBlock {
    if (!self.replacement.enabled || !self.replacement.hasTarget) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAGBlockReplacementDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self == nil || self.cooldownUntil != nil) {
                           return;
                       }
                       [self.replacement launchIfNeeded];
                       if (self.replacement.lastErrorText.length > 0) {
                           self.lastErrorText = self.replacement.lastErrorText;
                           [self notifyChanged];
                       }
                   });
}

- (void)recordBlockForBundleIdentifier:(NSString *)bundleIdentifier atDate:(NSDate *)date {
    NSMutableArray<NSDate *> *dates = self.recentBlockDates[bundleIdentifier];
    if (dates == nil) {
        dates = [NSMutableArray array];
        self.recentBlockDates[bundleIdentifier] = dates;
    }
    [dates addObject:date];
    NSTimeInterval cutoff = [date timeIntervalSince1970] - MAGBlockStormWindow;
    NSUInteger removeCount = 0;
    for (NSDate *existing in dates) {
        if (existing.timeIntervalSince1970 < cutoff) {
            removeCount += 1;
        } else {
            break;
        }
    }
    if (removeCount > 0) {
        [dates removeObjectsInRange:NSMakeRange(0, removeCount)];
    }
    if (dates.count >= MAGBlockStormThreshold) {
        self.cooldownUntil = [date dateByAddingTimeInterval:MAGBlockStormCooldown];
        self.lastErrorText = [NSString stringWithFormat:@"%@ keeps relaunching; blocking paused for %.0f s.",
                                                        [self displayNameForBundleIdentifier:bundleIdentifier],
                                                        MAGBlockStormCooldown];
    }
}

- (NSString *)displayNameForBundleIdentifier:(NSString *)bundleIdentifier {
    if ([bundleIdentifier isEqualToString:MAGBlockedMusicBundleIdentifier]) {
        return @"Apple Music";
    }
    if ([bundleIdentifier isEqualToString:MAGBlockedITunesBundleIdentifier]) {
        return @"iTunes";
    }
    return bundleIdentifier;
}

#pragma mark - Teardown

- (void)shutdown {
    if (self.observerTokens.count == 0) {
        return;
    }
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    for (id token in self.observerTokens) {
        [center removeObserver:token];
    }
    [self.observerTokens removeAllObjects];
}

- (void)notifyChanged {
    [self.delegate blockerDidChangeState:self];
}

@end
