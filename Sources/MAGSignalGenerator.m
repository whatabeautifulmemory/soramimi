//
//  MAGSignalGenerator.m
//  Soramimi
//

#import "MAGSignalGenerator.h"

#import <math.h>
#import <stdlib.h>
#import <string.h>

const double MAGSignalRampSeconds = 0.150;
static const double kTwoPi = 6.283185307179586476925286766559;

double MAGSignalDBToLinear(double db) {
    return pow(10.0, db / 20.0);
}

double MAGSignalLinearToDB(double linear) {
    if (linear <= 0.0) {
        return -INFINITY;
    }
    return 20.0 * log10(linear);
}

bool MAGSignalGeneratorInit(MAGSignalGenerator *generator, double sampleRate, double frequencyHz) {
    if (generator == NULL || sampleRate < 8000.0 || sampleRate > 768000.0 || frequencyHz <= 0.0) {
        return false;
    }
    memset(generator, 0, sizeof(*generator));
    generator->sampleRate = sampleRate;
    generator->frequencyHz = frequencyHz;
    generator->tableSize = 4096;
    generator->phaseStep = frequencyHz * (double)generator->tableSize / sampleRate;
    generator->table = (float *)calloc(generator->tableSize, sizeof(float));
    if (generator->table == NULL) {
        return false;
    }
    for (uint32_t i = 0; i < generator->tableSize; i++) {
        generator->table[i] = (float)sin(kTwoPi * (double)i / (double)generator->tableSize);
    }
    generator->initialized = true;
    return true;
}

void MAGSignalGeneratorDispose(MAGSignalGenerator *generator) {
    if (generator == NULL) {
        return;
    }
    free(generator->table);
    generator->table = NULL;
    generator->initialized = false;
}

void MAGSignalGeneratorSetLevelDB(MAGSignalGenerator *generator, double levelDB) {
    if (generator == NULL || !generator->initialized) {
        return;
    }
    generator->levelAmplitude = MAGSignalDBToLinear(levelDB);
    if (generator->active) {
        generator->targetAmplitude = generator->levelAmplitude;
        double rampSamples = MAGSignalRampSeconds * generator->sampleRate;
        generator->rampIncrement = (generator->targetAmplitude - generator->currentAmplitude) / rampSamples;
    }
}

void MAGSignalGeneratorSetActive(MAGSignalGenerator *generator, bool active) {
    if (generator == NULL || !generator->initialized) {
        return;
    }
    generator->active = active;
    generator->targetAmplitude = active ? generator->levelAmplitude : 0.0;
    double rampSamples = MAGSignalRampSeconds * generator->sampleRate;
    generator->rampIncrement = (generator->targetAmplitude - generator->currentAmplitude) / rampSamples;
}

void MAGSignalGeneratorFill(MAGSignalGenerator *generator, float *stereoInterleaved, uint32_t frames) {
    if (generator == NULL || stereoInterleaved == NULL) {
        return;
    }
    if (!generator->initialized || frames == 0) {
        memset(stereoInterleaved, 0, (size_t)frames * 2 * sizeof(float));
        return;
    }
    if (generator->currentAmplitude == 0.0 && generator->targetAmplitude == 0.0) {
        memset(stereoInterleaved, 0, (size_t)frames * 2 * sizeof(float));
        return;
    }

    const float *table = generator->table;
    const uint32_t mask = generator->tableSize - 1;
    double phase = generator->phase;
    double phaseStep = generator->phaseStep;
    double amplitude = generator->currentAmplitude;
    const double target = generator->targetAmplitude;
    double rampIncrement = generator->rampIncrement;
    const bool ramping = (amplitude != target);

    for (uint32_t frame = 0; frame < frames; frame++) {
        if (ramping) {
            if (fabs(target - amplitude) <= fabs(rampIncrement)) {
                amplitude = target;
            } else {
                amplitude += rampIncrement;
            }
        }
        uint32_t index = (uint32_t)phase;
        double fraction = phase - (double)index;
        float a = table[index & mask];
        float b = table[(index + 1) & mask];
        float sample = (float)((a + (b - a) * fraction) * amplitude);
        stereoInterleaved[frame * 2] = sample;
        stereoInterleaved[frame * 2 + 1] = sample;
        phase += phaseStep;
        if (phase >= (double)generator->tableSize) {
            phase -= (double)generator->tableSize;
        }
    }

    generator->phase = phase;
    generator->currentAmplitude = amplitude;
    if (ramping && amplitude == target) {
        // Snap to exact target so repeated comparisons settle.
        generator->currentAmplitude = target;
        generator->rampIncrement = 0.0;
    }
}

bool MAGSignalGeneratorIsSilent(const MAGSignalGenerator *generator) {
    if (generator == NULL || !generator->initialized) {
        return true;
    }
    return generator->currentAmplitude == 0.0 && generator->targetAmplitude == 0.0;
}
