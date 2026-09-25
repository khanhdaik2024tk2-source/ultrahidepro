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
	if (UH_UNLIKELY([UHConfig shouldBlockEnv:name])) {
		UHLogDebugF(@"getenv: blocked %s", name);
		return NULL;
	}
	return _orig_getenv(name);
}

#pragma mark - setenv

typedef int (*setenv_t)(const char *, const char *, int);
static setenv_t _orig_setenv = NULL;

static int $setenv(const char *name, const char *value, int overwrite) {
	if (UH_UNLIKELY([UHConfig shouldBlockEnv:name])) {
		errno = ENOENT;
		return -1;
	}
	return _orig_setenv(name, value, overwrite);
}

#pragma mark - secure_getenv

typedef char *(*secure_getenv_t)(const char *);
static secure_getenv_t _orig_secure_getenv = NULL;
static char *$secure_getenv(const char *name) {
	if (UH_UNLIKELY([UHConfig shouldBlockEnv:name])) return NULL;
	return _orig_secure_getenv(name);
}

#pragma mark - __system_property_get

typedef int (*system_property_get_t)(const char *, char *);
static system_property_get_t _orig_system_property_get = NULL;

static int $system_property_get(const char *name, char *value) {
	int rc = _orig_system_property_get(name, value);
	if (UH_UNLIKELY(rc > 0 && name != NULL)) {
		NSString *n = [[NSString stringWithUTF8String:name] lowercaseString];
		if ([n hasPrefix:@"ro.boot.jailbreak"] ||
		    [n hasPrefix:@"ro.debuggable"] ||
		    [n hasPrefix:@"ro.secure"] ||
		    [n hasPrefix:@"service.adb.root"]) {
			if (value != NULL && rc < (int)NAME_MAX) {
				value[0] = '\0';
				return 0;
			}
		}
	}
	return rc;
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

static NSArray *(*_orig_lsaw_allApplications)(id, SEL) = NULL;
static NSArray *$lsaw_allApplications(id self, SEL _cmd) {
	NSArray *apps = _orig_lsaw_allApplications(self, _cmd);
	if (!apps || ![UHConfig activeForCurrentApp]) return apps;
	NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:apps.count];
	for (id app in apps) {
		if ([app respondsToSelector:@selector(bundleIdentifier)]) {
			NSString *bid = [app performSelector:@selector(bundleIdentifier)];
			if (bid != nil && [UHConfig shouldBlockBundleID:bid]) {
				continue;
			}
		}
		[filtered addObject:app];
	}
	return [filtered copy];
}

static NSArray *(*_orig_lsaw_allInstalledApplications)(id, SEL) = NULL;
static NSArray *$lsaw_allInstalledApplications(id self, SEL _cmd) {
	NSArray *apps = _orig_lsaw_allInstalledApplications(self, _cmd);
	if (!apps || ![UHConfig activeForCurrentApp]) return apps;
	NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:apps.count];
	for (id app in apps) {
		if ([app respondsToSelector:@selector(bundleIdentifier)]) {
			NSString *bid = [app performSelector:@selector(bundleIdentifier)];
			if (bid != nil && [UHConfig shouldBlockBundleID:bid]) {
				continue;
			}
		}
		[filtered addObject:app];
	}
	return [filtered copy];
}

#pragma mark - Installer

void UHInstallEnvironmentHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	MSHookFunction((void *)getenv, (void *)$getenv, (void **)&_orig_getenv);
	MSHookFunction((void *)setenv, (void *)$setenv, (void **)&_orig_setenv);
	[stats bumpBy:2];

	void *sec_getenv = dlsym(RTLD_DEFAULT, "secure_getenv");
	if (sec_getenv != NULL) {
		MSHookFunction(sec_getenv, (void *)$secure_getenv, (void **)&_orig_secure_getenv);
		[stats bumpBy:1];
	}
	void *spg = dlsym(RTLD_DEFAULT, "__system_property_get");
	if (spg != NULL) {
		MSHookFunction(spg, (void *)$system_property_get, (void **)&_orig_system_property_get);
		[stats bumpBy:1];
	}

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
		MSHookMessageEx(lsaw, @selector(allApplications),
			(IMP)$lsaw_allApplications, (IMP *)&_orig_lsaw_allApplications);
		MSHookMessageEx(lsaw, @selector(allInstalledApplications),
			(IMP)$lsaw_allInstalledApplications, (IMP *)&_orig_lsaw_allInstalledApplications);
		[stats bumpBy:3];
	}
	Class lsap = NSClassFromString(@"LSApplicationProxy");
	if (lsap != NULL) {
		MSHookMessageEx(lsap, @selector(applicationIsInstalled:),
			(IMP)$lsap_appIsInstalled_, (IMP *)&_orig_lsap_appIsInstalled_);
		[stats bumpBy:1];
	}

	UHLogInfoF(@"environment hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
