#import "Header.h"
#import "../YouTubeHeader/YTSettingsSectionItem.h"

extern BOOL UseVP9();

%hook YTSettingsViewController

- (void)setSectionItems:(NSMutableArray <YTSettingsSectionItem *> *)sectionItems forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden {
    if (category == 14) {
        YTSettingsSectionItem *vp9 = [[%c(YTSettingsSectionItem) alloc] initWithTitle:@"Use VP9 codec" titleDescription:@"This enables usage of VP9 codec for HD videos, and in effect, enables video quality of 2K and 4K."];
        vp9.hasSwitch = vp9.switchVisible = YES;
        vp9.on = UseVP9();
        vp9.switchBlock = ^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:ENABLE_VP9_KEY];
            return YES;
        };
        [sectionItems addObject:vp9];
    }
    %orig(sectionItems, category, title, titleDescription, headerHidden);
}

%end