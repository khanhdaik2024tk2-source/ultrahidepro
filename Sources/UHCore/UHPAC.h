#ifndef UH_PAC_H
#define UH_PAC_H

#import "UHCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Pointer Authentication Code wrappers. We don't expect to actively use
/// them on iOS 18.6.2 + Dopamine 3.0.9 (which only runs on arm64 A8-A13),
/// but we still expose the wrappers so the runtime-protection layer can
/// compile on every supported platform and gracefully no-op on arm64.
///
/// Compiling PAC-stripping requires Xcode 12+ for the `__arm64e__` target
/// attribute. We feature-detect at runtime via `_dyld_get_image_header()`
/// + parse the `cputype` from the mach_header.
UH_EXPORT
@interface UHPAC : NSObject

/// YES when the current binary is built for arm64e.
+ (BOOL)isPACAvailable;

/// Bootstrap — query the host CPU type and cache the answer.
+ (void)bootstrap;

/// Strip the PAC bits from `ptr`. On arm64 (non-PAC) this is a no-op that
/// simply returns `ptr`. On arm64e this would emit `xpaci` (Cortex-A76+) or
/// equivalent at the call site.
+ (uintptr_t)strip:(uintptr_t)ptr;

/// Sign `ptr` with the given discriminator. On arm64 this is a no-op.
+ (uintptr_t)sign:(uintptr_t)ptr discriminator:(uint64_t)disc;

@end

NS_ASSUME_NONNULL_END

#endif // UH_PAC_H
