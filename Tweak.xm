#import <substrate.h>
#import <sys/sysctl.h>
#import <version.h>
#import "Header.h"

extern "C" BOOL UseVP9();
extern "C" BOOL AllVP9();

// Remove any <= 1080p VP9 formats if AllVP9 is disabled
NSArray <MLFormat *> *filteredFormats(NSArray <MLFormat *> *formats) {
    if (AllVP9()) return formats;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(MLFormat *format, NSDictionary *bindings) {
        return [format height] > 1080 || [[format MIMEType] videoCodec] != 'vp09';
    }];
    return [formats filteredArrayUsingPredicate:predicate];
}

static void hookFormats(MLABRPolicy *self) {
    YTIHamplayerConfig *config = [self valueForKey:@"_hamplayerConfig"];
    if ([config.videoAbrConfig respondsToSelector:@selector(setPreferSoftwareHdrOverHardwareSdr:)])
        config.videoAbrConfig.preferSoftwareHdrOverHardwareSdr = YES;
    if ([config respondsToSelector:@selector(setDisableResolveOverlappingQualitiesByCodec:)])
        config.disableResolveOverlappingQualitiesByCodec = NO;
    YTIHamplayerStreamFilter *filter = config.streamFilter;
    filter.enableVideoCodecSplicing = YES;
    filter.av1.maxArea = MAX_PIXELS;
    filter.av1.maxFps = MAX_FPS;
    filter.vp9.maxArea = MAX_PIXELS;
    filter.vp9.maxFps = MAX_FPS;
}

%hook MLHAMPlayerItem

- (void)load {
    MLInnerTubePlayerConfig *config = [self valueForKey:@"_config"];
    YTIMediaCommonConfig *mediaCommonConfig = config.mediaCommonConfig;
    mediaCommonConfig.useServerDrivenAbr = NO;
    %orig;
}

%end

%hook MLABRPolicy

- (void)setFormats:(NSArray *)formats {
    hookFormats(self);
    %orig(filteredFormats(formats));
}

%end

%hook MLABRPolicyOld

- (void)setFormats:(NSArray *)formats {
    hookFormats(self);
    %orig(filteredFormats(formats));
}

%end

%hook MLABRPolicyNew

- (void)setFormats:(NSArray *)formats {
    hookFormats(self);
    %orig(filteredFormats(formats));
}

%end

%hook YTHotConfig

- (BOOL)iosPlayerClientSharedConfigDisableServerDrivenAbr {
    return YES;
}

%end

%hook HAMDefaultABRPolicy

- (void)setFormats:(NSArray *)formats {
    @try {
        HAMDefaultABRPolicyConfig config = MSHookIvar<HAMDefaultABRPolicyConfig>(self, "_config");
        config.softwareAV1Filter.maxArea = MAX_PIXELS;
        config.softwareAV1Filter.maxFPS = MAX_FPS;
        config.softwareVP9Filter.maxArea = MAX_PIXELS;
        config.softwareVP9Filter.maxFPS = MAX_FPS;
        MSHookIvar<HAMDefaultABRPolicyConfig>(self, "_config") = config;
    } @catch (id ex) {}
    %orig;
}

%end

%hook MLHLSStreamSelector

- (void)didLoadHLSMasterPlaylist:(id)arg1 {
    %orig;
    MLHLSMasterPlaylist *playlist = [self valueForKey:@"_completeMasterPlaylist"];
    NSArray *remotePlaylists = [playlist remotePlaylists];
    [[self delegate] streamSelectorHasSelectableVideoFormats:remotePlaylists];
}

%end

%group Spoofing

%hook UIDevice

- (NSString *)systemVersion {
    return @"15.8.3";
}

%end

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion version;
    version.majorVersion = 15;
    version.minorVersion = 8;
    version.patchVersion = 3;
    return version;
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
    if (!UseVP9()) return;
    %init;
    if (!IS_IOS_OR_NEWER(iOS_15_0)) {
        %init(Spoofing);
    }
}
