#import <Foundation/Foundation.h>
#include <pthread/qos.h>
#include <sys/sysctl.h>

size_t dt_physical_cores(void) {
    int cores = 0;
    size_t size = sizeof(cores);
    return sysctlbyname("hw.physicalcpu", &cores, &size, NULL, 0) == 0 && cores > 0 ? (size_t)cores : 0;
}

size_t dt_scan_limit(size_t ceiling) {
    @autoreleasepool {
        NSProcessInfo *info = NSProcessInfo.processInfo;
        size_t limit = info.lowPowerModeEnabled ? MIN(ceiling, 2) : ceiling;
        switch (info.thermalState) {
            case NSProcessInfoThermalStateNominal: return limit;
            case NSProcessInfoThermalStateFair: return MIN(limit, (ceiling + 1) / 2);
            case NSProcessInfoThermalStateSerious: return MIN(limit, 2);
            default: return 1;
        }
    }
}

bool dt_scan_is_background(void) {
    qos_class_t qos = qos_class_self();
    return qos == QOS_CLASS_BACKGROUND || qos == QOS_CLASS_UTILITY;
}

void dt_scan_worker_start(bool background) {
    pthread_set_qos_class_self_np(background ? QOS_CLASS_UTILITY : QOS_CLASS_DEFAULT, 0);
}
