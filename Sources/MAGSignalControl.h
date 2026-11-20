//
//  MAGSignalControl.h
//  Soramimi
//
//  Thread-safe hand-off of the keep-alive parameters from the main thread (UI) to
//  the AudioQueue render thread.
//
//  Why this exists: the render callback must never race with the menu actions.
//  All mutations of MAGSignalGenerator happen on the render thread inside
//  MAGSignalControlApply(); the main thread only stores plain values into two
//  C11 atomics. ThreadSanitizer regression test: tests/MAGRaceTests.m
//  (scripts/test.sh runs it when the toolchain supports TSan).
//

#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import <stdbool.h>

#import "MAGSignalGenerator.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct MAGSignalControl {
    _Atomic(double) levelDB;
    _Atomic(bool) active;
    // Render-thread private copies used to detect changes.
    double appliedLevelDB;
    bool appliedActive;
    bool hasApplied;
} MAGSignalControl;

void MAGSignalControlInit(MAGSignalControl *control, double levelDB, bool active);

/// May be called from any thread (normally the main thread).
void MAGSignalControlSetLevelDB(MAGSignalControl *control, double levelDB);
void MAGSignalControlSetActive(MAGSignalControl *control, bool active);

/// Must be called only from the thread that owns the generator (AudioQueue render
/// thread). Applies pending changes to the generator, if any.
void MAGSignalControlApply(MAGSignalControl *control, MAGSignalGenerator *generator);

NS_ASSUME_NONNULL_END
