#ifndef UH_ANTI_HOOK_H
#define UH_ANTI_HOOK_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install anti-anti-hook vectors (4 vectors): hide the tweak dylib from
/// dyld image count, image name, vm_region scan, and csflags inspection.
UH_PRIVATE void UHInstallAntiHookHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_ANTI_HOOK_H
