// UHBridge.m — lazy scanner for Objective-C aggregate bypass.
//
// Threading model:
//
//   * The very first scan runs synchronously on the calling thread (the
//     tweak constructor thread). This catches the 90% case where the
//     detection framework is already loaded by the time we boot.
//
//   * If the first scan finds zero matching classes, we schedule a
//     bounded number of follow-up scans on a USER_INITIATED global queue.
//     We deliberately avoid dispatch_get_main_queue(): background
//     daemons (extensions, URL session workers) may have no main queue
//     loop. Threads: at most one worker, so we don't melt the UI.
//
//   * Each scan is guarded by a pthread mutex to keep reentry from
//     lazy-load scenarios idempotent.

#import "UHBridge.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <string.h>
#import <dispatch/dispatch.h>

static pthread_mutex_t gUHBridgeLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gUHBridgeFirstScanDone = NO;
static dispatch_queue_t gUHBridgeQueue = NULL;
static BOOL gUHBridgeRescanScheduled = NO;

// Forced return values per selector.
static BOOL UHBoolReturnFor(SEL sel) {
	const char *name = sel_getName(sel);
	if (name == NULL) return NO;
	// verifyIntegrity / isCompromised → YES (clean).
	if (strcmp(name, "verifyIntegrity") == 0) return YES;
	if (strcmp(name, "checkIntegrity") == 0) return YES;
	if (strcmp(name, "isCompromised") == 0) return YES;
	// Everything else → NO (clean).
	return NO;
}

static BOOL $BOOLGeneric(id self, SEL _cmd) {
	(void)self; (void)_cmd;
	return UHBoolReturnFor(_cmd);
}

static BOOL $BOOLGenericClass(id self, SEL _cmd) {
	(void)self; (void)_cmd;
	return UHBoolReturnFor(_cmd);
}

// performChecks returns an NSNumber / NSInteger with FORCE_CLEAN (1).
static NSInteger $performChecks_inst(id self, SEL _cmd) {
	(void)self; (void)_cmd;
	return 1; // FORCE_CLEAN
}

static Class $performChecks_cls(id self, SEL _cmd) {
	(void)self; (void)_cmd;
	return Nil;
}

#pragma mark - Class enumeration

// Walk the entire runtime class list and install hooks on every method
// whose class name and selector name are both on the bypass list.
static void UHBridgeScanAndHook(void) {
	pthread_mutex_lock(&gUHBridgeLock);

	int total = objc_getClassList(NULL, 0);
	if (total <= 0) { pthread_mutex_unlock(&gUHBridgeLock); return; }

	Class *classes = (Class *)calloc((size_t)total, sizeof(Class));
	if (classes == NULL) { pthread_mutex_unlock(&gUHBridgeLock); return; }
	objc_getClassList(classes, total);

	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger hooked = 0;

	for (int i = 0; i < total; i++) {
		Class cls = classes[i];
		const char *cname = class_getName(cls);
		if (cname == NULL) continue;
		if (![UHConfig shouldHookObjCClass:cname]) continue;

		// Hook selectors on instance method list.
		unsigned int mc = 0;
		Method *methods = class_copyMethodList(cls, &mc);
		for (unsigned int m = 0; m < mc; m++) {
			SEL sel = method_getName(methods[m]);
			const char *sname = sel_getName(sel);
			if (sname == NULL) continue;
			if (![UHConfig shouldHookObjCSelector:sname]) continue;

			IMP newImp = (IMP)$BOOLGeneric;
			if (strcmp(sname, "performChecks") == 0) {
				newImp = (IMP)$performChecks_inst;
			} else if (strcmp(sname, "verifyIntegrity") == 0 ||
			           strcmp(sname, "checkIntegrity") == 0 ||
			           strcmp(sname, "isCompromised") == 0) {
				newImp = (IMP)$BOOLGeneric;  // returns YES via UHBoolReturnFor
			} else {
				newImp = (IMP)$BOOLGeneric;
			}
			method_setImplementation(methods[m], newImp);
			hooked++;
		}
		if (methods != NULL) free(methods);

		// Class methods (meta class).
		Class meta = object_getClass(cls);
		if (meta != NULL) {
			Method *metaMethods = class_copyMethodList(meta, &mc);
			for (unsigned int m = 0; m < mc; m++) {
				SEL sel = method_getName(metaMethods[m]);
				const char *sname = sel_getName(sel);
				if (sname == NULL) continue;
				if (![UHConfig shouldHookObjCSelector:sname]) continue;
				IMP newImp = (IMP)$BOOLGenericClass;
				if (strcmp(sname, "performChecks") == 0) {
					newImp = (IMP)$performChecks_cls;
				}
				method_setImplementation(metaMethods[m], newImp);
				hooked++;
			}
			if (metaMethods != NULL) free(metaMethods);
		}
	}

	free(classes);
	[stats bumpBy:hooked];
	gUHBridgeFirstScanDone = YES;
	pthread_mutex_unlock(&gUHBridgeLock);
	if (hooked > 0) {
		UHLogInfoF(@"UHBridge: hooked %lu aggregate methods", (unsigned long)hooked);
	}
}

#pragma mark - Installer

void UHInstallBridgeHooks(void) {
	// First pass: run synchronously on the constructor thread so we
	// don't lose the chance to hook a framework that's already loaded
	// before we return from +load. This covers the most common case
	// (static dylibs from the app's main loader path).
	UHBridgeScanAndHook();

	if (gUHBridgeFirstScanDone && gUHBridgeRescanScheduled) return;
	gUHBridgeRescanScheduled = YES;

	if (gUHBridgeQueue == NULL) {
		gUHBridgeQueue = dispatch_queue_create("com.ultrahidepro.bridge",
			DISPATCH_QUEUE_SERIAL);
	}

	// Re-scan for a few seconds in case the framework is dlopen()ed after
	// our constructor returns (common for dependency-injected security
	// frameworks). Total cap: ~62s of follow-up scans, all on a single
	// serial queue so we don't race against the first scan.
	const NSTimeInterval intervals[] = { 2.0, 4.0, 8.0, 16.0, 32.0 };
	for (size_t i = 0; i < sizeof(intervals)/sizeof(intervals[0]); i++) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
			(int64_t)(intervals[i] * NSEC_PER_SEC)),
			gUHBridgeQueue, ^{
			UHBridgeScanAndHook();
		});
	}
	UHLogInfoF(@"bridge hooks scheduled (lazy scan)");
}
