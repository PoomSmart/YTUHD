#import "Header.h"
#import "../YouTubeHeader/YTSettingsViewController.h"
#import "../YouTubeHeader/YTSettingsSectionItem.h"
#import "../YouTubeHeader/YTSettingsSectionItemManager.h"
#import "../YouTubeHeader/YTAppSettingsSectionItemActionController.h"

extern BOOL UseVP9();

%hook YTSettingsViewController

- (void)setSectionItems:(NSMutableArray <YTSettingsSectionItem *> *)sectionItems forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden {
    YTAppSettingsSectionItemActionController *sectionItemActionController = [self valueForKey:@"_sectionItemActionController"];
    YTSettingsSectionItemManager *sectionItemManager = [sectionItemActionController valueForKey:@"_sectionItemManager"];
    BOOL isThatSection = category == ([sectionItemManager respondsToSelector:@selector(updateVideoQualitySectionWithEntry:)] ? 14 : 1);
    if (isThatSection) {
        YTSettingsSectionItem *vp9 = [%c(YTSettingsSectionItem) switchItemWithTitle:@"Use VP9 codec"
            titleDescription:@"This enables usage of VP9 codec for HD videos, and in effect, enables video quality of 2K and 4K. App restart is required."
            accessibilityIdentifier:nil
            switchOn:UseVP9()
            switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
                [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UseVP9Key];
                return YES;
            }
            settingItemId:0];
        if (category == 1) {
            NSUInteger index = [sectionItems indexOfObjectPassingTest:^BOOL (YTSettingsSectionItem *item, NSUInteger idx, BOOL *stop) { 
                return [[item valueForKey:@"_accessibilityIdentifier"] isEqualToString:@"id.settings.restricted_mode.switch"];
            }];
            [sectionItems insertObject:vp9 atIndex:index + 1];
        } else
            [sectionItems addObject:vp9];
    }
    %orig(sectionItems, category, title, titleDescription, headerHidden);
}

%end