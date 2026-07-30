#include "CaffeineSPI.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

typedef IOReturn (*IOPMSetSystemPowerSettingFunction)(
    CFStringRef key,
    CFTypeRef value
);
typedef CFDictionaryRef (*IOPMCopySystemPowerSettingsFunction)(void);

static pthread_once_t resolverOnce = PTHREAD_ONCE_INIT;
static void *iokitHandle = NULL;
static IOPMSetSystemPowerSettingFunction setSystemPowerSetting = NULL;
static IOPMCopySystemPowerSettingsFunction copySystemPowerSettings = NULL;

static void resolveSystemPowerSettingFunctions(void) {
    iokitHandle = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        RTLD_LAZY | RTLD_LOCAL
    );
    if (iokitHandle == NULL) {
        return;
    }

    void *setSymbol = dlsym(iokitHandle, "IOPMSetSystemPowerSetting");
    if (setSymbol != NULL) {
        _Static_assert(
            sizeof(setSystemPowerSetting) == sizeof(setSymbol),
            "Function and data pointers must have the same size on macOS"
        );
        memcpy(&setSystemPowerSetting, &setSymbol, sizeof(setSymbol));
    }

    void *copySymbol = dlsym(iokitHandle, "IOPMCopySystemPowerSettings");
    if (copySymbol != NULL) {
        _Static_assert(
            sizeof(copySystemPowerSettings) == sizeof(copySymbol),
            "Function and data pointers must have the same size on macOS"
        );
        memcpy(&copySystemPowerSettings, &copySymbol, sizeof(copySymbol));
    }
}

CaffeineSPIResult CaffeineCopySleepDisabled(bool *disabled) {
    if (disabled == NULL) {
        return CaffeineSPIResultFailure;
    }
    *disabled = false;

    (void)pthread_once(&resolverOnce, resolveSystemPowerSettingFunctions);
    if (copySystemPowerSettings == NULL) {
        return CaffeineSPIResultUnsupported;
    }

    CFDictionaryRef settings = copySystemPowerSettings();
    if (settings == NULL) {
        // The SPI returns NULL when the system has no custom power settings.
        // In that default state SleepDisabled is absent and therefore false.
        return CaffeineSPIResultSuccess;
    }

    CaffeineSPIResult result = CaffeineSPIResultSuccess;
    CFTypeRef value = CFDictionaryGetValue(
        settings,
        CFSTR("SleepDisabled")
    );
    if (value == NULL) {
        *disabled = false;
    } else if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        *disabled = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int numericValue = 0;
        if (!CFNumberGetValue(
                (CFNumberRef)value,
                kCFNumberIntType,
                &numericValue
            )) {
            result = CaffeineSPIResultFailure;
        } else {
            *disabled = numericValue != 0;
        }
    } else {
        result = CaffeineSPIResultFailure;
    }

    CFRelease(settings);
    return result;
}

CaffeineSPIResult CaffeineSetSleepDisabled(bool disabled) {
    (void)pthread_once(&resolverOnce, resolveSystemPowerSettingFunctions);

    if (setSystemPowerSetting == NULL) {
        return CaffeineSPIResultUnsupported;
    }

    IOReturn result = setSystemPowerSetting(
        CFSTR("SleepDisabled"),
        disabled ? kCFBooleanTrue : kCFBooleanFalse
    );

    if (result == kIOReturnSuccess) {
        return CaffeineSPIResultSuccess;
    }
    if (result == kIOReturnNotPrivileged) {
        return CaffeineSPIResultNotPrivileged;
    }
    return CaffeineSPIResultFailure;
}
