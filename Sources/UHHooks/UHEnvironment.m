#import "UHEnvironment.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>
#import <dlfcn.h>

#pragma mark - getenv

typedef char *(*getenv_t)(const char *);
static getenv_t _orig_getenv = NULL;

static char *$getenv(const char *name) {
	if (UH_UNLIKELY(UHEnvBlockedFast(name))) {
		return NULL;
	}
	return _orig_getenv(name);
}

#pragma mark - UIApplication canOpenURL:

static BOOL (*_orig_canOpenURL_)(id, SEL, NSURL *) = NULL;

static BOOL $canOpenURL_(id self, SEL _cmd, NSURL *url) {
	if (url != nil && url.scheme != nil) {
		if (UH_UNLIKELY([UHConfig shouldBlockURLScheme:url.scheme])) {
			return NO;
		}
	}
	return _orig_canOpenURL_(self, _cmd, url);
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

	MSHookFunction((void *)getenv, (void *)$getenv, (void **)&_orig_getenv);
	[stats bumpBy:1];

	Class uiApp = NSClassFromString(@"UIApplication");
	if (uiApp != NULL) {
		MSHookMessageEx(uiApp, @selector(canOpenURL:),
			(IMP)$canOpenURL_, (IMP *)&_orig_canOpenURL_);
		[stats bumpBy:1];
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

	UHLogInfoF(@"environment hooks installed (%lu total, safe mode)",
		(unsigned long)(stats.activeCount - before));
}
