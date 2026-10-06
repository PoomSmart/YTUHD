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

static BOOL isSoftwareOnlyCodec(CMVideoCodecType codecType) {
    return (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9) ||
           (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1);
}

%hook MLVideoDecoderFactory

- (id)videoDecoderWithDelegate:(id)delegate delegateQueue:(id)delegateQueue formatDescription:(HAMFormatDescription *)formatDescription pixelBufferAttributes:(NSDictionary *)pixelBufferAttributes preferredOutputFormats:(Span)preferredOutputFormats error:(NSError **)error {
    CMVideoCodecType codecType = [formatDescription mediaSubType];
    HBLogDebug(@"YTUHD - MLVideoDecoderFactory videoDecoderWithDelegate called with codec: %d", codecType);
    if (!vtSupportsVP9 && codecType == kCMVideoCodecType_VP9)
        return YTUHDCreateVPXDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    if (!vtSupportsAV1 && codecType == kCMVideoCodecType_AV1)
        return YTUHDCreateDav1dDecoder(self, delegate, delegateQueue, formatDescription, pixelBufferAttributes);
    id decoder = %orig;
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
    id decoder = %orig;
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
    id decoder = %orig;
    if (error) HBLogDebug(@"YTUHD - Creating video decoder for codec: %d, error: %@", codecType, *error);
    return decoder;
}

- (void)prepareDecoderForFormatDescription:(HAMFormatDescription *)formatDescription delegateQueue:(id)delegateQueue {
    if (isSoftwareOnlyCodec([formatDescription mediaSubType])) return;
    %orig;
}

- (void)prepareDecoderForFormatDescription:(HAMFormatDescription *)formatDescription setPixelBufferTypeOnlyIfEmpty:(BOOL)setPixelBufferTypeOnlyIfEmpty delegateQueue:(id)delegateQueue {
    if (isSoftwareOnlyCodec([formatDescription mediaSubType])) return;
    %orig;
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
    id decoder = %orig;
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
    id decoder = %orig;
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
    id decoder = %orig;
    if (error) HBLogDebug(@"YTUHD - Creating video decoder for codec: %d, error: %@", codecType, *error);
    return decoder;
}

%end

%hook YTIIosOnesieHotConfig

%new(B@:)
- (BOOL)prepareVideoDecoder { return YES; }

%end

static BOOL isAdrp(uint32_t insn) {
    return (insn & 0x9F000000) == 0x90000000;
}

static BOOL isLdr64(uint32_t insn) {
    return (insn & 0xFFC00000) == 0xF9400000;
}

static BOOL isLdrb(uint32_t insn) {
    return (insn & 0xFFC00000) == 0x39400000;
}

static BOOL isCmn1(uint32_t insn) {
    return (insn & 0xFFFFFC1F) == 0xB100041F && ((insn >> 10) & 0xFFF) == 1;
}

static void *ptrFromAdrpLdr(const uint32_t *insns) {
    uint32_t adrp = insns[0];
    uint32_t ldr  = insns[1];
    int64_t imm = (int64_t)((((adrp >> 5) & 0x7FFFF) << 2) | ((adrp >> 29) & 0x3));
    if (imm & (1 << 20)) imm -= (1 << 21);
    uint64_t page = ((uint64_t)(uintptr_t)insns & ~0xFFFULL) + ((uint64_t)imm << 12);
    uint32_t size = (ldr >> 30) & 0x3;
    uint32_t imm12 = (ldr >> 10) & 0xFFF;
    return (void *)(uintptr_t)(page + ((uint64_t)imm12 << size));
}

// Locate SupportsCodec's dispatch_once predicate and cached VP9/AV1 flags from
// ADRP+LDR pairs instead of version-specific instruction offsets. Writes data
// only; does not hook executable code (avoids AMFI panics).
static BOOL forceCodecSupportTrue(void *supportsCodec) {
    const uint32_t *insns = (const uint32_t *)supportsCodec;
    void *predicate = NULL;
    void *flags[2] = {0};
    int flagCount = 0;
    for (int i = 0; i < 64; i++) {
        if (isAdrp(insns[i]) && isLdr64(insns[i + 1]) && isCmn1(insns[i + 2]))
            predicate = ptrFromAdrpLdr(insns + i);
        if (isAdrp(insns[i]) && isLdrb(insns[i + 1]) && flagCount < 2)
            flags[flagCount++] = ptrFromAdrpLdr(insns + i);
    }
    if (!predicate || flagCount != 2) return NO;
    uintptr_t a = (uintptr_t)flags[0];
    uintptr_t b = (uintptr_t)flags[1];
    if (a > b) {
        uintptr_t tmp = a;
        a = b;
        b = tmp;
    }
    if (b - a != 1) return NO;
    if ((uintptr_t)predicate < a || (uintptr_t)predicate - a > 0x20) return NO;
    *(long *)predicate = -1;
    *(uint8_t *)a = 1;
    *(uint8_t *)b = 1;
    return YES;
}

%ctor {
    vtSupportsVP9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
    vtSupportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        DecodeThreadsKey: @2,
        ApplyGrainKey:    @YES,
    }];
    if (UseVP9AV1()) {
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
        void *supportsCodec = libundirect_find(binary, pattern1, sizeof(pattern1), 0x28);
        if (supportsCodec == NULL) {
            supportsCodec = libundirect_find(binary, pattern2, sizeof(pattern2), 0xf4);
            HBLogDebug(@"YTUHD: SupportsCodec pattern2");
        }
        __unused BOOL forced = supportsCodec && forceCodecSupportTrue(supportsCodec);
        HBLogDebug(@"YTUHD: SupportsCodec: %d forced: %d", supportsCodec != NULL, forced);
        %init;
    }
    if (DisableServerABR()) {
        %init(ServerABR);
    }
}