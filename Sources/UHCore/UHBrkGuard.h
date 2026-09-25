#ifndef UH_BRK_GUARD_H
#define UH_BRK_GUARD_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// ElleKit installs `BRK #1` at the start of every out-of-range trampoline
/// target and dispatches the original function pointer via its signal
/// handler. When multiple tweaks hook the same function, the handler
/// can recurse indefinitely if dispatch fails (it shouldn't, but iOS
/// 18.6.2 has known panic reports from this scenario).
///
/// UHBrkGuard installs a SIGBUS/SIGTRAP signal handler that:
///
///   1. Runs AFTER ElleKit's handler — so we don't shadow it.
///   2. Logs the offending PC and x0..x3 to the unified log.
///   3. Forwards the signal to the default handler so the process still
///      gets a clean diagnostic if something went wrong.
///
/// We intentionally do NOT install on ARM64E because the BRK encoding
/// conflicts with PAC trap instructions.
UH_PRIVATE void UHInstallBrkGuard(void);

/// Disables the BRK guard. Useful for unit tests that want to validate
/// the original behaviour.
UH_PRIVATE void UHUninstallBrkGuard(void);

#ifdef __cplusplus
}
#endif

#endif // UH_BRK_GUARD_H
