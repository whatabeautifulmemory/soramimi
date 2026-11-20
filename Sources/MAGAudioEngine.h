//
//  MAGAudioEngine.h
//  Soramimi
//
//  Continuous, shared-mode Core Audio output of a -100 dBFS (default) keep-alive
//  signal on the user's current default output device. The signal is a seamless
//  0.1 s / 440 Hz loop (44 cycles per loop), adapted from the speaker-awake design.
//
//  Design constraints (SRS FR-002..FR-005, NFR-003):
//    * Uses AudioQueue (AudioToolbox) only. No AVAudioEngine, no virtual driver,
//      no exclusive mode, no default-device change, no volume change.
//    * Never links MediaPlayer.framework, so no Now Playing session is ever
//      created and media keys keep controlling the previously active player.
//    * Follows default-output-device / sample-rate changes and system sleep/wake,
//      with capped exponential retry instead of a busy retry loop.
//    * No memory allocation on the audio callback thread.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread whenever running/error state changes.
extern NSString *const MAGAudioEngineStateDidChangeNotification;
/// Posted on the main thread when the default output device (or its format) changes.
extern NSString *const MAGAudioDefaultDeviceDidChangeNotification;

/// Keys of -deviceInfo.
extern NSString *const MAGAudioInfoKeyName;           // NSString, user-visible device name
extern NSString *const MAGAudioInfoKeyTransport;      // NSString, e.g. "Bluetooth"
extern NSString *const MAGAudioInfoKeyIsBluetooth;    // NSNumber (BOOL)
extern NSString *const MAGAudioInfoKeySampleRate;     // NSNumber (double)
extern NSString *const MAGAudioInfoKeyBitsPerChannel; // NSNumber (UInt32), 0 if unknown
extern NSString *const MAGAudioInfoKeyIsFloat;        // NSNumber (BOOL)
extern NSString *const MAGAudioInfoKeyQuantizationFloorDB; // NSNumber (double), NAN if unknown
extern NSString *const MAGAudioInfoKeyHasDevice;      // NSNumber (BOOL)

@interface MAGAudioEngine : NSObject

- (instancetype)init NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) BOOL pausedForSleep;
@property (nonatomic, readonly, copy, nullable) NSString *lastError;
@property (nonatomic) double levelDB;

/// Periodic "wake ping": a short 16 kHz burst that resets the standby timer of
/// speakers (e.g. Marshall) which ignore a continuous near-silent stream.
@property (nonatomic, readonly) BOOL wakePingEnabled;
@property (nonatomic, readonly) double wakePingIntervalSeconds;
@property (nonatomic, readonly) double wakePingLevelDB;
@property (nonatomic, readonly, copy, nullable) NSDate *lastWakePingDate;
- (void)setWakePingEnabled:(BOOL)enabled;
- (void)setWakePingIntervalSeconds:(double)seconds;
- (void)setWakePingLevelDB:(double)levelDB;
- (NSString *)wakePingSummary;

- (void)setEnabled:(BOOL)enabled;
- (void)shutdown;

- (NSDictionary<NSString *, id> *)deviceInfo;
- (NSString *)statusText;
- (NSString *)deviceSummary;
- (NSString *)signalSummary;

@end

NS_ASSUME_NONNULL_END
