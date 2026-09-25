#import "UHAppDelegate.h"
#import "UHTargetAppsViewController.h"

@implementation UHAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	
	UHTargetAppsViewController *rootVC = [[UHTargetAppsViewController alloc] init];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:rootVC];
	
	nav.navigationBar.prefersLargeTitles = YES;
	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];
	
	return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
	return YES;
}

@end
