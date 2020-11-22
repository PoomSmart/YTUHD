#import <sys/sysctl.h>
#import "Header.h"

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
    return @"14.2";
}

%end

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion version;
    version.majorVersion = 14;
    version.minorVersion = 2;
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
    return %orig(name, oldp, oldlenp, newp, newlen);
}

%ctor {
    %init;
}
