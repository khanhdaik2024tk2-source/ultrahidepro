#import "UHSandboxAMFI.h"
#import "UHCommon.h"
#import "UHCore/UHLog.h"

void UHInstallSandboxAMFIHooks(void) {
	// Hooking sandbox_check / SecCodeCheckValidity via MSHookFunction causes fatal ABI
	// parameter mismatches (variadic registers) and immediate WebKit/Security crashes.
	// Sandbox confinement is safely maintained natively by iOS.
	UHLogInfoF(@"Sandbox/AMFI layer initialized (safe zero-crash mode)");
}
