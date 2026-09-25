#import "UHRuntimeProtection.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"
#import "UHCore/UHMachO.h"
#import "UHCore/UHPAC.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/vm_map.h>
#import <stdint.h>
#import <string.h>

// UHRuntimeProtection.m — sanitize outbound vm_read buffers.
//
// On iOS 18.6.2 apps can request a task_read on their own process and
// scan for `BRK #1` instructions in the guest address space; ElleKit
// uses `BRK #1` as the way to reach its trampoline from out-of-range
// hook targets. We don't want a host process to be able to tell that we
// are present from a "BRK #1" string of bytes.
//
// The previously used upper bound `0x40000` was too coarse: it spanned
// any neighbouring library the kernel loaded near us (typically
// ElleKit + Mobile Substrate + Dopamine libs). We now use the precise
// __TEXT segment range returned by UHMachO.

static const uint32_t UH_BRK_IMM = 0xD4200000;
static const uint32_t UH_NOP     = 0xD503201F;

#pragma mark - vm_read / vm_read_overwrite

// Quick predicate: is the requested address range inside our own
// __TEXT segment? Using uintptr_t arithmetic avoids PAC stripping side
// effects on arm64e processors that we may run into accidentally.
static inline bool UHRangeOverlapsSelfText(uintptr_t address, uint64_t size) {
	uintptr_t start = 0, end = 0;
	[UHMachO ownTextRange:&start end:&end];
	if (start == 0 || end == 0 || end <= start) return false;
	uintptr_t lo = (uintptr_t)address;
	uintptr_t hi = lo + (size ? (uintptr_t)size : 1u);
	// True if [lo, hi) intersects [start, end).
	return (lo < end) && (start < hi);
}

static void UHSanitizeBRK(uint8_t *bytes, uintptr_t limit) {
	if (bytes == NULL || limit < 4) return;
	for (uintptr_t i = 0; i + 4 <= limit; i += 4) {
		uint32_t instr;
		memcpy(&instr, bytes + i, sizeof(instr));
		if (instr == UH_BRK_IMM) {
			instr = UH_NOP;
			memcpy(bytes + i, &instr, sizeof(instr));
		}
	}
}

typedef kern_return_t (*vm_read_overwrite_t)(vm_map_t, mach_vm_address_t,
                                             mach_vm_size_t, mach_vm_address_t,
                                             mach_vm_size_t *);
static vm_read_overwrite_t _orig_vm_read_overwrite = NULL;

static kern_return_t $vm_read_overwrite(vm_map_t target_task,
	mach_vm_address_t address, mach_vm_size_t size,
	mach_vm_address_t data, mach_vm_size_t *outsize) {
	kern_return_t kr = _orig_vm_read_overwrite(target_task, address, size,
		data, outsize);
	if (UH_UNLIKELY(kr != KERN_SUCCESS || data == 0 || size == 0)) return kr;
	if (!UHRangeOverlapsSelfText((uintptr_t)address, (uint64_t)size)) return kr;
	uint8_t *bytes = (uint8_t *)data;
	uint64_t n = outsize ? (uint64_t)*outsize : (uint64_t)size;
	uint64_t limit = (n < size) ? n : size;
	UHSanitizeBRK(bytes, (uintptr_t)limit);
	return kr;
}

typedef kern_return_t (*vm_read_t)(vm_map_t, mach_vm_address_t,
                                   mach_vm_size_t, void *,
                                   mach_msg_type_number_t *);
static vm_read_t _orig_vm_read = NULL;

static kern_return_t $vm_read(vm_map_t target_task,
	mach_vm_address_t address, mach_vm_size_t size,
	void *data, mach_msg_type_number_t *outlen) {
	kern_return_t kr = _orig_vm_read(target_task, address, size, data, outlen);
	if (UH_UNLIKELY(kr != KERN_SUCCESS || data == NULL || size == 0)) return kr;
	if (!UHRangeOverlapsSelfText((uintptr_t)address, (uint64_t)size)) return kr;
	uint8_t *bytes = (uint8_t *)data;
	mach_msg_type_number_t n = outlen ? *outlen : (mach_msg_type_number_t)size;
	mach_msg_type_number_t limit = (n < size) ? n : size;
	UHSanitizeBRK(bytes, (uintptr_t)limit);
	return kr;
}

#pragma mark - Installer

void UHInstallRuntimeProtectionHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	MSHookFunction((void *)vm_read_overwrite,
		(void *)$vm_read_overwrite,
		(void **)&_orig_vm_read_overwrite);
	MSHookFunction((void *)vm_read,
		(void *)$vm_read,
		(void **)&_orig_vm_read);
	[stats bumpBy:2];

	// PAC spoof is intentionally a no-op on arm64 (Dopamine 3.0.9 only
	// ships arm64). The wrappers in UHPAC short-circuit; we keep this
	// log line so the telemetry shows the layer is active.
	if ([UHPAC isPACAvailable]) {
		UHLogInfoF(@"PAC runtime detected; runtime-protection layer would emit xpaci stubs");
	}

	UHLogInfoF(@"runtime protection installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
