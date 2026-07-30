#include "CaffeineSPI.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <sys/types.h>
#include <unistd.h>

#define CAFFEINE_OWNERSHIP_PARENT_DIRECTORY "/var/db"
#define CAFFEINE_OWNERSHIP_DIRECTORY_NAME "tech.46h.caffeine"
#define CAFFEINE_OWNERSHIP_MARKER_NAME "SleepDisabledOwned"

static const char ownershipMarkerV1Contents[] =
    "Caffeine SleepDisabled ownership v1\n";
static const char ownershipMarkerV2FalseContents[] =
    "Caffeine SleepDisabled ownership v2 prior=0\n";
static const char ownershipMarkerV2TrueContents[] =
    "Caffeine SleepDisabled ownership v2 prior=1\n";

#define CAFFEINE_MAX_OWNERSHIP_MARKER_SIZE \
    (sizeof(ownershipMarkerV2FalseContents) - 1)

static CaffeineSPIResult resultForErrno(int errorNumber) {
    if (errorNumber == EACCES || errorNumber == EPERM) {
        return CaffeineSPIResultNotPrivileged;
    }
    return CaffeineSPIResultFailure;
}

static int closePreservingErrno(int fileDescriptor) {
    int savedErrno = errno;
    int result = close(fileDescriptor);
    errno = savedErrno;
    return result;
}

static bool syncFileDescriptor(int fileDescriptor, bool fullSync) {
    int result;
    do {
        result = fsync(fileDescriptor);
    } while (result != 0 && errno == EINTR);
    if (result != 0) {
        return false;
    }

#ifdef F_FULLFSYNC
    if (fullSync) {
        do {
            result = fcntl(fileDescriptor, F_FULLFSYNC);
        } while (result != 0 && errno == EINTR);
        if (result != 0) {
            return false;
        }
    }
#else
    if (fullSync) {
        errno = ENOTSUP;
        return false;
    }
#endif

    return true;
}

static bool directoryMetadataIsTrusted(const struct stat *metadata) {
    return S_ISDIR(metadata->st_mode)
        && metadata->st_uid == 0
        && metadata->st_gid == 0
        && (metadata->st_mode & 07777) == 0700;
}

static bool markerMetadataIsTrusted(const struct stat *metadata) {
    return S_ISREG(metadata->st_mode)
        && metadata->st_uid == 0
        && metadata->st_gid == 0
        && (metadata->st_mode & 07777) == 0600
        && metadata->st_nlink == 1
        && metadata->st_size > 0
        && metadata->st_size
            <= (off_t)CAFFEINE_MAX_OWNERSHIP_MARKER_SIZE;
}

static CaffeineSPIResult openOwnershipDirectory(
    bool create,
    int *directoryFileDescriptor
) {
    int parentFileDescriptor = open(
        CAFFEINE_OWNERSHIP_PARENT_DIRECTORY,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    );
    if (parentFileDescriptor < 0) {
        return resultForErrno(errno);
    }

    bool created = false;
    if (create) {
        if (mkdirat(
                parentFileDescriptor,
                CAFFEINE_OWNERSHIP_DIRECTORY_NAME,
                0700
            ) == 0) {
            created = true;
        } else if (errno != EEXIST) {
            int savedErrno = errno;
            closePreservingErrno(parentFileDescriptor);
            return resultForErrno(savedErrno);
        }
    }

    int directory = openat(
        parentFileDescriptor,
        CAFFEINE_OWNERSHIP_DIRECTORY_NAME,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    );
    if (directory < 0) {
        int savedErrno = errno;
        closePreservingErrno(parentFileDescriptor);
        if (!create && savedErrno == ENOENT) {
            *directoryFileDescriptor = -1;
            return CaffeineSPIResultSuccess;
        }
        return resultForErrno(savedErrno);
    }

    if (created
        && (fchown(directory, 0, 0) != 0
            || fchmod(directory, 0700) != 0)) {
        int savedErrno = errno;
        closePreservingErrno(directory);
        closePreservingErrno(parentFileDescriptor);
        return resultForErrno(savedErrno);
    }

    struct stat metadata;
    if (fstat(directory, &metadata) != 0) {
        int savedErrno = errno;
        closePreservingErrno(directory);
        closePreservingErrno(parentFileDescriptor);
        return resultForErrno(savedErrno);
    }
    if (!directoryMetadataIsTrusted(&metadata)) {
        closePreservingErrno(directory);
        closePreservingErrno(parentFileDescriptor);
        return CaffeineSPIResultFailure;
    }

    // Sync every create attempt, including EEXIST retries. A previous launch
    // may have created the directory but failed before its parent entry became
    // durable.
    if (create && !syncFileDescriptor(parentFileDescriptor, false)) {
        int savedErrno = errno;
        closePreservingErrno(directory);
        closePreservingErrno(parentFileDescriptor);
        return resultForErrno(savedErrno);
    }

    closePreservingErrno(parentFileDescriptor);
    *directoryFileDescriptor = directory;
    return CaffeineSPIResultSuccess;
}

static CaffeineSPIResult markerStatusAt(
    int directoryFileDescriptor,
    bool *owned,
    bool *priorDisabled
) {
    int markerFileDescriptor = openat(
        directoryFileDescriptor,
        CAFFEINE_OWNERSHIP_MARKER_NAME,
        O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
    );
    if (markerFileDescriptor < 0) {
        if (errno == ENOENT) {
            *owned = false;
            *priorDisabled = false;
            return CaffeineSPIResultSuccess;
        }
        return resultForErrno(errno);
    }

    struct stat metadata;
    if (fstat(markerFileDescriptor, &metadata) != 0) {
        int savedErrno = errno;
        closePreservingErrno(markerFileDescriptor);
        return resultForErrno(savedErrno);
    }
    if (!markerMetadataIsTrusted(&metadata)) {
        closePreservingErrno(markerFileDescriptor);
        return CaffeineSPIResultFailure;
    }

    size_t expectedSize = (size_t)metadata.st_size;
    char contents[CAFFEINE_MAX_OWNERSHIP_MARKER_SIZE];
    size_t totalBytesRead = 0;
    while (totalBytesRead < expectedSize) {
        ssize_t bytesRead = read(
            markerFileDescriptor,
            contents + totalBytesRead,
            expectedSize - totalBytesRead
        );
        if (bytesRead > 0) {
            totalBytesRead += (size_t)bytesRead;
            continue;
        }
        if (bytesRead < 0 && errno == EINTR) {
            continue;
        }
        closePreservingErrno(markerFileDescriptor);
        return CaffeineSPIResultFailure;
    }

    closePreservingErrno(markerFileDescriptor);

    if (expectedSize == sizeof(ownershipMarkerV1Contents) - 1
        && memcmp(
            contents,
            ownershipMarkerV1Contents,
            expectedSize
        ) == 0) {
        // Version 1 did not preserve a prior value and always restored false.
        // Reading it into the version 2 model is its safe migration path.
        *owned = true;
        *priorDisabled = false;
        return CaffeineSPIResultSuccess;
    }
    if (expectedSize == sizeof(ownershipMarkerV2FalseContents) - 1
        && memcmp(
            contents,
            ownershipMarkerV2FalseContents,
            expectedSize
        ) == 0) {
        *owned = true;
        *priorDisabled = false;
        return CaffeineSPIResultSuccess;
    }
    if (expectedSize == sizeof(ownershipMarkerV2TrueContents) - 1
        && memcmp(
            contents,
            ownershipMarkerV2TrueContents,
            expectedSize
        ) == 0) {
        *owned = true;
        *priorDisabled = true;
        return CaffeineSPIResultSuccess;
    }

    return CaffeineSPIResultFailure;
}

CaffeineSPIResult CaffeineSleepDisabledOwnershipStatus(
    bool *owned,
    bool *priorDisabled
) {
    if (owned == NULL || priorDisabled == NULL) {
        return CaffeineSPIResultFailure;
    }
    *owned = false;
    *priorDisabled = false;

    int directoryFileDescriptor;
    CaffeineSPIResult result = openOwnershipDirectory(
        false,
        &directoryFileDescriptor
    );
    if (result != CaffeineSPIResultSuccess
        || directoryFileDescriptor < 0) {
        return result;
    }

    result = markerStatusAt(
        directoryFileDescriptor,
        owned,
        priorDisabled
    );
    if (result == CaffeineSPIResultSuccess
        && !*owned
        && !syncFileDescriptor(directoryFileDescriptor, false)) {
        // This may be a retry after an unlink whose directory flush failed.
        // Do not claim cleanup is durable until the retry flush succeeds.
        result = CaffeineSPIResultCleanupPending;
    }
    closePreservingErrno(directoryFileDescriptor);
    return result;
}

static CaffeineSPIResult rollbackOwnershipMarker(
    int directoryFileDescriptor,
    int originalError
) {
    bool removed = unlinkat(
        directoryFileDescriptor,
        CAFFEINE_OWNERSHIP_MARKER_NAME,
        0
    ) == 0;
    bool removalIsDurable = removed
        && syncFileDescriptor(directoryFileDescriptor, false);
    return removalIsDurable
        ? resultForErrno(originalError)
        : CaffeineSPIResultCleanupPending;
}

static CaffeineSPIResult writeOwnershipMarker(
    int directoryFileDescriptor,
    bool priorDisabled
) {
    const char *markerContents = priorDisabled
        ? ownershipMarkerV2TrueContents
        : ownershipMarkerV2FalseContents;
    size_t markerSize = priorDisabled
        ? sizeof(ownershipMarkerV2TrueContents) - 1
        : sizeof(ownershipMarkerV2FalseContents) - 1;
    char temporaryName[NAME_MAX];
    int markerFileDescriptor = -1;

    for (unsigned int attempt = 0; attempt < 8; attempt += 1) {
        int nameLength = snprintf(
            temporaryName,
            sizeof(temporaryName),
            "%s.tmp.%d.%08x",
            CAFFEINE_OWNERSHIP_MARKER_NAME,
            getpid(),
            arc4random()
        );
        if (nameLength < 0 || (size_t)nameLength >= sizeof(temporaryName)) {
            return CaffeineSPIResultFailure;
        }

        markerFileDescriptor = openat(
            directoryFileDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0600
        );
        if (markerFileDescriptor >= 0) {
            break;
        }
        if (errno != EEXIST) {
            return resultForErrno(errno);
        }
    }

    if (markerFileDescriptor < 0) {
        return CaffeineSPIResultFailure;
    }

    CaffeineSPIResult result = CaffeineSPIResultFailure;
    if (fchown(markerFileDescriptor, 0, 0) != 0
        || fchmod(markerFileDescriptor, 0600) != 0) {
        result = resultForErrno(errno);
        goto cleanup;
    }

    size_t totalBytesWritten = 0;
    while (totalBytesWritten < markerSize) {
        ssize_t bytesWritten = write(
            markerFileDescriptor,
            markerContents + totalBytesWritten,
            markerSize - totalBytesWritten
        );
        if (bytesWritten > 0) {
            totalBytesWritten += (size_t)bytesWritten;
            continue;
        }
        if (bytesWritten < 0 && errno == EINTR) {
            continue;
        }
        result = resultForErrno(errno);
        goto cleanup;
    }

    if (!syncFileDescriptor(markerFileDescriptor, true)) {
        result = resultForErrno(errno);
        goto cleanup;
    }

    if (renameatx_np(
            directoryFileDescriptor,
            temporaryName,
            directoryFileDescriptor,
            CAFFEINE_OWNERSHIP_MARKER_NAME,
            RENAME_EXCL
        ) != 0) {
        if (errno == EEXIST) {
            bool owned = false;
            bool existingPriorDisabled = false;
            result = markerStatusAt(
                directoryFileDescriptor,
                &owned,
                &existingPriorDisabled
            );
            if (result == CaffeineSPIResultSuccess && owned) {
                result = CaffeineSPIResultSuccess;
            }
        } else {
            result = resultForErrno(errno);
        }
        goto cleanup;
    }

    if (!syncFileDescriptor(directoryFileDescriptor, false)) {
        result = rollbackOwnershipMarker(
            directoryFileDescriptor,
            errno
        );
        goto cleanup;
    }

    // Keep the marker file open across rename. A full sync after the directory
    // entry flush is the final root-volume persistence barrier for both file
    // contents and the newly named entry.
    if (!syncFileDescriptor(markerFileDescriptor, true)) {
        result = rollbackOwnershipMarker(
            directoryFileDescriptor,
            errno
        );
        goto cleanup;
    }

    result = CaffeineSPIResultSuccess;

cleanup:
    if (markerFileDescriptor >= 0) {
        if (close(markerFileDescriptor) != 0
            && result == CaffeineSPIResultSuccess) {
            result = CaffeineSPIResultCleanupPending;
        }
    }
    // After a successful rename the temporary path is already absent.
    (void)unlinkat(directoryFileDescriptor, temporaryName, 0);
    return result;
}

CaffeineSPIResult CaffeineEstablishSleepDisabledOwnership(
    bool priorDisabled
) {
    bool owned = false;
    bool existingPriorDisabled = false;
    CaffeineSPIResult result = CaffeineSleepDisabledOwnershipStatus(
        &owned,
        &existingPriorDisabled
    );
    if (result != CaffeineSPIResultSuccess || owned) {
        return result;
    }

    int directoryFileDescriptor;
    result = openOwnershipDirectory(true, &directoryFileDescriptor);
    if (result != CaffeineSPIResultSuccess) {
        return result;
    }

    result = markerStatusAt(
        directoryFileDescriptor,
        &owned,
        &existingPriorDisabled
    );
    if (result == CaffeineSPIResultSuccess && !owned) {
        result = writeOwnershipMarker(
            directoryFileDescriptor,
            priorDisabled
        );
    }
    closePreservingErrno(directoryFileDescriptor);
    return result;
}

CaffeineSPIResult CaffeineRelinquishSleepDisabledOwnership(void) {
    int directoryFileDescriptor;
    CaffeineSPIResult result = openOwnershipDirectory(
        false,
        &directoryFileDescriptor
    );
    if (result != CaffeineSPIResultSuccess
        || directoryFileDescriptor < 0) {
        return result;
    }

    bool owned = false;
    bool priorDisabled = false;
    result = markerStatusAt(
        directoryFileDescriptor,
        &owned,
        &priorDisabled
    );
    if (result != CaffeineSPIResultSuccess) {
        closePreservingErrno(directoryFileDescriptor);
        return result;
    }
    if (!owned) {
        // A retry may observe the unlink even though its preceding directory
        // sync failed. Flush again before declaring the cleanup complete.
        if (!syncFileDescriptor(directoryFileDescriptor, false)) {
            closePreservingErrno(directoryFileDescriptor);
            return CaffeineSPIResultCleanupPending;
        }
        closePreservingErrno(directoryFileDescriptor);
        return CaffeineSPIResultSuccess;
    }

    if (unlinkat(
            directoryFileDescriptor,
            CAFFEINE_OWNERSHIP_MARKER_NAME,
            0
        ) != 0) {
        int savedErrno = errno;
        closePreservingErrno(directoryFileDescriptor);
        return resultForErrno(savedErrno);
    }
    if (!syncFileDescriptor(directoryFileDescriptor, false)) {
        closePreservingErrno(directoryFileDescriptor);
        return CaffeineSPIResultCleanupPending;
    }

    closePreservingErrno(directoryFileDescriptor);
    return CaffeineSPIResultSuccess;
}
