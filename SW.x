#import <sys/sysctl.h>
#include <sys/utsname.h>

#define IOS_BUILD "18A5342e"
#define DEVICE_MACHINE "iPhone12,1"
#define DEVICE_MODEL "A2221"
#define MAX_FPS 60
#define MAX_HEIGHT 2160 // 4k
#define MAX_PIXELS 8294400 // 3840 x 2160 (4k)

%hook YTIHamplayerStreamFilter

- (BOOL)enableVideoCodecSplicing {
    return YES;
}

- (BOOL)hasVp9 {
    return YES;
}

%end

%hook YTIHamplayerSoftwareStreamFilter

- (int)maxFps {
    return MAX_FPS;
}

- (int)maxArea {
    return MAX_PIXELS;
}

%end

%hook YTSettings

- (bool)isWebMEnabled {
    return YES;
}

%end

%hook YTUserDefaults

- (int)manualQualitySelectionChosenResolution {
    return MAX_HEIGHT;
}

- (int)manualQualitySelectionPrecedingResolution {
    return MAX_HEIGHT;
}

%end

%hook MLManualFormatSelectionMetadata

- (int)stickyCeilingResolution {
    return MAX_HEIGHT;
}

%end

%hook UIDevice

- (NSString *)systemVersion {
    return @"14.0";
}

- (NSString *)model {
    return @(DEVICE_MACHINE);
}

%end

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion version;
    version.majorVersion = 14;
    version.minorVersion = 0;
    version.patchVersion = 0;
    return version;
}

%end

%hook YTVersionUtils

+ (NSString *)OSBuild {
    return @(IOS_BUILD);
}

%end

%hookf(int, sysctlbyname, const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (strcmp(name, "kern.osversion") == 0) {
        if (oldp)
            strcpy((char *)oldp, IOS_BUILD);
        *oldlenp = strlen(IOS_BUILD);
    }
    else if (strcmp(name, "hw.machine") == 0) {
        if (oldp)
            strcpy((char *)oldp, DEVICE_MACHINE);
        *oldlenp = strlen(DEVICE_MACHINE);
    }
    else if (strcmp(name, "hw.model") == 0) {
        if (oldp)
            strcpy((char *)oldp, DEVICE_MODEL);
        *oldlenp = strlen(DEVICE_MODEL);
    }
    return %orig(name, oldp, oldlenp, newp, newlen);
}

%hookf(int, uname, struct utsname *buf) {
    int r = %orig(buf);
    strcpy(buf->machine, DEVICE_MACHINE);
    return r;
}

%ctor {
    %init;
}
