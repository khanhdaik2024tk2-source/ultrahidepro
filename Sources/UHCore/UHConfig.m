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
	UHLogInfoF(@"Loading config from %@", _loadedPath);
	NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:_loadedPath];
	if (cfg == nil) {
		UHLogWarnF(@"Config not found at %@ — using safe defaults", _loadedPath);
		cfg = @{};
	}

	_targetApps               = UHConfigCopyStrings(cfg[@"target_apps"]);
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

	_filesystemEnabled   = [layers[@"filesystem"] boolValue];
	_processEnabled      = [layers[@"process"] boolValue];
	_dyldEnabled         = [layers[@"dyld"] boolValue];
	_environmentEnabled  = [layers[@"environment"] boolValue];
	_sandboxAmfiEnabled  = [layers[@"sandbox_amfi"] boolValue];
	_networkIOKitEnabled = [layers[@"network_iokit"] boolValue];
	_objcAggregateEnabled= [layers[@"objc_aggregate"] boolValue];

	// Kernel layer is gated by BOTH the master switch and the per-layer switch.
	_kernelEnabled       = [layers[@"kernel"] boolValue] &&
	                       [cfg[@"kernel_enabled"] boolValue];

	if (_targetApps.count == 0) {
		UHLogWarnF(@"target_apps is empty — running in catch-all mode");
	}

	UHLogInfoF(@"Config layers: fs=%d proc=%d dyld=%d env=%d sbamfi=%d net=%d objc=%d kern=%d",
		_filesystemEnabled, _processEnabled, _dyldEnabled, _environmentEnabled,
		_sandboxAmfiEnabled, _networkIOKitEnabled, _objcAggregateEnabled, _kernelEnabled);
}

- (void)reload {
	[self load];
}

- (NSString *)configPath { return _loadedPath; }

+ (NSString *)hostBundleID {
	static NSString *cached;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cached = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
	});
	return cached;
}

+ (BOOL)isTargetApp:(NSString *)bundleID {
	if (bundleID.length == 0) return NO;
	UHConfig *cfg = [self sharedInstance];
	if (cfg.targetApps.count == 0) return YES;
	return [cfg.targetApps containsObject:bundleID];
}

+ (BOOL)activeForCurrentApp {
	UHConfig *cfg = [self sharedInstance];
	NSString *bid = [self hostBundleID];
	if (bid.length == 0) return NO;
	if (![self isTargetApp:bid]) return NO;
	static NSSet<NSString *> *denyList;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		// System services use fork(), bootstrap helpers, etc. Forcing
		// our hooks here would corrupt SpringBoard / backboardd and
		// brick the UI. We refuse to install them in those processes
		// from UHInit; this is the runtime check mirror.
		denyList = [NSSet setWithArray:@[
			@"com.apple.springboard",
			@"com.apple.backboardd",
			@"com.apple.runningboard",
			@"com.apple.frontboard",
			@"com.apple.biokitd",
			@"com.apple.dt.xcode.debugger",
		]];
	});
	if ([denyList containsObject:bid]) return NO;
	return (cfg.filesystemEnabled || cfg.processEnabled ||
	        cfg.dyldEnabled        || cfg.environmentEnabled ||
	        cfg.sandboxAmfiEnabled || cfg.networkIOKitEnabled ||
	        cfg.objcAggregateEnabled);
}

+ (BOOL)shouldBlockPath:(NSString *)path {
	if (path.length == 0) return NO;
	NSString *lower = [path lowercaseString];
	for (NSString *blk in [self sharedInstance].blacklistPaths) {
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
