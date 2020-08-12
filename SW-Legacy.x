#import <sys/sysctl.h>
#import "Header.h"

%hook MLABRPolicy

- (void)setFormats:(NSArray <MLFormat *> *)formats {
    %orig(formats);
    NSArray *originalSortedFormats = [self valueForKey:@"_sortedFormats"];
    if (originalSortedFormats.count && [originalSortedFormats[0] isVideo]) {
        NSMutableArray *sortedFormats = [NSMutableArray arrayWithArray:originalSortedFormats];
        NSMutableDictionary <MLFormat *, MLABRPolicyFormatData *> *formatToData = [NSMutableDictionary dictionaryWithDictionary:[self valueForKey:@"_formatToData"]];
        for (MLFormat *format in formats) {
            if ([originalSortedFormats containsObject:format]) continue;
            if ([format codec] == 'vp09' || [format codec] == 'qvp9') {
                [sortedFormats insertObject:format atIndex:0];
                MLABRPolicyFormatData *formatData = [[%c(MLABRPolicyFormatData) alloc] initWithFormat:format];
                formatToData[format] = [formatData retain];
            }
        }
        [self setValue:[[sortedFormats sortedArrayUsingComparator:^NSComparisonResult(id format1, id format2) {
            MLFormat *f1 = (MLFormat *)format1;
            MLFormat *f2 = (MLFormat *)format2;
            return [f2 compareByQuality:f1];
        }] retain] forKey:@"_sortedFormats"];
        [self setValue:[formatToData retain] forKey:@"_formatToData"];
        NSObject <OS_dispatch_queue> *queue = [self valueForKey:@"_queue"];
        dispatch_async(queue, ^{
            [self requestFormatReselection];
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            MLHAMPlayerItem *playerItem = [self valueForKey:@"_policyDelegate"];
            [playerItem ABRPolicy:self selectableFormatsDidChange:sortedFormats];
        });
    }
}

%end

%hook YTSettings

- (bool)isWebMEnabled {
    return YES;
}

%end

%hook YTUserDefaults

- (int)manualQualitySelectionChosenResolution {
    return MAX_HEIGHT;
}

- (int)manualQualitySelectionPrecedingResolution {
    return MAX_HEIGHT;
}

%end

%hook MLManualFormatSelectionMetadata

- (int)stickyCeilingResolution {
    return MAX_HEIGHT;
}

%end

%hook UIDevice

- (NSString *)systemVersion {
    return @"14.0";
}

%end

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion version;
    version.majorVersion = 14;
    version.minorVersion = 0;
    version.patchVersion = 0;
    return version;
}

%end

%hook YTVersionUtils

+ (NSString *)OSBuild {
    return @(IOS_BUILD);
}

%end

%hookf(int, sysctlbyname, const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (strcmp(name, "kern.osversion") == 0) {
        if (oldp)
            strcpy((char *)oldp, IOS_BUILD);
        *oldlenp = strlen(IOS_BUILD);
    }
    return %orig(name, oldp, oldlenp, newp, newlen);
}

%ctor {
    %init;
}
