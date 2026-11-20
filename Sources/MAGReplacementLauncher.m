//
//  MAGReplacementLauncher.m
//  Soramimi
//

#import "MAGReplacementLauncher.h"

#import <AppKit/AppKit.h>

NSString *const MAGReplacementErrorDomain = @"MAGReplacementErrorDomain";

static const NSTimeInterval MAGReplacementLaunchCooldown = 3.0;

@interface MAGReplacementLauncher ()
@property (nonatomic, copy, readwrite, nullable) NSString *applicationPath;
@property (nonatomic, copy, readwrite, nullable) NSString *URLString;
@property (nonatomic, copy, readwrite, nullable) NSString *lastErrorText;
@property (nonatomic, strong, nullable) NSDate *lastLaunchDate;
@end

@implementation MAGReplacementLauncher

- (BOOL)hasTarget {
    return self.applicationPath.length > 0 || self.URLString.length > 0;
}

- (void)clearTarget {
    self.applicationPath = nil;
    self.URLString = nil;
    self.lastErrorText = nil;
}

#pragma mark - Configuration

- (BOOL)setApplicationPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error {
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    NSString *bundleIdentifier = bundle.bundleIdentifier;
    if (bundle == nil || bundleIdentifier.length == 0 || bundle.executableURL == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MAGReplacementErrorDomain
                                         code:MAGReplacementErrorInvalidApplication
                                     userInfo:@{NSLocalizedDescriptionKey : @"The selected item is not a valid "
                                                                                 @"application bundle."}];
        }
        return NO;
    }
    if ([bundleIdentifier isEqualToString:@"com.apple.Music"] ||
        [bundleIdentifier isEqualToString:@"com.apple.iTunes"]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MAGReplacementErrorDomain
                                         code:MAGReplacementErrorBlockedTarget
                                     userInfo:@{NSLocalizedDescriptionKey :
                                                    @"Apple Music or iTunes cannot be used as the replacement "
                                                    @"application."}];
        }
        return NO;
    }
    self.applicationPath = path;
    self.URLString = nil;
    self.lastErrorText = nil;
    return YES;
}

- (BOOL)setURLString:(NSString *)URLString error:(NSError *_Nullable *_Nullable)error {
    NSString *trimmed = [URLString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 2048) {
        trimmed = [trimmed substringToIndex:2048];
    }
    NSURL *url = [NSURL URLWithString:trimmed];
    NSString *scheme = url.scheme.lowercaseString;
    BOOL safeScheme = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    if (url == nil || !safeScheme || url.host.length == 0) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:MAGReplacementErrorDomain
                           code:MAGReplacementErrorInvalidURL
                       userInfo:@{NSLocalizedDescriptionKey :
                                      @"The replacement URL must be a valid http or https web address."}];
        }
        return NO;
    }
    self.URLString = trimmed;
    self.applicationPath = nil;
    self.lastErrorText = nil;
    return YES;
}

- (NSString *)displayName {
    if (self.applicationPath.length > 0) {
        NSBundle *bundle = [NSBundle bundleWithPath:self.applicationPath];
        NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        if (name.length == 0) {
            name = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
        }
        if (name.length == 0) {
            name = [[self.applicationPath lastPathComponent] stringByDeletingPathExtension];
        }
        return name;
    }
    return self.URLString ?: @"";
}

#pragma mark - Launch

- (void)launchIfNeeded {
    if (!self.enabled || !self.hasTarget) {
        return;
    }
    NSDate *now = [NSDate date];
    if (self.lastLaunchDate != nil && [now timeIntervalSinceDate:self.lastLaunchDate] < MAGReplacementLaunchCooldown) {
        return;
    }
    self.lastLaunchDate = now;

    if (self.applicationPath.length > 0) {
        [self launchApplicationIfNeeded];
        return;
    }
    if (self.URLString.length > 0) {
        [self openURL];
    }
}

- (void)launchApplicationIfNeeded {
    NSString *path = self.applicationPath;
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    NSString *bundleIdentifier = bundle.bundleIdentifier;
    if (bundle == nil || bundleIdentifier.length == 0) {
        self.lastErrorText = @"Replacement application is no longer available.";
        return;
    }

    NSArray<NSRunningApplication *> *running =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
    if (running.count > 0) {
        // Never start a second copy; bring the existing instance forward instead.
        [running.firstObject activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        return;
    }

    NSURL *appURL = [NSURL fileURLWithPath:path isDirectory:YES];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    configuration.addsToRecentItems = NO;
    __weak typeof(self) weakSelf = self;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL
                                          configuration:configuration
                                      completionHandler:^(NSRunningApplication *_Nullable app, NSError *_Nullable error) {
                                          if (error != nil) {
                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                  weakSelf.lastErrorText =
                                                      [NSString stringWithFormat:@"Could not launch replacement: %@",
                                                                                 error.localizedDescription];
                                              });
                                          }
                                      }];
}

- (void)openURL {
    NSURL *url = [NSURL URLWithString:self.URLString];
    if (url == nil) {
        self.lastErrorText = @"Replacement URL is invalid.";
        return;
    }
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    __weak typeof(self) weakSelf = self;
    [[NSWorkspace sharedWorkspace] openURL:url
                             configuration:configuration
                         completionHandler:^(NSRunningApplication *_Nullable app, NSError *_Nullable error) {
                             if (error != nil) {
                                 dispatch_async(dispatch_get_main_queue(), ^{
                                     weakSelf.lastErrorText =
                                         [NSString stringWithFormat:@"Could not open replacement URL: %@",
                                                                    error.localizedDescription];
                                 });
                             }
                         }];
}

@end
