/**
 * HAMDav1dVideoDecoder.m
 *
 * Software AV1 decoder for old YouTube versions (< 20) that have no
 * native dav1d / AV1 software decoder.
 *
 * Provides YTUHDDav1dVideoDecoder — injected by the factory hook in
 * Tweak.xm when:
 *   • UseAV1() is enabled in Settings
 *   • The native HAMDav1dVideoDecoder class is absent (old YouTube)
 *   • VTIsHardwareDecodeSupported(AV1) returns NO (no hardware AV1)
 *
 * Mirrors the design of YTUHDVPXVideoDecoder (HAMVPXVideoDecoder.m)
 * and uses the same HAMPixelBufferPool / HAMPlanarImage interface.
 */

#import <CoreMedia/CoreMedia.h>
#import <YouTubeHeader/HAMInputSampleBuffer.h>
#import <YouTubeHeader/HAMVideoDecoderDelegate.h>
#import <objc/message.h>
#import <stdatomic.h>

#include "dav1d/dav1d.h"

#import "Header.h"

// ---------------------------------------------------------------------------
// HAMPlanarImage — see HAMVPXVideoDecoder.m for layout notes.
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
} _HAMDav1dPlanarImage;

// ---------------------------------------------------------------------------
// Two function-pointer types for -[HAMPixelBufferPool pixelBufferWithPlanarImage:...]
//
// YT < 20.47 (short — YT19):  ...productionTime:periodID:error:
// YT >= 20.47 (long):         ...productionTime:periodID:originalPresentationTime:error:
// ---------------------------------------------------------------------------
typedef id (*_PixelBufShortFn)(id, SEL,
    const _HAMDav1dPlanarImage *,
    CMTime *, CMTime *,
    id, id,
    double, int64_t,
    NSError **);

typedef id (*_PixelBufLongFn)(id, SEL,
    const _HAMDav1dPlanarImage *,
    CMTime *, CMTime *,
    id, id,
    double, int64_t,
    CMTime *,
    NSError **
);

// ---------------------------------------------------------------------------
// YTUHDDav1dVideoDecoder
// ---------------------------------------------------------------------------
@interface YTUHDDav1dVideoDecoder : NSObject
- (instancetype)initWithDelegate:(id<HAMVideoDecoderDelegate>)delegate
                   delegateQueue:(dispatch_queue_t)delegateQueue
                     decodeQueue:(dispatch_queue_t)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMDav1dDecoderConfig)config;
- (void)prepare;
- (void)terminate;
- (void)discardPendingFrames;
- (BOOL)canAcceptFormatWithDescription:(id)formatDescription;
- (void)decodeSampleBuffer:(id)sampleBuffer completionHandler:(id)completionHandler;
- (NSInteger)samplesPendingDecode;
@end

@interface YTUHDDav1dVideoDecoder () {
    __weak id<HAMVideoDecoderDelegate> _delegate;
    dispatch_queue_t       _delegateQueue;
    dispatch_queue_t       _decodeQueue;
    HAMDav1dDecoderConfig  _config;
    _Atomic(int)           _samplesPendingDecode;
    _Atomic(uint32_t)      _frameEra;
    BOOL                   _terminated;
    Dav1dContext          *_dav1dCtx;          // NULL when not initialised
    id                     _pixelBufferPool;   // HAMPixelBufferPool instance
}
@end

@implementation YTUHDDav1dVideoDecoder

// ---------------------------------------------------------------------------
#pragma mark - Init / dealloc
// ---------------------------------------------------------------------------

- (instancetype)initWithDelegate:(id<HAMVideoDecoderDelegate>)delegate
                   delegateQueue:(dispatch_queue_t)delegateQueue
                     decodeQueue:(dispatch_queue_t)decodeQueue
           pixelBufferAttributes:(id)pixelBufferAttributes
                          config:(HAMDav1dDecoderConfig)config {
    self = [super init];
    if (!self) return nil;

    _delegate      = delegate;
    _delegateQueue = delegateQueue;
    _decodeQueue   = decodeQueue;
    _config        = config;
    _terminated    = NO;
    _dav1dCtx      = NULL;
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
    if (_dav1dCtx) {
        dav1d_close(&_dav1dCtx);
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
    dispatch_async(_decodeQueue, ^{
        if (_dav1dCtx) dav1d_flush(_dav1dCtx);
    });
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

    id handlerCopy = [completionHandler copy];

    dispatch_async(_decodeQueue, ^{
        [self internalDecodeSampleBuffer:buf frameEra:era completionHandler:handlerCopy];
    });
}

// ---------------------------------------------------------------------------
#pragma mark - Internal (run on _decodeQueue)
// ---------------------------------------------------------------------------

- (void)internalPrepare {
    Dav1dSettings s;
    dav1d_default_settings(&s);

    int threads = (_config.threads > 0) ? _config.threads : 2;
    s.n_threads      = threads;
    s.max_frame_delay = 1;          // low-latency: output each frame ASAP
    s.apply_grain    = _config.applyGrain ? 1 : 0;

    int res = dav1d_open(&_dav1dCtx, &s);
    if (res < 0) {
        NSError *error = [NSError
            errorWithDomain:@"YTUHDDav1dVideoDecoder"
                       code:res
                   userInfo:@{NSLocalizedDescriptionKey:
                       [NSString stringWithFormat:@"dav1d_open failed: %d", res]}];
        [self terminateWithError:error];
        return;
    }

    __weak id<HAMVideoDecoderDelegate> weakDelegate = _delegate;
    __weak YTUHDDav1dVideoDecoder *weakSelf = self;
    dispatch_async(_delegateQueue, ^{
        [weakDelegate videoDecoderDidPrepare:weakSelf];
    });
}

- (void)terminateWithError:(NSError *)error {
    if (_dav1dCtx) {
        dav1d_close(&_dav1dCtx);
        _dav1dCtx = NULL;
    }
    _pixelBufferPool = nil;
    _terminated = YES;

    __weak id<HAMVideoDecoderDelegate> weakDelegate = _delegate;
    __weak YTUHDDav1dVideoDecoder *weakSelf = self;
    NSError *capturedError = error;
    dispatch_async(_delegateQueue, ^{
        if (capturedError) {
            [weakDelegate videoDecoder:weakSelf didFailWithError:capturedError];
        } else {
            [weakDelegate videoDecoderDidTerminate:weakSelf];
        }
    });
}

// Free callback for dav1d_data_wrap — must be a plain C function pointer.
static void _dav1dFreeBuffer(const uint8_t *data, void *cookie) {
    free((void *)data);
}

// Resolve the HAMPixelBufferPool selector at runtime — YT19 has the short form
// without originalPresentationTime:, YT >= 20.47 has the long form.
static SEL  s_dav1dPixelBufSel;
static BOOL s_dav1dPixelBufHasOrigPT;
static dispatch_once_t s_dav1dOnce;

static void ensureDav1dPixelBufSel(id pool) {
    dispatch_once(&s_dav1dOnce, ^{
        SEL longSel = NSSelectorFromString(
            @"pixelBufferWithPlanarImage:presentationTime:"
             "presentationDuration:formatSelection:formatDescription:"
             "productionTime:periodID:originalPresentationTime:error:");
        SEL shortSel = NSSelectorFromString(
            @"pixelBufferWithPlanarImage:presentationTime:"
             "presentationDuration:formatSelection:formatDescription:"
             "productionTime:periodID:error:");
        if ([pool respondsToSelector:longSel]) {
            s_dav1dPixelBufSel    = longSel;
            s_dav1dPixelBufHasOrigPT = YES;
        } else {
            s_dav1dPixelBufSel    = shortSel;
            s_dav1dPixelBufHasOrigPT = NO;
        }
    });
}

- (void)internalDecodeSampleBuffer:(HAMInputSampleBuffer *)sampleBuffer
                          frameEra:(uint32_t)era
                 completionHandler:(id)completionHandler {
    if (!_dav1dCtx || atomic_load(&_frameEra) != era) {
        atomic_fetch_sub(&_samplesPendingDecode,
                         (int)[sampleBuffer sampleCount]);
        return;
    }

    ensureDav1dPixelBufSel(_pixelBufferPool);

    BOOL    dropFrames        = [sampleBuffer dropFrames];
    id      formatSelection   = [sampleBuffer formatSelection];
    id      formatDescription = [sampleBuffer formatDescription];
    double  productionTime    = [sampleBuffer productionTime];
    int64_t periodID          = [sampleBuffer periodID];

    NSData        *data        = [sampleBuffer data];
    const uint8_t *bytes       = (const uint8_t *)[data bytes];
    NSInteger      sampleCount = [sampleBuffer sampleCount];
    NSInteger      byteOffset  = 0;

    for (NSInteger i = 0; i < sampleCount; i++) {
        @autoreleasepool {
            NSInteger sampleSize = [sampleBuffer sizeForSample:i];
            CMSampleTimingInfo timing = [sampleBuffer timingInfoForSample:i];

            // Copy sample bytes to a malloc buffer owned by the Dav1dData.
            uint8_t *pktBuf = (uint8_t *)malloc((size_t)sampleSize);
            if (!pktBuf) {
                atomic_fetch_sub(&_samplesPendingDecode,
                                 (int)(sampleCount - i));
                NSError *oomError = [NSError
                    errorWithDomain:@"YTUHDDav1dVideoDecoder"
                               code:ENOMEM
                           userInfo:@{NSLocalizedDescriptionKey: @"malloc failed"}];
                [self terminateWithError:oomError];
                return;
            }
            memcpy(pktBuf, bytes + byteOffset, (size_t)sampleSize);
            byteOffset += sampleSize;

            Dav1dData pkt;
            memset(&pkt, 0, sizeof(pkt));
            // dav1d_data_wrap takes ownership; the free callback is called
            // by dav1d when the underlying buffer is no longer needed.
            int wrapRes = dav1d_data_wrap(&pkt, pktBuf, (size_t)sampleSize,
                                          _dav1dFreeBuffer, NULL);
            if (wrapRes < 0) {
                free(pktBuf);
                atomic_fetch_sub(&_samplesPendingDecode,
                                 (int)(sampleCount - i));
                NSError *err = [NSError
                    errorWithDomain:@"YTUHDDav1dVideoDecoder"
                               code:wrapRes
                           userInfo:@{NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:
                                   @"dav1d_data_wrap failed: %d", wrapRes]}];
                [self terminateWithError:err];
                return;
            }

            // Push compressed data and pull decoded pictures.
            BOOL sentData = NO;
            BOOL errorOccurred = NO;

            while (!sentData || !errorOccurred) {
                if (!sentData) {
                    int sendRes = dav1d_send_data(_dav1dCtx, &pkt);
                    if (sendRes == 0) {
                        sentData = YES;
                    } else if (sendRes != DAV1D_ERR(EAGAIN)) {
                        // Fatal send error.
                        dav1d_data_unref(&pkt);
                        atomic_fetch_sub(&_samplesPendingDecode,
                                         (int)(sampleCount - i));
                        NSError *sendErr = [NSError
                            errorWithDomain:@"YTUHDDav1dVideoDecoder"
                                       code:sendRes
                                   userInfo:@{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:
                                           @"dav1d_send_data: %d", sendRes]}];
                        [self terminateWithError:sendErr];
                        errorOccurred = YES;
                        break;
                    }
                    // sendRes == DAV1D_ERR(EAGAIN): pipeline full,
                    // drain a picture first then retry.
                }

                Dav1dPicture pic;
                memset(&pic, 0, sizeof(pic));
                int getRes = dav1d_get_picture(_dav1dCtx, &pic);

                if (getRes == 0) {
                    // Got a decoded picture.
                    if (!dropFrames && atomic_load(&_frameEra) == era &&
                        _pixelBufferPool) {

                        // Only I420 (4:2:0 planar) is expected from AV1.
                        if (pic.p.layout == DAV1D_PIXEL_LAYOUT_I420) {
                            _HAMDav1dPlanarImage planar = {
                                .planeY   = (const uint8_t *)pic.data[0],
                                .planeCb  = (const uint8_t *)pic.data[1],
                                .planeCr  = (const uint8_t *)pic.data[2],
                                .strideY  = (uint64_t)llabs(pic.stride[0]),
                                .strideCb = (uint64_t)llabs(pic.stride[1]),
                                .strideCr = (uint64_t)llabs(pic.stride[1]),
                                .width    = (uint64_t)pic.p.w,
                                .height   = (uint64_t)pic.p.h,
                                .bitDepth = (int32_t)pic.p.bpc,
                            };

                            CMTime presentationTime     = timing.presentationTimeStamp;
                            CMTime presentationDuration = timing.duration;

                            NSError *pbError = nil;
                            id hamBuffer;
                            if (s_dav1dPixelBufHasOrigPT) {
                                CMTime originalPT = kCMTimeInvalid;
                                if ([sampleBuffer respondsToSelector:
                                        @selector(originalPresentationTime)])
                                    originalPT = [sampleBuffer originalPresentationTime];
                                _PixelBufLongFn fn = (_PixelBufLongFn)objc_msgSend;
                                hamBuffer = fn(
                                    _pixelBufferPool, s_dav1dPixelBufSel,
                                    &planar,
                                    &presentationTime,
                                    &presentationDuration,
                                    formatSelection,
                                    formatDescription,
                                    productionTime,
                                    periodID,
                                    &originalPT,
                                    &pbError);
                            } else {
                                _PixelBufShortFn fn = (_PixelBufShortFn)objc_msgSend;
                                hamBuffer = fn(
                                    _pixelBufferPool, s_dav1dPixelBufSel,
                                    &planar,
                                    &presentationTime,
                                    &presentationDuration,
                                    formatSelection,
                                    formatDescription,
                                    productionTime,
                                    periodID,
                                    &pbError);
                            }

                            if (hamBuffer) {
                                void (^handler)(id) = (void (^)(id))completionHandler;
                                handler(hamBuffer);
                            } else if (pbError) {
                                dav1d_picture_unref(&pic);
                                dav1d_data_unref(&pkt);
                                atomic_fetch_sub(&_samplesPendingDecode,
                                                 (int)(sampleCount - i));
                                [self terminateWithError:pbError];
                                errorOccurred = YES;
                                break;
                            }
                        }
                    }
                    dav1d_picture_unref(&pic);
                } else if (getRes == DAV1D_ERR(EAGAIN)) {
                    // No picture ready yet — need more input.
                    if (sentData) break; // We already sent; nothing more to do.
                    // else loop to retry dav1d_send_data.
                } else {
                    // Fatal get error.
                    dav1d_data_unref(&pkt);
                    atomic_fetch_sub(&_samplesPendingDecode,
                                     (int)(sampleCount - i));
                    NSError *getErr = [NSError
                        errorWithDomain:@"YTUHDDav1dVideoDecoder"
                                   code:getRes
                               userInfo:@{NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:
                                       @"dav1d_get_picture: %d", getRes]}];
                    [self terminateWithError:getErr];
                    errorOccurred = YES;
                    break;
                }
            }

            if (errorOccurred) return;
            atomic_fetch_sub(&_samplesPendingDecode, 1);
        }
    }
}

@end
