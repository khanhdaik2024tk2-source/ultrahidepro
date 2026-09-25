#ifndef UH_KCALL_H
#define UH_KCALL_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Initialise kernel primitives via libjailbreak. Returns 0 on success.
/// On platforms that lack libjailbreak this returns -1 and the rest of the
/// kernel layer becomes a no-op.
UH_PRIVATE int UHInitKernelPrimitives(void);

/// Returns YES when kcall/kreadbuf/kwritebuf are usable.
UH_PRIVATE bool UHKernelPrimitivesReady(void);

/// Apply the five kernel patches (AMFI, sandbox MAC, csflags kill, task
/// conv, per-process csflags mask).
UH_PRIVATE void UHInstallKernelPatches(void);

#ifdef __cplusplus
}
#endif

#endif // UH_KCALL_H
