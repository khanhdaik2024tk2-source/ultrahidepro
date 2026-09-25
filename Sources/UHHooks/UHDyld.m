#import "UHDyld.h"
#import "UHCommon.h"
#import "UHCore/UHLog.h"

void UHInstallDyldHooks(void) {
	// In iOS 18 (dyld4), hooking dlopen/dlsym/dladdr via MSHookFunction corrupts internal
	// dyld state and PAC signing, resulting in instant crash on startup.
	// Image inspection is safely handled via Objective-C runtime and NSBundle swizzling.
	UHLogInfoF(@"Dyld layer initialized (safe zero-crash mode)");
}
