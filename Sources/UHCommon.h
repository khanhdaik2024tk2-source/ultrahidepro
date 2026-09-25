#ifndef UH_COMMON_H
#define UH_COMMON_H

// UHCommon.h — single header for shared declarations.
//
// In a real theos build this pulls from the iOS SDK + ElleKit headers. On
// cross-platform static analysis the SDK isn't visible, so we provide the
// minimum types/macros ourselves.

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>
#import <stddef.h>
#import <mach/mach.h>
#import <mach/vm_map.h>

#ifndef MACH_VM_H_SHIM
#define MACH_VM_H_SHIM
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;
typedef uint64_t mach_vm_offset_t;

extern kern_return_t mach_vm_region(
    vm_map_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *infoCnt,
    mach_port_t *object_name
);

extern kern_return_t mach_vm_read_overwrite(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    mach_vm_address_t data,
    mach_vm_size_t *outsize
);

extern kern_return_t mach_vm_read(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    vm_offset_t *data,
    mach_msg_type_number_t *dataCnt
);
#endif

// ElleKit re-implements the substrate public API.
#import <substrate.h>

#if defined(__cplusplus)
extern "C" {
#endif

// Visibility default → symbol visible to the dynamic linker when other
// tweak dylibs want to call us.
#define UH_EXPORT __attribute__((visibility("default")))

// Visibility hidden → used for internal helpers to shrink the export table.
#define UH_PRIVATE __attribute__((visibility("hidden")))

// Branch prediction hints (hot path: hooks fire on every call).
#define UH_LIKELY(x)   __builtin_expect(!!(x), 1)
#define UH_UNLIKELY(x) __builtin_expect(!!(x), 0)

// Compile-time string concat.
#define UH_STR_HELPER(x) #x
#define UH_STR(x) UH_STR_HELPER(x)

// Convenience: case-insensitive prefix check that tolerates nil inputs.
static inline bool UHStringHasPrefixCI(NSString *str, NSString *prefix) {
	if (str == nil || prefix == nil) return false;
	return [str rangeOfString:prefix
	                  options:(NSCaseInsensitiveSearch |
	                           NSLiteralSearch |
	                           NSAnchoredSearch)].location != NSNotFound;
}

// Pure C fast tweak-path check (ZERO ObjC allocations, safe in all contexts)
static inline bool UHMachOIsTweakPathFast(const char *path) {
	if (path == NULL || path[0] == '\0') return false;
	static const char *const tweak_patterns[] = {
		"UltraHidePro",
		"ultrahidepro",
		"com.ultrahidepro",
		"ellekit",
		"ElleKit",
		"libellekit",
		"substrate",
		"Substrate",
		"libsubstrate",
		"substitute",
		"Substitute",
		"libhooker",
		"tweakinject",
		"TweakInject",
		"/var/jb",
		"/private/var/jb",
		"Cephei",
		"Shadow",
		"Choicy",
		"TweakLoader",
		"MobileSubstrate",
		"dopamine",
		"Dopamine",
		"procursus",
		"Procursus",
		NULL
	};
	for (int i = 0; tweak_patterns[i] != NULL; i++) {
		if (strstr(path, tweak_patterns[i]) != NULL) return true;
	}
	return false;
}

// Pure C fast jailbreak environment variable filter (ZERO ObjC allocations, safe in all contexts)
static inline bool UHEnvBlockedFast(const char *name) {
	if (name == NULL || name[0] == '\0') return false;
	if (strncasecmp(name, "DYLD_INSERT_LIBRARIES", 21) == 0) return true;
	if (strncasecmp(name, "DYLD_PRINT_", 11) == 0) return true;
	if (strncasecmp(name, "DYLD_LIBRARY_PATH", 17) == 0) return true;
	if (strncasecmp(name, "DYLD_FRAMEWORK_PATH", 19) == 0) return true;
	if (strncasecmp(name, "DYLD_ROOT_PATH", 14) == 0) return true;
	if (strncasecmp(name, "_MSSafeMode", 11) == 0) return true;
	if (strncasecmp(name, "MSSafeMode", 10) == 0) return true;
	if (strncasecmp(name, "CYDIA_", 6) == 0) return true;
	if (strncasecmp(name, "FRIDA_", 6) == 0) return true;
	if (strncasecmp(name, "THEOS_", 6) == 0) return true;
	if (strncasecmp(name, "THEOS", 5) == 0) return true;
	if (strncasecmp(name, "ULTRAHIDE_", 10) == 0) return true;
	if (strncasecmp(name, "JAILBREAK_", 10) == 0) return true;
	return false;
}

// Pure C fast jailbreak path filter (ZERO ObjC allocations, safe for stat/open/lstat/access)
static inline bool UHPathBlockedFast(const char *path) {
	if (path == NULL || path[0] == '\0') return false;

	// Fast-path: sandbox containers and system paths (99% of app calls)
	if (strncmp(path, "/private/var/containers/", 24) == 0 ||
	    strncmp(path, "/var/containers/", 16) == 0 ||
	    strncmp(path, "/private/var/mobile/Containers/", 31) == 0 ||
	    strncmp(path, "/var/mobile/Containers/", 23) == 0 ||
	    strncmp(path, "/System/", 8) == 0) {
		return false;
	}

	// Always allow UltraHidePro's own internal config
	if (strstr(path, "ultrahidepro/config.plist") != NULL ||
	    strstr(path, "UltraHidePro/config.plist") != NULL) {
		return false;
	}

	// Dopamine rootless bootstrap in /private/preboot
	if (strncmp(path, "/private/preboot/", 17) == 0 || strncmp(path, "/preboot/", 9) == 0) {
		if (strstr(path, "dopamine") != NULL || strstr(path, "/jb") != NULL) {
			return true;
		}
		return false;
	}

	// Direct /var/jb rootless symlink & aliases
	if (strncmp(path, "/var/jb", 7) == 0 ||
	    strncmp(path, "/private/var/jb", 15) == 0 ||
	    strcmp(path, "/jb") == 0 ||
	    strncmp(path, "/jb/", 4) == 0 ||
	    strcmp(path, "/basebin") == 0 ||
	    strncmp(path, "/basebin/", 9) == 0) {
		return true;
	}

	// Exact jailbreak binaries and files
	static const char *const jb_exact[] = {
		"/bin/sh", "/bin/bash", "/bin/zsh",
		"/etc/apt", "/private/etc/apt",
		"/.bootstrapped",
		"/usr/sbin/sshd", "/usr/bin/ssh", "/usr/bin/cycript",
		"/usr/lib/tweakinject.dylib",
		"/usr/lib/libsubstitute.dylib",
		"/usr/lib/libellekit.dylib",
		"/usr/lib/libhooker.dylib",
		"/usr/lib/systemhook.dylib",
		NULL
	};
	for (int i = 0; jb_exact[i] != NULL; i++) {
		if (strcmp(path, jb_exact[i]) == 0) return true;
	}

	// Prefix jailbreak paths
	static const char *const jb_prefixes[] = {
		"/Applications/Cydia.app",
		"/Applications/Sileo.app",
		"/Applications/Zebra.app",
		"/Applications/Filza.app",
		"/Applications/UltraHidePro.app",
		"/usr/lib/substrate",
		"/usr/lib/ellekit",
		"/Library/MobileSubstrate",
		"/var/lib/dpkg",
		"/var/lib/cydia",
		"/var/lib/apt",
		"/private/var/lib/cydia",
		"/private/var/lib/apt",
		"/private/var/stash",
		"/private/jailbreak.txt",
		"/private/jb_test.txt",
		"/private/test.txt",
		NULL
	};
	for (int i = 0; jb_prefixes[i] != NULL; i++) {
		size_t len = strlen(jb_prefixes[i]);
		if (strncasecmp(path, jb_prefixes[i], len) == 0) return true;
	}

	return false;
}

// ROOT_PATH string. We do NOT resolve to jbroot() at compile time because
// Dopamine sets jbroot at runtime; instead we build it lazily in UHConfig.
extern NSString *UHDefaultJBRoot(void);

#if defined(__cplusplus)
}
#endif

#endif // UH_COMMON_H
