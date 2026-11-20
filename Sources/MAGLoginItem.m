//
//  MAGLoginItem.m
//  Soramimi
//

#import "MAGLoginItem.h"

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

@interface MAGLoginItem ()
@property (nonatomic, readwrite) BOOL available;
@property (nonatomic, readwrite) BOOL enabled;
@property (nonatomic, readwrite) BOOL requiresApproval;
@property (nonatomic, readwrite) NSInteger rawStatus;
@property (nonatomic, copy, readwrite) NSString *statusText;
@end

@implementation MAGLoginItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _available = [self isAPIAvailable];
        _statusText = @"Unavailable";
        [self refresh];
    }
    return self;
}

- (BOOL)isAPIAvailable {
    if (@available(macOS 13.0, *)) {
        return YES;
    }
    return NO;
}

- (void)refresh {
    if (![self isAPIAvailable]) {
        self.available = NO;
        self.enabled = NO;
        self.requiresApproval = NO;
        self.statusText = @"Unavailable (requires macOS 13 or later)";
        return;
    }
    self.available = YES;
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        self.rawStatus = (NSInteger)service.status;
        switch (service.status) {
            case SMAppServiceStatusEnabled:
                self.enabled = YES;
                self.requiresApproval = NO;
                self.statusText = @"On";
                break;
            case SMAppServiceStatusRequiresApproval:
                self.enabled = YES;
                self.requiresApproval = YES;
                self.statusText = @"Needs approval in System Settings";
                break;
            case SMAppServiceStatusNotFound:
                // No registration record for this app yet; treat as off. Actual API
                // failures surface from registerAndReturnError: in setEnabled:error:.
                self.enabled = NO;
                self.requiresApproval = NO;
                self.statusText = @"Off";
                break;
            case SMAppServiceStatusNotRegistered:
            default:
                self.enabled = NO;
                self.requiresApproval = NO;
                self.statusText = @"Off";
                break;
        }
    }
}

- (BOOL)setEnabled:(BOOL)enabled error:(NSError *_Nullable *_Nullable)error {
    if (![self isAPIAvailable]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"MAGLoginItemErrorDomain"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"Launch at Login requires macOS 13 or "
                                                                                 @"later."}];
        }
        return NO;
    }
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        NSError *serviceError = nil;
        BOOL result = enabled ? [service registerAndReturnError:&serviceError]
                              : [service unregisterAndReturnError:&serviceError];
        [self refresh];
        if (!result) {
            if (error != NULL) {
                *error = serviceError ?: [NSError
                    errorWithDomain:@"MAGLoginItemErrorDomain"
                               code:2
                           userInfo:@{NSLocalizedDescriptionKey :
                                          @"macOS refused to change the login item (no error details were "
                                          @"provided by SMAppService)."}];
            }
            return NO;
        }
        return YES;
    }
    return NO;
}

- (void)openSystemSettingsLoginItems {
    if (@available(macOS 13.0, *)) {
        [SMAppService openSystemSettingsLoginItems];
        return;
    }
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"];
    if (url != nil) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

@end
