#import "UHProcess.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <sys/types.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <dlfcn.h>

#pragma mark - fork

typedef pid_t (*fork_t)(void);
static fork_t _orig_fork = NULL;

static pid_t $fork(void) {
	// Standard iOS sandbox denies fork(); mimic stock sandbox behaviour
	errno = EPERM;
	return -1;
}

#pragma mark - ptrace

typedef int (*ptrace_t)(int, pid_t, caddr_t, int);
static ptrace_t _orig_ptrace = NULL;

static int $ptrace(int request, pid_t pid, caddr_t addr, int data) {
	// PT_DENY_ATTACH == 31. Returning 0 mimics the "no debugger allowed"
	// semantic that stock iOS user-mode sees; we do NOT want to surface
	// the kernel failure (ENOTSUP) which a detection library uses as a
	// "device is jailbroken" tell.
	if (request == 31 /* PT_DENY_ATTACH */) {
		return 0;
	}
	return _orig_ptrace(request, pid, addr, data);
}

#pragma mark - Installer

void UHInstallProcessHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	MSHookFunction((void *)fork, (void *)$fork, (void **)&_orig_fork);
	[stats bumpBy:1];

	void *fn_ptrace = dlsym(RTLD_DEFAULT, "ptrace");
	if (fn_ptrace != NULL) {
		MSHookFunction(fn_ptrace, (void *)$ptrace, (void **)&_orig_ptrace);
		[stats bumpBy:1];
	}

	UHLogInfoF(@"process hooks installed (%lu total, safe mode)",
		(unsigned long)(stats.activeCount - before));
}
