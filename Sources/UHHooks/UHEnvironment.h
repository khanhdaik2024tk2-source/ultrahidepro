#ifndef UH_ENVIRONMENT_H
#define UH_ENVIRONMENT_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install all Lớp 4 hooks (8 vectors): getenv, canOpenURL,
/// __system_property_get, etc.
UH_PRIVATE void UHInstallEnvironmentHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_ENVIRONMENT_H
