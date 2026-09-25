#ifndef UH_NETWORK_IOKIT_H
#define UH_NETWORK_IOKIT_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install all Lớp 6 hooks (6 vectors): getifaddrs, io_service_open,
/// MGCopyAnswer, etc.
UH_PRIVATE void UHInstallNetworkIOKitHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_NETWORK_IOKIT_H
