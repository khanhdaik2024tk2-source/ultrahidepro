#ifndef UH_DYLD_H
#define UH_DYLD_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install all Lớp 3 hooks (8 vectors): _dyld_image_count,
/// _dyld_get_image_name, dlopen, dlsym, objc_*, etc.
UH_PRIVATE void UHInstallDyldHooks(void);

/// Tell the dyld image-count hook how many entries to subtract from the
/// reported count. Used by UHAntiHook to hide our own dylib from apps that
/// inspect the table.
UH_PRIVATE void UHDyldSetHiddenImageDelta(uint32_t delta);

#ifdef __cplusplus
}
#endif

#endif // UH_DYLD_H
