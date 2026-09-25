#import "UHConfig.h"
#import "UHLog.h"
#import <Foundation/Foundation.h>

// We probe a list of candidate paths because:
// - rootless (Dopamine) install under /var/jb/Library/UltraHidePro
// - rootful install under /Library/UltraHidePro
// - development sandbox under $HOME for offline testing
static NSString *UHConfigResolvePath(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray<NSString *> *candidates = @[
		@"/var/jb/Library/UltraHidePro/config.plist",  // rootless Dopamine
		@"/Library/UltraHidePro/config.plist",         // rootful fallback
		@"/var/jb/etc/ultrahidepro/config.plist",      // alternate rootless
	];
	for (NSString *p in candidates) {
		if ([fm fileExistsAtPath:p]) return p;
	}
	// Default to rootless so we can still build a valid symlink during install.
	return candidates.firstObject;
}

// Lowercase copy; we always compare paths/env vars/schemes case-insensitive
// because real-world detection code is the same way.
static NSArray<NSString *> *UHConfigNormaliseStrings(id raw) {
	NSMutableArray<NSString *> *out = [NSMutableArray array];
	if ([raw isKindOfClass:[NSArray class]]) {
		for (id v in (NSArray *)raw) {
			if ([v isKindOfClass:[NSString class]]) {
				[out addObject:[(NSString *)v lowercaseString]];
			}
		}
	}
	return [out copy];
}

static NSArray<NSString *> *UHConfigCopyStrings(id raw) {
	NSMutableArray<NSString *> *out = [NSMutableArray array];
	if ([raw isKindOfClass:[NSArray class]]) {
		for (id v in (NSArray *)raw) {
			if ([v isKindOfClass:[NSString class]]) {
				[out addObject:(NSString *)v];
			}
		}
	}
	return [out copy];
}

@implementation UHConfig {
	NSString *_loadedPath;
}

+ (instancetype)sharedInstance {
	static UHConfig *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [UHConfig new]; [s load]; });
	return s;
}

- (void)load {
	_loadedPath = UHConfigResolvePath();
	NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:_loadedPath];
	if (cfg == nil) {
		cfg = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.ultrahidepro.plist"];
	}
	if (cfg == nil) {
		cfg = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.ultrahidepro.plist"];
	}
	if (cfg == nil) {
		cfg = @{};
	}

	// 1. Try CFPreferences / cfprefsd (crucial for sandboxed apps on Dopamine rootless!)
	NSArray *targetsFromPrefs = nil;
	CFArrayRef cfTargets = (CFArrayRef)CFPreferencesCopyAppValue(CFSTR("target_apps"), CFSTR("com.ultrahidepro"));
	if (cfTargets != NULL) {
		if (CFGetTypeID(cfTargets) == CFArrayGetTypeID()) {
			targetsFromPrefs = [(__bridge NSArray *)cfTargets copy];
		}
		CFRelease(cfTargets);
	}

	if (targetsFromPrefs.count > 0) {
		_targetApps = UHConfigCopyStrings(targetsFromPrefs);
	} else if (cfg[@"target_apps"] != nil && [cfg[@"target_apps"] count] > 0) {
		_targetApps = UHConfigCopyStrings(cfg[@"target_apps"]);
	} else {
		// Out-of-the-box protection list for popular banking & sensitive apps
		_targetApps = @[
			@"com.mb.mbbank",
			@"vn.com.mbbank.mb.ios",
			@"com.mbbank.mobilebanking",
			@"com.mbmobile",
			@"com.mb.mbprivate",
			@"com.vcb.digibank",
			@"com.techcombank.mobile",
			@"com.vnpay.vntrip",
			@"com.momo.wallet"
		];
	}

	_blacklistPaths           = UHConfigNormaliseStrings(cfg[@"blacklist_paths"]);
	_blacklistEnvVars         = UHConfigNormaliseStrings(cfg[@"blacklist_env_vars"]);
	_blacklistURLSchemes      = UHConfigNormaliseStrings(cfg[@"blacklist_url_schemes"]);
	_blacklistInterfacePrefixes = UHConfigNormaliseStrings(cfg[@"blacklist_interface_prefixes"]);
	_blacklistProcessNames    = UHConfigNormaliseStrings(cfg[@"blacklist_process_names"]);
	_blacklistMGKeys          = UHConfigNormaliseStrings(cfg[@"blacklist_mg_keys"]);
	_objcClassRegexBlacklist  = UHConfigCopyStrings(cfg[@"objc_class_regex_blacklist"]);
	_objcSelectorRegexBlacklist = UHConfigCopyStrings(cfg[@"objc_selector_regex_blacklist"]);

	NSDictionary *layers = cfg[@"enabled_layers"];
	if (![layers isKindOfClass:[NSDictionary class]]) layers = @{};

	_filesystemEnabled   = layers[@"filesystem"] ? [layers[@"filesystem"] boolValue] : YES;
	_processEnabled      = layers[@"process"] ? [layers[@"process"] boolValue] : YES;
	_dyldEnabled         = layers[@"dyld"] ? [layers[@"dyld"] boolValue] : YES;
	_environmentEnabled  = layers[@"environment"] ? [layers[@"environment"] boolValue] : YES;
	_sandboxAmfiEnabled  = layers[@"sandbox_amfi"] ? [layers[@"sandbox_amfi"] boolValue] : YES;
	_networkIOKitEnabled = [layers[@"network_iokit"] boolValue];
	_objcAggregateEnabled= [layers[@"objc_aggregate"] boolValue];
	_kernelEnabled       = NO;

	UHLogInfoF(@"Config loaded: %lu target apps", (unsigned long)_targetApps.count);
}

- (void)reload {
	[self load];
}

- (NSString *)configPath { return _loadedPath; }

+ (NSString *)hostBundleID {
	static NSString *cached = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		CFBundleRef mainBundle = CFBundleGetMainBundle();
		if (mainBundle != NULL) {
			CFStringRef cfBid = CFBundleGetIdentifier(mainBundle);
			if (cfBid != NULL) {
				cached = [(__bridge NSString *)cfBid copy];
			}
		}
		if (cached == nil || cached.length == 0) {
			cached = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
		}
	});
	return cached;
}

+ (BOOL)isTargetApp:(NSString *)bundleID {
	if (bundleID.length == 0) return NO;
	UHConfig *cfg = [self sharedInstance];
	if (cfg.targetApps.count == 0) return NO;
	for (NSString *target in cfg.targetApps) {
		if ([bundleID caseInsensitiveCompare:target] == NSOrderedSame) return YES;
	}
	return NO;
}

+ (BOOL)filesystemEnabled { return [self sharedInstance].filesystemEnabled; }
+ (BOOL)processEnabled { return [self sharedInstance].processEnabled; }
+ (BOOL)dyldEnabled { return [self sharedInstance].dyldEnabled; }
+ (BOOL)environmentEnabled { return [self sharedInstance].environmentEnabled; }
+ (BOOL)sandboxAmfiEnabled { return [self sharedInstance].sandboxAmfiEnabled; }
+ (BOOL)networkIOKitEnabled { return [self sharedInstance].networkIOKitEnabled; }
+ (BOOL)objcAggregateEnabled { return [self sharedInstance].objcAggregateEnabled; }
+ (BOOL)kernelEnabled { return [self sharedInstance].kernelEnabled; }

+ (BOOL)activeForCurrentApp {
	NSString *bid = [self hostBundleID];
	if (bid.length == 0) return NO;

	static NSSet<NSString *> *denyList;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		denyList = [NSSet setWithArray:@[
			@"com.apple.springboard",
			@"com.apple.backboardd",
			@"com.apple.runningboard",
			@"com.apple.frontboard",
			@"com.apple.biokitd",
			@"com.apple.Preferences",
			@"com.apple.dt.xcode.debugger",
			@"org.coolstar.SileoStore",
			@"org.coolstar.SileoNightly",
			@"xyz.willy.Zebra",
			@"com.tigisoftware.Filza",
			@"com.ultrahidepro.app"
		]];
	});
	if ([denyList containsObject:bid]) return NO;
	return [self isTargetApp:bid];
}

+ (BOOL)shouldBlockPath:(NSString *)path {
	if (path.length == 0) return NO;
	const char *cpath = [path UTF8String];
	if (cpath == NULL) return NO;

	// Fast-path: sandbox containers and system paths (99.9% of app calls)
	if (strncmp(cpath, "/private/var/containers/", 24) == 0 ||
	    strncmp(cpath, "/var/containers/", 16) == 0 ||
	    strncmp(cpath, "/private/var/mobile/Containers/", 31) == 0 ||
	    strncmp(cpath, "/var/mobile/Containers/", 23) == 0 ||
	    strncmp(cpath, "/System/", 8) == 0) {
		return NO;
	}

	if (UHPathBlockedFast(cpath)) return YES;

	NSString *lower = [path lowercaseString];
	NSArray<NSString *> *blist = [self sharedInstance].blacklistPaths;
	for (NSString *blk in blist) {
		if ([lower hasPrefix:blk]) return YES;
	}

	return NO;
}

+ (BOOL)shouldBlockEnv:(const char *)name {
	if (name == NULL) return NO;
	NSString *n = [[NSString stringWithUTF8String:name] lowercaseString];
	for (NSString *blk in [self sharedInstance].blacklistEnvVars) {
		if ([n isEqualToString:blk]) return YES;
	}
	return NO;
}

+ (BOOL)shouldBlockURLScheme:(NSString *)scheme {
	if (scheme.length == 0) return NO;
	NSString *lower = [scheme lowercaseString];
	for (NSString *blk in [self sharedInstance].blacklistURLSchemes) {
		if ([lower isEqualToString:blk]) return YES;
	}
	return NO;
}

+ (BOOL)shouldBlockBundleID:(NSString *)bundleID {
	if (bundleID.length == 0) return NO;
	NSString *lower = [bundleID lowercaseString];
	static NSArray<NSString *> *jbBundles;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		jbBundles = @[
			@"org.coolstar.sileostore",
			@"org.coolstar.sileonightly",
			@"xyz.willy.zebra",
			@"com.tigisoftware.filza",
			@"org.cydia.cydia",
			@"com.saurik.cydia",
			@"com.opa334.dopamine",
			@"com.opa334.trollstore",
			@"com.ultrahidepro.app",
			@"com.rileytestut.altstore",
		];
	});
	for (NSString *jb in jbBundles) {
		if ([lower isEqualToString:jb] || [lower hasPrefix:jb]) return YES;
	}
	return NO;
}

+ (BOOL)shouldHookObjCClass:(const char *)className {
	if (className == NULL) return NO;
	NSString *n = [NSString stringWithUTF8String:className];
	NSArray<NSString *> *patterns = [self sharedInstance].objcClassRegexBlacklist;
	// Fast path: prefix match.
	for (NSString *pattern in patterns) {
		if ([n hasPrefix:pattern]) return YES;
	}
	// Slow path: regex.
	for (NSString *pattern in patterns) {
		NSError *err = nil;
		NSRegularExpression *re =
			[NSRegularExpression regularExpressionWithPattern:pattern
			                                          options:0
			                                            error:&err];
		if (re != nil && [re numberOfMatchesInString:n
		                                    options:0
		                                      range:NSMakeRange(0, n.length)] > 0) {
			return YES;
		}
	}
	return NO;
}

+ (BOOL)shouldHookObjCSelector:(const char *)selectorName {
	if (selectorName == NULL) return NO;
	NSString *n = [NSString stringWithUTF8String:selectorName];
	NSArray<NSString *> *patterns = [self sharedInstance].objcSelectorRegexBlacklist;
	// Selector names are usually exact matches; we treat each entry as a
	// substring match (which still beats regex cost for most cases).
	for (NSString *pattern in patterns) {
		if ([n rangeOfString:pattern].location != NSNotFound) return YES;
	}
	return NO;
}

+ (BOOL)shouldHideProcessName:(const char *)comm {
	if (comm == NULL) return NO;
	NSString *n = [[NSString stringWithUTF8String:comm] lowercaseString];
	if (n.length == 0) return NO;
	for (NSString *blk in [self sharedInstance].blacklistProcessNames) {
		if ([n rangeOfString:blk].location != NSNotFound) return YES;
	}
	return NO;
}

+ (BOOL)shouldHideInterfaceName:(const char *)ifName {
	if (ifName == NULL) return NO;
	NSString *n = [[NSString stringWithUTF8String:ifName] lowercaseString];
	for (NSString *prefix in [self sharedInstance].blacklistInterfacePrefixes) {
		if ([n hasPrefix:prefix]) return YES;
	}
	return NO;
}

+ (BOOL)shouldHideMGKey:(const char *)key {
	if (key == NULL) return NO;
	NSString *n = [[NSString stringWithUTF8String:key] lowercaseString];
	for (NSString *blk in [self sharedInstance].blacklistMGKeys) {
		if ([n isEqualToString:blk]) return YES;
	}
	return NO;
}

@end
