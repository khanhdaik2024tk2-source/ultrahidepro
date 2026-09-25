#ifndef UH_CONFIG_H
#define UH_CONFIG_H

#import "UHCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Singleton loader for the tweak runtime configuration. The plist lives at
/// `/var/jb/Library/UltraHidePro/config.plist` on a Dopamine rootless install
/// and at `/Library/UltraHidePro/config.plist` as a fallback.
///
/// Everything is read-only after `+[load]` because hot-reloads are
/// intentionally restricted to system tools (the disk watchdog in UHRules).
@interface UHConfig : NSObject

@property (nonatomic, copy, readonly) NSArray<NSString *> *targetApps;
@property (nonatomic, copy, readonly) NSArray<NSString *> *blacklistPaths;
@property (nonatomic, copy, readonly) NSArray<NSString *> *blacklistEnvVars;
@property (nonatomic, copy, readonly) NSArray<NSString *> *blacklistURLSchemes;
@property (nonatomic, copy, readonly) NSArray<NSString *> *objcClassRegexBlacklist;
@property (nonatomic, copy, readonly) NSArray<NSString *> *objcSelectorRegexBlacklist;
@property (nonatomic, copy, readonly) NSArray<NSString *> *blacklistInterfacePrefixes;
@property (nonatomic, copy, readonly) NSArray<NSString *> *blacklistProcessNames;
@property (nonatomic, copy, readonly) NSArray<NSString *> *blacklistMGKeys;

@property (nonatomic, assign, readonly) BOOL filesystemEnabled;
@property (nonatomic, assign, readonly) BOOL processEnabled;
@property (nonatomic, assign, readonly) BOOL dyldEnabled;
@property (nonatomic, assign, readonly) BOOL environmentEnabled;
@property (nonatomic, assign, readonly) BOOL sandboxAmfiEnabled;
@property (nonatomic, assign, readonly) BOOL networkIOKitEnabled;
@property (nonatomic, assign, readonly) BOOL objcAggregateEnabled;
@property (nonatomic, assign, readonly) BOOL kernelEnabled;

+ (instancetype)sharedInstance;

+ (BOOL)filesystemEnabled;
+ (BOOL)processEnabled;
+ (BOOL)dyldEnabled;
+ (BOOL)environmentEnabled;
+ (BOOL)sandboxAmfiEnabled;
+ (BOOL)networkIOKitEnabled;
+ (BOOL)objcAggregateEnabled;
+ (BOOL)kernelEnabled;

/// Force a reload from disk (used by UHWatchdog).
- (void)reload;

/// YES when the host process is in `targetApps` (or when the list is empty)
/// AND at least one detection layer is enabled. Hot hooks short-circuit on
/// this to avoid paying any cost in non-target processes.
+ (BOOL)activeForCurrentApp;

/// Path blacklist — case-insensitive prefix match.
+ (BOOL)shouldBlockPath:(NSString *)path;

/// Env var name blacklist — case-insensitive equality.
+ (BOOL)shouldBlockEnv:(const char *)name;

/// URL scheme blacklist — case-insensitive equality.
+ (BOOL)shouldBlockURLScheme:(NSString *)scheme;

/// Jailbreak app bundle identifier blacklist (e.g. Sileo, Zebra, Filza).
+ (BOOL)shouldBlockBundleID:(NSString *)bundleID;

/// Returns YES if the class name matches the regex blacklist. Tries prefix
/// match first (fast path) and falls back to NSRegularExpression when needed.
+ (BOOL)shouldHookObjCClass:(const char *)className;

/// Returns YES if the selector name matches the selector blacklist.
+ (BOOL)shouldHookObjCSelector:(const char *)selectorName;

/// Returns YES if the process name (p_comm) is on the blacklist.
+ (BOOL)shouldHideProcessName:(const char *)comm;

/// Returns YES if the network interface name starts with a blacklist prefix.
+ (BOOL)shouldHideInterfaceName:(const char *)ifName;

/// Returns YES if the MobileGestalt key is on the blacklist.
+ (BOOL)shouldHideMGKey:(const char *)key;

/// Bundle identifier of the host process (cached on first call).
+ (nullable NSString *)hostBundleID;

/// Path to the loaded config plist (for diagnostics).
- (nullable NSString *)configPath;

@end

NS_ASSUME_NONNULL_END

#endif // UH_CONFIG_H
