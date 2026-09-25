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

#pragma mark - dlsym

static bool UHDyldIsHiddenSymbolPrefix(const char *symbol) {
	if (symbol == NULL) return false;
	if (symbol[0] == '_') symbol++; // Mach-O leading underscore.
	if (symbol[0] == '\0') return false;
	static const char *prefixes[] = {
		"MSHookFunction",
		"MSHookMessageEx",
		"ultrahidepro_",
		"UltraHidePro_",
		"ellekit",
		"ElleKit",
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

#pragma mark - dladdr

typedef int (*dladdr_t)(const void *, Dl_info *);
static dladdr_t _orig_dladdr = NULL;

static int $dladdr(const void *addr, Dl_info *info) {
	int rc = _orig_dladdr(addr, info);
	if (rc != 0 && info != NULL && info->dli_fname != NULL) {
		if (UH_UNLIKELY([UHMachO isTweakPath:info->dli_fname])) {
			info->dli_fname = "/usr/lib/system/libsystem_c.dylib";
			info->dli_sname = "strlen";
		}
	}
	return rc;
}

#pragma mark - _dyld_register_func_for_add_image

typedef void (*dyld_image_callback_t)(const struct mach_header *, intptr_t);
typedef void (*dyld_register_func_for_add_image_t)(dyld_image_callback_t);
static dyld_register_func_for_add_image_t _orig_dyld_register_func_for_add_image = NULL;

static dyld_image_callback_t gAppAddImageCallbacks[16];
static size_t gAppAddImageCallbackCount = 0;

static void UHAddImageCallbackDispatcher(const struct mach_header *mh, intptr_t vmaddr_slide) {
	if (mh == NULL) return;
	Dl_info info;
	if (dladdr((const void *)mh, &info) != 0 && info.dli_fname != NULL) {
		if ([UHMachO isTweakPath:info.dli_fname]) {
			// Suppress tweak images from detection callbacks
			return;
		}
	}
	for (size_t i = 0; i < gAppAddImageCallbackCount; i++) {
		if (gAppAddImageCallbacks[i] != NULL) {
			gAppAddImageCallbacks[i](mh, vmaddr_slide);
		}
	}
}

static void $dyld_register_func_for_add_image(dyld_image_callback_t func) {
	if (func == NULL) return;
	if (gAppAddImageCallbackCount < 16) {
		gAppAddImageCallbacks[gAppAddImageCallbackCount++] = func;
		if (gAppAddImageCallbackCount == 1 && _orig_dyld_register_func_for_add_image != NULL) {
			_orig_dyld_register_func_for_add_image(UHAddImageCallbackDispatcher);
		}
	} else if (_orig_dyld_register_func_for_add_image != NULL) {
		_orig_dyld_register_func_for_add_image(func);
	}
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
	MSHookFunction((void *)dladdr,
	               (void *)$dladdr,
	               (void **)&_orig_dladdr);
	MSHookFunction((void *)_dyld_register_func_for_add_image,
	               (void *)$dyld_register_func_for_add_image,
	               (void **)&_orig_dyld_register_func_for_add_image);
	[stats bumpBy:6];

	UHLogInfoF(@"dyld hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
