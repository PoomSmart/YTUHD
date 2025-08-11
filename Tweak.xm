#import <Foundation/NSString.h>
#import <HBLog.h>
#import <VideoToolbox/VideoToolbox.h>
#import <substrate.h>
#ifdef SIDELOAD
#import <libundirect/libundirect_dynamic.h>
#else
#import <libundirect/libundirect.h>
#endif
#import <sys/sysctl.h>
#import <version.h>
#import "Header.h"

extern "C" {
    BOOL UseVP9();
    BOOL AllVP9();
    int DecodeThreads();
    BOOL SkipLoopFilter();
    BOOL LoopFilterOptimization();
    BOOL RowThreading();
}

// Remove any <= 1080p VP9 formats if AllVP9 is disabled
NSArray <MLFormat *> *filteredFormats(NSArray <MLFormat *> *formats) {
    if (AllVP9()) return formats;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(MLFormat *format, NSDictionary *bindings) {
        NSString *qualityLabel = [format qualityLabel];
        BOOL isHighRes = [qualityLabel hasPrefix:@"2160p"] || [qualityLabel hasPrefix:@"1440p"];
        BOOL isVP9orAV1 = [[format MIMEType] videoCodec] == 'vp09' || [[format MIMEType] videoCodec] == 'av01';
        return (isHighRes && isVP9orAV1) || !isVP9orAV1;
    }];
    return [formats filteredArrayUsingPredicate:predicate];
}

static void hookFormatsBase(YTIHamplayerConfig *config) {
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

static void hookFormats(MLABRPolicy *self) {
    hookFormatsBase([self valueForKey:@"_hamplayerConfig"]);
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

%hook MLHAMPlayerItem

- (void)load {
    hookFormatsBase([self valueForKey:@"_hamplayerConfig"]);
    %orig;
}

- (void)loadWithInitialSeekRequired:(BOOL)initialSeekRequired initialSeekTime:(double)initialSeekTime {
    hookFormatsBase([self valueForKey:@"_hamplayerConfig"]);
    %orig;
}

%end

%hook YTIHamplayerHotConfig

%new(i@:)
- (int)libvpxDecodeThreads {
    return DecodeThreads();
}

%new(B@:)
- (BOOL)libvpxRowThreading {
    return RowThreading();
}

%new(B@:)
- (BOOL)libvpxSkipLoopFilter {
    return SkipLoopFilter();
}

%new(B@:)
- (BOOL)libvpxLoopFilterOptimization {
    return LoopFilterOptimization();
}

%end

%hook YTColdConfig

- (BOOL)iosPlayerClientSharedConfigPopulateSwAv1MediaCapabilities {
    return YES;
}

%end

%hook YTHotConfig

- (BOOL)iosPlayerClientSharedConfigPostponeCabrPreferredFormatFiltering {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigHamplayerPrepareVideoDecoderForAvsbdl {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigHamplayerAlwaysEnqueueDecodedSampleBuffersToAvsbdl {
    return YES;
}

%end

%hook HAMDefaultABRPolicy

- (id)getSelectableFormatDataAndReturnError:(NSError **)error {
    [self setValue:@(NO) forKey:@"_postponePreferredFormatFiltering"];
    // @try {
    //     HAMDefaultABRPolicyConfig config = MSHookIvar<HAMDefaultABRPolicyConfig>(self, "_config");
    //     config.softwareAV1Filter.maxArea = MAX_PIXELS;
    //     config.softwareAV1Filter.maxFPS = MAX_FPS;
    //     config.softwareVP9Filter.maxArea = MAX_PIXELS;
    //     config.softwareVP9Filter.maxFPS = MAX_FPS;
    //     MSHookIvar<HAMDefaultABRPolicyConfig>(self, "_config") = config;
    // } @catch (id ex) {}
    return filteredFormats(%orig);
}

- (void)setFormats:(NSArray *)formats {
    [self setValue:@(YES) forKey:@"_postponePreferredFormatFiltering"];
    // @try {
    //     HAMDefaultABRPolicyConfig config = MSHookIvar<HAMDefaultABRPolicyConfig>(self, "_config");
    //     config.softwareAV1Filter.maxArea = MAX_PIXELS;
    //     config.softwareAV1Filter.maxFPS = MAX_FPS;
    //     config.softwareVP9Filter.maxArea = MAX_PIXELS;
    //     config.softwareVP9Filter.maxFPS = MAX_FPS;
    //     MSHookIvar<HAMDefaultABRPolicyConfig>(self, "_config") = config;
    // } @catch (id ex) {}
    %orig(filteredFormats(formats));
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

BOOL override = NO;

%hookf(Boolean, VTIsHardwareDecodeSupported, CMVideoCodecType codecType) {
    if (codecType == kCMVideoCodecType_VP9 || codecType == kCMVideoCodecType_AV1)
        return YES;
    return %orig;
}

%hook MLVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes preferredOutputFormats:(const void *)preferredOutputFormats error:(NSError **)error {
    override = YES;
    id decoder = %orig;
    override = NO;
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty error:(NSError **)error {
    override = YES;
    id decoder = %orig;
    override = NO;
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes error:(NSError **)error {
    override = YES;
    id decoder = %orig;
    override = NO;
    return decoder;
}

%end

%hook HAMDefaultVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes preferredOutputFormats:(const void *)preferredOutputFormats error:(NSError **)error {
    override = YES;
    id decoder = %orig;
    override = NO;
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty error:(NSError **)error {
    override = YES;
    id decoder = %orig;
    override = NO;
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes error:(NSError **)error {
    override = YES;
    id decoder = %orig;
    override = NO;
    return decoder;
}

%end

%group Codec

BOOL (*SupportsCodec)(CMVideoCodecType codec) = NULL;
%hookf(BOOL, SupportsCodec, CMVideoCodecType codec) {
    if (override && (codec == kCMVideoCodecType_VP9 || codec == kCMVideoCodecType_AV1)) {
        return NO;
    }

    return %orig;
}

%end

%group Spoofing

%hook UIDevice

- (NSString *)systemVersion {
    return @"15.8.4";
}

%end

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion version;
    version.majorVersion = 15;
    version.minorVersion = 8;
    version.patchVersion = 4;
    return version;
}

%end

%hookf(int, sysctlbyname, const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (strcmp(name, "kern.osversion") == 0) {
        int ret = %orig;
        if (oldp) {
            strcpy((char *)oldp, IOS_BUILD);
            *oldlenp = strlen(IOS_BUILD);
        }
        return ret;
    }
    return %orig;
}

%end

%ctor {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DecodeThreadsKey: @2
    }];
    if (!UseVP9()) return;
    %init;
    uint8_t pattern1[] = {
        0x28, 0x66, 0x8c, 0x52,
        0xc8, 0x2e, 0xac, 0x72,
        0x1f, 0x00, 0x08, 0x6b,
        0x61, 0x00, 0x00, 0x54,
        0x20, 0x00, 0x80, 0x52,
        0xc0, 0x03, 0x5f, 0xd6
    };
    uint8_t pattern2[] = {
        0xf4, 0x4f, 0xbe, 0xa9,
        0xfd, 0x7b, 0x01, 0xa9,
        0xfd, 0x43, 0x00, 0x91,
        0x28, 0x66, 0x8c, 0x52,
        0xc8, 0x2e, 0xac, 0x72
    };
    NSString *bundlePath = [NSString stringWithFormat:@"%@/Frameworks/Module_Framework.framework", NSBundle.mainBundle.bundlePath];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSString *binary;
    if (bundle) {
        [bundle load];
        binary = @"Module_Framework";
    } else
        binary = @"YouTube";
    SupportsCodec = (BOOL (*)(CMVideoCodecType))libundirect_find(binary, pattern1, sizeof(pattern1), 0x28);
    if (SupportsCodec == NULL)
        SupportsCodec = (BOOL (*)(CMVideoCodecType))libundirect_find(binary, pattern2, sizeof(pattern2), 0xf4);
    HBLogDebug(@"YTUHD: SupportsCodec: %d", SupportsCodec != NULL);
    if (SupportsCodec) {
        %init(Codec);
    }
    if (!IS_IOS_OR_NEWER(iOS_15_0)) {
        %init(Spoofing);
    }
}
