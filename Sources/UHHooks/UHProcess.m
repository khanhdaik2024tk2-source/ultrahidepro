#import "UHProcess.h"
#import "UHCommon.h"
#import "UHCore/UHLog.h"

void UHInstallProcessHooks(void) {
	// Syscall stub hooks (fork, ptrace, sysctl) are intentionally bypassed on iOS 18 + ElleKit.
	// In rootless Dopamine, hooking 16-byte raw syscall stubs in libsystem_kernel.dylib
	// corrupts neighboring stubs and breaks PC-relative branches, causing instant crashes on launch.
	// Standard App Store sandbox already enforces process confinement.
	UHLogInfoF(@"Process layer initialized (safe zero-crash mode)");
}
