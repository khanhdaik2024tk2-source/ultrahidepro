#ifndef UH_SANDBOX_AMFI_H
#define UH_SANDBOX_AMFI_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install all Lớp 5 hooks (10 vectors): sandbox_check, SecCode*,
/// entitlements, MIS*, etc.
UH_PRIVATE void UHInstallSandboxAMFIHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_SANDBOX_AMFI_H
