#ifndef UH_FILE_SYSTEM_H
#define UH_FILE_SYSTEM_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install all Lớp 1 hooks (12 vectors). Idempotent — safe to call once
/// at tweak bootstrap. Counts each successful hook into UHHookStats.
UH_PRIVATE void UHInstallFileSystemHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_FILE_SYSTEM_H
