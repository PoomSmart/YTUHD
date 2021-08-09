#import "Header.h"

BOOL UseVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UseVP9Key];
}

%hook MLABRPolicy

- (void)setFormats:(NSArray <MLFormat *> *)formats {
    YTIHamplayerConfig *config = [self valueForKey:@"_hamplayerConfig"];
    YTIHamplayerStreamFilter *filter = config.streamFilter;
    filter.enableVideoCodecSplicing = YES;
    filter.vp9.maxArea = MAX_PIXELS;
    filter.vp9.maxFps = MAX_FPS;
    %orig(formats);
}

%end

%ctor {
    if (UseVP9()) {
        %init;
    }
}
