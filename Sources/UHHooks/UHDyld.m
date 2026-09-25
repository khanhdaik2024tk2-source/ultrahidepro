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
		"UH",        // UltraHidePro public symbols.
		"EK",        // ElleKit public surface.
		"MSHook",    // substrate legacy.
		"LH",        // libhooker legacy.
		"ultrahidepro_tweak_",
		"ElleKit_",
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
		// Allow the tweak itself to keep using the symbols. We
		// approximate "self" by checking whether the calling handle's
		// backing image is our own disguise path; if so, fall through
		// to the real implementation.
		Dl_info info;
		if (handle != NULL && dladdr(handle, &info) != 0 &&
		    info.dli_fname != NULL &&
		    [UHMachO isTweakPath:info.dli_fname]) {
			return _orig_dlsym(handle, symbol);
		}
		// Otherwise: pretend the symbol doesn't exist. This makes
		// it impossible for an attacker to enumerate our toolkit.
		UHLogDebugF(@"dlsym: hid %s", symbol);
		// On platforms that require a non-NULL return, callers fall
		// back gracefully. We follow dlsym(3) which says failure is
		// indicated by NULL with errno=ENOENT-equivalent, but
		// CallerHooks isn't always checking dlerror(), so we prefer
		// a NULL for clarity.
		return NULL;
	}
	return _orig_dlsym(handle, symbol);
}

#pragma mark - objc_copyClassList / objc_getClassList

typedef int (*objc_copyClassList_t)(Class *, int);
static objc_copyClassList_t _orig_objc_copyClassList = NULL;
typedef int (*objc_getClassList_t)(Class *, int);
static objc_getClassList_t _orig_objc_getClassList = NULL;

// Cached list of classes we want to hide. Populated lazily on first call.
static Class *gHiddenClasses = NULL;
static int gHiddenClassesCount = 0;
static bool gHiddenClassesScanned = false;

static void UHDyldScanHiddenClasses(void) {
	if (gHiddenClassesScanned) return;
	int total = _orig_objc_copyClassList(NULL, 0);
	if (total <= 0) { gHiddenClassesScanned = true; return; }
	Class *all = (Class *)calloc((size_t)total, sizeof(Class));
	if (all == NULL) return;
	_orig_objc_copyClassList(all, total);

	// First pass: count.
	int hidden = 0;
	for (int i = 0; i < total; i++) {
		const char *name = object_getClassName((id)all[i]);
		if (name == NULL) continue;
		if ([UHConfig shouldHookObjCClass:name]) hidden++;
	}
	if (hidden == 0) {
		free(all);
		gHiddenClassesScanned = true;
		return;
	}
	gHiddenClasses = (Class *)calloc((size_t)hidden, sizeof(Class));
	if (gHiddenClasses == NULL) { free(all); gHiddenClassesScanned = true; return; }
	int j = 0;
	for (int i = 0; i < total; i++) {
		const char *name = object_getClassName((id)all[i]);
		if (name == NULL) continue;
		if ([UHConfig shouldHookObjCClass:name] && j < hidden) {
			gHiddenClasses[j++] = all[i];
		}
	}
	gHiddenClassesCount = j;
	free(all);
	gHiddenClassesScanned = true;
	UHLogInfoF(@"UHDyld: %d hidden classes registered", j);
}

static int $objc_copyClassList(Class *buffer, int count) {
	int total = _orig_objc_copyClassList(buffer, count);
	if (UH_UNLIKELY(!gHiddenClassesScanned)) UHDyldScanHiddenClasses();
	if (gHiddenClassesCount == 0 || buffer == NULL || count == 0) return total;

	// Walk through and remove hidden classes.
	int writeIdx = 0;
	for (int readIdx = 0; readIdx < total; readIdx++) {
		Class c = buffer[readIdx];
		bool isHidden = false;
		for (int k = 0; k < gHiddenClassesCount; k++) {
			if (gHiddenClasses[k] == c) { isHidden = true; break; }
		}
		if (!isHidden) buffer[writeIdx++] = c;
	}
	return writeIdx;
}

static int $objc_getClassList(Class *buffer, int count) {
	return $objc_copyClassList(buffer, count);
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
	MSHookFunction((void *)objc_copyClassList,
	               (void *)$objc_copyClassList,
	               (void **)&_orig_objc_copyClassList);
	MSHookFunction((void *)objc_getClassList,
	               (void *)$objc_getClassList,
	               (void **)&_orig_objc_getClassList);
	[stats bumpBy:6];

	UHLogInfoF(@"dyld hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
