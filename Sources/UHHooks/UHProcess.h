#ifndef UH_PROCESS_H
#define UH_PROCESS_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Install all Lớp 2 hooks (10 vectors): fork, execve, sysctl, getppid,
/// ptrace, csops, etc. Idempotent.
UH_PRIVATE void UHInstallProcessHooks(void);

#ifdef __cplusplus
}
#endif

#endif // UH_PROCESS_H
