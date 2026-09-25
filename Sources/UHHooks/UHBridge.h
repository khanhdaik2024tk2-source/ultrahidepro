#ifndef UH_BRIDGE_H
#define UH_BRIDGE_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install Lớp 7 hooks (6 vectors): aggregate bypass cho IOSSecurity,
/// JailbreakChecker, etc. The implementation lazily scans objc_getClassList
/// on first invocation and applies hooks to all matching classes.
UH_PRIVATE void UHInstallBridgeHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_BRIDGE_H
