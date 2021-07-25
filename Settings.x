#import "Header.h"
#import "../YouTubeHeader/YTSettingsViewController.h"
#import "../YouTubeHeader/YTAppSettingsSectionItemActionController.h"
#import "../YouTubeHeader/YTSettingsSectionItem.h"
#import "../YouTubeHeader/YTSettingsSectionItemManager.h"
#import "../YouTubeHeader/YTAppSettingsStore.h"

static const int UseVP9Number = 1040;

extern BOOL UseVP9();

%hook YTAppSettingsStore

+ (NSUInteger)valueTypeForSetting:(int)setting {
    return setting == UseVP9Number ? 1 : %orig;
}

- (void)setBool:(BOOL)value forSetting:(int)setting {
    if (setting == UseVP9Number) {
        [[NSUserDefaults standardUserDefaults] setBool:value forKey:ENABLE_VP9_KEY];
        return;
    }
    %orig;
}

- (BOOL)boolForSetting:(int)setting {
    return setting == UseVP9Number ? UseVP9() : %orig;
}

%end

%hook YTSettingsViewController

- (void)setSectionItems:(NSMutableArray <YTSettingsSectionItem *> *)sectionItems forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden {
    if (category == 14) {
        YTAppSettingsSectionItemActionController *sectionItemActionController = [self valueForKey:@"_sectionItemActionController"];
        YTSettingsSectionItemManager *sectionItemManager = [sectionItemActionController valueForKey:@"_sectionItemManager"];
        YTAppSettingsStore *appSettingsStore = [sectionItemManager valueForKey:@"_appSettingsStore"];
        YTSettingsSectionItem *vp9 = [%c(YTSettingsSectionItem) switchItemWithTitle:@"Use VP9 codec"
            titleDescription:@"This enables usage of VP9 codec for HD videos, and in effect, enables video quality of 2K and 4K."
            accessibilityIdentifier:nil
            switchOn:[appSettingsStore boolForSetting:UseVP9Number]
            switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
                if (appSettingsStore) {
                    [appSettingsStore setBool:enabled forSetting:UseVP9Number];
                    return YES;
                }
                return NO;
            }
            settingItemId:UseVP9Number];
        [sectionItems addObject:vp9];
    }
    %orig(sectionItems, category, title, titleDescription, headerHidden);
}

%end