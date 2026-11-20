//
//  MAGLoginItem.h
//  Soramimi
//
//  Wrapper around SMAppService (macOS 13+) so "Launch at Login" needs no helper
//  bundle, no LaunchAgent plist and no administrator rights.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MAGLoginItem : NSObject

@property (nonatomic, readonly) BOOL available;      // NO on macOS < 13
@property (nonatomic, readonly) BOOL enabled;        // registered (or awaiting approval)
@property (nonatomic, readonly) BOOL requiresApproval;
@property (nonatomic, readonly, copy) NSString *statusText;

- (void)refresh;
- (BOOL)setEnabled:(BOOL)enabled error:(NSError *_Nullable *_Nullable)error;
- (void)openSystemSettingsLoginItems;

@end

NS_ASSUME_NONNULL_END
