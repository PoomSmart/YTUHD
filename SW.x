#import "Header.h"

%group LateHook

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

%end

%hook YTBaseInnerTubeService

+ (void)initialize {
    %orig;
    %init(LateHook);
}

%end

%ctor {
    %init;
}
