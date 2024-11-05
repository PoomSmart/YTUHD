#import <substrate.h>
#import "Header.h"
#import <VideoToolbox/VideoToolbox.h>

BOOL UseVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UseVP9Key];
}

BOOL AllVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:AllVP9Key];
}

BOOL VP9DecodeSupported() {
    return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
}
BOOL AV1DecodeSupported() {
    return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
}

// Remove any <= 1080p VP9/AV1 formats if AllVP9 is disabled
NSArray <MLFormat *> *filteredFormats(NSArray <MLFormat *> *formats) {
    if (AllVP9()) return formats;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(MLFormat *format, NSDictionary *bindings) {
        BOOL keep = [[format MIMEType] videoCodec] == 'vp09';
        if (AV1DecodeSupported() && !VP9DecodeSupported()) {
            keep = keep || [[format MIMEType] videoCodec] == 'av01';
        }
        return [format height] > 1080 || !keep;
    }];
    return [formats filteredArrayUsingPredicate:predicate];
}

%hook YTIMediaCommonConfig

%new(B@:)
- (BOOL)useServerDrivenAbr {
    return NO;
}

%end

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

- (BOOL)iosClientGlobalConfigEnableNewMlabrpolicy {
    return NO;
}

- (BOOL)iosPlayerClientSharedConfigEnableNewMlabrpolicy {
    return NO;
}

- (BOOL)iosPlayerClientSharedConfigPostponeCabrPreferredFormatFiltering {
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

%ctor {
    if (UseVP9()) {
        %init;
    }
}
