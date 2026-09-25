#ifndef UH_MACHO_H
#define UH_MACHO_H

#import "UHCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Mach-O inspection helpers. We rely on `dyld_all_image_infos` which is
/// exported via `_dyld_get_image_info_addr()`. The struct lives in the
/// shared cache and we map only the first page to keep cost low.
UH_EXPORT
@interface UHMachO : NSObject

/// Fill in the human-readable install path of the current tweak dylib.
/// Used by the anti-anti-hook layer to know what to disguise.
+ (nullable NSString *)ownInstallPath;

/// Returns YES when the given path is the tweak's own dylib (or one of the
/// substrings commonly used to identify our tweak).
+ (BOOL)isTweakPath:(const char *)path;

/// Returns the load address (slide-adjusted) for the tweak's own dylib.
/// Returns NULL on failure.
+ (nullable const void *)ownLoadAddress;

/// Returns the precise address range of the tweak's __TEXT segment so
/// callers (notably UHRuntimeProtection) can sanitise vm_read output
/// without false-positives on neighbouring libraries.
+ (void)ownTextRange:(nullable uintptr_t *)outStart end:(nullable uintptr_t *)outEnd;

/// Returns the path to disguise ourselves as (default = /usr/lib/system/libsystem_c.dylib).
/// Cached after first call.
+ (NSString *)disguisePath;

/// Bootstrap — call once before any other UHMachO accessor.
+ (void)bootstrap;

@end

NS_ASSUME_NONNULL_END

#endif // UH_MACHO_H
