//
//  MAGSignalControl.m
//  Soramimi
//

#import "MAGSignalControl.h"

void MAGSignalControlInit(MAGSignalControl *control, double levelDB, bool active) {
    if (control == NULL) {
        return;
    }
    atomic_store_explicit(&control->levelDB, levelDB, memory_order_relaxed);
    atomic_store_explicit(&control->active, active, memory_order_relaxed);
    control->appliedLevelDB = levelDB;
    control->appliedActive = false;
    control->hasApplied = false;
}

void MAGSignalControlSetLevelDB(MAGSignalControl *control, double levelDB) {
    if (control == NULL) {
        return;
    }
    atomic_store_explicit(&control->levelDB, levelDB, memory_order_relaxed);
}

void MAGSignalControlSetActive(MAGSignalControl *control, bool active) {
    if (control == NULL) {
        return;
    }
    atomic_store_explicit(&control->active, active, memory_order_relaxed);
}

void MAGSignalControlApply(MAGSignalControl *control, MAGSignalGenerator *generator) {
    if (control == NULL || generator == NULL) {
        return;
    }
    double levelDB = atomic_load_explicit(&control->levelDB, memory_order_relaxed);
    bool active = atomic_load_explicit(&control->active, memory_order_relaxed);

    if (!control->hasApplied || levelDB != control->appliedLevelDB) {
        MAGSignalGeneratorSetLevelDB(generator, levelDB);
        control->appliedLevelDB = levelDB;
    }
    if (!control->hasApplied || active != control->appliedActive) {
        MAGSignalGeneratorSetActive(generator, active);
        control->appliedActive = active;
    }
    control->hasApplied = true;
}
