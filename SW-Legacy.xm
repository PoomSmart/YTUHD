#import "Header.h"

%hook YTIHamplayerConfig

- (int)renderViewType {
    return 2;
}

%end

%hook MLABRPolicy

- (void)setFormats:(NSArray <MLFormat *> *)formats {
    YTIHamplayerConfig *config = [self valueForKey:@"_hamplayerConfig"];
    YTIHamplayerStreamFilter *filter = [config streamFilter];
    filter.enableVideoCodecSplicing = YES;
    filter.vp9.maxArea = MAX_PIXELS;
    filter.vp9.maxFps = MAX_FPS;
    %orig(formats);
}

%end

%ctor {
    %init;
}
