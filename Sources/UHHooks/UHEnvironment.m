#import "UHEnvironment.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - UIApplication URL Scheme Hooks (100% Safe Objective-C Swizzling)

static BOOL (*_orig_canOpenURL_)(id, SEL, NSURL *) = NULL;
static BOOL (*_orig_openURL_)(id, SEL, NSURL *) = NULL;
static void (*_orig_openURL_options_completionHandler_)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) = NULL;

static BOOL $canOpenURL_(id self, SEL _cmd, NSURL *url) {
	if (url != nil && url.scheme != nil) {
		if (UH_UNLIKELY([UHConfig shouldBlockURLScheme:url.scheme])) {
			return NO;
		}
	}
	return _orig_canOpenURL_(self, _cmd, url);
}

static BOOL $openURL_(id self, SEL _cmd, NSURL *url) {
	if (url != nil && url.scheme != nil) {
		if (UH_UNLIKELY([UHConfig shouldBlockURLScheme:url.scheme])) {
			return NO;
		}
	}
	return _orig_openURL_(self, _cmd, url);
}

static void $openURL_options_completionHandler_(id self, SEL _cmd, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
	if (url != nil && url.scheme != nil) {
		if (UH_UNLIKELY([UHConfig shouldBlockURLScheme:url.scheme])) {
			if (completion) completion(NO);
			return;
		}
	}
	_orig_openURL_options_completionHandler_(self, _cmd, url, options, completion);
}

#pragma mark - LSApplicationWorkspace

static BOOL (*_orig_lsaw_appIsInstalled_)(id, SEL, NSString *) = NULL;

static BOOL $lsaw_appIsInstalled_(id self, SEL _cmd, NSString *bundleID) {
	if (UH_UNLIKELY(bundleID != nil &&
	    ([UHConfig shouldBlockBundleID:bundleID] || [UHConfig shouldBlockURLScheme:bundleID]))) {
		return NO;
	}
	return _orig_lsaw_appIsInstalled_(self, _cmd, bundleID);
}

static BOOL (*_orig_lsap_appIsInstalled_)(id, SEL, NSString *) = NULL;
static BOOL $lsap_appIsInstalled_(id self, SEL _cmd, NSString *bundleID) {
	if (UH_UNLIKELY(bundleID != nil &&
	    ([UHConfig shouldBlockBundleID:bundleID] || [UHConfig shouldBlockURLScheme:bundleID]))) {
		return NO;
	}
	return _orig_lsap_appIsInstalled_(self, _cmd, bundleID);
}

#pragma mark - Installer

void UHInstallEnvironmentHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	Class uiApp = NSClassFromString(@"UIApplication");
	if (uiApp != NULL) {
		MSHookMessageEx(uiApp, @selector(canOpenURL:),
			(IMP)$canOpenURL_, (IMP *)&_orig_canOpenURL_);
		MSHookMessageEx(uiApp, @selector(openURL:),
			(IMP)$openURL_, (IMP *)&_orig_openURL_);
		if ([uiApp instancesRespondToSelector:@selector(openURL:options:completionHandler:)]) {
			MSHookMessageEx(uiApp, @selector(openURL:options:completionHandler:),
				(IMP)$openURL_options_completionHandler_, (IMP *)&_orig_openURL_options_completionHandler_);
			[stats bumpBy:3];
		} else {
			[stats bumpBy:2];
		}
	}

	Class lsaw = NSClassFromString(@"LSApplicationWorkspace");
	if (lsaw != NULL) {
		MSHookMessageEx(lsaw, @selector(applicationIsInstalled:),
			(IMP)$lsaw_appIsInstalled_, (IMP *)&_orig_lsaw_appIsInstalled_);
		[stats bumpBy:1];
	}
	Class lsap = NSClassFromString(@"LSApplicationProxy");
	if (lsap != NULL) {
		MSHookMessageEx(lsap, @selector(applicationIsInstalled:),
			(IMP)$lsap_appIsInstalled_, (IMP *)&_orig_lsap_appIsInstalled_);
		[stats bumpBy:1];
	}

	UHLogInfoF(@"Environment layer initialized (pure ObjC swizzling, zero C code patching)");
}
