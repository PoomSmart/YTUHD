#import "Header.h"

NSInteger HAMGetSampleSize(HAMInputSampleBuffer *buf, NSInteger i) {
    if ([buf respondsToSelector:@selector(sampleSizeForSample:)]) {
        return [buf sampleSizeForSample:i];
    }

    static ptrdiff_t off;
    if (!off) {
        Ivar iv = class_getInstanceVariable([buf class], "_sampleBuffer");
        off = iv ? ivar_getOffset(iv) : -1;
    }
    CMSampleBufferRef cmBuf = (off > 0)
        ? *(CMSampleBufferRef *)((uint8_t *)(__bridge void *)buf + off) : NULL;
    return (cmBuf) ? CMSampleBufferGetSampleSize(cmBuf, i) : 0;
}

CMSampleTimingInfo HAMGetSampleTiming(HAMInputSampleBuffer *buf, NSInteger i) {
    if ([buf respondsToSelector:@selector(timingInfoForSample:)]) {
        return [buf timingInfoForSample:i];
    }

    static ptrdiff_t off;
    if (!off) {
        Ivar iv = class_getInstanceVariable([buf class], "_sampleBuffer");
        off = iv ? ivar_getOffset(iv) : -1;
    }
    CMSampleBufferRef cmBuf = (off > 0)
        ? *(CMSampleBufferRef *)((uint8_t *)(__bridge void *)buf + off) : NULL;
    CMSampleTimingInfo t;
    if (!cmBuf || CMSampleBufferGetSampleTimingInfo(cmBuf, i, &t) != noErr)
        t = (CMSampleTimingInfo){kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    return t;
}
