#ifndef CAFFEINE_SPI_H
#define CAFFEINE_SPI_H

#include <CoreFoundation/CFBase.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef CF_ENUM(int32_t, CaffeineSPIResult) {
    CaffeineSPIResultSuccess = 0,
    /// IOKit or the required private power-management SPI is unavailable.
    CaffeineSPIResultUnsupported = 1,
    /// The caller is not running with the root privileges required by IOKit.
    CaffeineSPIResultNotPrivileged = 2,
    /// IOKit resolved the operation but could not persist the requested value.
    CaffeineSPIResultFailure = 3,
    /// A marker mutation partially completed and requires a safety repair.
    CaffeineSPIResultCleanupPending = 4,
};

/// Reads the private IOKit `SleepDisabled` system power setting.
///
/// A missing dictionary entry is the system default and is reported as false.
/// The private symbol is resolved at runtime.
CaffeineSPIResult CaffeineCopySleepDisabled(bool *disabled);

/// Sets the private IOKit `SleepDisabled` system power setting.
///
/// The private symbol is resolved at runtime so an OS that removes it produces
/// `CaffeineSPIResultUnsupported` instead of preventing the helper from
/// launching.
CaffeineSPIResult CaffeineSetSleepDisabled(bool disabled);

/// Root-only durable marker used to distinguish Caffeine ownership from an
/// unrelated user's or tool's global SleepDisabled setting.
#define CAFFEINE_SLEEP_DISABLED_OWNERSHIP_MARKER \
    "/var/db/tech.46h.caffeine/SleepDisabledOwned"

/// Reads and validates Caffeine's durable ownership marker and its saved value.
///
/// Version 1 markers are accepted as `priorDisabled=false`, which is the value
/// they historically restored.
CaffeineSPIResult CaffeineSleepDisabledOwnershipStatus(
    bool *owned,
    bool *priorDisabled
);

/// Atomically writes and durably flushes Caffeine's ownership marker.
///
/// This must succeed before setting SleepDisabled=true.
CaffeineSPIResult CaffeineEstablishSleepDisabledOwnership(
    bool priorDisabled
);

/// Durably removes Caffeine's ownership marker.
///
/// This must only be called after the marker's saved prior value is restored.
CaffeineSPIResult CaffeineRelinquishSleepDisabledOwnership(void);

#ifdef __cplusplus
}
#endif

#endif
