#import <Foundation/Foundation.h>
#import <substrate.h>

#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"
#import "UHCore/UHMachO.h"
#import "UHCore/UHPAC.h"
#import "UHCore/UHBrkGuard.h"

#import "UHHooks/UHFileSystem.h"
#import "UHHooks/UHProcess.h"
#import "UHHooks/UHDyld.h"
#import "UHHooks/UHEnvironment.h"
#import "UHHooks/UHSandboxAMFI.h"
#import "UHHooks/UHNetworkIOKit.h"
#import "UHHooks/UHBridge.h"
#import "UHHooks/UHAntiHook.h"
#import "UHHooks/UHRuntimeProtection.h"

#import "UHKernel/UHKcall.h"
#import "UHRules/UHRuleLoader.h"

// Constructor — runs as soon as the tweak dylib finishes loading. The
// ordering is critical:
//
//   1) UHPAC bootstrap     : capture CPU type so guard macros are sane.
//   2) UHMachO bootstrap    : query the precise __TEXT range BEFORE we
//                             install any hooks that call back into the
//                             dyld API. This avoids a chicken-and-egg
//                             problem where the very hooks we install
//                             would otherwise see a "filtered" view of
//                             themselves.
//   3) UHConfig singleton   : load the plist (read-only from here on).
//   4) hook installers     : each layer short-circuits when not active.
//   5) rule loader          : tail-end so it may override decisions.
//
// We also defensively skip the entire tweak if it's being loaded into a
// process that should never host a hide-tweak (SpringBoard stays healthy).
__attribute__((constructor))
static void UHInit(void) {
	// Zero-Risk Safe Mode Guard:
	// Only activate inside target applications.
	// If the current process is SpringBoard, backboardd, a system daemon, or
	// not in target_apps, immediately bail out before doing ANY work
	// (no signal handlers, no hooks, no memory scans).
	if (![UHConfig activeForCurrentApp]) {
		return;
	}

	UHLogInfo(@"UltraHide Pro v1.0.0 booting for %@", [UHConfig hostBundleID]);

	// Order matters: capture PAC, capture Mach-O, then load config.
	[UHPAC bootstrap];
	[UHMachO bootstrap];
	UHConfig *cfg = [UHConfig sharedInstance];
	[UHHookStats sharedInstance];

	// Install BRK guard so multi-tweak BRK#1 recursion can't lurk in
	// the host's signal handler chain.
	UHInstallBrkGuard();

	// Defensive: if the host is arm64e (A12+) and Dopamine 3.0.9 has
	// not stabilised its arm64e Momentarius bypass, we currently
	// refuse to install. The PAC-aware path will ship in a future
	// release; for now we exit cleanly so no hooks get installed and
	// SpringBoard stays consistent.
	if ([UHPAC isPACAvailable]) {
		UHLogWarnF(@"arm64e detected — UltraHide Pro has no PAC-safe hook path yet; skipping");
		setenv("ULTRAHIDE_ACTIVE_HOOKS", "0", 1);
		UHUninstallBrkGuard();
		return;
	}

	if (cfg.filesystemEnabled)   UHInstallFileSystemHooks();
	if (cfg.processEnabled)      UHInstallProcessHooks();
	if (cfg.dyldEnabled)         UHInstallDyldHooks();
	if (cfg.environmentEnabled)  UHInstallEnvironmentHooks();
	if (cfg.sandboxAmfiEnabled)  UHInstallSandboxAMFIHooks();
	if (cfg.networkIOKitEnabled) UHInstallNetworkIOKitHooks();
	if (cfg.objcAggregateEnabled) UHInstallBridgeHooks();
	UHInstallAntiHookHooks();           // always on
	UHInstallRuntimeProtectionHooks();  // always on

	if (cfg.kernelEnabled) {
		UHInitKernelPrimitives();
		UHInstallKernelPatches();
	}

	// Dynamic rules last, so they can override defaults installed above.
	[[UHRuleLoader sharedInstance] activate];

	NSUInteger activeCount = [UHHookStats sharedInstance].activeCount;
	UHLogInfo(@"UltraHide Pro loaded with %lu active hooks", (unsigned long)activeCount);

	// Expose the active count via env so external tools can introspect.
	setenv("ULTRAHIDE_ACTIVE_HOOKS", [[NSString stringWithFormat:@"%lu", (unsigned long)activeCount] UTF8String], 1);
}
