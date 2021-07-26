#import "Header.h"

BOOL UseVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UseVP9Key];
}

%hook YTIHamplayerConfig

- (int)renderViewType {
    return UseVP9() ? 2 : %orig;
}

- (BOOL)useSbdlRenderView {
    return UseVP9() ? YES : %orig;
}

%end

%hook MLABRPolicy

- (void)setFormats:(NSArray <MLFormat *> *)formats {
    if (UseVP9()) {
        YTIHamplayerConfig *config = [self valueForKey:@"_hamplayerConfig"];
        YTIHamplayerStreamFilter *filter = [config streamFilter];
        filter.enableVideoCodecSplicing = YES;
        filter.vp9.maxArea = MAX_PIXELS;
        filter.vp9.maxFps = MAX_FPS;
    }
    %orig(formats);
}

%end
