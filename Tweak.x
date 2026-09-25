#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>
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

// Constructor — runs as soon as the tweak dylib finishes loading.
__attribute__((constructor))
static void UHInit(void) {
	// Zero-Risk Safe Mode Guard:
	// 1. Instant C-level fast path: SpringBoard, backboardd, daemons, and jailbreak apps must NEVER run UltraHidePro
	const char *progname = getprogname();
	if (progname != NULL) {
		if (strcmp(progname, "SpringBoard") == 0 ||
		    strcmp(progname, "backboardd") == 0 ||
		    strcmp(progname, "launchd") == 0 ||
		    strcmp(progname, "runningboardd") == 0 ||
		    strcmp(progname, "Preferences") == 0 ||
		    strcmp(progname, "Sileo") == 0 ||
		    strcmp(progname, "Zebra") == 0 ||
		    strcmp(progname, "Filza") == 0 ||
		    strcmp(progname, "UltraHidePro") == 0) {
			return;
		}
	}

	// 2. Per-app bundle guard: only activate if this app is configured in target_apps.
	if (![UHConfig activeForCurrentApp]) {
		return;
	}

	UHLogInfo(@"UltraHide Pro v1.1.5 booting for %@", [UHConfig hostBundleID]);

	// Order matters: capture PAC, capture Mach-O, then load config.
	[UHPAC bootstrap];
	[UHMachO bootstrap];
	UHConfig *cfg = [UHConfig sharedInstance];
	[UHHookStats sharedInstance];

	if (cfg.filesystemEnabled)   UHInstallFileSystemHooks();
	if (cfg.processEnabled)      UHInstallProcessHooks();
	if (cfg.dyldEnabled)         UHInstallDyldHooks();
	if (cfg.environmentEnabled)  UHInstallEnvironmentHooks();
	if (cfg.sandboxAmfiEnabled)  UHInstallSandboxAMFIHooks();
	if (cfg.networkIOKitEnabled) UHInstallNetworkIOKitHooks();
	if (cfg.objcAggregateEnabled) UHInstallBridgeHooks();
	UHInstallAntiHookHooks();           // always on

	if (cfg.kernelEnabled) {
		UHInitKernelPrimitives();
		UHInstallKernelPatches();
	}

	NSUInteger activeCount = [UHHookStats sharedInstance].activeCount;
	UHLogInfo(@"UltraHide Pro loaded with %lu active hooks", (unsigned long)activeCount);

	// Expose the active count via env so external tools can introspect.
	setenv("ULTRAHIDE_ACTIVE_HOOKS", [[NSString stringWithFormat:@"%lu", (unsigned long)activeCount] UTF8String], 1);
}
