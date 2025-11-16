#import <PSHeader/Misc.h>
#import <VideoToolbox/VideoToolbox.h>
#import <YouTubeHeader/YTHotConfig.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import "Header.h"

#define TweakName @"YTUHD"

#define LOC(x) [tweakBundle localizedStringForKey:x value:nil table:nil]

static const NSInteger TweakSection = 'ythd';

@interface YTSettingsSectionItemManager (YTUHD)
- (void)updateYTUHDSectionWithEntry:(id)entry;
@end

BOOL UseVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UseVP9Key];
}

BOOL AllVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:AllVP9Key];
}

BOOL DisableServerABR() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:DisableServerABRKey];
}

int DecodeThreads() {
    return [[NSUserDefaults standardUserDefaults] integerForKey:DecodeThreadsKey];
}

BOOL SkipLoopFilter() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SkipLoopFilterKey];
}

BOOL LoopFilterOptimization() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:LoopFilterOptimizationKey];
}

BOOL RowThreading() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:RowThreadingKey];
}

NSBundle *YTUHDBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"YTUHD" ofType:@"bundle"];
        bundle = [NSBundle bundleWithPath:tweakBundlePath ?: PS_ROOT_PATH_NS(@"/Library/Application Support/YTUHD.bundle")];
    });
    return bundle;
}

%hook YTSettingsGroupData

- (NSArray <NSNumber *> *)orderedCategories {
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
        return %orig;
    NSMutableArray *mutableCategories = %orig.mutableCopy;
    [mutableCategories insertObject:@(TweakSection) atIndex:0];
    return mutableCategories.copy;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    NSArray <NSNumber *> *order = %orig;
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    if (insertIndex != NSNotFound) {
        NSMutableArray <NSNumber *> *mutableOrder = [order mutableCopy];
        [mutableOrder insertObject:@(TweakSection) atIndex:insertIndex + 1];
        order = mutableOrder.copy;
    }
    return order;
}

%end

%hook YTSettingsSectionItemManager

- (void)updateVideoQualitySectionWithEntry:(id)entry {
    YTHotConfig *hotConfig = [self valueForKey:@"_hotConfig"];
    YTIMediaQualitySettingsHotConfig *mediaQualitySettingsHotConfig = [hotConfig hotConfigGroup].mediaHotConfig.mediaQualitySettingsHotConfig;
    BOOL defaultValue = mediaQualitySettingsHotConfig.enablePersistentVideoQualitySettings;
    mediaQualitySettingsHotConfig.enablePersistentVideoQualitySettings = YES;
    %orig;
    mediaQualitySettingsHotConfig.enablePersistentVideoQualitySettings = defaultValue;
}

%new(v@:@)
- (void)updateYTUHDSectionWithEntry:(id)entry {
    NSMutableArray <YTSettingsSectionItem *> *sectionItems = [NSMutableArray array];
    NSBundle *tweakBundle = YTUHDBundle();
    BOOL hasVP9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
    Class YTSettingsSectionItemClass = %c(YTSettingsSectionItem);
    YTSettingsViewController *settingsViewController = [self valueForKey:@"_settingsViewControllerDelegate"];

    // Use VP9
    YTSettingsSectionItem *vp9 = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"USE_VP9")
        titleDescription:[NSString stringWithFormat:@"%@\n\n%@: %d", LOC(@"USE_VP9_DESC"), LOC(@"HW_VP9_SUPPORT"), hasVP9]
        accessibilityIdentifier:nil
        switchOn:UseVP9()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UseVP9Key];
            return YES;
        }
        settingItemId:0];
    [sectionItems addObject:vp9];

    // All VP9
    YTSettingsSectionItem *allVP9 = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"ALL_VP9")
        titleDescription:LOC(@"ALL_VP9_DESC")
        accessibilityIdentifier:nil
        switchOn:AllVP9()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:AllVP9Key];
            return YES;
        }
        settingItemId:0];
    [sectionItems addObject:allVP9];

    // Disable server ABR
    YTSettingsSectionItem *disableServerABR = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"DISABLE_SERVER_ABR")
        titleDescription:LOC(@"DISABLE_SERVER_ABR_DESC")
        accessibilityIdentifier:nil
        switchOn:DisableServerABR()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:DisableServerABRKey];
            return YES;
        }
        settingItemId:0];
    [sectionItems addObject:disableServerABR];

    // Decode threads
    NSString *decodeThreadsTitle = LOC(@"DECODE_THREADS");
    YTSettingsSectionItem *decodeThreads = [YTSettingsSectionItemClass itemWithTitle:decodeThreadsTitle
        titleDescription:LOC(@"DECODE_THREADS_DESC")
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *() {
            return [NSString stringWithFormat:@"%d", DecodeThreads()];
        }
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            NSMutableArray <YTSettingsSectionItem *> *rows = [NSMutableArray array];
            for (int i = 1; i <= NSProcessInfo.processInfo.activeProcessorCount; ++i) {
                NSString *title = [NSString stringWithFormat:@"%d", i];
                NSString *titleDescription = i == 2 ? LOC(@"DECODE_THREADS_DEFAULT_VALUE") : nil;
                YTSettingsSectionItem *thread = [YTSettingsSectionItemClass checkmarkItemWithTitle:title titleDescription:titleDescription selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
                    [[NSUserDefaults standardUserDefaults] setInteger:i forKey:DecodeThreadsKey];
                    [settingsViewController reloadData];
                    return YES;
                }];
                [rows addObject:thread];
            }
            NSUInteger index = DecodeThreads() - 1;
            if (index >= NSProcessInfo.processInfo.activeProcessorCount) {
                index = 1;
                [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:DecodeThreadsKey];
            }
            YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc] initWithNavTitle:decodeThreadsTitle pickerSectionTitle:nil rows:rows selectedItemIndex:index parentResponder:[settingsViewController parentResponder]];
            [settingsViewController pushViewController:picker];
            return YES;
        }];
    [sectionItems addObject:decodeThreads];

    // Skip loop filter
    YTSettingsSectionItem *skipLoopFilter = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"SKIP_LOOP_FILTER")
        titleDescription:nil
        accessibilityIdentifier:nil
        switchOn:SkipLoopFilter()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SkipLoopFilterKey];
            return YES;
        }
        settingItemId:0];
    [sectionItems addObject:skipLoopFilter];

    // Loop filter optimization
    YTSettingsSectionItem *loopFilterOptimization = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"LOOP_FILTER_OPTIMIZATION")
        titleDescription:nil
        accessibilityIdentifier:nil
        switchOn:LoopFilterOptimization()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:LoopFilterOptimizationKey];
            return YES;
        }
        settingItemId:0];
    [sectionItems addObject:loopFilterOptimization];

    // Row threading
    YTSettingsSectionItem *rowThreading = [YTSettingsSectionItemClass switchItemWithTitle:LOC(@"ROW_THREADING")
        titleDescription:nil
        accessibilityIdentifier:nil
        switchOn:RowThreading()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:RowThreadingKey];
            return YES;
        }
        settingItemId:0];
    [sectionItems addObject:rowThreading];

    if ([settingsViewController respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        YTIIcon *icon = [%c(YTIIcon) new];
        icon.iconType = YT_SETTINGS_HD;
        [settingsViewController setSectionItems:sectionItems forCategory:TweakSection title:TweakName icon:icon titleDescription:nil headerHidden:NO];
    } else
        [settingsViewController setSectionItems:sectionItems forCategory:TweakSection title:TweakName titleDescription:nil headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == TweakSection) {
        [self updateYTUHDSectionWithEntry:entry];
        return;
    }
    %orig;
}

%end