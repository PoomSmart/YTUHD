/**
 * HAMVPXVideoDecoder.m
 *
 * Full reimplementation of the HAMVPXVideoDecoder class for YouTube versions
 * >= 20.47.3 that removed the native libvpx-based HAMVPXVideoDecoder.
 *
 * Provides YTUHDVPXVideoDecoder — a drop-in VP9 software decoder using
 * libvpx that is injected by the HAMDefaultVideoDecoderFactory hook in
 * Tweak.xm when the native class is absent (hasHAMVPXVideoDecoder == NO).
 *
 * Class design mirrors the original HAMVPXVideoDecoder decompiled from
 * YouTube 20.18.4:
 *   - Same init/prepare/terminate/decodeSampleBuffer: interface
 *   - Same vpx_codec_control IDs: 265/268/269
 *   - HAMPixelBufferPool used for I420→NV12 conversion and for wrapping
 *     decoded output into HAMSampleBuffer objects
 */

#import <CoreMedia/CoreMedia.h>
#import <YouTubeHeader/HAMInputSampleBuffer.h>
#import <YouTubeHeader/HAMVideoDecoderDelegate.h>
#import <objc/message.h>
#import <stdatomic.h>

#include <vpx/vpx_decoder.h>
#include <vpx/vp8dx.h>

#import "Header.h"

// ---------------------------------------------------------------------------
// HAMPlanarImage — internal struct of HAMPixelBufferPool.
//
// Layout confirmed from decompilation of both YouTube 20.18.4 and 21.17.3
// binaries for -[HAMPixelBufferPool pixelBufferWithPlanarImage:...]:
//   offset  0: const uint8_t *planeY   (8 bytes)
//   offset  8: const uint8_t *planeCb  (8 bytes)
//   offset 16: const uint8_t *planeCr  (8 bytes)
//   offset 24: uint64_t       strideY  (8 bytes)
//   offset 32: uint64_t       strideCb (8 bytes)
//   offset 40: uint64_t       strideCr (8 bytes)
//   offset 48: uint64_t       width    (8 bytes)
//   offset 56: uint64_t       height   (8 bytes)
//   offset 64: int32_t        bitDepth (4 bytes + 4 pad)
// ---------------------------------------------------------------------------
typedef struct {
    const uint8_t *planeY;
    const uint8_t *planeCb;
    const uint8_t *planeCr;
    uint64_t strideY;
    uint64_t strideCb;
    uint64_t strideCr;
    uint64_t width;
    uint64_t height;
    int32_t  bitDepth;
} HAMPlanarImage;

// ---------------------------------------------------------------------------
// Function-pointer type for -[HAMPixelBufferPool pixelBufferWithPlanarImage:
//   presentationTime:presentationDuration:formatSelection:formatDescription:
//   productionTime:periodID:originalPresentationTime:error:]
// (signature present in YouTube >= ~20.47 — confirmed in 21.17.3 IDA)
// ---------------------------------------------------------------------------
typedef id (*PixelBufferPoolFn)(id, SEL,
    const HAMPlanarImage *,
    CMTime *,
    CMTime *,
    id,
    id,
    double,
    int64_t,
    CMTime *,
    NSError **
);

// ---------------------------------------------------------------------------
// YTUHDVPXVideoDecoder
// ---------------------------------------------------------------------------
@interface YTUHDVPXVideoDecoder : NSObject
- (instancetype)initWithDelegate:(id<HAMVideoDecoderDelegate>)delegate
                   delegateQueue:(dispatch_queue_t)delegateQueue
                     decodeQueue:(dispatch_queue_t)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMVPXDecoderConfig)config;
- (void)prepare;
- (void)terminate;
- (void)discardPendingFrames;
- (BOOL)canAcceptFormatWithDescription:(id)formatDescription;
- (void)decodeSampleBuffer:(id)sampleBuffer completionHandler:(id)completionHandler;
- (NSInteger)samplesPendingDecode;
@end

@interface YTUHDVPXVideoDecoder () {
    __weak id<HAMVideoDecoderDelegate> _delegate;
    dispatch_queue_t    _delegateQueue;
    dispatch_queue_t    _decodeQueue;
    HAMVPXDecoderConfig _config;
    _Atomic(int)        _samplesPendingDecode;
    _Atomic(uint32_t)   _frameEra;
    BOOL                _terminated;
    vpx_codec_ctx_t     _decoder;      // .name != NULL ↔ initialised
    id                  _pixelBufferPool;  // HAMPixelBufferPool instance
}
@end

@implementation YTUHDVPXVideoDecoder

// ---------------------------------------------------------------------------
#pragma mark - Init / dealloc
// ---------------------------------------------------------------------------

- (instancetype)initWithDelegate:(id<HAMVideoDecoderDelegate>)delegate
                   delegateQueue:(dispatch_queue_t)delegateQueue
                     decodeQueue:(dispatch_queue_t)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMVPXDecoderConfig)config {
    self = [super init];
    if (!self) return nil;

    _delegate      = delegate;
    _delegateQueue = delegateQueue;
    _decodeQueue   = decodeQueue;
    _config        = config;
    _terminated    = NO;
    memset(&_decoder, 0, sizeof(_decoder));
    atomic_init(&_samplesPendingDecode, 0);
    atomic_init(&_frameEra, 0u);

    Class poolClass = NSClassFromString(@"HAMPixelBufferPool");
    if (poolClass) {
        _pixelBufferPool = [[poolClass alloc]
            performSelector:@selector(initWithPixelBufferAttributes:)
                 withObject:pixelBufferAttributes];
    }
    return self;
}

- (void)dealloc {
    if (_decoder.name) {
        vpx_codec_destroy(&_decoder);
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Public HAMVideoDecoder interface
// ---------------------------------------------------------------------------

- (void)prepare {
    dispatch_async(_decodeQueue, ^{
        [self internalPrepare];
    });
}

- (void)terminate {
    dispatch_async(_decodeQueue, ^{
        [self terminateWithError:nil];
    });
}

- (void)discardPendingFrames {
    atomic_fetch_add(&_frameEra, 1u);
}

- (BOOL)canAcceptFormatWithDescription:(__unused id)formatDescription {
    return YES;
}

- (NSInteger)samplesPendingDecode {
    return (NSInteger)atomic_load(&_samplesPendingDecode);
}

- (void)decodeSampleBuffer:(id)sampleBuffer completionHandler:(id)completionHandler {
    if (_terminated) return;

    HAMInputSampleBuffer *buf = (HAMInputSampleBuffer *)sampleBuffer;
    NSInteger count = [buf sampleCount];
    if (count <= 0) return;

    atomic_fetch_add(&_samplesPendingDecode, (int)count);
    uint32_t era = atomic_load(&_frameEra);

    // Copy block to heap so it survives dispatch.
    id handlerCopy = [completionHandler copy];

    dispatch_async(_decodeQueue, ^{
        [self internalDecodeSampleBuffer:buf frameEra:era completionHandler:handlerCopy];
    });
}

// ---------------------------------------------------------------------------
#pragma mark - Internal (run on _decodeQueue)
// ---------------------------------------------------------------------------

- (void)internalPrepare {
    int threads = (_config.threads > 0) ? _config.threads : 2;
    vpx_codec_dec_cfg_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.threads = (unsigned int)threads;

    vpx_codec_err_t err = vpx_codec_dec_init_ver(
        &_decoder, vpx_codec_vp9_dx(), &cfg, 0, VPX_DECODER_ABI_VERSION);

    if (err != VPX_CODEC_OK) {
        NSError *error = [NSError
            errorWithDomain:@"YTUHDVPXVideoDecoder"
                       code:err
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:
                           @"vpx_codec_dec_init_ver failed: %d", err]}];
        [self terminateWithError:error];
        return;
    }

    // VP9_SET_SKIP_LOOP_FILTER  = 265
    vpx_codec_control(&_decoder, VP9_SET_SKIP_LOOP_FILTER,
                      (int)_config.skipLoopFilter);
    // VP9D_SET_LOOP_FILTER_OPT  = 269
    vpx_codec_control(&_decoder, VP9D_SET_LOOP_FILTER_OPT,
                      (int)_config.loopFilterOptimization);
    // VP9D_SET_ROW_MT           = 268
    vpx_codec_control(&_decoder, VP9D_SET_ROW_MT,
                      (int)_config.rowThreading);

    __weak id<HAMVideoDecoderDelegate> weakDelegate = _delegate;
    __weak YTUHDVPXVideoDecoder *weakSelf = self;
    dispatch_async(_delegateQueue, ^{
        [weakDelegate videoDecoderDidPrepare:weakSelf];
    });
}

- (void)terminateWithError:(NSError *)error {
    if (_decoder.name) {
        vpx_codec_destroy(&_decoder);
        memset(&_decoder, 0, sizeof(_decoder));
    }
    _pixelBufferPool = nil;
    _terminated = YES;

    __weak id<HAMVideoDecoderDelegate> weakDelegate = _delegate;
    __weak YTUHDVPXVideoDecoder *weakSelf = self;
    NSError *capturedError = error;
    dispatch_async(_delegateQueue, ^{
        if (capturedError) {
            [weakDelegate videoDecoder:weakSelf didFailWithError:capturedError];
        } else {
            [weakDelegate videoDecoderDidTerminate:weakSelf];
        }
    });
}

- (void)internalDecodeSampleBuffer:(HAMInputSampleBuffer *)sampleBuffer
                          frameEra:(uint32_t)era
                 completionHandler:(id)completionHandler {
    if (!_decoder.name || atomic_load(&_frameEra) != era) {
        atomic_fetch_sub(&_samplesPendingDecode,
                         (int)[sampleBuffer sampleCount]);
        return;
    }

    BOOL    dropFrames        = [sampleBuffer dropFrames];
    id      formatSelection   = [sampleBuffer formatSelection];
    id      formatDescription = [sampleBuffer formatDescription];
    double  productionTime    = [sampleBuffer productionTime];
    int64_t periodID          = [sampleBuffer periodID];

    NSData        *data        = [sampleBuffer data];
    const uint8_t *bytes       = (const uint8_t *)[data bytes];
    NSInteger      sampleCount = [sampleBuffer sampleCount];
    NSInteger      byteOffset  = 0;

    // Resolve pixelBufferPool selector once (new YT >= ~20.47 signature).
    static SEL s_pixelBufSel;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_pixelBufSel = NSSelectorFromString(
            @"pixelBufferWithPlanarImage:presentationTime:"
             "presentationDuration:formatSelection:formatDescription:"
             "productionTime:periodID:originalPresentationTime:error:");
    });

    for (NSInteger i = 0; i < sampleCount; i++) {
        @autoreleasepool {
            NSInteger sampleSize = [sampleBuffer sizeForSample:i];
            CMSampleTimingInfo timing = [sampleBuffer timingInfoForSample:i];

            vpx_codec_err_t err = vpx_codec_decode(
                &_decoder,
                bytes + byteOffset,
                (unsigned int)sampleSize,
                NULL, 0);
            byteOffset += sampleSize;

            if (err != VPX_CODEC_OK) {
                atomic_fetch_sub(&_samplesPendingDecode,
                                 (int)(sampleCount - i));
                NSError *decodeError = [NSError
                    errorWithDomain:@"YTUHDVPXVideoDecoder"
                               code:err
                           userInfo:@{NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:
                                   @"vpx_codec_decode: %d", err]}];
                [self terminateWithError:decodeError];
                return;
            }

            atomic_fetch_sub(&_samplesPendingDecode, 1);

            if (dropFrames || atomic_load(&_frameEra) != era) continue;

            vpx_codec_iter_t iter = NULL;
            vpx_image_t *img;
            while ((img = vpx_codec_get_frame(&_decoder, &iter)) != NULL) {
                if (atomic_load(&_frameEra) != era) break;

                // Only I420 (8-bit) and I42016 (10-bit 4:2:0 planar) accepted
                if (img->fmt != VPX_IMG_FMT_I420 &&
                    img->fmt != VPX_IMG_FMT_I42016) continue;

                if (!_pixelBufferPool) continue;

                HAMPlanarImage planar = {
                    .planeY   = img->planes[VPX_PLANE_Y],
                    .planeCb  = img->planes[VPX_PLANE_U],
                    .planeCr  = img->planes[VPX_PLANE_V],
                    .strideY  = (uint64_t)(unsigned)img->stride[VPX_PLANE_Y],
                    .strideCb = (uint64_t)(unsigned)img->stride[VPX_PLANE_U],
                    .strideCr = (uint64_t)(unsigned)img->stride[VPX_PLANE_V],
                    .width    = img->d_w,
                    .height   = img->d_h,
                    .bitDepth = (int32_t)img->bit_depth,
                };

                CMTime presentationTime     = timing.presentationTimeStamp;
                CMTime presentationDuration = timing.duration;
                CMTime originalPT           = kCMTimeInvalid;
                if ([sampleBuffer respondsToSelector:
                        @selector(originalPresentationTime)]) {
                    originalPT = [sampleBuffer originalPresentationTime];
                }

                NSError *pbError = nil;
                PixelBufferPoolFn fn = (PixelBufferPoolFn)objc_msgSend;
                id hamBuffer = fn(
                    _pixelBufferPool, s_pixelBufSel,
                    &planar,
                    &presentationTime,
                    &presentationDuration,
                    formatSelection,
                    formatDescription,
                    productionTime,
                    periodID,
                    &originalPT,
                    &pbError);

                if (!hamBuffer) {
                    [self terminateWithError:pbError];
                    return;
                }

                void (^handler)(id) = (void (^)(id))completionHandler;
                handler(hamBuffer);
            }
        }
    }
}

@end
