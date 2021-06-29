#import <sys/sysctl.h>
#import <version.h>
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

- (int)ml_manualQualitySelectionChosenResolution {
    return MAX_HEIGHT;
}

- (int)manualQualitySelectionPrecedingResolution {
    return MAX_HEIGHT;
}

- (int)ml_manualQualitySelectionPrecedingResolution {
    return MAX_HEIGHT;
}

%end

%hook MLManualFormatSelectionMetadata

- (int)stickyCeilingResolution {
    return MAX_HEIGHT;
}

%end

%group Spoofing

%hook UIDevice

- (NSString *)systemVersion {
    return @"14.6";
}

%end

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion version;
    version.majorVersion = 14;
    version.minorVersion = 6;
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

%end

%ctor {
    %init;
    if (!IS_IOS_OR_NEWER(iOS_14_0)) {
        %init(Spoofing);
    }
}
