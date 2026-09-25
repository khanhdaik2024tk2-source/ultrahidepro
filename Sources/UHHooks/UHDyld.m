#import "UHDyld.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"
#import "UHCore/UHMachO.h"

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>

#pragma mark - dlopen / dlopen_from

typedef void *(*dlopen_t)(const char *, int);
static dlopen_t _orig_dlopen = NULL;

static void *$dlopen(const char *path, int mode) {
	if (UH_UNLIKELY(path != NULL && UHPathBlockedFast(path))) {
		UHLogDebugF(@"dlopen: blocked %s", path);
		return NULL;
	}
	return _orig_dlopen(path, mode);
}

#pragma mark - dlsym

static bool UHDyldIsHiddenSymbolPrefix(const char *symbol) {
	if (symbol == NULL) return false;
	if (symbol[0] == '_') symbol++; // Mach-O leading underscore.
	if (symbol[0] == '\0') return false;
	static const char *prefixes[] = {
		"MSHook",
		"MSFindSymbol",
		"MSGetImageByName",
		"ultrahidepro_",
		"UltraHidePro_",
		"ellekit",
		"ElleKit",
		"libellekit",
		"substrate",
		"Substrate",
		"substitute",
		"Substitute",
		"libhooker",
		"cydia",
		"frida",
		"dopamine",
		NULL,
	};
	for (size_t i = 0; prefixes[i] != NULL; i++) {
		size_t n = strlen(prefixes[i]);
		if (strncasecmp(symbol, prefixes[i], n) == 0) return true;
	}
	return false;
}

typedef void *(*dlsym_t)(void *, const char *);
static dlsym_t _orig_dlsym = NULL;

static void *$dlsym(void *handle, const char *symbol) {
	if (UH_UNLIKELY(symbol != NULL && UHDyldIsHiddenSymbolPrefix(symbol))) {
		Dl_info info;
		if (dladdr(__builtin_return_address(0), &info) != 0 &&
		    info.dli_fname != NULL &&
		    UHMachOIsTweakPathFast(info.dli_fname)) {
			return _orig_dlsym(handle, symbol);
		}
		UHLogDebugF(@"dlsym: hid %s", symbol);
		return NULL;
	}
	return _orig_dlsym(handle, symbol);
}

#pragma mark - dladdr

typedef int (*dladdr_t)(const void *, Dl_info *);
static dladdr_t _orig_dladdr = NULL;

static int $dladdr(const void *addr, Dl_info *info) {
	int rc = _orig_dladdr(addr, info);
	if (rc != 0 && info != NULL && info->dli_fname != NULL) {
		if (UH_UNLIKELY(UHMachOIsTweakPathFast(info->dli_fname))) {
			info->dli_fname = "/usr/lib/system/libsystem_trace.dylib";
		}
	}
	return rc;
}

#pragma mark - Installer

void UHInstallDyldHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	MSHookFunction((void *)dlopen,
	               (void *)$dlopen,
	               (void **)&_orig_dlopen);
	MSHookFunction((void *)dlsym,
	               (void *)$dlsym,
	               (void **)&_orig_dlsym);
	MSHookFunction((void *)dladdr,
	               (void *)$dladdr,
	               (void **)&_orig_dladdr);
	[stats bumpBy:3];

	UHLogInfoF(@"dyld hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
