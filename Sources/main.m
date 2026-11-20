//
//  main.m
//  Soramimi
//
//  Menu bar agent entry point plus the small command-line surface used for
//  installation, reset and verification:
//
//    --version            print version and exit
//    --dump-state         print current preferences / device / login item state as JSON
//    --self-test          run audio + environment checks, print PASS/FAIL lines
//    --test-login-item    (verification build only) register/unregister login item once
//    --reset              unregister the login item and remove all preferences
//
//  Everything below the GUI entry point is intentionally allocation-light and
//  writes only to stdout/stderr; it performs no network I/O.
//

#import <Cocoa/Cocoa.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

#import "MAGAppDelegate.h"
#import "MAGAudioEngine.h"
#import "MAGBlocker.h"
#import "MAGLoginItem.h"
#import "MAGPreferences.h"

static NSString *MAGBundleVersion(void) {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return version.length > 0 ? version : @"1.0.0";
}

static NSString *MAGBundleIdentifier(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"local.soramimi";
}

static NSString *MAGArchitectureName(void) {
#if defined(__arm64__)
    return @"arm64";
#elif defined(__x86_64__)
    return @"x86_64";
#else
    return @"unknown";
#endif
}

static id MAGJSONSafeValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        double number = [value doubleValue];
        if (!isfinite(number)) {
            return @"not-applicable";
        }
        return value;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
            (void)stop;
            result[key] = MAGJSONSafeValue(object);
        }];
        return result;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id object in (NSArray *)value) {
            [result addObject:MAGJSONSafeValue(object)];
        }
        return result;
    }
    return value;
}

static void MAGPrintUsage(FILE *stream) {
    fprintf(stream,
            "Soramimi %s\n"
            "Usage: Soramimi [option]\n"
            "  (no option)          start the menu bar agent\n"
            "  --version            print version information\n"
            "  --dump-state         print preferences/device/login item state as JSON\n"
            "  --self-test          run audio and environment checks (PASS/FAIL output)\n"
#ifdef MAG_TESTING
            "  --test-login-item    register and unregister the login item once\n"
#endif

            "  --reset              unregister the login item and remove all preferences\n",
            MAGBundleVersion().UTF8String);
}

static int MAGRunSelfTest(void) {
    int failures = 0;
    printf("INFO: Soramimi %s self-test\n", MAGBundleVersion().UTF8String);
    printf("INFO: bundle=%s arch=%s macOS=%s\n", MAGBundleIdentifier().UTF8String,
           MAGArchitectureName().UTF8String,
           [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);

    // 1. The process must not have MediaPlayer/MediaRemote loaded, which is the
    //    static guarantee that no Now Playing session can be created.
    uint32_t imageCount = _dyld_image_count();
    int forbiddenImages = 0;
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *path = _dyld_get_image_name(index);
        if (path == NULL) {
            continue;
        }
        if (strstr(path, "MediaPlayer.framework") != NULL || strstr(path, "MediaRemote") != NULL) {
            printf("FAIL: forbidden media framework loaded: %s\n", path);
            failures += 1;
            forbiddenImages += 1;
        }
    }
    if (forbiddenImages == 0) {
        printf("PASS: no MediaPlayer/MediaRemote framework is loaded (media-key focus untouched)\n");
    }

    // 2. Start the keep-alive engine and let the run loop deliver Core Audio callbacks.
    MAGAudioEngine *engine = [[MAGAudioEngine alloc] init];
    engine.levelDB = -100.0;
    [engine setEnabled:YES];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
    while (deadline.timeIntervalSinceNow > 0.0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    NSDictionary<NSString *, id> *device = [engine deviceInfo];
    if ([device[MAGAudioInfoKeyHasDevice] boolValue]) {
        printf("INFO: output device: %s\n", [[engine deviceSummary] UTF8String]);
        BOOL isFloat = [device[MAGAudioInfoKeyIsFloat] boolValue];
        unsigned int bits = [device[MAGAudioInfoKeyBitsPerChannel] unsignedIntValue];
        double floorDB = [device[MAGAudioInfoKeyQuantizationFloorDB] doubleValue];
        if (isFloat) {
            printf("INFO: device sample format: %u-bit float (no integer quantization)\n", bits);
        } else if (bits > 0) {
            printf("INFO: device sample format: %u-bit integer (quantization floor %.1f dBFS)\n", bits, floorDB);
        } else {
            printf("INFO: device sample format: unknown\n");
        }
        printf("PASS: default audio output device is available\n");
    } else {
        printf("FAIL: no default audio output device\n");
        failures += 1;
    }
    if (engine.running && engine.lastError == nil) {
        printf("PASS: audio queue started and kept running (level -100 dBFS)\n");
    } else {
        printf("FAIL: audio queue did not run: %s\n", (engine.lastError ?: @"not running").UTF8String);
        failures += 1;
    }
    [engine setEnabled:NO];
    [engine shutdown];

    // 3. Apple Music presence and the login item API.
    NSURL *musicURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.Music"];
    if (musicURL != nil) {
        printf("PASS: Apple Music is installed (%s)\n", musicURL.path.UTF8String);
    } else {
        printf("FAIL: Apple Music was not found; blocking cannot be verified\n");
        failures += 1;
    }
    NSURL *itunesURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.iTunes"];
    printf("INFO: iTunes installed: %s\n", itunesURL != nil ? "yes" : "no");

    MAGLoginItem *loginItem = [[MAGLoginItem alloc] init];
    if (loginItem.available) {
        printf("PASS: SMAppService login item API available (%s)\n", loginItem.statusText.UTF8String);
    } else {
        printf("FAIL: SMAppService login item API unavailable\n");
        failures += 1;
    }

    // 4. Report the persisted configuration (no personal data).
    NSDictionary *state = [[MAGPreferences sharedPreferences] dumpState];
    printf("INFO: preferences: %s\n", [[state description] UTF8String]);

    if (failures == 0) {
        printf("PASS: self-test completed with 0 failures\n");
        return 0;
    }
    printf("FAIL: self-test completed with %d failure(s)\n", failures);
    return 1;
}

static int MAGDumpState(void) {
    MAGPreferences *preferences = [MAGPreferences sharedPreferences];
    MAGAudioEngine *engine = [[MAGAudioEngine alloc] init];
    MAGLoginItem *loginItem = [[MAGLoginItem alloc] init];

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"version"] = MAGBundleVersion();
    state[@"bundleIdentifier"] = MAGBundleIdentifier();
    state[@"architecture"] = MAGArchitectureName();
    state[@"macOS"] = [[NSProcessInfo processInfo] operatingSystemVersionString];
    state[@"preferences"] = MAGJSONSafeValue([preferences dumpState]);
    state[@"outputDevice"] = [engine deviceSummary];
    state[@"deviceInfo"] = MAGJSONSafeValue([engine deviceInfo]);
    state[@"musicInstalled"] = @([[NSWorkspace sharedWorkspace]
                                     URLForApplicationWithBundleIdentifier:@"com.apple.Music"] != nil);
    state[@"iTunesInstalled"] = @([[NSWorkspace sharedWorkspace]
                                      URLForApplicationWithBundleIdentifier:@"com.apple.iTunes"] != nil);
    state[@"loginItemAvailable"] = @(loginItem.available);
    state[@"loginItemStatus"] = loginItem.statusText;

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:MAGJSONSafeValue(state)
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&error];
    [engine shutdown];
    if (json == nil) {
        fprintf(stderr, "FAIL: could not serialize state: %s\n",
                error.localizedDescription.UTF8String ?: "unknown error");
        return 1;
    }
    fwrite(json.bytes, 1, json.length, stdout);
    printf("\n");
    return 0;
}

static int MAGResetState(void) {
    MAGPreferences *preferences = [MAGPreferences sharedPreferences];
    MAGLoginItem *loginItem = [[MAGLoginItem alloc] init];
    [loginItem refresh];
    if (loginItem.enabled) {
        NSError *error = nil;
        if ([loginItem setEnabled:NO error:&error]) {
            printf("PASS: login item unregistered\n");
        } else {
            printf("WARN: could not unregister login item: %s\n",
                   (error.localizedDescription ?: @"unknown error").UTF8String);
        }
    } else {
        printf("PASS: login item was not registered\n");
    }
    [preferences resetAll];
    printf("PASS: preferences removed for %s\n", MAGBundleIdentifier().UTF8String);
    printf("PASS: reset complete (no network access was performed)\n");
    return 0;
}

#ifdef MAG_TESTING
static int MAGTestLoginItem(void) {
    MAGLoginItem *loginItem = [[MAGLoginItem alloc] init];
    [loginItem refresh];
    printf("INFO: login item before: %s\n", loginItem.statusText.UTF8String);
    NSError *error = nil;
    if (![loginItem setEnabled:YES error:&error]) {
        printf("FAIL: could not register login item: %s\n",
               (error.localizedDescription ?: @"unknown error").UTF8String);
        return 1;
    }
    printf("PASS: login item registered (%s)\n", loginItem.statusText.UTF8String);
    error = nil;
    if (![loginItem setEnabled:NO error:&error]) {
        printf("FAIL: could not unregister login item: %s\n",
               (error.localizedDescription ?: @"unknown error").UTF8String);
        return 1;
    }
    printf("PASS: login item unregistered (%s)\n", loginItem.statusText.UTF8String);
    return 0;
}
#endif

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *command = nil;
        if (argc > 1) {
            command = [NSString stringWithUTF8String:argv[1]];
        }
        if ([command isEqualToString:@"--version"]) {
            printf("Soramimi %s (%s, %s)\n", MAGBundleVersion().UTF8String, MAGBundleIdentifier().UTF8String,
                   MAGArchitectureName().UTF8String);
            printf("No network access. No administrator rights required.\n");
            return 0;
        }
        if ([command isEqualToString:@"--help"] || [command isEqualToString:@"-h"]) {
            MAGPrintUsage(stdout);
            return 0;
        }
        if ([command isEqualToString:@"--dump-state"]) {
            return MAGDumpState();
        }
        if ([command isEqualToString:@"--self-test"]) {
            return MAGRunSelfTest();
        }
#ifdef MAG_TESTING
        if ([command isEqualToString:@"--test-login-item"]) {
            return MAGTestLoginItem();
        }
#endif
        if ([command isEqualToString:@"--reset"]) {
            return MAGResetState();
        }
        if (command.length > 0 && [command hasPrefix:@"--"]) {
            fprintf(stderr, "Unknown option: %s\n", command.UTF8String);
            MAGPrintUsage(stderr);
            return 2;
        }

        // Normal menu bar agent. Refuse to start a second copy of the same app.
        NSString *bundleIdentifier = MAGBundleIdentifier();
        for (NSRunningApplication *application in
             [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier]) {
            if (application.processIdentifier != getpid()) {
                fprintf(stderr, "Soramimi is already running (pid %d); exiting.\n",
                        application.processIdentifier);
                return 0;
            }
        }

        static MAGAppDelegate *delegate = nil;
        delegate = [[MAGAppDelegate alloc] init];
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
