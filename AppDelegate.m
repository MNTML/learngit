//
//  AppDelegate.m
//  HyacinthBean
//
//  Created by Ryan on 2016/10/14.
//  Copyright © 2016年 Ryan. All rights reserved.
//

#import "AppDelegate.h"
#import "AppDelegate+HBAddition.h"
#import "AppDelegate+HBVendors.h"
#import "AppDelegate+HBCarame.h"
#import "HBUserManager.h"
#import "HBSocketAPIManager.h"
#import "HBApplicationManager.h"
#import "HBHTTPManager.h"
#import "HBDeviceControlFeedBack.h"
#import "HBSecurityManager.h"
#import "HBPushManager.h"
#import "HBLoginViewController.h"
#import "HBNavigationController.h"
#import <xmSDK/xmSDK.h>
#import "SocketManager.h"
#import "XHVersion.h"
// 引入JPush功能所需头文件
#import "JPUSHService.h"
// iOS10注册APNs所需头文件
#ifdef NSFoundationVersionNumber_iOS_9_x_Max
#import <UserNotifications/UserNotifications.h>
#endif
// 如果需要使用idfa功能所需要引入的头文件（可选）
#import <AdSupport/AdSupport.h>
#import "HBAlertDialogView.h"
#import "CYLPlusButtonSubclass.h"
#import "HBSettingManager.h"
#import "HBHomeManager.h"
#import "HBExperienceUser.h"

@interface AppDelegate () <JPUSHRegisterDelegate>
@property (nonatomic, strong) AFNetworkReachabilityManager *manager;
@property (nonatomic, strong) NSTimer *kickOutTimer;
@property (nonatomic, strong) HBAlertDialogView *diglogView;
@property (nonatomic, assign) BOOL isShowAlert;
@end
BOOL gIsGuest = FALSE;
NSString *userID = nil;
NSString *userPSW = nil;

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor whiteColor];
    [self.window makeKeyAndVisible];

    [self initializeThirdPart];
    [self setupCamera];
	[self monitorNetwork];
	
	[CYLPlusButtonSubclass registerPlusButton];
    [HBHTTPManager fetchNormalRequestParamters];
    [HBApplicationManager configRealm];

    UIViewController *rootVC = [AppDelegate rootViewController];
    [self.window setRootViewController:rootVC];

    if ([HBUserManager currentUser]) {
        // 登录当前账号
        [HBUserManager currentUserLogin];
		
        // 连接socket
		[[HBSocketAPIManager sharedInstance] connectSocket];
		
        // apn 内容获取：
        NSDictionary *remoteNotification = [launchOptions objectForKey: UIApplicationLaunchOptionsRemoteNotificationKey];
        [[HBPushManager sharedInstance] hanldePushMsg:remoteNotification[@"content"]];
    }
    
    [self addNotifications];
    
    JPUSHRegisterEntity * entity = [[JPUSHRegisterEntity alloc] init];
    entity.types = JPAuthorizationOptionAlert|JPAuthorizationOptionBadge|JPAuthorizationOptionSound;
    if ([[UIDevice currentDevice].systemVersion floatValue] >= 8.0) {
        // 可以添加自定义categories
        // NSSet<UNNotificationCategory *> *categories for iOS10 or later
        // NSSet<UIUserNotificationCategory *> *categories for iOS8 and iOS9
    }
    [JPUSHService registerForRemoteNotificationConfig:entity delegate:self];
    
    // 获取IDFA
    // 如需使用IDFA功能请添加此代码并在初始化方法的advertisingIdentifier参数中填写对应值
    NSString *advertisingId = [[[ASIdentifierManager sharedManager] advertisingIdentifier] UUIDString];
    
    [JPUSHService setupWithOption:launchOptions appKey:HBJPushAppKey channel:HBJPushChannel
                 apsForProduction:0 advertisingIdentifier:advertisingId];
	
	[XHVersion checkNewVersion];
	
    return YES;
}

- (void)startKickoutMonitor {
	self.kickOutTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(sendMultiLogin) userInfo:nil repeats:YES];
}

- (void)sendMultiLogin {
	if ([HBUserManager userId].length) {
		[[SocketManager instance] sendLoginData];
	}
}

- (void)addNotifications {
	@weakify(self)
    // 添加告警记录
    [[[[NSNotificationCenter defaultCenter] rac_addObserverForName:HB_NOTI_RFDEVICE_CONTROL_FEEDBACK object:nil] takeUntil:self.rac_willDeallocSignal] subscribeNext:^(NSNotification *notification) {
        HBDeviceControlFeedBack *feedBack = notification.userInfo[HB_DEVICE_CONTROL_FEEDBACK_KEY];
        [HBSecurityManager addOrIgnoreSecurityRecordWithFeedback:feedBack];
    }];
	// 被强制挤下线
	[[[[NSNotificationCenter defaultCenter] rac_addObserverForName:HB_NOTI_MULTI_LOGIN object:nil]
	  takeUntil:self.rac_willDeallocSignal] subscribeNext:^(id x) {
		@strongify(self)
		if (self.diglogView.isShow) {
			return ;
		}
		
		self.diglogView = [HBAlertDialogView showWithCompletionBlock:^{
			[HBUserManager logoutCompletion:nil];
		}];
		
		self.diglogView.didClickBtnBlock = ^{
			HBLoginViewController *loginVC = [[HBLoginViewController alloc] init];
			HBNavigationController *nav = [[HBNavigationController alloc] initWithRootViewController:loginVC];
			[UIApplication sharedApplication].keyWindow.rootViewController = nav;
		};
	}];
	// 场所被删除
	[[[[[NSNotificationCenter defaultCenter] rac_addObserverForName:HB_NOTI_ACCOUNT_HOME_DELETED object:nil] takeUntil:self.rac_willDeallocSignal] deliverOnMainThread] subscribeNext:^(NSNotification *notification) {
		@strongify(self)
		if (self.isShowAlert) {
			return ;
		}
		
		
		NSString *homeId = notification.userInfo[@"home_id"];
		HBHomeDeleteType type = [notification.userInfo[@"del_type"] integerValue];
		NSString *userId = [notification.userInfo[@"userid"] lowercaseString];
		// 如果推送过来的通知，不是删除分享的
		if (!([userId isEqualToString:[HBUserManager userId]] && type == HBHomeDeleteShare)) {
			return;
		}
		
		self.isShowAlert = YES;
		if (homeId && [homeId isEqualToString:[HBUserManager homeId]]) {
			HBUser *user = [HBUserManager currentUser];
			// 如果是体验账号
			if ([user isMemberOfClass:[HBExperienceUser class]]) {
				[UIAlertController noneCancelAlertWithMessage:@"当前场所已被删除\n将自动回到登录界面" title:nil confirmTitle:@"确定" confirmClosure:^{
					HBLoginViewController *loginVC = [[HBLoginViewController alloc] init];
					HBNavigationController *nav = [[HBNavigationController alloc] initWithRootViewController:loginVC];
					[UIApplication sharedApplication].keyWindow.rootViewController = nav;
					self.isShowAlert = NO;
				}];
				[HBUserManager logoutCompletion:nil];
			} else {
				[UIAlertController noneCancelAlertWithMessage:@"当前场所已被删除\n将自动切换到默认场所" title:nil confirmTitle:@"确定" confirmClosure:^{
					self.isShowAlert = NO;
				}];
				[HBHomeManager changeToDefaultHome];
			}
		}
	}];
	
}

- (void)monitorNetwork
{
	self.manager = [AFNetworkReachabilityManager sharedManager];
	
	@weakify(self)
	[self.manager setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
		@strongify(self)
		self.status = status;
		// 当网络状态改变时调用
		switch (status) {
			case AFNetworkReachabilityStatusUnknown:
				NSLog(@"未知网络");
				break;
			case AFNetworkReachabilityStatusNotReachable:
				NSLog(@"没有网络");
				break;
			case AFNetworkReachabilityStatusReachableViaWWAN:
				NSLog(@"手机自带网络");
				break;
			case AFNetworkReachabilityStatusReachableViaWiFi:
				NSLog(@"WIFI");
				break;
		}
		// 重连SOCOKET
		[[HBSocketAPIManager sharedInstance] connectSocket];
		[[NSNotificationCenter defaultCenter] postNotificationName:HB_NOTI_REACHABILITY_STATUS_CHANGE object:@(status)];
	}];
	
	//开始监控
	[self.manager startMonitoring];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    // Required - 注册 DeviceToken
    [JPUSHService registerDeviceToken:deviceToken];
}

- (void)applicationWillTerminate:(UIApplication *)application {
	// 退出账号
	BOOL result = [[pwNetAPI xmGetSDKInstance] xmSignOut];
	NSLog(@"退出摄像头账号%@", result?@"成功":@"失败");
}
    
- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    //Optional
    NSLog(@"did Fail To Register For Remote Notifications With Error: %@", error);
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	// 重连
	if ([HBUserManager currentUser]) {
		[[pwNetAPI xmGetSDKInstance] xmReConnectServer];
	}
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	application.applicationIconBadgeNumber = 0;
	[application cancelAllLocalNotifications];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	application.applicationIconBadgeNumber = 0;
	[application cancelAllLocalNotifications];
}
   
#pragma mark- JPUSHRegisterDelegate
    
// iOS 10 Support
- (void)jpushNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(NSInteger))completionHandler {
    // Required
    NSDictionary * userInfo = notification.request.content.userInfo;
    if([notification.request.trigger isKindOfClass:[UNPushNotificationTrigger class]]) {
        [JPUSHService handleRemoteNotification:userInfo];
    }
    [[HBPushManager sharedInstance] hanldePushMsg:userInfo[@"content"]];
    // 需要执行这个方法，选择是否提醒用户，有Badge、Sound、Alert三种类型可以选择设置
    completionHandler(UNNotificationPresentationOptionAlert);
}
    
// iOS 10 Support
- (void)jpushNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)())completionHandler {
    
    NSDictionary * userInfo = response.notification.request.content.userInfo;
    if([response.notification.request.trigger isKindOfClass:[UNPushNotificationTrigger class]]) {
        [JPUSHService handleRemoteNotification:userInfo];
    }
    
    [[HBPushManager sharedInstance] hanldePushMsg:userInfo[@"content"]];
    completionHandler();
}
    
@end
