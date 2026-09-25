#ifndef UH_DYLD_H
#define UH_DYLD_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install dyld hooks: dlopen, dlsym, dladdr.
UH_PRIVATE void UHInstallDyldHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_DYLD_H
