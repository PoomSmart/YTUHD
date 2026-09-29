#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <HBLog.h>
#import <substrate.h>
#import <libundirect/libundirect.h>
#import "Header.h"

typedef struct {
    const unsigned int *data;
    uint64_t length;
} Span;

extern "C" {
    BOOL UseVP9AV1();
    BOOL AllVP9();
    BOOL ApplyGrain();
    BOOL DisableServerABR();
    int DecodeThreads();
    BOOL SkipLoopFilter();
    BOOL LoopFilterOptimization();
    BOOL RowThreading();
}

@interface HAMVideoDecoder : NSObject
@property (nonatomic, readwrite, weak) id<HAMVideoDecoderDelegate> delegate;
- (void)terminate;
@end

@interface MLMediaCapabilitiesProviderImpl : NSObject
- (const void *)mediaCapabilities;
@end

static HAMVideoDecoder *prepareDecoder(MLVideoDecoderFactory *self, id delegate, id delegateQueue, HAMFormatDescription *formatDescription, NSDictionary *pixelBufferAttributes) {
    HAMVideoDecoder *preparedDecoder = [self valueForKey:@"_preparedDecoder"];
    if (preparedDecoder) {
        if ([self valueForKey:@"_delegateQueue"] == delegateQueue) {
            HAMFormatDescription *preparedFormat = [self valueForKey:@"_preparedFormatDescription"];
            CMFormatDescriptionRef preparedFormatDescription = [preparedFormat formatDescription];
            if (CMFormatDescriptionEqual([formatDescription formatDescription], preparedFormatDescription)) {
                if ([pixelBufferAttributes isEqualToDictionary:[self valueForKey:@"_preparedPixelBufferAttributes"]]) {
                    [self clearPreparedDecoder];
                    preparedDecoder.delegate = delegate;
                    return preparedDecoder;
                }
            }    
        }
        [preparedDecoder terminate];
        [self clearPreparedDecoder];
    }
    return nil;
}

@interface YTUHDVPXVideoDecoder : NSObject
- (instancetype)initWithDelegate:(id)delegate
                   delegateQueue:(id)delegateQueue
                     decodeQueue:(id)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMVPXDecoderConfig)config;
@end

@interface YTUHDDav1dVideoDecoder : NSObject
- (instancetype)initWithDelegate:(id)delegate
                   delegateQueue:(id)delegateQueue
                     decodeQueue:(id)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMDav1dDecoderConfig)config;
@end

BOOL vtSupportsVP9;
BOOL vtSupportsAV1;

static HAMVPXDecoderConfig YTUHDMakeConfig(void) {
    return (HAMVPXDecoderConfig){
        .threads                = MAX(1, DecodeThreads()),
        .skipLoopFilter         = SkipLoopFilter(),
        .loopFilterOptimization = LoopFilterOptimization(),
        .rowThreading           = RowThreading(),
        ._reserved              = NO,
    };
}

static id YTUHDCreateVPXDecoder(MLVideoDecoderFactory *self, id delegate, id delegateQueue, HAMFormatDescription *formatDescription, id pixelBufferAttributes) {
    id preparedDecoder = self ? prepareDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes) : nil;
    if (preparedDecoder) return preparedDecoder;
    dispatch_queue_t decodeQueue =
        dispatch_queue_create("com.ytuhd.vpx.decode", DISPATCH_QUEUE_SERIAL);
    return [[YTUHDVPXVideoDecoder alloc]
        initWithDelegate:delegate
           delegateQueue:delegateQueue
             decodeQueue:decodeQueue
   pixelBufferAttributes:pixelBufferAttributes
                  config:YTUHDMakeConfig()];
}

static id YTUHDCreateDav1dDecoder(MLVideoDecoderFactory *self, id delegate, id delegateQueue, HAMFormatDescription *formatDescription, id pixelBufferAttributes) {
    id preparedDecoder = self ? prepareDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes) : nil;
    if (preparedDecoder) return preparedDecoder;
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
    if (AllVP9()) return formats;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(MLFormat *format, NSDictionary *bindings) {
        if (![format isKindOfClass:%c(MLFormat)]) return YES;
        BOOL isVP9 = [[format MIMEType] videoCodec] == 'vp09';
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
    filter.vp9.maxArea = MAX_PIXELS;
    filter.vp9.maxFps = MAX_FPS;
}

static void hookFormats(MLABRPolicy *self) {
    hookFormatsBase([self valueForKey:@"_hamplayerConfig"]);
}

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

%group ServerABR

%hook YTIHamplayerServerABRConfig

%new(B@:)
- (BOOL)skipFilterPreferredVideoFormats {
    return NO;
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

- (BOOL)iosClientGlobalConfigEnableNewMlabrpolicy {
    return NO;
}

- (BOOL)iosPlayerClientSharedConfigDisableServerDrivenAbr {
    return YES;
}

- (BOOL)iosPlayerClientSharedConfigPostponeCabrPreferredFormatFiltering {
    return YES;
}

%end

%end

%hook YTHotConfig

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

- (NSArray *)getSelectableFormatDataAndReturnError:(NSError **)error {
    [self setValue:@(NO) forKey:@"_postponePreferredFormatFiltering"];
    // @try {
    //     HAMDefaultABRPolicyConfig config = MSHookIvar<HAMDefaultABRPolicyConfig>(self, "_config");
    //     config.softwareAV1Filter.maxArea = MAX_PIXELS;
    //     config.softwareAV1Filter.maxFPS = MAX_FPS;
    //     config.softwareVP9Filter.maxArea = MAX_PIXELS;
    //     config.softwareVP9Filter.maxFPS = MAX_FPS;
    //     MSHookIvar<HAMDefaultABRPolicyConfig>(self, "_config") = config;
    // } @catch (id ex) {}
    NSArray *formats = %orig;
    return filteredFormats(formats);
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

%hook MLHAMSBDLSampleBufferRenderingView

- (NSArray *)supportedCodecs {
    NSArray *orig = %orig;
    BOOL suppressVP9 = !vtSupportsVP9;
    BOOL suppressAV1 = !vtSupportsAV1;
    NSNumber *vp9 = @(kCMVideoCodecType_VP9);
    NSNumber *av1 = @(kCMVideoCodecType_AV1);
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSNumber *codec in orig) {
        if ((suppressVP9 && [codec isEqualToNumber:vp9]) ||
            (suppressAV1 && [codec isEqualToNumber:av1])) {
            HBLogDebug(@"YTUHD - MLHAMSBDLSampleBufferRenderingView supportedCodecs filtering out codec: %@", codec);
            continue;
        }
        [filtered addObject:codec];
    }
    return filtered;
}

%end

BOOL overrideSupportsCodec = NO;

%hook MLVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(NSDictionary *)pixelBufferAttributes preferredOutputFormats:(Span)preferredOutputFormats error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - MLVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    if (error) HBLogDebug(@"YTUHD - Creating video decoder for codec: %d, error: %@", codecType, *error);
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - MLVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    if (error) HBLogDebug(@"YTUHD - Creating video decoder for codec: %d, error: %@", codecType, *error);
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - MLVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    if (error) HBLogDebug(@"YTUHD - Creating video decoder for codec: %d, error: %@", codecType, *error);
    return decoder;
}

- (void)prepareDecoderForFormatDescription:(HAMFormatDescription *)formatDescription delegateQueue:(id)delegateQueue {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    if ((!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9) ||
        (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)) return;
    overrideSupportsCodec = YES;
    %orig;
    overrideSupportsCodec = NO;
}

- (void)prepareDecoderForFormatDescription:(HAMFormatDescription *)formatDescription setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty delegateQueue:(id)delegateQueue {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    if ((!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9) ||
        (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)) return;
    overrideSupportsCodec = YES;
    %orig;
    overrideSupportsCodec = NO;
}

%end

%hook HAMDefaultVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes preferredOutputFormats:(Span)preferredOutputFormats error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - HAMDefaultVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    if (error) HBLogDebug(@"YTUHD - Creating video decoder for codec: %d, error: %@", codecType, *error);
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - HAMDefaultVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    if (error) HBLogDebug(@"YTUHD - Creating video decoder for codec: %d, error: %@", codecType, *error);
    return decoder;
}

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(id)pixelBufferAttributes error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - HAMDefaultVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(nil, delegate, delegateQueue, nil, pixelBufferAttributes);
    overrideSupportsCodec = YES;
    id decoder = %orig;
    overrideSupportsCodec = NO;
    if (error) HBLogDebug(@"YTUHD - Creating video decoder for codec: %d, error: %@", codecType, *error);
    return decoder;
}

%end

%hook YTIIosOnesieHotConfig

%new(B@:)
- (BOOL)prepareVideoDecoder { return YES; }

%end

%group Codec

static void *ptrFromAdrpLdr(const void *at) {
    const uint32_t *insns = (const uint32_t *)at;
    uint32_t adrp = insns[0];
    uint32_t ldr  = insns[1];
    int64_t imm = (int64_t)((((adrp >> 5) & 0x7FFFF) << 2) | ((adrp >> 29) & 0x3));
    if (imm & (1 << 20)) imm -= (1 << 21);
    uint64_t page = ((uint64_t)(uintptr_t)at & ~0xFFFULL) + ((uint64_t)imm << 12);
    uint32_t size = (ldr >> 30) & 0x3;
    uint32_t imm12 = (ldr >> 10) & 0xFFF;
    return (void *)(uintptr_t)(page + ((uint64_t)imm12 << size));
}

static void forceCodecSupportTrue(void *supportsCodec) {
    uint8_t *fn = (uint8_t *)supportsCodec;
    void *predicate = ptrFromAdrpLdr(fn + 0x5C);
    void *vp9Flag    = ptrFromAdrpLdr(fn + 0x8C);
    void *av1Flag    = ptrFromAdrpLdr(fn + 0x98);
    *(long *)predicate = -1;  // pretend SupportsCodec's dispatch_once already ran
    *(uint8_t *)vp9Flag = 1;
    *(uint8_t *)av1Flag = 1;
}

static void (*PopulateCodecCapability)(CMVideoCodecType codec, const void *caps) = NULL;

static void injectMissingCodecCapabilities(const void *caps) {
    static void *injected[4];
    if (!caps || !PopulateCodecCapability) return;
    for (int i = 0; i < 4; i++) {
        if (injected[i] == caps) return;
        if (!injected[i]) { injected[i] = (void *)caps; break; }
    }
    PopulateCodecCapability(kCMVideoCodecType_VP9, caps);
    PopulateCodecCapability(kCMVideoCodecType_AV1, caps);
}

%hook MLMediaCapabilitiesProviderImpl

- (const void *)mediaCapabilities {
    const void *caps = %orig;
    injectMissingCodecCapabilities(caps);
    return caps;
}

%end

%end

%ctor {
    vtSupportsVP9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
    vtSupportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DecodeThreadsKey: @2,
        ApplyGrainKey:    @YES,
    }];
    if (UseVP9AV1()) {
        uint8_t supportsCodecPattern[] = {
            0x28, 0x66, 0x8c, 0x52,
            0xc8, 0x2e, 0xac, 0x72,
            0x1f, 0x00, 0x08, 0x6b,
            0x61, 0x00, 0x00, 0x54,
            0x28, 0x00, 0x80, 0x52,
        };
        uint8_t populateCapabilityPattern[] = {
            0x08, 0x07, 0x8e, 0x52,
            0xc8, 0x2e, 0xae, 0x72,
            0xbf, 0x02, 0x08, 0x6b,
            0x6c, 0x01, 0x00, 0x54,
            0x28, 0x06, 0x86, 0x52,
            0xc8, 0x2e, 0xac, 0x72,
            0xbf, 0x02, 0x08, 0x6b,
            0x80, 0x07, 0x00, 0x54,
            0x28, 0x66, 0x8c, 0x52,
            0xc8, 0x2e, 0xac, 0x72,
            0xbf, 0x02, 0x08, 0x6b,
            0xa1, 0x01, 0x00, 0x54,
            0x56, 0x00, 0x80, 0x52,
            0x0c, 0x00, 0x00, 0x14,
        };
        NSString *bundlePath = [NSString stringWithFormat:@"%@/Frameworks/Module_Framework.framework", NSBundle.mainBundle.bundlePath];
        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        NSString *binary;
        if (bundle) {
            [bundle load];
            binary = @"Module_Framework";
        } else
            binary = @"YouTube";
        void *supportsCodec = libundirect_find(binary, supportsCodecPattern, sizeof(supportsCodecPattern), 0x28);
        HBLogDebug(@"YTUHD: SupportsCodec: %d", supportsCodec != NULL);
        void *populateCapabilityMatch = libundirect_find(binary, populateCapabilityPattern, sizeof(populateCapabilityPattern), 0);
        if (populateCapabilityMatch) {
            PopulateCodecCapability = (void (*)(CMVideoCodecType, const void *))((uint8_t *)populateCapabilityMatch - 0x40);
        }
        HBLogDebug(@"YTUHD: PopulateCodecCapability: %d", PopulateCodecCapability != NULL);
        if (supportsCodec) {
            forceCodecSupportTrue(supportsCodec);
        }
        %init;
        if (supportsCodec && PopulateCodecCapability) {
            %init(Codec);
        }
    }
    if (DisableServerABR()) {
        %init(ServerABR);
    }
}