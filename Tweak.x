#import "Header.h"

BOOL UseVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UseVP9Key];
}

%hook MLHAMPlayerItem

- (void)load {
    MLInnerTubePlayerConfig *config = [self config];
    YTIMediaCommonConfig *mediaCommonConfig = [config mediaCommonConfig];
    mediaCommonConfig.useServerDrivenAbr = NO;
    %orig;
}

%end

%hook MLABRPolicy

- (void)setFormats:(NSArray <MLFormat *> *)formats {
    // TODO: HAX to just enable 720p+ (non-HDR) for UHD HDR videos
    for (MLFormat *format in formats) {
        if (format.singleDimensionResolution >= 720 && format.FPS >= 60 && format.formatStream.colorInfo.transferCharacteristics == 1) {
            format.formatStream.colorInfo.transferCharacteristics = 16;
        }
    }
    YTIHamplayerConfig *config = [self valueForKey:@"_hamplayerConfig"];
    config.videoAbrConfig.preferSoftwareHdrOverHardwareSdr = YES;
    YTIHamplayerStreamFilter *filter = config.streamFilter;
    filter.enableVideoCodecSplicing = YES;
    filter.vp9.maxArea = MAX_PIXELS;
    filter.vp9.maxFps = MAX_FPS;
    %orig;
}

%end

%ctor {
    if (UseVP9()) {
        %init;
    }
}
