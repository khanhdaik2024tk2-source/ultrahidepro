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

#pragma mark - _dyld_image_count

typedef uint32_t (*dyld_image_count_t)(void);
static dyld_image_count_t _orig_dyld_image_count = NULL;

// Number of tweaks that we've decided to hide. Set by UHAntiHook too;
// kept here because the original hook of _dyld_image_count lives in this
// file as a "first-line" defense.
static uint32_t gHiddenImageDelta = 0;

void UHDyldSetHiddenImageDelta(uint32_t delta) { gHiddenImageDelta = delta; }

static uint32_t $dyld_image_count(void) {
	uint32_t n = _orig_dyld_image_count();
	if (UH_UNLIKELY(gHiddenImageDelta > 0 && n >= gHiddenImageDelta)) {
		return n - gHiddenImageDelta;
	}
	return n;
}

#pragma mark - _dyld_get_image_name

typedef const char *(*dyld_get_image_name_t)(uint32_t);
static dyld_get_image_name_t _orig_dyld_get_image_name = NULL;

// Returned to the caller when the requested index is one of our hidden
// tweaks. Cached so we don't allocate per call.
static const char *gDisguisedNamePtr = NULL;

static const char *$dyld_get_image_name(uint32_t index) {
	const char *orig = _orig_dyld_get_image_name(index);
	if (orig == NULL) return NULL;
	if (UH_UNLIKELY([UHMachO isTweakPath:orig])) {
		if (gDisguisedNamePtr == NULL) {
			gDisguisedNamePtr = strdup([[UHMachO disguisePath] UTF8String]);
		}
		return gDisguisedNamePtr;
	}
	return orig;
}

#pragma mark - dlopen / dlopen_from

typedef void *(*dlopen_t)(const char *, int);
static dlopen_t _orig_dlopen = NULL;

static void *$dlopen(const char *path, int mode) {
	if (UH_UNLIKELY(path != NULL && [UHConfig shouldBlockPath:
		[NSString stringWithUTF8String:path]])) {
		UHLogDebugF(@"dlopen: blocked %s", path);
		return NULL;
	}
	return _orig_dlopen(path, mode);
}

// dlopen_from has a third LR argument on iOS 14+. We can hook the public
// symbol `dlopen` and rely on Apple's own dlopen routing inside dyld for
// most callers. If we need finer control later we add a second hook here.

#pragma mark - dlsym

// UHAntiHook interplays with this file: anti-hook components must NOT
// see our tweak's symbols under any handle they pull through dlsym.
static bool UHDyldIsHiddenSymbolPrefix(const char *symbol) {
	if (symbol == NULL) return false;
	if (symbol[0] == '_') symbol++; // Mach-O leading underscore.
	if (symbol[0] == '\0') return false;
	static const char *prefixes[] = {
		"MSHookFunction",
		"MSHookMessageEx",
		"ultrahidepro_",
		"UltraHidePro_",
		NULL,
	};
	for (size_t i = 0; prefixes[i] != NULL; i++) {
		size_t n = strlen(prefixes[i]);
		if (strncmp(symbol, prefixes[i], n) == 0) return true;
	}
	return false;
}

typedef void *(*dlsym_t)(void *, const char *);
static dlsym_t _orig_dlsym = NULL;

static void *$dlsym(void *handle, const char *symbol) {
	if (UH_UNLIKELY(symbol != NULL && UHDyldIsHiddenSymbolPrefix(symbol))) {
		Dl_info info;
		if (handle != NULL && dladdr(handle, &info) != 0 &&
		    info.dli_fname != NULL &&
		    [UHMachO isTweakPath:info.dli_fname]) {
			return _orig_dlsym(handle, symbol);
		}
		UHLogDebugF(@"dlsym: hid %s", symbol);
		return NULL;
	}
	return _orig_dlsym(handle, symbol);
}

#pragma mark - Installer

void UHInstallDyldHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	MSHookFunction((void *)_dyld_image_count,
	               (void *)$dyld_image_count,
	               (void **)&_orig_dyld_image_count);
	MSHookFunction((void *)_dyld_get_image_name,
	               (void *)$dyld_get_image_name,
	               (void **)&_orig_dyld_get_image_name);
	MSHookFunction((void *)dlopen,
	               (void *)$dlopen,
	               (void **)&_orig_dlopen);
	MSHookFunction((void *)dlsym,
	               (void *)$dlsym,
	               (void **)&_orig_dlsym);
	[stats bumpBy:4];

	UHLogInfoF(@"dyld hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
