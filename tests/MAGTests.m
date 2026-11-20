//
//  MAGTests.m
//  Soramimi
//
//  Dependency-free test runner for the two pieces of pure logic in the app:
//  the keep-alive signal generator and the blocking policy. It links only
//  Foundation and no AppKit/CoreAudio, so it runs fast and without side effects
//  (it never touches the user's defaults domain or audio devices).
//
//  Build/run: scripts/test.sh
//

#import <Foundation/Foundation.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#import "MAGBlockPolicy.h"
#import "MAGPreferences.h"
#import "MAGSignalGenerator.h"

static int gFailures = 0;
static int gChecks = 0;

static void MAGCheck(BOOL condition, NSString *name) {
    gChecks += 1;
    if (condition) {
        printf("PASS: %s\n", name.UTF8String);
    } else {
        printf("FAIL: %s\n", name.UTF8String);
        gFailures += 1;
    }
}

static void MAGCheckNear(double actual, double expected, double tolerance, NSString *name) {
    BOOL ok = fabs(actual - expected) <= tolerance;
    gChecks += 1;
    if (ok) {
        printf("PASS: %s (actual %.12g, expected %.12g)\n", name.UTF8String, actual, expected);
    } else {
        printf("FAIL: %s (actual %.12g, expected %.12g, tolerance %.3g)\n", name.UTF8String, actual, expected,
               tolerance);
        gFailures += 1;
    }
}

static void MAGTestLevelConversion(void) {
    MAGCheckNear(MAGSignalDBToLinear(0.0), 1.0, 1e-15, @"0 dBFS is linear amplitude 1.0");
    MAGCheckNear(MAGSignalDBToLinear(-100.0), 1e-5, 1e-16, @"-100 dBFS is linear amplitude 1e-5");
    MAGCheckNear(MAGSignalLinearToDB(1e-5), -100.0, 1e-10, @"linear amplitude 1e-5 is -100 dBFS");
    MAGCheck(MAGSignalLinearToDB(0.0) == -INFINITY, @"digital silence maps to -infinity dBFS");
}

static void MAGTestSignalLevelsAndDCOffset(void) {
    MAGSignalGenerator generator;
    MAGCheck(MAGSignalGeneratorInit(&generator, 44100.0, 20.0), @"signal generator initializes at 44.1 kHz");
    MAGSignalGeneratorSetLevelDB(&generator, -100.0);
    MAGSignalGeneratorSetActive(&generator, true);

    const uint32_t rampFrames = 22050; // 0.5 s is longer than the 150 ms fade-in
    // 44100 samples at 20 Hz is exactly 20 cycles, so the steady-state mean must be 0.
    const uint32_t measureFrames = 44100;
    float *buffer = malloc((size_t)measureFrames * 2 * sizeof(float));
    uint32_t produced = 0;
    while (produced < rampFrames) {
        MAGSignalGeneratorFill(&generator, buffer, 1024);
        produced += 1024;
    }
    MAGSignalGeneratorFill(&generator, buffer, measureFrames);
    double sum = 0.0;
    double peak = 0.0;
    for (uint32_t i = 0; i < measureFrames; i++) {
        double sample = buffer[i * 2];
        sum += sample;
        peak = fmax(peak, fabs(sample));
        if (buffer[i * 2] != buffer[i * 2 + 1]) {
            gFailures += 1;
            printf("FAIL: left and right channels differ\n");
        }
    }
    double mean = sum / (double)measureFrames;
    MAGCheckNear(mean, 0.0, 1e-11, @"generated signal has no DC component (steady-state mean ~ 0)");
    MAGCheckNear(peak, 1e-5, 2e-7, @"generated signal peak matches -100 dBFS after the fade-in ramp");
    free(buffer);
    MAGSignalGeneratorDispose(&generator);
}

static void MAGTestFadeOutAndSilence(void) {
    MAGSignalGenerator generator;
    MAGCheck(MAGSignalGeneratorInit(&generator, 48000.0, 20.0), @"signal generator initializes at 48 kHz");
    MAGSignalGeneratorSetLevelDB(&generator, -60.0);
    MAGSignalGeneratorSetActive(&generator, true);

    const uint32_t frames = 4096;
    float *buffer = malloc((size_t)frames * 2 * sizeof(float));
    // One second is far more than the 150 ms ramp.
    for (int i = 0; i < 12; i++) {
        MAGSignalGeneratorFill(&generator, buffer, frames);
    }
    double peak = 0.0;
    for (uint32_t i = 0; i < frames; i++) {
        peak = fmax(peak, fabs(buffer[i * 2]));
    }
    MAGCheckNear(peak, MAGSignalDBToLinear(-60.0), 2e-5, @"-60 dBFS level is reached after fade-in");

    MAGSignalGeneratorSetActive(&generator, false);
    for (int i = 0; i < 12; i++) {
        MAGSignalGeneratorFill(&generator, buffer, frames);
    }
    BOOL silent = true;
    for (uint32_t i = 0; i < frames; i++) {
        if (buffer[i * 2] != 0.0f || buffer[i * 2 + 1] != 0.0f) {
            silent = false;
            break;
        }
    }
    MAGCheck(silent, @"fade-out ends in exact digital silence (no clicks, no residual DC)");
    MAGCheck(MAGSignalGeneratorIsSilent(&generator), @"generator reports silent after fade-out");
    free(buffer);
    MAGSignalGeneratorDispose(&generator);
}

static void MAGTestBlockingPolicy(void) {
    MAGBlockDecision *decision = [MAGBlockPolicy decisionForPolicy:MAGBlockPolicyModeAlways
                                            secondsSinceLastTrigger:INFINITY
                                                     triggerCause:MAGLaunchTriggerCauseNone];
    MAGCheck(decision.block, @"Always Block blocks a launch with no system trigger");
    MAGCheck(!decision.isAutomatic, @"Always Block decision is classified as not automatic");

    decision = [MAGBlockPolicy decisionForPolicy:MAGBlockPolicyModeSmart
                          secondsSinceLastTrigger:3.0
                                   triggerCause:MAGLaunchTriggerCauseAudioDeviceChange];
    MAGCheck(decision.block, @"Smart Block blocks a launch 3 s after an audio device change");
    MAGCheck(decision.isAutomatic, @"Smart Block decision is classified as automatic");
    MAGCheck([decision.reason rangeOfString:@"audio output device change"].location != NSNotFound,
             @"Smart Block reason mentions the audio device trigger");

    decision = [MAGBlockPolicy decisionForPolicy:MAGBlockPolicyModeSmart
                          secondsSinceLastTrigger:INFINITY
                                   triggerCause:MAGLaunchTriggerCauseNone];
    MAGCheck(!decision.block, @"Smart Block allows a launch with no observed system trigger");

    decision = [MAGBlockPolicy decisionForPolicy:MAGBlockPolicyModeSmart
                          secondsSinceLastTrigger:20.0
                                   triggerCause:MAGLaunchTriggerCauseSystemWake];
    MAGCheck(!decision.block, @"Smart Block allows a launch outside the 15 s correlation window");

    decision = [MAGBlockPolicy decisionForPolicy:MAGBlockPolicyModeAlways
                          secondsSinceLastTrigger:1.0
                                   triggerCause:MAGLaunchTriggerCauseSystemWake];
    MAGCheck(decision.block && decision.isAutomatic, @"Always Block still blocks inside the correlation window");

    decision = [MAGBlockPolicy decisionForPolicy:MAGBlockPolicyModeSmart
                          secondsSinceLastTrigger:NAN
                                   triggerCause:MAGLaunchTriggerCauseAudioDeviceChange];
    MAGCheck(!decision.block, @"Smart Block treats a non-finite trigger age as no trigger");
}

static void MAGTestPreferenceBounds(void) {
    MAGPreferences *preferences = [MAGPreferences sharedPreferences];
    double original = preferences.keepAliveLevelDB;
    preferences.keepAliveLevelDB = -100.0;
    MAGCheckNear(preferences.keepAliveLevelDB, -100.0, 0.0, @"default keep-alive level is -100 dBFS");
    preferences.keepAliveLevelDB = -500.0;
    MAGCheckNear(preferences.keepAliveLevelDB, MAGPreferencesMinimumLevelDB, 0.0,
                 @"keep-alive level is clamped to the documented minimum");
    preferences.keepAliveLevelDB = 0.0;
    MAGCheckNear(preferences.keepAliveLevelDB, MAGPreferencesMaximumLevelDB, 0.0,
                 @"keep-alive level is clamped to the documented maximum");
    preferences.keepAliveLevelDB = original;
}

int main(void) {
    @autoreleasepool {
        printf("== Soramimi logic tests ==\n");
        MAGTestLevelConversion();
        MAGTestSignalLevelsAndDCOffset();
        MAGTestFadeOutAndSilence();
        MAGTestBlockingPolicy();
        MAGTestPreferenceBounds();
        printf("== %d checks, %d failure(s) ==\n", gChecks, gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
