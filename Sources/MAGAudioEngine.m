//
//  MAGAudioEngine.m
//  Soramimi
//

#import "MAGAudioEngine.h"

#import "MAGSignalControl.h"
#import "MAGSignalGenerator.h"
#import "MAGPreferences.h"

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

NSString *const MAGAudioEngineStateDidChangeNotification = @"MAGAudioEngineStateDidChangeNotification";
NSString *const MAGAudioDefaultDeviceDidChangeNotification = @"MAGAudioDefaultDeviceDidChangeNotification";

NSString *const MAGAudioInfoKeyName = @"name";
NSString *const MAGAudioInfoKeyTransport = @"transport";
NSString *const MAGAudioInfoKeyIsBluetooth = @"isBluetooth";
NSString *const MAGAudioInfoKeySampleRate = @"sampleRate";
NSString *const MAGAudioInfoKeyBitsPerChannel = @"bitsPerChannel";
NSString *const MAGAudioInfoKeyIsFloat = @"isFloat";
NSString *const MAGAudioInfoKeyQuantizationFloorDB = @"quantizationFloorDB";
NSString *const MAGAudioInfoKeyHasDevice = @"hasDevice";

/// Keep-alive signal design adapted from the speaker-awake approach (MIT,
/// https://github.com/subhande/speaker-awake): a seamlessly looping short buffer
/// instead of an open-ended stream. 0.1 s at 440 Hz contains exactly 44 full
/// cycles, so the loop point is sample-continuous for any device sample rate.
/// The signal is continuous (not a periodic burst); at the default -100 dBFS it
/// is inaudible but keeps the audio pipeline and the speaker's input active.
static const double MAGSignalFrequencyHz = 440.0;
static const NSTimeInterval MAGSignalLoopSeconds = 0.1;
enum { MAGAudioBufferCount = 3 };
/// Periodic wake ping. Marshall (and some other) speakers enter standby when
/// their input sees "no sound" for N minutes; a continuous -100 dBFS stream is
/// treated as silence. A short 16 kHz burst every few minutes gives the speaker
/// a real signal to reset its standby timer while staying above most adults'
/// hearing range. Defaults: every 5 min, 0.5 s, -18 dBFS.
static const double MAGWakePingFrequencyHz = 16000.0;
static const double MAGWakePingDurationSeconds = 0.5;
static const double MAGWakePingDefaultLevelDB = -18.0;
static const double MAGWakePingDefaultIntervalSeconds = 300.0;
static const NSTimeInterval MAGAudioRebuildDebounce = 0.25;
static const NSTimeInterval MAGAudioFadeOutDuration = 0.22;
static const double MAGAudioInitialRetryDelay = 0.5;
static const double MAGAudioMaximumRetryDelay = 30.0;

#pragma mark - Core Audio helpers

static AudioDeviceID MAGDefaultOutputDevice(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = (UInt32)sizeof(device);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    return status == noErr ? device : kAudioObjectUnknown;
}

static NSString *MAGCopyDeviceStringProperty(AudioDeviceID device, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    UInt32 size = (UInt32)sizeof(value);
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr || value == NULL) {
        return nil;
    }
    NSString *result = [(__bridge NSString *)value copy];
    CFRelease(value);
    return result;
}

static BOOL MAGCopyDeviceUInt32Property(AudioDeviceID device, AudioObjectPropertySelector selector, UInt32 *outValue) {
    UInt32 value = 0;
    UInt32 size = (UInt32)sizeof(value);
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) {
        return NO;
    }
    if (outValue != NULL) {
        *outValue = value;
    }
    return YES;
}

static double MAGDeviceNominalSampleRate(AudioDeviceID device) {
    Float64 value = 0.0;
    UInt32 size = (UInt32)sizeof(value);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyNominalSampleRate,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) {
        return 0.0;
    }
    return (double)value;
}

static BOOL MAGDeviceOutputFormat(AudioDeviceID device, UInt32 *outBits, BOOL *outIsFloat, UInt32 *outChannels) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = (UInt32)sizeof(format);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamFormat,
                                          kAudioObjectPropertyScopeOutput,
                                          kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &format) != noErr) {
        return NO;
    }
    if (outBits != NULL) {
        *outBits = format.mBitsPerChannel;
    }
    if (outIsFloat != NULL) {
        *outIsFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    }
    if (outChannels != NULL) {
        *outChannels = format.mChannelsPerFrame;
    }
    return YES;
}

static NSString *MAGTransportDisplayName(UInt32 transport) {
    switch (transport) {
        case kAudioDeviceTransportTypeBluetooth:
            return @"Bluetooth";
        case kAudioDeviceTransportTypeBluetoothLE:
            return @"Bluetooth LE";
        case kAudioDeviceTransportTypeBuiltIn:
            return @"Built-in";
        case kAudioDeviceTransportTypeUSB:
            return @"USB";
        case kAudioDeviceTransportTypeHDMI:
            return @"HDMI";
        case kAudioDeviceTransportTypeDisplayPort:
            return @"DisplayPort";
        case kAudioDeviceTransportTypeAirPlay:
            return @"AirPlay";
        case kAudioDeviceTransportTypeVirtual:
            return @"Virtual";
        case kAudioDeviceTransportTypeAggregate:
            return @"Aggregate";
        case kAudioDeviceTransportTypePCI:
            return @"PCI";
        case kAudioDeviceTransportTypeFireWire:
            return @"FireWire";
        default:
            return @"Unknown";
    }
}

static BOOL MAGTransportIsBluetooth(UInt32 transport) {
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE;
}

static double MAGQuantizationFloorDB(UInt32 bits, BOOL isFloat) {
    if (isFloat) {
        return -INFINITY; // float output path does not quantize the signal to integer steps
    }
    if (bits < 8 || bits > 64) {
        return NAN;
    }
    return 20.0 * log10(1.0 / (double)(1LL << (bits - 1)));
}

#pragma mark - Audio callback context

static void MAGAudioQueueOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);

typedef struct MAGAudioCallbackContext {
    MAGSignalGenerator generator;
    MAGSignalControl control;
    MAGSignalGenerator pingGenerator;
    _Atomic(bool) pingRequested;
    _Atomic(double) pingLevelDB;
    bool pingActive;
    UInt32 pingFramesRemaining;
    double pingSampleRate;
} MAGAudioCallbackContext;

/// AudioQueue render callback. Runs on an AudioQueue-owned thread; it only writes
/// into the provided buffer and must never allocate, lock or call AppKit.
static void MAGAudioQueueOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    MAGAudioCallbackContext *context = (MAGAudioCallbackContext *)inUserData;
    if (context != NULL && context->generator.initialized) {
        UInt32 frames = inBuffer->mAudioDataBytesCapacity / (UInt32)(sizeof(float) * 2);
        float *destination = (float *)inBuffer->mAudioData;

        // A wake ping temporarily takes over the output. The generator's own
        // 150 ms ramp-fade keeps start/end click-free and the switch sample-safe.
        bool pingRequested = atomic_exchange_explicit(&context->pingRequested, false, memory_order_relaxed);
        if (pingRequested && !context->pingActive) {
            double levelDB = atomic_load_explicit(&context->pingLevelDB, memory_order_relaxed);
            MAGSignalGeneratorSetLevelDB(&context->pingGenerator, levelDB);
            MAGSignalGeneratorSetActive(&context->pingGenerator, true);
            context->pingActive = true;
            context->pingFramesRemaining = (UInt32)llround(MAGWakePingDurationSeconds * context->pingSampleRate);
        }
        if (context->pingActive) {
            MAGSignalGeneratorFill(&context->pingGenerator, destination, frames);
            if (context->pingFramesRemaining > 0) {
                if (frames >= context->pingFramesRemaining) {
                    context->pingFramesRemaining = 0;
                    MAGSignalGeneratorSetActive(&context->pingGenerator, false);
                } else {
                    context->pingFramesRemaining -= frames;
                }
            } else if (MAGSignalGeneratorIsSilent(&context->pingGenerator)) {
                context->pingActive = false;
            }
        } else {
            // The render thread is the only thread that mutates the generator; the
            // UI thread communicates through MAGSignalControl's atomics.
            MAGSignalControlApply(&context->control, &context->generator);
            MAGSignalGeneratorFill(&context->generator, destination, frames);
        }
    } else {
        memset(inBuffer->mAudioData, 0, inBuffer->mAudioDataBytesCapacity);
    }
    inBuffer->mAudioDataByteSize = inBuffer->mAudioDataBytesCapacity;
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

#pragma mark - Engine

typedef struct MAGDeviceSnapshot {
    AudioDeviceID deviceID;
    BOOL hasDevice;
    BOOL isBluetooth;
    UInt32 bitsPerChannel;
    BOOL isFloat;
    double sampleRate;
    char transport[64];
} MAGDeviceSnapshot;

@interface MAGAudioEngine () {
    AudioQueueRef _queue;
    AudioQueueBufferRef _buffers[MAGAudioBufferCount];
    MAGAudioCallbackContext *_callbackContext;
    MAGDeviceSnapshot _lastSnapshot;
    AudioObjectPropertyListenerBlock _systemListenerBlock;
    AudioObjectPropertyListenerBlock _deviceListenerBlock;
    BOOL _deviceListenersInstalled;
    AudioDeviceID _listenerDeviceID;
    BOOL _enabled;
    BOOL _running;
    BOOL _pausedForSleep;
    BOOL _intentionalStop;
    BOOL _rebuildScheduled;
    double _levelDB;
    double _retryDelay;
    NSUInteger _recoveryGeneration;
    NSString *_lastError;
    id _sleepObserver;
    id _wakeObserver;
    dispatch_source_t _wakePingTimer;
    BOOL _wakePingEnabled;
    double _wakePingIntervalSeconds;
    double _wakePingLevelDB;
    NSDate *_lastWakePingDate;
}

@end

@implementation MAGAudioEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        _levelDB = MAGPreferencesDefaultLevelDB;
        _retryDelay = MAGAudioInitialRetryDelay;
        _wakePingEnabled = YES;
        _wakePingIntervalSeconds = MAGWakePingDefaultIntervalSeconds;
        _wakePingLevelDB = MAGWakePingDefaultLevelDB;
        [self installSystemPropertyListener];
        [self installPowerObservers];
        [self refreshSnapshotAndNotifyIfChanged];
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

#pragma mark - Public state

- (BOOL)enabled {
    return _enabled;
}

- (BOOL)running {
    return _running;
}

- (BOOL)pausedForSleep {
    return _pausedForSleep;
}

- (NSString *)lastError {
    return _lastError;
}

- (BOOL)wakePingEnabled {
    return _wakePingEnabled;
}

- (double)wakePingIntervalSeconds {
    return _wakePingIntervalSeconds;
}

- (double)wakePingLevelDB {
    return _wakePingLevelDB;
}

- (NSDate *)lastWakePingDate {
    return _lastWakePingDate;
}

- (void)setWakePingEnabled:(BOOL)enabled {
    _wakePingEnabled = enabled;
    [self updateWakePingTimer];
    [self notifyStateChanged];
}

- (void)setWakePingIntervalSeconds:(double)seconds {
    _wakePingIntervalSeconds = MAX(60.0, MIN(1800.0, seconds));
    _lastWakePingDate = nil;
    [self updateWakePingTimer];
    [self notifyStateChanged];
}

- (void)setWakePingLevelDB:(double)levelDB {
    _wakePingLevelDB = MAX(-40.0, MIN(-6.0, levelDB));
    if (_callbackContext != NULL) {
        atomic_store_explicit(&_callbackContext->pingLevelDB, _wakePingLevelDB, memory_order_relaxed);
    }
    [self notifyStateChanged];
}

- (NSString *)wakePingSummary {
    if (!_wakePingEnabled) {
        return @"off";
    }
    NSString *interval;
    if (_wakePingIntervalSeconds >= 60.0) {
        interval = [NSString stringWithFormat:@"%.0f min", _wakePingIntervalSeconds / 60.0];
    } else {
        interval = [NSString stringWithFormat:@"%.0f s", _wakePingIntervalSeconds];
    }
    if (_lastWakePingDate != nil) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
        return [NSString stringWithFormat:@"every %@ (%@, last %@)", interval,
                                          [NSString stringWithFormat:@"%.0f dBFS", _wakePingLevelDB],
                                          [formatter stringFromDate:_lastWakePingDate]];
    }
    return [NSString stringWithFormat:@"every %@ (%.0f dBFS)", interval, _wakePingLevelDB];
}

- (void)setLevelDB:(double)levelDB {
    _levelDB = MAX(MAGPreferencesMinimumLevelDB, MIN(MAGPreferencesMaximumLevelDB, levelDB));
    if (_callbackContext != NULL) {
        MAGSignalControlSetLevelDB(&_callbackContext->control, _levelDB);
    }
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) {
        return;
    }
    _enabled = enabled;
    if (enabled) {
        _retryDelay = MAGAudioInitialRetryDelay;
        _recoveryGeneration++;
        [self attemptStart];
    } else {
        [self fadeOutAndStop];
    }
    [self notifyStateChanged];
}

- (void)shutdown {
    [self cancelWakePingTimer];
    [self stopQueueImmediately];
    _enabled = NO;
    [self removePowerObservers];
    if (_systemListenerBlock != nil) {
        AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
                                              kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, dispatch_get_main_queue(),
                                               _systemListenerBlock);
        _systemListenerBlock = nil;
    }
}

#pragma mark - Start / stop

- (BOOL)startQueueReturningError:(NSString *_Nullable *_Nullable)errorText {
    AudioDeviceID device = MAGDefaultOutputDevice();
    if (device == kAudioObjectUnknown) {
        if (errorText != NULL) {
            *errorText = @"No default audio output device";
        }
        return NO;
    }

    double sampleRate = MAGDeviceNominalSampleRate(device);
    if (!(sampleRate >= 8000.0 && sampleRate <= 768000.0)) {
        sampleRate = 44100.0;
    }

    MAGAudioCallbackContext *context = (MAGAudioCallbackContext *)calloc(1, sizeof(MAGAudioCallbackContext));
    if (context == NULL) {
        if (errorText != NULL) {
            *errorText = @"Out of memory preparing audio context";
        }
        return NO;
    }
    if (!MAGSignalGeneratorInit(&context->generator, sampleRate, MAGSignalFrequencyHz)) {
        free(context);
        if (errorText != NULL) {
            *errorText = @"Could not prepare signal generator";
        }
        return NO;
    }
    MAGSignalControlInit(&context->control, _levelDB, true);
    if (!MAGSignalGeneratorInit(&context->pingGenerator, sampleRate, MAGWakePingFrequencyHz)) {
        MAGSignalGeneratorDispose(&context->generator);
        free(context);
        if (errorText != NULL) {
            *errorText = @"Could not prepare wake-ping generator";
        }
        return NO;
    }
    context->pingSampleRate = sampleRate;
    atomic_store_explicit(&context->pingLevelDB, _wakePingLevelDB, memory_order_relaxed);
    atomic_store_explicit(&context->pingRequested, false, memory_order_relaxed);

    AudioStreamBasicDescription format = {0};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = sizeof(float) * 2;
    format.mBytesPerPacket = sizeof(float) * 2;

    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewOutput(&format, MAGAudioQueueOutputCallback, context, NULL, NULL, 0, &queue);
    if (status != noErr || queue == NULL) {
        MAGSignalGeneratorDispose(&context->pingGenerator);
        MAGSignalGeneratorDispose(&context->generator);
        free(context);
        if (errorText != NULL) {
            *errorText = [NSString stringWithFormat:@"AudioQueueNewOutput failed (%d)", (int)status];
        }
        return NO;
    }

    // Bind explicitly to the *current default* device. This never changes the system
    // default output device; it only tells the queue where to render shared audio.
    NSString *deviceUID = MAGCopyDeviceStringProperty(device, kAudioDevicePropertyDeviceUID);
    if (deviceUID.length > 0) {
        CFStringRef uid = (__bridge CFStringRef)deviceUID;
        AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, (UInt32)sizeof(uid));
    }

    // One seamless 0.1 s loop per buffer (44 cycles of 440 Hz at any sample rate),
    // matching the speaker-awake signal design. Three buffers give 300 ms of slack.
    UInt32 bufferFrames = (UInt32)llround(sampleRate * MAGSignalLoopSeconds);
    if (bufferFrames < 1024) {
        bufferFrames = 1024;
    }
    if (bufferFrames > 9600) {
        bufferFrames = 9600;
    }
    const UInt32 bufferBytes = bufferFrames * format.mBytesPerFrame;
    for (UInt32 i = 0; i < MAGAudioBufferCount; i++) {
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(queue, bufferBytes, &buffer);
        if (status != noErr || buffer == NULL) {
            for (UInt32 b = 0; b < MAGAudioBufferCount; b++) {
                _buffers[b] = NULL;
            }
            AudioQueueDispose(queue, true);
            MAGSignalGeneratorDispose(&context->pingGenerator);
            MAGSignalGeneratorDispose(&context->generator);
            free(context);
            if (errorText != NULL) {
                *errorText = [NSString stringWithFormat:@"AudioQueueAllocateBuffer failed (%d)", (int)status];
            }
            return NO;
        }
        _buffers[i] = buffer;
        MAGAudioQueueOutputCallback(context, queue, buffer);
    }

    status = AudioQueueStart(queue, NULL);
    if (status != noErr) {
        for (UInt32 b = 0; b < MAGAudioBufferCount; b++) {
            _buffers[b] = NULL;
        }
        AudioQueueDispose(queue, true);
        MAGSignalGeneratorDispose(&context->pingGenerator);
        MAGSignalGeneratorDispose(&context->generator);
        free(context);
        if (errorText != NULL) {
            *errorText = [NSString stringWithFormat:@"AudioQueueStart failed (%d)", (int)status];
        }
        return NO;
    }

    _queue = queue;
    _callbackContext = context;
    _running = YES;
    [self installQueueRunningListener];
    [self installDevicePropertyListenersForDevice:device];
    [self refreshSnapshotAndNotifyIfChanged];
    [self updateWakePingTimer];
    return YES;
}

- (void)attemptStart {
    if (!_enabled || _pausedForSleep) {
        return;
    }
    [self stopQueueImmediately];
    NSString *error = nil;
    if ([self startQueueReturningError:&error]) {
        _lastError = nil;
        _retryDelay = MAGAudioInitialRetryDelay;
        [self notifyStateChanged];
        return;
    }
    _running = NO;
    _lastError = error ?: @"Unknown audio error";
    [self notifyStateChanged];
    [self scheduleRecoveryAttempt];
}

- (void)scheduleRecoveryAttempt {
    double delay = _retryDelay;
    _retryDelay = MIN(_retryDelay * 2.0, MAGAudioMaximumRetryDelay);
    NSUInteger generation = ++_recoveryGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self == nil || generation != self->_recoveryGeneration) {
                           return;
                       }
                       if (!self->_enabled || self->_pausedForSleep) {
                           return;
                       }
                       [self attemptStart];
                   });
}

- (void)scheduleRebuildAfterDeviceChange {
    if (_rebuildScheduled) {
        return;
    }
    _rebuildScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAGAudioRebuildDebounce * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self == nil) {
                           return;
                       }
                       self->_rebuildScheduled = NO;
                       [self refreshSnapshotAndNotifyIfChanged];
                       if (!self->_enabled || self->_pausedForSleep) {
                           return;
                       }
                       self->_recoveryGeneration++;
                       self->_retryDelay = MAGAudioInitialRetryDelay;
                       [self attemptStart];
                   });
}

- (void)fadeOutAndStop {
    _recoveryGeneration++;
    [self cancelWakePingTimer];
    if (_queue == NULL || _callbackContext == NULL) {
        [self stopQueueImmediately];
        return;
    }
    MAGSignalControlSetActive(&_callbackContext->control, false);
    NSUInteger generation = ++_recoveryGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAGAudioFadeOutDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self == nil || generation != self->_recoveryGeneration) {
                           return;
                       }
                       [self stopQueueImmediately];
                   });
}

- (void)stopQueueImmediately {
    _intentionalStop = YES;
    [self cancelWakePingTimer];
    if (_queue != NULL) {
        [self removeQueueRunningListener];
        AudioQueueStop(_queue, true);
        AudioQueueDispose(_queue, true);
        _queue = NULL;
    }
    if (_callbackContext != NULL) {
        MAGSignalControlSetActive(&_callbackContext->control, false);
        MAGSignalGeneratorDispose(&_callbackContext->pingGenerator);
        MAGSignalGeneratorDispose(&_callbackContext->generator);
        free(_callbackContext);
        _callbackContext = NULL;
    }
    for (UInt32 i = 0; i < MAGAudioBufferCount; i++) {
        _buffers[i] = NULL;
    }
    [self removeDevicePropertyListeners];
    _running = NO;
    _intentionalStop = NO;
}

- (void)cancelWakePingTimer {
    if (_wakePingTimer != nil) {
        dispatch_source_cancel(_wakePingTimer);
        _wakePingTimer = nil;
    }
}

- (void)updateWakePingTimer {
    [self cancelWakePingTimer];
    if (!_enabled || _pausedForSleep || !_wakePingEnabled || _callbackContext == NULL) {
        return;
    }
    double interval = MAX(60.0, _wakePingIntervalSeconds);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    if (timer == NULL) {
        return;
    }
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(interval * (double)NSEC_PER_SEC),
                              (uint64_t)(2.0 * (double)NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || !self->_enabled || self->_pausedForSleep || self->_callbackContext == NULL) {
            return;
        }
        self->_lastWakePingDate = [NSDate date];
        atomic_store_explicit(&self->_callbackContext->pingRequested, true, memory_order_relaxed);
        if (getenv("MAG_WAKE_PING_LOG") != NULL) {
            fprintf(stderr, "MAG_WAKE_PING level=%.0f dBFS interval=%.0f s\n",
                    self->_wakePingLevelDB, self->_wakePingIntervalSeconds);
            fflush(stderr);
        }
        [self notifyStateChanged];
    });
    _wakePingTimer = timer;
    dispatch_resume(timer);
}

#pragma mark - Core Audio listeners

- (void)installSystemPropertyListener {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    __weak typeof(self) weakSelf = self;
    _systemListenerBlock = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
        (void)inNumberAddresses;
        (void)inAddresses;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) {
                return;
            }
            [self scheduleRebuildAfterDeviceChange];
        });
    };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, dispatch_get_main_queue(),
                                        _systemListenerBlock);
}

- (void)installDevicePropertyListenersForDevice:(AudioDeviceID)device {
    if (_deviceListenersInstalled) {
        return;
    }
    AudioObjectPropertyAddress addresses[3] = {
        {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
    };
    __weak typeof(self) weakSelf = self;
    _deviceListenerBlock = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
        (void)inNumberAddresses;
        (void)inAddresses;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) {
                return;
            }
            [self scheduleRebuildAfterDeviceChange];
        });
    };
    for (size_t i = 0; i < sizeof(addresses) / sizeof(addresses[0]); i++) {
        AudioObjectAddPropertyListenerBlock(device, &addresses[i], dispatch_get_main_queue(), _deviceListenerBlock);
    }
    _deviceListenersInstalled = YES;
    _listenerDeviceID = device;
}

- (void)removeDevicePropertyListeners {
    if (!_deviceListenersInstalled) {
        return;
    }
    AudioDeviceID device = _listenerDeviceID;
    if (device != kAudioObjectUnknown) {
        AudioObjectPropertyAddress addresses[3] = {
            {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
        };
        for (size_t i = 0; i < sizeof(addresses) / sizeof(addresses[0]); i++) {
            AudioObjectRemovePropertyListenerBlock(device, &addresses[i], dispatch_get_main_queue(),
                                                   _deviceListenerBlock);
        }
    }
    _deviceListenerBlock = nil;
    _deviceListenersInstalled = NO;
    _listenerDeviceID = kAudioObjectUnknown;
}

static void MAGAudioQueueRunningListener(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID) {
    if (inID != kAudioQueueProperty_IsRunning) {
        return;
    }
    UInt32 isRunning = 0;
    UInt32 size = (UInt32)sizeof(isRunning);
    if (AudioQueueGetProperty(inAQ, kAudioQueueProperty_IsRunning, &isRunning, &size) != noErr) {
        return;
    }
    if (isRunning) {
        return;
    }
    MAGAudioEngine *engine = (__bridge MAGAudioEngine *)inUserData;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (engine == nil) {
            return;
        }
        [engine handleUnexpectedQueueStop];
    });
}

- (void)installQueueRunningListener {
    if (_queue == NULL) {
        return;
    }
    AudioQueueAddPropertyListener(_queue, kAudioQueueProperty_IsRunning, MAGAudioQueueRunningListener,
                                  (__bridge void *)self);
}

- (void)removeQueueRunningListener {
    if (_queue == NULL) {
        return;
    }
    AudioQueueRemovePropertyListener(_queue, kAudioQueueProperty_IsRunning, MAGAudioQueueRunningListener,
                                     (__bridge void *)self);
}

- (void)handleUnexpectedQueueStop {
    if (_intentionalStop || !_enabled || _pausedForSleep) {
        return;
    }
    _running = NO;
    _lastError = @"Audio output stopped unexpectedly";
    [self notifyStateChanged];
    [self scheduleRecoveryAttempt];
}

#pragma mark - Power

- (void)installPowerObservers {
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    __weak typeof(self) weakSelf = self;
    _sleepObserver = [center addObserverForName:NSWorkspaceWillSleepNotification
                                        object:nil
                                         queue:[NSOperationQueue mainQueue]
                                    usingBlock:^(NSNotification *note) {
                                        (void)note;
                                        __strong typeof(weakSelf) self = weakSelf;
                                        if (self == nil) {
                                            return;
                                        }
                                        self->_pausedForSleep = YES;
                                        self->_recoveryGeneration++;
                                        [self stopQueueImmediately];
                                        [self notifyStateChanged];
                                    }];
    _wakeObserver = [center addObserverForName:NSWorkspaceDidWakeNotification
                                       object:nil
                                        queue:[NSOperationQueue mainQueue]
                                   usingBlock:^(NSNotification *note) {
                                       (void)note;
                                       __strong typeof(weakSelf) self = weakSelf;
                                       if (self == nil) {
                                           return;
                                       }
                                       self->_pausedForSleep = NO;
                                       self->_retryDelay = MAGAudioInitialRetryDelay;
                                       self->_recoveryGeneration++;
                                       if (self->_enabled) {
                                           [self attemptStart];
                                       }
                                       [self notifyStateChanged];
                                   }];
}

- (void)removePowerObservers {
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    if (_sleepObserver != nil) {
        [center removeObserver:_sleepObserver];
        _sleepObserver = nil;
    }
    if (_wakeObserver != nil) {
        [center removeObserver:_wakeObserver];
        _wakeObserver = nil;
    }
}

#pragma mark - Device info

- (void)refreshSnapshotQuietly {
    MAGDeviceSnapshot snapshot = {0};
    snapshot.deviceID = MAGDefaultOutputDevice();
    snapshot.hasDevice = snapshot.deviceID != kAudioObjectUnknown;
    if (snapshot.hasDevice) {
        UInt32 transport = 0;
        if (MAGCopyDeviceUInt32Property(snapshot.deviceID, kAudioDevicePropertyTransportType, &transport)) {
            snapshot.isBluetooth = MAGTransportIsBluetooth(transport);
            NSString *transportName = MAGTransportDisplayName(transport);
            strlcpy(snapshot.transport, transportName.UTF8String ?: "Unknown", sizeof(snapshot.transport));
        }
        snapshot.sampleRate = MAGDeviceNominalSampleRate(snapshot.deviceID);
        UInt32 bits = 0;
        BOOL isFloat = NO;
        UInt32 channels = 0;
        if (MAGDeviceOutputFormat(snapshot.deviceID, &bits, &isFloat, &channels)) {
            snapshot.bitsPerChannel = bits;
            snapshot.isFloat = isFloat;
        }
    }

    _lastSnapshot = snapshot;
}

- (void)refreshSnapshotAndNotifyIfChanged {
    MAGDeviceSnapshot before = _lastSnapshot;
    [self refreshSnapshotQuietly];
    BOOL changed = before.deviceID != _lastSnapshot.deviceID ||
                   before.hasDevice != _lastSnapshot.hasDevice ||
                   before.isBluetooth != _lastSnapshot.isBluetooth ||
                   before.bitsPerChannel != _lastSnapshot.bitsPerChannel ||
                   before.isFloat != _lastSnapshot.isFloat ||
                   fabs(before.sampleRate - _lastSnapshot.sampleRate) > 1.0 ||
                   strcmp(before.transport, _lastSnapshot.transport) != 0;
    if (changed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:MAGAudioDefaultDeviceDidChangeNotification
                                                            object:self];
        [self notifyStateChanged];
    }
}

- (NSDictionary<NSString *, id> *)deviceInfo {
    // Refresh on demand so menu text is never stale; cheap property reads only.
    // This deliberately does not post change notifications (no re-entrant menu updates).
    [self refreshSnapshotQuietly];
    MAGDeviceSnapshot snapshot = _lastSnapshot;
    if (!snapshot.hasDevice) {
        return @{MAGAudioInfoKeyHasDevice : @NO};
    }
    // Device names are arbitrary Unicode; query them live as NSString instead of
    // copying into a fixed char buffer (which could split a UTF-8 sequence and
    // make stringWithUTF8String: return nil, crashing a dictionary literal).
    NSString *name = MAGCopyDeviceStringProperty(snapshot.deviceID, kAudioObjectPropertyName);
    if (name.length == 0) {
        name = @"Unknown Device";
    }
    NSString *transport = [NSString stringWithUTF8String:snapshot.transport];
    if (transport.length == 0) {
        transport = @"Unknown";
    }
    double floorDB = MAGQuantizationFloorDB(snapshot.bitsPerChannel, snapshot.isFloat);
    return @{
        MAGAudioInfoKeyHasDevice : @YES,
        MAGAudioInfoKeyName : name,
        MAGAudioInfoKeyTransport : transport,
        MAGAudioInfoKeyIsBluetooth : @(snapshot.isBluetooth),
        MAGAudioInfoKeySampleRate : @(snapshot.sampleRate),
        MAGAudioInfoKeyBitsPerChannel : @(snapshot.bitsPerChannel),
        MAGAudioInfoKeyIsFloat : @(snapshot.isFloat),
        MAGAudioInfoKeyQuantizationFloorDB : @(floorDB),
    };
}

- (NSString *)deviceSummary {
    NSDictionary *info = [self deviceInfo];
    if (![info[MAGAudioInfoKeyHasDevice] boolValue]) {
        return @"No output device";
    }
    NSString *name = info[MAGAudioInfoKeyName];
    NSString *transport = info[MAGAudioInfoKeyTransport];
    double sampleRate = [info[MAGAudioInfoKeySampleRate] doubleValue];
    NSString *rate = sampleRate >= 1000.0 ? [NSString stringWithFormat:@"%.1f kHz", sampleRate / 1000.0]
                                          : [NSString stringWithFormat:@"%.0f Hz", sampleRate];
    return [NSString stringWithFormat:@"%@ (%@, %@)", name, transport, rate];
}

- (NSString *)signalSummary {
    return [NSString stringWithFormat:@"%.0f dBFS / %.0f Hz sine", _levelDB, MAGSignalFrequencyHz];
}

- (NSString *)statusText {
    if (!_enabled) {
        return @"Stopped (off)";
    }
    if (_pausedForSleep) {
        return @"Paused during system sleep";
    }
    if (_lastError.length > 0) {
        return [NSString stringWithFormat:@"Error: %@", _lastError];
    }
    if (_running) {
        return @"Running";
    }
    return @"Starting…";
}

#pragma mark - Notifications

- (void)notifyStateChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:MAGAudioEngineStateDidChangeNotification
                                                        object:self];
}

@end
