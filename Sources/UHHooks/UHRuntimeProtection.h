#ifndef UH_RUNTIME_PROTECTION_H
#define UH_RUNTIME_PROTECTION_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install runtime-protection vectors (3 vectors): BRK scan spoof,
/// PAC spoof, function prologue integrity spoof.
UH_PRIVATE void UHInstallRuntimeProtectionHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_RUNTIME_PROTECTION_H
