//
//  MAGAppDelegate.m
//  Soramimi
//
//  Menu bar UI and application lifecycle. Everything is event-driven: there is no
//  polling timer and no periodic work, which keeps idle CPU at effectively 0 %.
//

#import "MAGAppDelegate.h"

#import "MAGAudioEngine.h"
#import "MAGBlocker.h"
#import "MAGBlockPolicy.h"
#import "MAGLoginItem.h"
#import "MAGPreferences.h"
#import "MAGReplacementLauncher.h"

static NSString *const MAGVersionFallback = @"1.0.0";
static NSString *const MAGApplicationName = @"Soramimi";
static const NSInteger MAGMenuIndentationChild = 1;

@interface MAGAppDelegate () <NSMenuDelegate, MAGBlockerDelegate>

@property (nonatomic, strong) MAGPreferences *preferences;
@property (nonatomic, strong) MAGAudioEngine *audioEngine;
@property (nonatomic, strong) MAGBlocker *blocker;
@property (nonatomic, strong) MAGLoginItem *loginItem;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSMutableArray<id> *notificationTokens;

// Dynamic menu items kept for state updates.
@property (nonatomic, strong) NSMenuItem *headerItem;
@property (nonatomic, strong) NSMenuItem *keepAliveItem;
@property (nonatomic, strong) NSMenuItem *levelItem;
@property (nonatomic, strong) NSMenu *levelMenu;
@property (nonatomic, strong) NSMenuItem *wakePingItem;
@property (nonatomic, strong) NSMenu *wakePingMenu;
@property (nonatomic, strong) NSMenuItem *pingLevelItem;
@property (nonatomic, strong) NSMenu *pingLevelMenu;
@property (nonatomic, strong) NSMenuItem *deviceItem;
@property (nonatomic, strong) NSMenuItem *engineStatusItem;
@property (nonatomic, strong) NSMenuItem *levelWarningItem;
@property (nonatomic, strong) NSMenuItem *musicBlockerItem;
@property (nonatomic, strong) NSMenuItem *itunesBlockerItem;
@property (nonatomic, strong) NSMenuItem *policyItem;
@property (nonatomic, strong) NSMenu *policyMenu;
@property (nonatomic, strong) NSMenuItem *lastBlockItem;
@property (nonatomic, strong) NSMenuItem *blockerStatusItem;
@property (nonatomic, strong) NSMenuItem *replacementItem;
@property (nonatomic, strong) NSMenuItem *replacementTargetItem;
@property (nonatomic, strong) NSMenuItem *clearReplacementItem;
@property (nonatomic, strong) NSMenuItem *loginItemMenuItem;
@property (nonatomic, strong) NSMenuItem *loginApprovalItem;
@property (nonatomic, strong) NSMenuItem *loginStatusItem;

@end

@implementation MAGAppDelegate

#pragma mark - Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.preferences = [MAGPreferences sharedPreferences];
    self.audioEngine = [[MAGAudioEngine alloc] init];
    self.audioEngine.levelDB = self.preferences.keepAliveLevelDB;
    self.blocker = [[MAGBlocker alloc] init];
    self.blocker.delegate = self;
    self.loginItem = [[MAGLoginItem alloc] init];
    self.notificationTokens = [NSMutableArray array];

    [self buildStatusItem];
    [self installObservers];
    [self applyStoredPreferences];
    [self applyTestOverrides];
    [self updateStatusIcon];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    // Stop audio and release the Core Audio device before the process disappears.
    [self.audioEngine shutdown];
    [self.blocker shutdown];
    [self removeObservers];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    (void)app;
    return YES;
}

#pragma mark - Startup configuration

- (void)applyStoredPreferences {
    MAGPreferences *preferences = self.preferences;
    self.audioEngine.levelDB = preferences.keepAliveLevelDB;
    [self.audioEngine setWakePingEnabled:preferences.wakePingEnabled];
    [self.audioEngine setWakePingIntervalSeconds:preferences.wakePingIntervalSeconds];
    [self.audioEngine setWakePingLevelDB:preferences.wakePingLevelDB];
    [self.audioEngine setEnabled:preferences.keepAliveEnabled];

    self.blocker.policy = preferences.blockingPolicy;
    [self.blocker setMusicBlockingEnabled:preferences.musicBlockerEnabled];
    [self.blocker setITunesBlockingEnabled:preferences.iTunesBlockerEnabled];

    MAGReplacementLauncher *replacement = self.blocker.replacement;
    replacement.enabled = preferences.replacementEnabled;
    if ([preferences.replacementKind isEqualToString:@"app"] && preferences.replacementValue.length > 0) {
        NSError *error = nil;
        if (![replacement setApplicationPath:preferences.replacementValue error:&error]) {
            replacement.enabled = NO;
            preferences.replacementEnabled = NO;
        }
    } else if ([preferences.replacementKind isEqualToString:@"url"] && preferences.replacementValue.length > 0) {
        NSError *error = nil;
        if (![replacement setURLString:preferences.replacementValue error:&error]) {
            replacement.enabled = NO;
            preferences.replacementEnabled = NO;
        }
    }
    [self.loginItem refresh];
}

- (void)applyTestOverrides {
#ifdef MAG_TESTING
    // Verification-build only (scripts/build.sh --test-hooks). These hooks are
    // compiled out of the shipped release build so the distributed app has no
    // environment-variable control surface at all.
    NSDictionary<NSString *, NSString *> *environment = [[NSProcessInfo processInfo] environment];
    BOOL testMode = NO;

    NSString *keepAlive = environment[@"MAG_TEST_KEEP_ALIVE"];
    if (keepAlive.boolValue) {
        testMode = YES;
        NSString *level = environment[@"MAG_TEST_LEVEL_DB"];
        if (level.length > 0) {
            self.audioEngine.levelDB = level.doubleValue;
        }
        [self.audioEngine setEnabled:YES];
    }

    NSString *musicBlocker = environment[@"MAG_TEST_ENABLE_MUSIC_BLOCKER"];
    if (musicBlocker.boolValue) {
        testMode = YES;
        [self.blocker setMusicBlockingEnabled:YES];
    }
    NSString *itunesBlocker = environment[@"MAG_TEST_ENABLE_ITUNES_BLOCKER"];
    if (itunesBlocker.boolValue) {
        testMode = YES;
        [self.blocker setITunesBlockingEnabled:YES];
    }
    NSString *policy = environment[@"MAG_TEST_POLICY"];
    if ([policy isEqualToString:@"smart"]) {
        testMode = YES;
        self.blocker.policy = MAGBlockPolicyModeSmart;
    } else if ([policy isEqualToString:@"always"]) {
        testMode = YES;
        self.blocker.policy = MAGBlockPolicyModeAlways;
    }
    NSString *replacementEnabled = environment[@"MAG_TEST_ENABLE_REPLACEMENT"];
    if (replacementEnabled.boolValue) {
        testMode = YES;
        self.blocker.replacement.enabled = YES;
    }

    // Verification hook: configure a replacement application without touching the
    // user's persisted preferences, so the full blocked-launch -> replacement flow
    // can be exercised by scripts/verify.sh.
    NSString *replacementPath = environment[@"MAG_TEST_REPLACEMENT_PATH"];
    if (replacementPath.length > 0) {
        testMode = YES;
        NSError *replacementError = nil;
        if ([self.blocker.replacement setApplicationPath:replacementPath error:&replacementError]) {
            self.blocker.replacement.enabled = YES;
        } else {
            fprintf(stderr, "MAG_TEST_REPLACEMENT_PATH invalid: %s\n",
                    (replacementError.localizedDescription ?: @"unknown error").UTF8String);
        }
    }

    // Verification hook: emit a synthetic "system event" after N seconds so the
    // Smart Block correlation path can be exercised end-to-end by scripts.
    NSString *triggerAfter = environment[@"MAG_TEST_TRIGGER_AUTO_SECONDS"];
    if (triggerAfter.length > 0) {
        testMode = YES;
        NSTimeInterval delay = MAX(0.1, triggerAfter.doubleValue);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [self.blocker noteAutomaticTrigger:MAGLaunchTriggerCauseAudioDeviceChange];
                           fprintf(stderr, "MAG_TEST_TRIGGER audio-device-change emitted\n");
                           fflush(stderr);
                       });
    }

    if (testMode) {
        NSDictionary *device = [self.audioEngine deviceInfo];
        fprintf(stdout, "MAG_READY pid=%d keepAlive=%d musicBlocker=%d policy=%s device=%s\n", getpid(),
                self.audioEngine.enabled ? 1 : 0, self.blocker.musicBlockingEnabled ? 1 : 0,
                self.blocker.policy == MAGBlockPolicyModeAlways ? "always" : "smart",
                [[self.audioEngine deviceSummary] UTF8String]);
        fflush(stdout);
        (void)device;
    }

    NSString *quitAfter = environment[@"MAG_TEST_QUIT_AFTER_SECONDS"];
    if (quitAfter.length > 0) {
        NSTimeInterval delay = MAX(0.1, quitAfter.doubleValue);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [NSApp terminate:nil];
                       });
    }
#else
    // Release build: no test-only control surface exists.
#endif
}

- (void)installObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    __weak typeof(self) weakSelf = self;
    id engineState = [center addObserverForName:MAGAudioEngineStateDidChangeNotification
                                         object:nil
                                          queue:[NSOperationQueue mainQueue]
                                     usingBlock:^(NSNotification *note) {
                                         (void)note;
                                         __strong typeof(weakSelf) self = weakSelf;
                                         [self updateStatusIcon];
                                     }];
    id deviceChange = [center addObserverForName:MAGAudioDefaultDeviceDidChangeNotification
                                          object:nil
                                           queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *note) {
                                          (void)note;
                                          __strong typeof(weakSelf) self = weakSelf;
                                          [self.blocker noteAutomaticTrigger:MAGLaunchTriggerCauseAudioDeviceChange];
                                          [self updateStatusIcon];
                                      }];
    id wake = [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidWakeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    __strong typeof(weakSelf) self = weakSelf;
                    [self.blocker noteAutomaticTrigger:MAGLaunchTriggerCauseSystemWake];
                }];
    [self.notificationTokens addObjectsFromArray:@[ engineState, deviceChange, wake ]];
}

- (void)removeObservers {
    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
    for (id token in self.notificationTokens) {
        [defaultCenter removeObserver:token];
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:token];
    }
    [self.notificationTokens removeAllObjects];
}

#pragma mark - Status item and menu

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.toolTip = MAGApplicationName;
    [self.statusItem setMenu:[self buildMenu]];
    [self updateStatusIcon];
}

- (NSMenuItem *)addItemWithTitle:(NSString *)title action:(nullable SEL)action toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return item;
}

- (NSMenuItem *)addDisabledItemWithTitle:(NSString *)title toMenu:(NSMenu *)menu {
    NSMenuItem *item = [self addItemWithTitle:title action:nil toMenu:menu];
    item.enabled = NO;
    return item;
}

- (NSMenuItem *)addChildItemWithTitle:(NSString *)title action:(nullable SEL)action toMenu:(NSMenu *)menu {
    NSMenuItem *item = [self addItemWithTitle:title action:action toMenu:menu];
    item.indentationLevel = MAGMenuIndentationChild;
    return item;
}

- (void)addSeparatorToMenu:(NSMenu *)menu {
    [menu addItem:[NSMenuItem separatorItem]];
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:MAGApplicationName];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.statusMenu = menu;

    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (version.length == 0) {
        version = MAGVersionFallback;
    }
    self.headerItem =
        [self addDisabledItemWithTitle:[NSString stringWithFormat:@"%@ %@", MAGApplicationName, version]
                                toMenu:menu];
    [self addSeparatorToMenu:menu];

    self.keepAliveItem = [self addItemWithTitle:@"Bluetooth Keep-Alive"
                                          action:@selector(toggleKeepAlive:)
                                          toMenu:menu];
    self.keepAliveItem.state = NSControlStateValueOff;

    self.levelItem = [self addChildItemWithTitle:@"Signal Level"
                                          action:nil
                                          toMenu:menu];
    self.levelMenu = [[NSMenu alloc] initWithTitle:@"Signal Level"];
    self.levelMenu.autoenablesItems = NO;
    for (NSNumber *level in @[ @(-100.0), @(-90.0), @(-80.0), @(-70.0), @(-60.0) ]) {
        NSString *title = [NSString stringWithFormat:@"%@%.0f dBFS%@", level.doubleValue < 0 ? @"−" : @"",
                                                     fabs(level.doubleValue),
                                                     level.doubleValue == -100.0 ? @" (default)" : @""];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectSignalLevel:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = level;
        [self.levelMenu addItem:item];
    }
    self.levelItem.submenu = self.levelMenu;

    self.wakePingItem = [self addChildItemWithTitle:@"Wake Ping" action:nil toMenu:menu];
    self.wakePingMenu = [[NSMenu alloc] initWithTitle:@"Wake Ping"];
    self.wakePingMenu.autoenablesItems = NO;
    for (NSNumber *seconds in @[ @0, @60, @120, @300, @600 ]) {
        NSString *title;
        if (seconds.doubleValue <= 0.0) {
            title = @"Off";
        } else {
            title = [NSString stringWithFormat:@"%.0f min", seconds.doubleValue / 60.0];
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(selectWakePingInterval:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = seconds;
        [self.wakePingMenu addItem:item];
    }
    self.wakePingItem.submenu = self.wakePingMenu;

    self.pingLevelItem = [self addChildItemWithTitle:@"Ping Level" action:nil toMenu:menu];
    self.pingLevelMenu = [[NSMenu alloc] initWithTitle:@"Ping Level"];
    self.pingLevelMenu.autoenablesItems = NO;
    for (NSNumber *level in @[ @(-30.0), @(-24.0), @(-18.0), @(-12.0), @(-6.0) ]) {
        NSString *title = [NSString stringWithFormat:@"%@%.0f dBFS", level.doubleValue < 0 ? @"−" : @"",
                                                     fabs(level.doubleValue)];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(selectWakePingLevel:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = level;
        [self.pingLevelMenu addItem:item];
    }
    self.pingLevelItem.submenu = self.pingLevelMenu;

    self.deviceItem = [self addChildItemWithTitle:@"Output Device" action:nil toMenu:menu];
    self.deviceItem.enabled = NO;

    self.engineStatusItem = [self addChildItemWithTitle:@"Signal Status" action:nil toMenu:menu];
    self.engineStatusItem.enabled = NO;

    self.levelWarningItem = [self addChildItemWithTitle:@"Warning" action:nil toMenu:menu];
    self.levelWarningItem.enabled = NO;
    self.levelWarningItem.hidden = YES;

    [self addSeparatorToMenu:menu];

    self.musicBlockerItem = [self addItemWithTitle:@"Block Apple Music" action:@selector(toggleMusicBlocking:) toMenu:menu];
    self.itunesBlockerItem = [self addItemWithTitle:@"Block iTunes" action:@selector(toggleITunesBlocking:) toMenu:menu];

    self.policyItem = [self addChildItemWithTitle:@"Blocking Policy" action:nil toMenu:menu];
    self.policyMenu = [[NSMenu alloc] initWithTitle:@"Blocking Policy"];
    self.policyMenu.autoenablesItems = NO;
    NSArray<NSString *> *policyTitles = @[ @"Always Block", @"Smart Block" ];
    [policyTitles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectPolicy:) keyEquivalent:@""];
        item.target = self;
        item.tag = (NSInteger)index;
        [self.policyMenu addItem:item];
    }];
    self.policyItem.submenu = self.policyMenu;

    self.blockerStatusItem = [self addChildItemWithTitle:@"Blocking Status" action:nil toMenu:menu];
    self.blockerStatusItem.enabled = NO;

    self.lastBlockItem = [self addChildItemWithTitle:@"Last Block" action:nil toMenu:menu];
    self.lastBlockItem.enabled = NO;
    self.lastBlockItem.hidden = YES;

    [self addSeparatorToMenu:menu];

    self.replacementItem = [self addItemWithTitle:@"Replacement App" action:@selector(toggleReplacement:) toMenu:menu];
    self.replacementTargetItem = [self addChildItemWithTitle:@"Target" action:nil toMenu:menu];
    self.replacementTargetItem.enabled = NO;

    NSMenuItem *chooseApp = [self addChildItemWithTitle:@"Select Application…"
                                                 action:@selector(chooseReplacementApplication:)
                                                 toMenu:menu];
    (void)chooseApp;
    NSMenuItem *chooseURL = [self addChildItemWithTitle:@"Set Custom URL…"
                                                 action:@selector(chooseReplacementURL:)
                                                 toMenu:menu];
    (void)chooseURL;
    self.clearReplacementItem = [self addChildItemWithTitle:@"Clear Replacement"
                                                     action:@selector(clearReplacement:)
                                                     toMenu:menu];
    self.clearReplacementItem.hidden = YES;

    [self addSeparatorToMenu:menu];

    self.loginItemMenuItem = [self addItemWithTitle:@"Launch at Login"
                                             action:@selector(toggleLaunchAtLogin:)
                                             toMenu:menu];
    self.loginStatusItem = [self addChildItemWithTitle:@"Login Item Status" action:nil toMenu:menu];
    self.loginStatusItem.enabled = NO;
    self.loginApprovalItem = [self addChildItemWithTitle:@"Open Login Items Settings…"
                                                  action:@selector(openLoginItemsSettings:)
                                                  toMenu:menu];
    self.loginApprovalItem.hidden = YES;

    [self addSeparatorToMenu:menu];
    [self addItemWithTitle:@"About Soramimi" action:@selector(showAboutPanel:) toMenu:menu];
    [self addItemWithTitle:@"Quit Soramimi" action:@selector(quitApplication:) toMenu:menu];
    return menu;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.statusMenu) {
        return;
    }
    [self refreshMenuState];
}

- (void)refreshMenuState {
    MAGPreferences *preferences = self.preferences;

    self.keepAliveItem.state = self.audioEngine.enabled ? NSControlStateValueOn : NSControlStateValueOff;

    double level = self.audioEngine.levelDB;
    self.levelItem.title = [NSString stringWithFormat:@"Signal Level: %@%.0f dBFS", level < 0 ? @"−" : @"",
                                                      fabs(level)];
    for (NSMenuItem *item in self.levelMenu.itemArray) {
        NSNumber *itemLevel = item.representedObject;
        item.state = (itemLevel.doubleValue == level) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    BOOL wakePingEnabled = self.audioEngine.wakePingEnabled;
    double wakePingInterval = self.audioEngine.wakePingIntervalSeconds;
    NSString *wakePingText = @"off";
    if (wakePingEnabled) {
        wakePingText = [NSString stringWithFormat:@"every %.0f min", wakePingInterval / 60.0];
        NSDate *lastPing = self.audioEngine.lastWakePingDate;
        if (lastPing != nil) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"HH:mm";
            wakePingText = [NSString stringWithFormat:@"%@ · last %@", wakePingText,
                                                      [formatter stringFromDate:lastPing]];
        }
    }
    self.wakePingItem.title = [NSString stringWithFormat:@"Wake Ping: %@", wakePingText];
    for (NSMenuItem *item in self.wakePingMenu.itemArray) {
        double seconds = [item.representedObject doubleValue];
        BOOL selected = seconds <= 0.0 ? !wakePingEnabled : (wakePingEnabled && seconds == wakePingInterval);
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.pingLevelItem.title = [NSString stringWithFormat:@"Ping Level: −%.0f dBFS",
                                                          fabs(self.audioEngine.wakePingLevelDB)];
    for (NSMenuItem *item in self.pingLevelMenu.itemArray) {
        BOOL selected = [item.representedObject doubleValue] == self.audioEngine.wakePingLevelDB;
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    }

    self.deviceItem.title = [NSString stringWithFormat:@"Output Device: %@", [self.audioEngine deviceSummary]];
    self.engineStatusItem.title =
        [NSString stringWithFormat:@"Signal Status: %@ (%@)", [self.audioEngine statusText],
                                   [self.audioEngine signalSummary]];

    NSDictionary<NSString *, id> *deviceInfo = [self.audioEngine deviceInfo];
    BOOL hasDevice = [deviceInfo[MAGAudioInfoKeyHasDevice] boolValue];
    BOOL isFloat = [deviceInfo[MAGAudioInfoKeyIsFloat] boolValue];
    NSUInteger bits = (NSUInteger)[deviceInfo[MAGAudioInfoKeyBitsPerChannel] unsignedIntValue];
    double floorDB = [deviceInfo[MAGAudioInfoKeyQuantizationFloorDB] doubleValue];
    BOOL showWarning = NO;
    NSString *warningText = nil;
    if (!hasDevice) {
        showWarning = YES;
        warningText = @"Warning: no audio output device is available.";
    } else if (self.audioEngine.enabled && !isFloat && bits > 0 && isfinite(floorDB) && level < floorDB) {
        showWarning = YES;
        warningText = [NSString stringWithFormat:@"Warning: %.0f dBFS is below this device's %lu-bit resolution "
                                                  @"(%.1f dBFS floor); the signal may become digital silence.",
                                                 level, (unsigned long)bits, floorDB];
    }
    self.levelWarningItem.hidden = !showWarning;
    self.levelWarningItem.title = warningText ?: @"";

    self.musicBlockerItem.state = self.blocker.musicBlockingEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.itunesBlockerItem.hidden = !self.blocker.iTunesInstalled;
    self.itunesBlockerItem.state = self.blocker.iTunesBlockingEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    BOOL smart = self.blocker.policy == MAGBlockPolicyModeSmart;
    self.policyItem.title = smart ? @"Blocking Policy: Smart Block" : @"Blocking Policy: Always Block";
    for (NSMenuItem *item in self.policyMenu.itemArray) {
        BOOL selected = (item.tag == MAGBlockPolicyModeSmart) == smart;
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    }

    self.blockerStatusItem.title = [NSString stringWithFormat:@"Blocking Status: %@", [self.blocker statusText]];
    NSString *lastBlock = [self.blocker lastBlockText];
    self.lastBlockItem.hidden = lastBlock.length == 0;
    self.lastBlockItem.title = lastBlock.length > 0 ? [NSString stringWithFormat:@"Last Block: %@", lastBlock] : @"";

    MAGReplacementLauncher *replacement = self.blocker.replacement;
    self.replacementItem.state = preferences.replacementEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (replacement.hasTarget) {
        self.replacementTargetItem.title = [NSString stringWithFormat:@"Target: %@", [replacement displayName]];
    } else {
        self.replacementTargetItem.title = @"Target: none selected";
    }
    self.clearReplacementItem.hidden = !replacement.hasTarget;

    [self.loginItem refresh];
    self.loginItemMenuItem.state = self.loginItem.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (!self.loginItem.available) {
        self.loginItemMenuItem.enabled = NO;
        self.loginItemMenuItem.title = @"Launch at Login (requires macOS 13)";
    } else {
        self.loginItemMenuItem.enabled = YES;
        self.loginItemMenuItem.title = @"Launch at Login";
    }
    self.loginStatusItem.title = [NSString stringWithFormat:@"Login Item: %@", [self.loginItem statusText]];
    self.loginApprovalItem.hidden = !self.loginItem.requiresApproval;
}

- (void)updateStatusIcon {
    NSString *symbol = @"waveform.path";
    if (self.audioEngine.lastError.length > 0) {
        symbol = @"exclamationmark.triangle";
    } else if (self.audioEngine.running) {
        symbol = @"waveform";
    }
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:MAGApplicationName];
    image.template = YES;
    self.statusItem.button.image = image;

    NSString *keepAliveStatus = self.audioEngine.enabled
                                    ? [NSString stringWithFormat:@"Keep-alive: %@ (%@)", [self.audioEngine statusText],
                                                                 [self.audioEngine signalSummary]]
                                    : @"Keep-alive: off";
    self.statusItem.button.toolTip =
        [NSString stringWithFormat:@"%@ — %@ · Blocking: %@", MAGApplicationName, keepAliveStatus,
                                   [self.blocker statusText]];
}

#pragma mark - Actions: keep-alive

- (void)toggleKeepAlive:(id)sender {
    (void)sender;
    BOOL enable = !self.audioEngine.enabled;
    self.preferences.keepAliveEnabled = enable;
    self.preferences.keepAliveLevelDB = self.audioEngine.levelDB;
    [self.audioEngine setEnabled:enable];
    [self updateStatusIcon];
}

- (void)selectSignalLevel:(NSMenuItem *)sender {
    double level = [sender.representedObject doubleValue];
    self.preferences.keepAliveLevelDB = level;
    self.audioEngine.levelDB = level;
    [self updateStatusIcon];
}

- (void)selectWakePingInterval:(NSMenuItem *)sender {
    double seconds = [sender.representedObject doubleValue];
    BOOL enabled = seconds > 0.0;
    self.preferences.wakePingEnabled = enabled;
    if (enabled) {
        self.preferences.wakePingIntervalSeconds = seconds;
    }
    [self.audioEngine setWakePingEnabled:enabled];
    if (enabled) {
        [self.audioEngine setWakePingIntervalSeconds:seconds];
    }
    [self updateStatusIcon];
}

- (void)selectWakePingLevel:(NSMenuItem *)sender {
    double level = [sender.representedObject doubleValue];
    self.preferences.wakePingLevelDB = level;
    [self.audioEngine setWakePingLevelDB:level];
    [self updateStatusIcon];
}

#pragma mark - Actions: blocking

- (void)toggleMusicBlocking:(id)sender {
    (void)sender;
    BOOL enable = !self.blocker.musicBlockingEnabled;
    self.preferences.musicBlockerEnabled = enable;
    [self.blocker setMusicBlockingEnabled:enable];
    [self updateStatusIcon];
}

- (void)toggleITunesBlocking:(id)sender {
    (void)sender;
    if (!self.blocker.iTunesInstalled) {
        return;
    }
    BOOL enable = !self.blocker.iTunesBlockingEnabled;
    self.preferences.iTunesBlockerEnabled = enable;
    [self.blocker setITunesBlockingEnabled:enable];
    [self updateStatusIcon];
}

- (void)selectPolicy:(NSMenuItem *)sender {
    MAGBlockPolicyMode policy = (MAGBlockPolicyMode)sender.tag;
    self.preferences.blockingPolicy = policy;
    self.blocker.policy = policy;
}

- (void)toggleReplacement:(id)sender {
    (void)sender;
    BOOL enable = !self.preferences.replacementEnabled;
    if (enable && !self.blocker.replacement.hasTarget) {
        [self showAlertWithTitle:@"Replacement App"
                     message:@"Choose a replacement application or URL first."
                  firstButton:@"OK"
                 secondButton:nil
                    completion:nil];
        return;
    }
    self.preferences.replacementEnabled = enable;
    self.blocker.replacement.enabled = enable;
}

- (void)chooseReplacementApplication:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.resolvesAliases = YES;
    panel.title = @"Select Replacement Application";
    panel.message = @"Choose the application to open after Apple Music has been blocked.";
    panel.prompt = @"Select";
    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] != NSModalResponseOK || panel.URL == nil) {
        return;
    }
    NSString *path = panel.URL.path;
    NSError *error = nil;
    if (![self.blocker.replacement setApplicationPath:path error:&error]) {
        [self showAlertWithTitle:@"Invalid Application"
                         message:error.localizedDescription ?: @"The selected item is not a usable application."
                     firstButton:@"OK"
                    secondButton:nil
                       completion:nil];
        return;
    }
    self.preferences.replacementKind = @"app";
    self.preferences.replacementValue = path;
    [self updateStatusIcon];
}

- (void)chooseReplacementURL:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Replacement URL";
    alert.informativeText = @"Enter the web address (http or https) to open after Apple Music has been blocked.";
    [alert addButtonWithTitle:@"Set URL"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.placeholderString = @"e.g. a web music player URL";
    NSString *existing = self.blocker.replacement.URLString;
    if (existing.length > 0) {
        field.stringValue = existing;
    }
    alert.accessoryView = field;
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    NSError *error = nil;
    if (![self.blocker.replacement setURLString:field.stringValue error:&error]) {
        [self showAlertWithTitle:@"Invalid URL"
                         message:error.localizedDescription ?: @"The URL is not valid."
                     firstButton:@"OK"
                    secondButton:nil
                       completion:nil];
        return;
    }
    self.preferences.replacementKind = @"url";
    self.preferences.replacementValue = self.blocker.replacement.URLString;
    [self updateStatusIcon];
}

- (void)clearReplacement:(id)sender {
    (void)sender;
    [self.blocker.replacement clearTarget];
    self.preferences.replacementEnabled = NO;
    self.preferences.replacementKind = nil;
    self.preferences.replacementValue = nil;
}

- (void)blockerDidChangeState:(MAGBlocker *)blocker {
    (void)blocker;
    [self updateStatusIcon];
}

#pragma mark - Actions: login item

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    if (!self.loginItem.available) {
        [self showAlertWithTitle:@"Launch at Login"
                         message:@"Launch at Login requires macOS 13 or later."
                     firstButton:@"OK"
                    secondButton:nil
                       completion:nil];
        return;
    }
    BOOL enable = !self.loginItem.enabled;
    NSError *error = nil;
    if (![self.loginItem setEnabled:enable error:&error]) {
        [self showAlertWithTitle:@"Launch at Login"
                         message:error.localizedDescription ?: @"macOS did not allow changing the login item."
                     firstButton:@"OK"
                    secondButton:nil
                       completion:nil];
        return;
    }
    [self.loginItem refresh];
    if (self.loginItem.requiresApproval) {
        [self showAlertWithTitle:@"Login Item Approval Needed"
                         message:@"macOS requires approval before this app can start at login. Open Login Items "
                                 @"settings and enable Soramimi."
                     firstButton:@"Open Login Items Settings…"
                    secondButton:@"Later"
                       completion:^(NSInteger buttonIndex) {
                           if (buttonIndex == NSAlertFirstButtonReturn) {
                               [self.loginItem openSystemSettingsLoginItems];
                           }
                       }];
    }
}

- (void)openLoginItemsSettings:(id)sender {
    (void)sender;
    [self.loginItem openSystemSettingsLoginItems];
}

#pragma mark - Actions: about / quit

- (void)showAboutPanel:(id)sender {
    (void)sender;
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"] ?: MAGVersionFallback;
    NSString *buildDateRaw = info[@"MAGBuildDate"] ?: @"";
    NSString *buildDateText = @"unknown";
    if (buildDateRaw.length > 0) {
        NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
        NSDate *buildDate = [isoFormatter dateFromString:buildDateRaw];
        if (buildDate != nil) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateStyle = NSDateFormatterMediumStyle;
            formatter.timeStyle = NSDateFormatterShortStyle;
            buildDateText = [formatter stringFromDate:buildDate];
        } else {
            buildDateText = buildDateRaw;
        }
    }

    // Deliberately minimal: the About panel shows the build time only (plus the
    // app name/version in the title). No source path, bundle identifier or build
    // machine details are exposed here.
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%@ %@", MAGApplicationName, version];
    alert.informativeText = [NSString stringWithFormat:@"Build: %@", buildDateText];
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)quitApplication:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

#pragma mark - Helpers

- (void)showAlertWithTitle:(NSString *)title
                   message:(NSString *)message
               firstButton:(NSString *)firstButton
              secondButton:(nullable NSString *)secondButton
                 completion:(void (^__nullable)(NSInteger buttonIndex))completion {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:firstButton];
    if (secondButton.length > 0) {
        [alert addButtonWithTitle:secondButton];
    }
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response = [alert runModal];
    if (completion != nil) {
        completion(response);
    }
}

@end
