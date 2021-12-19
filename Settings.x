#import "Header.h"
#import <VideoToolbox/VideoToolbox.h>
#import <dlfcn.h>
#import "../YouTubeHeader/YTHotConfig.h"
#import "../YouTubeHeader/YTSettingsViewController.h"
#import "../YouTubeHeader/YTSettingsSectionItem.h"
#import "../YouTubeHeader/YTSettingsSectionItemManager.h"

extern BOOL UseVP9();

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

%hook YTSettingsViewController

- (void)setSectionItems:(NSMutableArray <YTSettingsSectionItem *> *)sectionItems forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden {
    if (category == 14) {
        BOOL hasVP9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
        void *avd = dlopen("/System/Library/VideoDecoders/AVD.videodecoder", RTLD_NOW);
        YTSettingsSectionItem *vp9 = [%c(YTSettingsSectionItem) switchItemWithTitle:@"Use VP9 codec"
            titleDescription:[NSString stringWithFormat:@"Enable VP9 codec which supports up to 4K resolutions. App restart is required.\
                \n\nVP9 Support: %d, Decoder: %d", hasVP9, avd != NULL]
            accessibilityIdentifier:nil
            switchOn:UseVP9()
            switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
                [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UseVP9Key];
                return YES;
            }
            settingItemId:0];
        // vp9.enabled = hasVP9;
        [sectionItems addObject:vp9];
    }
    %orig(sectionItems, category, title, titleDescription, headerHidden);
}

%end