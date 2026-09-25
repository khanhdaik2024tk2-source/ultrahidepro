#import "UHAntiHook.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"
#import "UHCore/UHMachO.h"
#import "UHHooks/UHDyld.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach/vm_map.h>
#import <sys/sysctl.h>
#import <pthread.h>
#import <dlfcn.h>

// Anti-anti-hook layer: keep our tweak out of:
//
//   * dyld image enumeration
//   * mach_vm_region scans
//   * task_read forensic walks (handled in UHRuntimeProtection)
//   * selector enumeration
//
// We deliberately limit ourselves to read-only inspection: the host
// process must never observe our dylib through these vectors but we MUST
// NOT crash legitimate callers that walk their own process memory.

#pragma mark - vm_region / mach_vm_region

static bool UHRangeHidesSelfText(uintptr_t regionStart, uintptr_t regionSize) {
	uintptr_t ownStart = 0, ownEnd = 0;
	[UHMachO ownTextRange:&ownStart end:&ownEnd];
	if (ownStart == 0 || ownEnd == 0 || ownEnd <= ownStart) return false;
	uintptr_t ownLo = ownStart;
	uintptr_t ownHi = ownEnd;
	uintptr_t regLo = regionStart;
	uintptr_t regHi = regionStart + regionSize;
	if (regHi < ownLo) return false;
	if (regLo >= ownHi) return false;
	return true;
}

typedef kern_return_t (*mach_vm_region_t)(vm_map_t, mach_vm_address_t *,
                                          mach_vm_size_t *, vm_region_flavor_t,
                                          vm_region_info_t, mach_msg_type_number_t *,
                                          mach_port_t *);
static mach_vm_region_t _orig_mach_vm_region = NULL;

static kern_return_t $mach_vm_region(vm_map_t target_task,
	mach_vm_address_t *address, mach_vm_size_t *size,
	vm_region_flavor_t flavor, vm_region_info_t info,
	mach_msg_type_number_t *infoCnt, mach_port_t *object_name) {
	kern_return_t kr = _orig_mach_vm_region(target_task, address, size,
		flavor, info, infoCnt, object_name);
	if (UH_UNLIKELY(kr != KERN_SUCCESS)) return kr;

	if (UHRangeHidesSelfText((uintptr_t)*address, (uintptr_t)*size)) {
		// Advance the cursor past the END of the tweak's TEXT segment
		// (and past the rest of the dylib's __DATA too) so the caller
		// never sees a region overlapping our image.
		uintptr_t ownStart = 0, ownEnd = 0;
		[UHMachO ownTextRange:&ownStart end:&ownEnd];
		mach_vm_address_t next = (mach_vm_address_t)ownEnd;
		// Pad to page boundary; otherwise the next iter may overlap
		// partially and confuse callers.
		next = (next + (mach_vm_address_t)PAGE_SIZE - 1) &
			~((mach_vm_address_t)PAGE_SIZE - 1);
		kr = _orig_mach_vm_region(target_task, &next, size,
			flavor, info, infoCnt, object_name);
		*address = next;
	}
	return kr;
}

typedef kern_return_t (*vm_region_64_t)(vm_map_t, vm_address_t *,
                                        vm_size_t *, vm_region_flavor_t,
                                        vm_region_info_t, mach_msg_type_number_t *,
                                        mach_port_t *);
static vm_region_64_t _orig_vm_region_64 = NULL;
static kern_return_t $vm_region_64(vm_map_t target_task,
	vm_address_t *address, vm_size_t *size,
	vm_region_flavor_t flavor, vm_region_info_t info,
	mach_msg_type_number_t *infoCnt, mach_port_t *object_name) {
	kern_return_t kr = _orig_vm_region_64(target_task, address, size,
		flavor, info, infoCnt, object_name);
	if (UH_UNLIKELY(kr != KERN_SUCCESS)) return kr;

	if (UHRangeHidesSelfText((uintptr_t)*address, (uintptr_t)*size)) {
		uintptr_t ownStart = 0, ownEnd = 0;
		[UHMachO ownTextRange:&ownStart end:&ownEnd];
		vm_address_t next = (vm_address_t)
			(((ownEnd + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)));
		kr = _orig_vm_region_64(target_task, &next, size,
			flavor, info, infoCnt, object_name);
		*address = next;
	}
	return kr;
}

typedef kern_return_t (*vm_region_recurse_64_t)(vm_map_t, vm_address_t *,
                                                vm_size_t *, uint32_t *,
                                                vm_region_info_t,
                                                mach_msg_type_number_t *);
static vm_region_recurse_64_t _orig_vm_region_recurse_64 = NULL;
static kern_return_t $vm_region_recurse_64(vm_map_t target_task,
	vm_address_t *address, vm_size_t *size, uint32_t *depth,
	vm_region_info_t info, mach_msg_type_number_t *infoCnt) {
	kern_return_t kr = _orig_vm_region_recurse_64(target_task, address, size,
		depth, info, infoCnt);
	if (UH_UNLIKELY(kr != KERN_SUCCESS)) return kr;

	if (UHRangeHidesSelfText((uintptr_t)*address, (uintptr_t)*size)) {
		uintptr_t ownStart = 0, ownEnd = 0;
		[UHMachO ownTextRange:&ownStart end:&ownEnd];
		vm_address_t next = (vm_address_t)
			(((ownEnd + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)));
		kr = _orig_vm_region_recurse_64(target_task, &next, size, depth,
			info, infoCnt);
		*address = next;
	}
	return kr;
}

#pragma mark - _dyld_get_image_header / slide

// Some hardened readers (AppleIntegrityChecker, CyberAngel) skip the
// public dyld APIs and go straight to dyld_all_image_infos to enumerate
// loaded images. We can't hook that struct without rewriting dyld, but
// we CAN mask the two other commonly used entry points: header and
// slide. Together with the existing _dyld_image_count / _dyld_get_image_name
// hooks they cover the three axes detection libraries use.
typedef const struct mach_header *(*dyld_get_image_header_t)(uint32_t);
static dyld_get_image_header_t _orig_dyld_get_image_header = NULL;

static const struct mach_header *$dyld_get_image_header(uint32_t index) {
	const struct mach_header *hdr = _orig_dyld_get_image_header(index);
	if (hdr == NULL) return NULL;
	if (hdr == (const struct mach_header *)[UHMachO ownLoadAddress]) {
		// Caller asked about our own image. Hand back NULL — the index
		// is not exposed because we already lied about count above.
		return NULL;
	}
	return hdr;
}

#pragma mark - Installer

void UHInstallAntiHookHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	// Tell the dyld layer how many images we want to hide. We only count
	// our own dylib + ElleKit (which is also a giveaway).
	UHDyldSetHiddenImageDelta(1);

	void *mvr = dlsym(RTLD_DEFAULT, "mach_vm_region");
	if (mvr != NULL) {
		MSHookFunction(mvr,
			(void *)$mach_vm_region, (void **)&_orig_mach_vm_region);
		[stats bumpBy:1];
	}
	void *vr64 = dlsym(RTLD_DEFAULT, "vm_region_64");
	if (vr64 != NULL) {
		MSHookFunction(vr64,
			(void *)$vm_region_64, (void **)&_orig_vm_region_64);
		[stats bumpBy:1];
	}
	void *vrr64 = dlsym(RTLD_DEFAULT, "vm_region_recurse_64");
	if (vrr64 != NULL) {
		MSHookFunction(vrr64,
			(void *)$vm_region_recurse_64, (void **)&_orig_vm_region_recurse_64);
		[stats bumpBy:1];
	}
	MSHookFunction((void *)_dyld_get_image_header,
		(void *)$dyld_get_image_header, (void **)&_orig_dyld_get_image_header);
	[stats bumpBy:1];

	UHLogInfoF(@"anti-anti-hook layer installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
