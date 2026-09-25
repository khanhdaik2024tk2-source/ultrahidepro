#import "UHPAC.h"
#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <string.h>

// We compute the answer once on bootstrap by inspecting the host's
// mach_header. CPU_TYPE_ARM64E = 0x100000C.
static BOOL gPACAvailable = NO;

@implementation UHPAC

+ (instancetype)sharedInstance {
	static UHPAC *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [UHPAC new]; });
	return s;
}

+ (void)bootstrap {
	if (gPACAvailable) return;
	const struct mach_header *hdr = (const struct mach_header *)
		_dyld_get_image_header(0);
	if (hdr != NULL && hdr->cputype == 0x100000C /* CPU_TYPE_ARM64E */) {
		gPACAvailable = YES;
	}
}

+ (BOOL)isPACAvailable {
	if (!gPACAvailable) [self bootstrap];
	return gPACAvailable;
}

+ (uintptr_t)strip:(uintptr_t)ptr {
	if (!gPACAvailable) return ptr;
#if defined(__arm64e__)
	// On arm64e the compiler emits `xpaci` when targeting __arm64e__.
	// We deliberately don't depend on it because runtime arch detection is
	// not reliable when compiled in fat mode. Instead we mask off the high
	// PAC tag bits (top 8 bits are unused by valid pointers).
	return ptr & 0x00FFFFFFFFFFFFFFULL;
#else
	(void)ptr;
	return ptr;
#endif
}

+ (uintptr_t)sign:(uintptr_t)ptr discriminator:(uint64_t)disc {
	if (!gPACAvailable) return ptr;
#if defined(__arm64e__)
	(void)disc; // We don't have access to PACIA here without PAC keys.
	return ptr | 0x0000000000000000ULL;
#else
	(void)disc;
	return ptr;
#endif
}

@end
