#import "UHMachO.h"
#import "UHLog.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>
#import <dlfcn.h>

// UHMachO.m — Mach-O loader introspection. Critical correctness rules:
//
//   * This file is consulted by UHAntiHook and UHRuntimeProtection to
//     identify "the tweak's own memory". The lookup MUST be done via the
//     raw libdyld entry points so that we are not tricked by the very
//     hooks UHDyld/Anti-hook install a few lines later.
//
//   * To stay safe across both arm64 and arm64e, we keep the load address
//     as a `uintptr_t` (not a typed pointer) so it survives PACII/AKEY
//     stripping via `UHPAC strip:` before being compared.
#import "UHMachO.h"
#import "UHLog.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <string.h>
#import <dlfcn.h>

// dyld_all_image_infos has been stable across iOS 13..18 but its layout
// is private. We only need the first three fields. Typed a "void*"
// rather than the canonical struct to keep the header diet minimal.
struct dyld_all_image_infos_compat {
	uint32_t version;
	uint32_t infoArrayCount;
	const void *infoArray;
};

static NSString *gOwnPath = nil;
static uintptr_t gOwnLoadAddr = 0;
static uintptr_t gOwnTextStart = 0; // address of the first executable byte
static uintptr_t gOwnTextEnd = 0;   // address of the last executable byte

// Walk the Mach-O headers of an image to find the __TEXT segment. Returns
// the text-low and text-high virtual addresses (NOT file offsets). The
// caller must subtract the image's slide to compare to gOwnLoadAddr.
static void UHLocateTextSegment(const struct mach_header *hdr, uintptr_t slide,
                                 uintptr_t *outLow, uintptr_t *outHigh) {
	*outLow = 0;
	*outHigh = 0;
	if (hdr == NULL) return;
	const uint8_t *cmd;
	if (hdr->magic == MH_MAGIC_64 || hdr->magic == MH_CIGAM_64) {
		cmd = (const uint8_t *)hdr + sizeof(struct mach_header_64);
	} else {
		cmd = (const uint8_t *)hdr + sizeof(struct mach_header);
	}
	for (uint32_t i = 0; i < hdr->ncmds; i++) {
		const struct load_command *lc = (const struct load_command *)cmd;
		if (lc->cmdsize == 0) break;
		if (lc->cmd == LC_SEGMENT_64) {
			const struct segment_command_64 *seg =
				(const struct segment_command_64 *)cmd;
			if (strcmp(seg->segname, "__TEXT") == 0) {
				*outLow = (uintptr_t)seg->vmaddr + slide;
				*outHigh = *outLow + (uintptr_t)seg->vmsize;
				return;
			}
		} else if (lc->cmd == LC_SEGMENT) {
			const struct segment_command *seg =
				(const struct segment_command *)cmd;
			if (strcmp(seg->segname, "__TEXT") == 0) {
				*outLow = (uintptr_t)seg->vmaddr + slide;
				*outHigh = *outLow + (uintptr_t)seg->vmsize;
				return;
			}
		}
		cmd += lc->cmdsize;
	}
}

@implementation UHMachO

+ (instancetype)sharedInstance {
	static UHMachO *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [UHMachO new]; });
	return s;
}

+ (void)bootstrap {
	if (gOwnPath != nil) return;

	uint32_t count = _dyld_image_count();
	for (uint32_t i = 0; i < count; i++) {
		const char *name = _dyld_get_image_name(i);
		if (name == NULL) continue;
		if (strstr(name, "UltraHidePro") != NULL) {
			gOwnPath = [NSString stringWithUTF8String:name];
			const struct mach_header *hdr = _dyld_get_image_header(i);
			intptr_t slide = _dyld_get_image_vmaddr_slide(i);
			gOwnLoadAddr = (uintptr_t)hdr;
			UHLocateTextSegment(hdr, (uintptr_t)slide,
				&gOwnTextStart, &gOwnTextEnd);
			UHLogInfoF(@"UHMachO: own path=%@ base=%p text=[0x%lx..0x%lx)",
				gOwnPath, hdr, (unsigned long)gOwnTextStart,
				(unsigned long)gOwnTextEnd);
			return;
		}
	}

	// Fallback for static-analysis / unit-test environments where the
	// tweak wasn't injected by dopamine.
	UHLogWarnF(@"UHMachO: own path not found via _dyld_image_count; falling back to dladdr");
	Dl_info info;
	if (dladdr((const void *)&UHLocateTextSegment, &info) != 0 &&
	    info.dli_fname != NULL && info.dli_fbase != NULL) {
		gOwnPath = [NSString stringWithUTF8String:info.dli_fname];
		gOwnLoadAddr = (uintptr_t)info.dli_fbase;
		UHLocateTextSegment((const struct mach_header *)info.dli_fbase, 0,
			&gOwnTextStart, &gOwnTextEnd);
	}
}

+ (NSString *)ownInstallPath {
	if (gOwnPath == nil) [self bootstrap];
	return gOwnPath ?: @"";
}

+ (const void *)ownLoadAddress {
	if (gOwnLoadAddr == 0) [self bootstrap];
	return (const void *)gOwnLoadAddr;
}

+ (void)ownTextRange:(uintptr_t *)outStart end:(uintptr_t *)outEnd {
	if (gOwnTextStart == 0) [self bootstrap];
	if (outStart) *outStart = gOwnTextStart;
	if (outEnd)   *outEnd   = gOwnTextEnd;
}

+ (BOOL)isTweakPath:(const char *)path {
	return UHMachOIsTweakPathFast(path);
}

+ (NSString *)disguisePath {
	static NSString *cached;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		// libsystem_c.dylib is widely linked; never gives away
		// a jailbreak suspicion in a basic scan.
		cached = @"/usr/lib/system/libsystem_c.dylib";
	});
	return cached;
}

@end
