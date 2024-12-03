#import "Header.h"
#import <rootless.h>
#import <VideoToolbox/VideoToolbox.h>
#import <YouTubeHeader/YTHotConfig.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>

#define LOC(x) [tweakBundle localizedStringForKey:x value:nil table:nil]

BOOL UseVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UseVP9Key];
}

BOOL AllVP9() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:AllVP9Key];
}

NSBundle *YTUHDBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"YTUHD" ofType:@"bundle"];
        if (tweakBundlePath)
            bundle = [NSBundle bundleWithPath:tweakBundlePath];
        else
            bundle = [NSBundle bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/YTUHD.bundle")];
    });
    return bundle;
}

%hook YTSettingsSectionItemManager

- (void)updateVideoQualitySectionWithEntry:(id)entry {
    YTHotConfig *hotConfig;
    @try {
        hotConfig = [self valueForKey:@"_hotConfig"];
    } @catch (id ex) {
        hotConfig = [self.gimme instanceForType:%c(YTHotConfig)];
    }
    YTIMediaQualitySettingsHotConfig *mediaQualitySettingsHotConfig = [hotConfig hotConfigGroup].mediaHotConfig.mediaQualitySettingsHotConfig;
    BOOL defaultValue = mediaQualitySettingsHotConfig.enablePersistentVideoQualitySettings;
    mediaQualitySettingsHotConfig.enablePersistentVideoQualitySettings = YES;
    %orig;
    mediaQualitySettingsHotConfig.enablePersistentVideoQualitySettings = defaultValue;
}

%end

static void addSectionItem(NSMutableArray <YTSettingsSectionItem *> *sectionItems, NSInteger category) {
    if (category != 14) return;
    NSBundle *tweakBundle = YTUHDBundle();
    BOOL hasVP9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
    BOOL hasAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    YTSettingsSectionItem *vp9 = [%c(YTSettingsSectionItem) switchItemWithTitle:LOC(@"USE_VP9")
        titleDescription:[NSString stringWithFormat:@"%@\n\n%@\n\n%@: %d\n%@: %d", LOC(@"USE_VP9_DESC"), LOC(@"YOUPIP_DESC"), LOC(@"HW_VP9_SUPPORT"), hasVP9, LOC(@"HW_AV1_SUPPORT"), hasAV1]
        accessibilityIdentifier:nil
        switchOn:UseVP9()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UseVP9Key];
            return YES;
        }
        settingItemId:0];
    [sectionItems addObject:vp9];
    YTSettingsSectionItem *allVP9 = [%c(YTSettingsSectionItem) switchItemWithTitle:LOC(@"ALL_VP9")
        titleDescription:LOC(@"ALL_VP9_DESC")
        accessibilityIdentifier:nil
        switchOn:AllVP9()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:AllVP9Key];
            return YES;
        }
        settingItemId:0];
    [sectionItems addObject:allVP9];
}

%hook YTSettingsViewController

- (void)setSectionItems:(NSMutableArray <YTSettingsSectionItem *> *)sectionItems forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden {
    addSectionItem(sectionItems, category);
    %orig;
}

- (void)setSectionItems:(NSMutableArray <YTSettingsSectionItem *> *)sectionItems forCategory:(NSInteger)category title:(NSString *)title icon:(YTIIcon *)icon titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden {
    addSectionItem(sectionItems, category);
    %orig;
}

%end
