#import "UHBrkGuard.h"
#import "UHCommon.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHPAC.h"

#import <Foundation/Foundation.h>
#import <signal.h>
#import <pthread.h>
#import <os/log.h>
#import <mach-o/loader.h>

// We pass on install if we detect a fat binary containing an arm64e slice
// (PAC) — BRK traps there are ambiguous between our escape hatch and the
// PAC trap, so we'd risk obfuscating real Apple issues.

static struct sigaction gOldSigtrap;
static struct sigaction gOldSigbus;
static volatile int gInstallCount = 0;

static void UH_BrkDumpState(int sig, siginfo_t *info, ucontext_t *ctx) {
#if defined(__arm64__) || defined(__arm64e__)
	uint64_t pc = 0;
	if (ctx != NULL && ctx->uc_mcontext != NULL) {
		pc = (uint64_t)ctx->uc_mcontext->__ss.__pc;
	}
	UHLogErrorF(@"BRK guard: signal=%d at PC=0x%llx (ElleKit trampoline recursion suspected)",
		sig, (unsigned long long)pc);
#else
	(void)sig; (void)info; (void)ctx;
#endif
}

static void UH_BrkHandler(int sig, siginfo_t *info, void *uap) {
	UH_BrkDumpState(sig, info, (ucontext_t *)uap);
	// Always forward to the prior handler — never swallow the signal
	// ourselves. If ElleKit was supposed to handle it, it has been
	// bypassed by us intercepting first; we re-invoke the saved handler.
	struct sigaction *prev = (sig == SIGTRAP) ? &gOldSigtrap : &gOldSigbus;
	if (prev->sa_sigaction != NULL) {
		prev->sa_sigaction(sig, info, uap);
		return;
	}
	// Fall through: re-raise with default behaviour so the process
	// still terminates cleanly.
	signal(sig, SIG_DFL);
	raise(sig);
}

void UHInstallBrkGuard(void) {
	if (__sync_fetch_and_add(&gInstallCount, 1) > 0) return;
#if defined(__arm64__) && !defined(__arm64e__)
	if ([UHPAC isPACAvailable]) {
		// On arm64e skip — BRK conflicts with PAC traps.
		UHLogInfoF(@"BRK guard: skip on arm64e");
		return;
	}
	struct sigaction act = {0};
	act.sa_sigaction = UH_BrkHandler;
	act.sa_flags = SA_SIGINFO;
	sigemptyset(&act.sa_mask);
	sigaction(SIGTRAP, &act, &gOldSigtrap);
	sigaction(SIGBUS,   &act, &gOldSigbus);
	UHLogInfoF(@"BRK guard installed (SIGTRAP+SIGBUS)");
#endif
}

void UHUninstallBrkGuard(void) {
	if (__sync_fetch_and_sub(&gInstallCount, 1) != 1) return;
#if defined(__arm64__) && !defined(__arm64e__)
	sigaction(SIGTRAP, &gOldSigtrap, NULL);
	sigaction(SIGBUS,   &gOldSigbus,   NULL);
#endif
}
