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

// ROOT_PATH string. We do NOT resolve to jbroot() at compile time because
// Dopamine sets jbroot at runtime; instead we build it lazily in UHConfig.
extern NSString *UHDefaultJBRoot(void);

#if defined(__cplusplus)
}
#endif

#endif // UH_COMMON_H
