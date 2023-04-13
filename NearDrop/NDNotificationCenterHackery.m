//
//  NDNotificationCenterHackery.m
//  NearDrop
//
//  Created by Grishka on 10.04.2023.
//

#import <UserNotifications/UserNotifications.h>
#import <AppKit/AppKit.h>
#import "NDNotificationCenterHackery.h"

@interface UNMutableNotificationCategory : UNNotificationCategory
@property(copy) NSString *actionsMenuTitle;
@property(copy) UNNotificationAction *alternateAction;
@property(copy) NSArray *minimalActions;
@property unsigned long long backgroundStyle;
@property(copy) NSArray *actions;
@end

@interface UNNotificationIcon : NSObject
+ (id)iconForApplicationIdentifier:(id)arg1;
+ (id)iconAtPath:(id)arg1;
+ (id)iconNamed:(id)arg1;
@end

@interface UNMutableNotificationContent (NDPrivateAPIs)
@property BOOL hasDefaultAction;
@property(copy) NSString *defaultActionTitle;
@property(copy) NSString *header;
@property (assign,nonatomic) BOOL shouldDisplayActionsInline;
@property (assign,nonatomic) BOOL shouldShowSubordinateIcon;
@property (nonatomic,copy) NSString * accessoryImageName;
@property(copy) UNNotificationIcon *icon;
@end

@implementation NDNotificationCenterHackery

+ (UNNotificationCategory*)hackedNotificationCategory{
	UNNotificationAction *accept=[UNNotificationAction actionWithIdentifier:@"ACCEPT" title:NSLocalizedString(@"Accept", nil) options:0];
	UNNotificationAction *decline=[UNNotificationAction actionWithIdentifier:@"DECLINE" title:NSLocalizedString(@"Decline", nil) options:0];
	UNMutableNotificationCategory *category=[UNMutableNotificationCategory categoryWithIdentifier:@"INCOMING_TRANSFERS" actions:@[accept, decline] intentIdentifiers:@[] hiddenPreviewsBodyPlaceholder:@"" options: UNNotificationCategoryOptionCustomDismissAction];
	return category;
}

+ (void)removeDefaultAction:(UNMutableNotificationContent*) content{
	content.hasDefaultAction=false;
}

@end
