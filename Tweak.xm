#import <CoreMedia/CoreMedia.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSString.h>
#import <VideoToolbox/VideoToolbox.h>
#import <HBLog.h>
#import <substrate.h>
#ifdef SIDELOAD
#import <libundirect/libundirect_dynamic.h>
#else
#import <libundirect/libundirect.h>
#endif
#import <sys/sysctl.h>
#import <version.h>
#import "Header.h"

typedef struct {
    const unsigned int *data;
    uint64_t length;
} Span;

extern "C" {
    BOOL UseVP9();
    BOOL AllVP9();
    BOOL UseAV1();
    BOOL ApplyGrain();
    BOOL DisableServerABR();
    int DecodeThreads();
    BOOL SkipLoopFilter();
    BOOL LoopFilterOptimization();
    BOOL RowThreading();
}

// Reimplemented VP9 decoder (YTUHDVPXVideoDecoder defined in HAMVPXVideoDecoder.m).
// Only instantiated when the native HAMVPXVideoDecoder class is absent (new YT).
@interface YTUHDVPXVideoDecoder : NSObject
- (instancetype)initWithDelegate:(id)delegate
                   delegateQueue:(id)delegateQueue
                     decodeQueue:(id)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMVPXDecoderConfig)config;
@end

// Reimplemented AV1 decoder (YTUHDDav1dVideoDecoder defined in HAMDav1dVideoDecoder.m).
// Instantiated when UseAV1() && !hasHAMDav1dVideoDecoder && !vtSupportsAV1.
@interface YTUHDDav1dVideoDecoder : NSObject
- (instancetype)initWithDelegate:(id)delegate
                   delegateQueue:(id)delegateQueue
                     decodeQueue:(id)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMDav1dDecoderConfig)config;
@end

BOOL hasHAMVPXVideoDecoder;
BOOL vtSupportsVP9;
BOOL hasHAMDav1dVideoDecoder;
BOOL vtSupportsAV1;

// Build a HAMVPXDecoderConfig from the current user settings.
static HAMVPXDecoderConfig YTUHDMakeConfig(void) {
    return (HAMVPXDecoderConfig){
        .threads                = MAX(1, DecodeThreads()),
        .skipLoopFilter         = SkipLoopFilter(),
        .loopFilterOptimization = LoopFilterOptimization(),
        .rowThreading           = RowThreading(),
        ._reserved              = NO,
    };
}

// Create a YTUHDVPXVideoDecoder with user settings.
// Used by all factory hooks on new YouTube (>= 20.47.3).
static id YTUHDCreateVPXDecoder(id delegate, id delegateQueue, id pixelBufferAttributes) {
    dispatch_queue_t decodeQueue =
        dispatch_queue_create("com.ytuhd.vpx.decode", DISPATCH_QUEUE_SERIAL);
    return [[YTUHDVPXVideoDecoder alloc]
        initWithDelegate:delegate
           delegateQueue:delegateQueue
             decodeQueue:decodeQueue
   pixelBufferAttributes:pixelBufferAttributes
                  config:YTUHDMakeConfig()];
}

// True when we should use software AV1 decode via dav1d.
static BOOL useSoftwareAV1(void) {
    return UseAV1() && !hasHAMDav1dVideoDecoder && !vtSupportsAV1;
}

// Create a YTUHDDav1dVideoDecoder with user settings.
static id YTUHDCreateDav1dDecoder(id delegate, id delegateQueue, id pixelBufferAttributes) {
    dispatch_queue_t decodeQueue =
        dispatch_queue_create("com.ytuhd.dav1d.decode", DISPATCH_QUEUE_SERIAL);
    return [[YTUHDDav1dVideoDecoder alloc]
        initWithDelegate:delegate
           delegateQueue:delegateQueue
             decodeQueue:decodeQueue
   pixelBufferAttributes:pixelBufferAttributes
                  config:(HAMDav1dDecoderConfig){
                      .threads    = MAX(1, DecodeThreads()),
                      .applyGrain = ApplyGrain(),
                  }];
}

// Remove any <= 1080p VP9 formats if AllVP9 is disabled.
NSArray <MLFormat *> *filteredFormats(NSArray <MLFormat *> *formats) {
    // VP9 is always decodable when UseVP9 is enabled:
    //   old YT  -> native HAMVPXVideoDecoder (libvpx)
    //   new YT  -> hardware VideoToolbox (A12+) or YTUHDVPXVideoDecoder (A11-)
    BOOL canDecodeVP9 = YES;
    if (AllVP9() && canDecodeVP9) return formats;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(MLFormat *format, NSDictionary *bindings) {
        if (![format isKindOfClass:%c(MLFormat)]) return YES;
        BOOL isVP9 = [[format MIMEType] videoCodec] == 'vp09';
        // Always strip VP9 when nothing can decode it
        if (isVP9 && !canDecodeVP9) return NO;
        NSString *qualityLabel = [format qualityLabel];
        BOOL isHighRes = [qualityLabel hasPrefix:@"2160p"] || [qualityLabel hasPrefix:@"1440p"];
        BOOL isVP9orAV1 = isVP9 || [[format MIMEType] videoCodec] == 'av01';
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
    // Advertise VP9 capability — covered by native decoder, hardware VT, or
    // our YTUHDVPXVideoDecoder backport depending on the YouTube version.
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

%new(i@:)
- (int)libdav1dDecodeThreads {
    return DecodeThreads();
}

%new(B@:)
- (BOOL)libdav1dApplyGrain {
    return ApplyGrain();
}

%end

%hook YTColdConfig

- (BOOL)iosPlayerClientSharedConfigPopulateSwAv1MediaCapabilities {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigPopulateAc3MediaCapabilities {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigPopulateEac3MediaCapabilities {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigDisableLibvpxDecoder {
    return NO;
}

%end

%hook YTHotConfig

- (BOOL)iosPlayerClientSharedConfigDisableServerDrivenAbr {
    return DisableServerABR() ? YES : %orig;
}

- (BOOL)iosPlayerClientSharedConfigPostponeCabrPreferredFormatFiltering {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigHamplayerPrepareVideoDecoderForAvsbdl {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigHamplayerAlwaysEnqueueDecodedSampleBuffersToAvsbdl {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigUseMediaCapabilitiesForClientFiltering {
    return NO;
}

- (BOOL)iosPlayerClientSharedConfigPopulateMoreMediaCapabilities {
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

// Suppress the list of hardware-decoded codecs when we are using software
// decoders, so the pixel-buffer track renderer path is taken instead of
// AVSBDL (which requires the hardware to handle compressed buffers).
%hook MLHAMSBDLSampleBufferRenderingView

- (NSArray *)supportedCodecs {
    NSArray *orig = %orig;
    if (!useSoftwareAV1()) return orig;
    // Filter out AV1 so the SBDL compressed-buffer path is skipped for AV1
    // while leaving H.264 / HEVC / VP9 etc. unaffected.
    NSNumber *av1 = @(kCMVideoCodecType_AV1);
    return [orig filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(id obj, NSDictionary *_) {
                    return ![obj isEqual:av1];
                }]];
}

%end

BOOL overrideSupportsCodec = NO;

%hook MLVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes preferredOutputFormats:(Span)preferredOutputFormats error:(NSError **)error {
    CMVideoCodecType codecType = [(HAMFormatDescription *)formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - MLVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!hasHAMVPXVideoDecoder && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(delegate, delegateQueue, pixelBufferAttributes);
    if (useSoftwareAV1() && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(delegate, delegateQueue, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty error:(NSError **)error {
    CMVideoCodecType codecType = [(HAMFormatDescription *)formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - MLVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!hasHAMVPXVideoDecoder && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(delegate, delegateQueue, pixelBufferAttributes);
    if (useSoftwareAV1() && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(delegate, delegateQueue, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes error:(NSError **)error {
    CMVideoCodecType codecType = [(HAMFormatDescription *)formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - MLVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!hasHAMVPXVideoDecoder && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(delegate, delegateQueue, pixelBufferAttributes);
    if (useSoftwareAV1() && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(delegate, delegateQueue, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    return decoder;
}

%end

%hook HAMDefaultVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes preferredOutputFormats:(Span)preferredOutputFormats error:(NSError **)error {
    CMVideoCodecType codecType = [(HAMFormatDescription *)formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - HAMDefaultVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!hasHAMVPXVideoDecoder && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(delegate, delegateQueue, pixelBufferAttributes);
    if (useSoftwareAV1() && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(delegate, delegateQueue, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty error:(NSError **)error {
    CMVideoCodecType codecType = [(HAMFormatDescription *)formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - HAMDefaultVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!hasHAMVPXVideoDecoder && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(delegate, delegateQueue, pixelBufferAttributes);
    if (useSoftwareAV1() && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(delegate, delegateQueue, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(id)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes error:(NSError **)error {
    CMVideoCodecType codecType = [(HAMFormatDescription *)formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - HAMDefaultVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!hasHAMVPXVideoDecoder && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(delegate, delegateQueue, pixelBufferAttributes);
    if (useSoftwareAV1() && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(delegate, delegateQueue, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    return decoder;
}

%end

%hook YTIIosOnesieHotConfig

%new(B@:)
- (BOOL)prepareVideoDecoder { return YES; }

%end

%group Codec

BOOL (*SupportsCodec)(CMVideoCodecType codec) = NULL;
%hookf(BOOL, SupportsCodec, CMVideoCodecType codec) {
    if (overrideSupportsCodec) {
        // Suppress VP9 when libvpx decoder exists (old YT → routes to HAMVPXVideoDecoder),
        // or when VT has no VP9 support (A11 and earlier on new YT — formats are already
        // stripped by filteredFormats, this is just a belt-and-suspenders guard).
        // When neither condition is true (new YT + A12+), let VT decode VP9 natively.
        BOOL suppressVP9 = hasHAMVPXVideoDecoder || !vtSupportsVP9;
        // Suppress AV1 from the hardware/AVSBDL path when we are routing to dav1d.
        BOOL suppressAV1 = useSoftwareAV1();
        BOOL suppressCodec = (codec == kCMVideoCodecType_AV1 && suppressAV1) ||
                             (codec == kCMVideoCodecType_VP9 && suppressVP9);
        if (suppressCodec) {
            HBLogDebug(@"YTUHD - SupportsCodec called for codec: %d, returning NO", codec);
            return NO;
        }
    }
    return YES;
}

%end

%group Spoofing

%hook UIDevice

- (NSString *)systemVersion {
    return @"15.8.7";
}

%end

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion version;
    version.majorVersion = 15;
    version.minorVersion = 8;
    version.patchVersion = 7;
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
    vtSupportsVP9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
    vtSupportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DecodeThreadsKey: @2,
        ApplyGrainKey:    @YES,
    }];
    if (!UseVP9() && !UseAV1()) return;
    uint8_t pattern1[] = {
        0x28, 0x66, 0x8c, 0x52,
        0xc8, 0x2e, 0xac, 0x72,
        0x1f, 0x00, 0x08, 0x6b,
        0x61, 0x00, 0x00, 0x54,
        0x28, 0x00, 0x80, 0x52,
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
    hasHAMVPXVideoDecoder = %c(HAMVPXVideoDecoder) != nil;
    hasHAMDav1dVideoDecoder = %c(HAMDav1dVideoDecoder) != nil;
    %init;
    SupportsCodec = (BOOL (*)(CMVideoCodecType))libundirect_find(binary, pattern1, sizeof(pattern1), 0x28);
    if (SupportsCodec == NULL) {
        SupportsCodec = (BOOL (*)(CMVideoCodecType))libundirect_find(binary, pattern2, sizeof(pattern2), 0xf4);
        HBLogDebug(@"YTUHD: SupportsCodec pattern2");
    }
    HBLogDebug(@"YTUHD: SupportsCodec: %d", SupportsCodec != NULL);
    if (SupportsCodec) {
        %init(Codec);
    }
    if (!IS_IOS_OR_NEWER(iOS_15_0)) {
        %init(Spoofing);
    }
}