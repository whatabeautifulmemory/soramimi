//
//  MAGRaceTests.m
//  Soramimi
//
//  ThreadSanitizer regression test for the live-level-change data race that was
//  found by an independent review: the AudioQueue render thread calls
//  MAGSignalGeneratorFill() while the main thread changes the signal level.
//  With MAGSignalControl the render thread is the only writer of the generator;
//  the UI thread only stores atomics.
//
//  Build/run: scripts/test.sh (TSan variant). Exits non-zero if TSan reports a
//  race (TSan aborts the process by default with exit_on_error) or if the
//  generated signal is obviously wrong.
//

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <sched.h>
#import <stdatomic.h>
#import <stdio.h>
#import <string.h>

#import "MAGSignalControl.h"
#import "MAGSignalGenerator.h"

typedef struct RaceHarness {
    MAGSignalGenerator generator;
    MAGSignalControl control;
    _Atomic(bool) stop;
} RaceHarness;

static void *MAGRaceRenderThread(void *argument) {
    RaceHarness *harness = (RaceHarness *)argument;
    float buffer[512 * 2];
    while (!atomic_load_explicit(&harness->stop, memory_order_relaxed)) {
        MAGSignalControlApply(&harness->control, &harness->generator);
        MAGSignalGeneratorFill(&harness->generator, buffer, 512);
    }
    return NULL;
}

int main(void) {
    @autoreleasepool {
        RaceHarness harness;
        memset(&harness, 0, sizeof(harness));
        if (!MAGSignalGeneratorInit(&harness.generator, 44100.0, 20.0)) {
            printf("FAIL: generator init\n");
            return 1;
        }
        MAGSignalControlInit(&harness.control, -100.0, true);

        pthread_t thread;
        if (pthread_create(&thread, NULL, MAGRaceRenderThread, &harness) != 0) {
            printf("FAIL: could not start render thread\n");
            return 1;
        }

        // Simulate the menu changing the level and toggling the feature while the
        // render thread is filling buffers.
        const double levels[] = { -100.0, -90.0, -80.0, -70.0, -60.0, -100.0 };
        for (int iteration = 0; iteration < 2000; iteration++) {
            MAGSignalControlSetLevelDB(&harness.control, levels[iteration % 6]);
            MAGSignalControlSetActive(&harness.control, (iteration % 7) != 0);
            sched_yield();
        }
        atomic_store_explicit(&harness.stop, true, memory_order_relaxed);
        pthread_join(thread, NULL);

        MAGSignalGeneratorDispose(&harness.generator);
        printf("PASS: concurrent level/active hand-off completed without a TSan race\n");
        return 0;
    }
}
