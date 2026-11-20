//
//  MAGSignalGenerator.h
//  Soramimi
//
//  Allocation-free continuous signal generator. The generated waveform is a pure
//  sine wave (no DC component) whose amplitude is the requested dBFS level.
//  A 150 ms linear amplitude ramp is applied whenever the generator is switched
//  on/off (or the level is changed) so no click or pop can be produced.
//
//  Everything in this file is plain C inside a struct: no Foundation calls and no
//  memory allocation happen on the audio callback thread after init.
//

#import <Foundation/Foundation.h>
#import <stdbool.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

extern const double MAGSignalRampSeconds; // 0.150 s

typedef struct MAGSignalGenerator {
    double sampleRate;
    double frequencyHz;
    double phase;        // current position in table units [0, tableSize)
    double phaseStep;    // table units per sample
    double levelAmplitude; // configured linear amplitude for "active"
    double targetAmplitude;
    double currentAmplitude;
    double rampIncrement; // signed amplitude change per sample
    uint32_t tableSize;
    float *table;
    bool active;
    bool initialized;
} MAGSignalGenerator;

/// dBFS <-> linear amplitude helpers (0 dBFS == 1.0).
double MAGSignalDBToLinear(double db);
double MAGSignalLinearToDB(double linear);

/// Allocates the sine table. Returns false on invalid arguments or allocation failure.
bool MAGSignalGeneratorInit(MAGSignalGenerator *generator, double sampleRate, double frequencyHz);
void MAGSignalGeneratorDispose(MAGSignalGenerator *generator);

/// Changes the configured level. If active, the amplitude ramps to the new value.
void MAGSignalGeneratorSetLevelDB(MAGSignalGenerator *generator, double levelDB);

/// Switches the signal on (ramps up) or off (ramps down to exact digital silence).
void MAGSignalGeneratorSetActive(MAGSignalGenerator *generator, bool active);

/// Fills an interleaved stereo float32 buffer. The same mono signal is written to
/// both channels, which keeps DC at zero on every channel.
void MAGSignalGeneratorFill(MAGSignalGenerator *generator, float *stereoInterleaved, uint32_t frames);

/// True once a fade-out has fully reached digital silence.
bool MAGSignalGeneratorIsSilent(const MAGSignalGenerator *generator);

NS_ASSUME_NONNULL_END
