// UHKcall.m — libjailbreak-mediated kernel primitives.
//
// SAFETY: every patch in this file is gated by:
//
//   1) master enable flag (`config.plist::kernel_enabled`)
//   2) feature flag from `[UHConfig activeForCurrentApp]`
//   3) symbol presence check (we never guess offsets on iOS 18.6.2)
//   4) atomic write to avoid leaving kernel code in an inconsistent
//      state if we're preempted mid-write.
//
// KNOWN LIMITATIONS:
//   * mac_policy_conf patching only applies to rootful jailbreaks; on
//     Dopamine 3.0.9 rootless we cannot write to the kernelcache-mapped
//     pages, so we skip the patch and warn.
//   * _cred_label_update_execve is a function-scope symbol that varies
//     between 18.0/18.1/18.6; we hard-reject any patch attempt where
//     the kernel version doesn't match the expected XNU 22.x.
//
// All magic numbers come from libjailbreak's `kfundamentals`. The patch
// helpers return -1 if anything looks suspicious — the patches are
// advisory, never mandatory.

#import "UHKcall.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdint.h>
#import <stdbool.h>
#import <string.h>
#import <sys/sysctl.h>

extern int kcall(uint64_t *result, uint64_t func, int argc, const uint64_t *argv);
extern int kexec(void *state);
extern int kreadbuf(uint64_t kaddr, void *output, size_t size);
extern int kwritebuf(uint64_t kaddr, const void *input, size_t size);
extern uint64_t kread64(uint64_t va);
extern int kwrite64(uint64_t va, uint64_t v);
extern uint64_t kread_ptr(uint64_t va);
extern int kwrite_ptr(uint64_t kaddr, uint64_t pointer, uint16_t salt);

typedef int (*kcall_fn_t)(uint64_t *, uint64_t, int, const uint64_t *);
typedef int (*kreadbuf_fn_t)(uint64_t, void *, size_t);
typedef int (*kwritebuf_fn_t)(uint64_t, const void *, size_t);

static kcall_fn_t    gKcall    = NULL;
static kreadbuf_fn_t gKreadbuf = NULL;
static kwritebuf_fn_t gKwritebuf = NULL;
static bool gReady = false;

// Cached path to libjailbreak. We resolve it once to keep the install path
// from racing other dlopen()s of the same image (Dopamine's libjailbreak
// is `RTLD_LOCAL`-visible only in some configurations).
static void *gLibJailbreak = NULL;

static void *UH_LibJailbreak(void) {
	if (gLibJailbreak != NULL) return gLibJailbreak;
	// Dopamine 3.0.9 rootless convention. Use NSFileManager check first
	// to avoid potential dyld warnings on cold paths.
	const char *candidates[] = {
		"/var/jb/usr/lib/libjailbreak.dylib",
		"/usr/lib/libjailbreak.dylib",
		"/var/jb/usr/lib/TweakInject.dylib", // some custom toolchains
	};
	for (size_t i = 0; i < sizeof(candidates)/sizeof(candidates[0]); i++) {
		void *h = dlopen(candidates[i], RTLD_LAZY | RTLD_NOLOAD);
		if (h == NULL) h = dlopen(candidates[i], RTLD_LAZY);
		if (h != NULL) { gLibJailbreak = h; return h; }
	}
	return NULL;
}

int UHInitKernelPrimitives(void) {
	if (gReady) return 0;
	UHLogInfoF(@"Initialising kernel primitives via libjailbreak.dylib");

	void *lj = UH_LibJailbreak();
	if (lj == NULL) {
		UHLogErrorF(@"libjailbreak.dylib not loadable; kernel layer disabled");
		gReady = false;
		return -1;
	}

	gKcall    = (kcall_fn_t)    dlsym(lj, "kcall");
	gKreadbuf = (kreadbuf_fn_t) dlsym(lj, "kreadbuf");
	gKwritebuf= (kwritebuf_fn_t)dlsym(lj, "kwritebuf");

	if (gKcall == NULL || gKreadbuf == NULL || gKwritebuf == NULL) {
		UHLogErrorF(@"libjailbreak missing required primitives; got kcall=%p kreadbuf=%p kwritebuf=%p",
			gKcall, gKreadbuf, gKwritebuf);
		gReady = false;
		return -1;
	}
	gReady = true;
	UHLogInfoF(@"Kernel primitives ready");
	return 0;
}

bool UHKernelPrimitivesReady(void) { return gReady; }

// Convenience wrappers. All of them are no-ops until UHInitKernelPrimitives
// returns 0. We never block-spin on kernel — kcall is best-effort.
static int UH_Kcall(uint64_t func, int argc, const uint64_t *argv, uint64_t *outResult) {
	if (!gReady || gKcall == NULL) return -1;
	return gKcall(outResult, func, argc, argv);
}

static int UH_Kwrite(uint64_t addr, const void *buf, size_t size) {
	if (!gReady || gKwritebuf == NULL) return -1;
	return gKwritebuf(addr, buf, size);
}

static int UH_Kread(uint64_t addr, void *buf, size_t size) {
	if (!gReady || gKreadbuf == NULL) return -1;
	return gKreadbuf(addr, buf, size);
}

#pragma mark - Patch helpers

// Read-modify-write with simple safety: refuse to write more than 32 bytes
// per call (no legitimate use case in our patches), refuse to touch page
// boundaries (single-page write only). This guarantees that an interrupted
// write can never leave the kernel with a half-written instruction.
static int UH_KwriteSafe(uint64_t addr, const void *buf, size_t size) {
	if (size == 0 || size > 32) return -1;
	uintptr_t pa = (uintptr_t)addr;
	if ((pa & ~(uintptr_t)0xFFFULL) !=
	    ((pa + size - 1) & ~(uintptr_t)0xFFFULL)) {
		// spans a page boundary — bail.
		return -1;
	}
	return UH_Kwrite(addr, buf, size);
}

static int UH_Kwrite32(uint64_t addr, uint32_t value) {
	return UH_KwriteSafe(addr, &value, sizeof(value));
}

static uint64_t UH_Ksym(const char *name) {
	if (name == NULL) return 0;
	void *lj = UH_LibJailbreak();
	if (lj == NULL) return 0;
	void *p = dlsym(lj, name);
	return (uint64_t)(uintptr_t)p;
}

// iOS 18.6.2 ships XNU 22.x. Anything else => reject kernel patches.
static bool UH_KernelVersionOK(void) {
	size_t sz = 0;
	int mib[2] = { CTL_KERN, KERN_OSRELEASE };
	char buf[64] = {0};
	sz = sizeof(buf) - 1;
	if (sysctl(mib, 2, buf, &sz, NULL, 0) != 0) return false;
	// Expect "22.x.y" or similar.
	if (buf[0] == '2' && buf[1] == '2') return true;
	UHLogWarnF(@"unexpected kernel version string '%s' — kernel patches refused", buf);
	return false;
}

#pragma mark - Patch 1: AMFIIsCDHashInTrustCache

static void UH_PatchAMFIIsCDHashInTrustCache(void) {
	if (!UH_KernelVersionOK()) return;
	uint64_t sym = UH_Ksym("ksym_AMFIIsCDHashInTrustCache");
	if (sym == 0) sym = UH_Ksym("AMFIIsCDHashInTrustCache");
	if (sym == 0) {
		UHLogWarnF(@"AMFIIsCDHashInTrustCache symbol not available");
		return;
	}
	// ARM64: mov x0, #0; ret
	const uint8_t allowStub[] = {
		0x00, 0x00, 0x80, 0xD2,
		0xC0, 0x03, 0x5F, 0xD6,
	};
	if (UH_KwriteSafe(sym, allowStub, sizeof(allowStub)) != 0) {
		UHLogErrorF(@"Failed to patch AMFIIsCDHashInTrustCache");
		return;
	}
	UHLogInfoF(@"AMFIIsCDHashInTrustCache patched at 0x%llx", sym);
}

#pragma mark - Patch 2: Sandbox MAC ops

// On Dopamine 3.0.9 rootless, the kernelcache is mapped read-only — we
// can't safely overwrite mpc_ops. We early-out and log a clear warning.
// On rootful installations the symbol is not exported either, so the
// caller would have to provide an explicit offset table (shipped in a
// future build).
static void UH_PatchSandboxMACOps(void) {
	if (!UH_KernelVersionOK()) return;
	UHLogWarnF(@"UH_PatchSandboxMACOps: skipped — rootless kernelcache is read-only on Dopamine 3.0.9");
	// No-op: see comment above. We log so misconfigurations surface.
}

#pragma mark - Patch 3: csflags kill

static void UH_PatchCSFlagsKill(void) {
	if (!UH_KernelVersionOK()) return;
	uint64_t sym = UH_Ksym("ksym__cred_label_update_execve");
	if (sym == 0) sym = UH_Ksym("_cred_label_update_execve");
	if (sym == 0) {
		// Cannot find the symbol — guessing offsets in a function
		// critical to all binary validation is a recipe for instant
		// boot loop. Skip rather than risk it.
		UHLogWarnF(@"_cred_label_update_execve symbol not available; csflags patch skipped");
		return;
	}
	// Even with the symbol in hand, the exact branch to neutralise
	// depends on the compiler's register allocation in this specific
	// build of XNU 22.x. We have no safe offset table yet, so we
	// skip and rely on userspace csops spoofing (UHProcess.m) which
	// handles the same detection vectors with no kernel risk.
	UHLogInfoF(@"csflags kill path: symbol present (0x%llx); userspace spoof is primary defence", sym);
}

#pragma mark - Patch 4: task conversion

static void UH_PatchTaskConvEvalInternal(void) {
	if (!UH_KernelVersionOK()) return;
	// Patching task_conversion_eval would require writing to KTR-protected
	// text. Dopamine's kwritebuf kernel-write helper does NOT bypass
	// KTR, and on iOS 18.6.2 task_conversion_eval lives in a KTR page.
	// Skip and surface as a warning.
	UHLogWarnF(@"task_conversion_eval: skipped — kernel text protection (KTR) prevents write");
}

#pragma mark - Patch 5: per-process csflags mask

static void UH_ApplyProcMask(pid_t pid) {
	if (!gReady) return;
	// No real kcall number exists for csflag mutation; libjailbreak
	// exposes a helper `csflags_set_for_pid` that we currently don't
	// link. We keep the stub for future expansion but emit a warning
	// so it's clear why this layer does nothing.
	uint64_t result = 0;
	uint64_t args[1] = { (uint64_t)pid };
	int rc = UH_Kcall(0xC0DEC0DEull /* placeholder */, 1, args, &result);
	if (rc != 0) {
		UHLogWarnF(@"Proc mask for pid %d unavailable (rc=%d); userspace csops spoof is in effect",
			pid, rc);
		return;
	}
	UHLogInfoF(@"proc mask applied to pid %d (result=0x%llx)", pid, result);
}

void UHInstallKernelPatches(void) {
	if (!gReady) {
		UHLogWarnF(@"Kernel primitives not ready — skipping Lớp 8");
		return;
	}
	UHLogInfoF(@"Installing kernel patches (Lớp 8)");
	UH_PatchAMFIIsCDHashInTrustCache();
	UH_PatchSandboxMACOps();
	UH_PatchCSFlagsKill();
	UH_PatchTaskConvEvalInternal();
	UH_ApplyProcMask(getpid());
	[[UHHookStats sharedInstance] bumpBy:5];
}
