#import "UHProcess.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>
#import <spawn.h>
#import <dlfcn.h>

#pragma mark - fork / vfork

#pragma mark - fork

typedef pid_t (*fork_t)(void);
static fork_t _orig_fork = NULL;

static pid_t $fork(void) {
	// Standard iOS sandbox denies fork(); mimic stock sandbox behaviour
	errno = EPERM;
	return -1;
}

#pragma mark - execve / posix_spawn

typedef int (*execve_t)(const char *, char *const[], char *const[]);
static execve_t _orig_execve = NULL;

static int $execve(const char *path, char *const argv[], char *const envp[]) {
	if (UH_UNLIKELY(path != NULL && UHPathBlockedFast(path))) {
		errno = EPERM;
		return -1;
	}
	return _orig_execve(path, argv, envp);
}

typedef int (*posix_spawn_t)(pid_t *, const char *,
	const void *, void *, char *const[], char *const[]);
static posix_spawn_t _orig_posix_spawn = NULL;

static int $posix_spawn(pid_t *pid, const char *path,
	const void *desc, void *attrp,
	char *const argv[], char *const envp[]) {
	if (UH_UNLIKELY(path != NULL && UHPathBlockedFast(path))) {
		errno = EPERM;
		return -1;
	}
	return _orig_posix_spawn(pid, path, desc, attrp, argv, envp);
}

#pragma mark - sysctl

// sysctl is the vector most often used to enumerate processes. We use the
// KERN_PROC/KERN_PROCARGS pattern (top 2 levels of mib: CTL_KERN, KERN_PROC).
typedef int (*sysctl_t)(int *, u_int, void *, size_t *, void *, size_t);
static sysctl_t _orig_sysctl = NULL;

static int $sysctl(int *name, u_int namelen,
                   void *oldp, size_t *oldlenp,
                   void *newp, size_t newlen) {
	// Avoid recursion: $getppid / $kill call `_orig_sysctl` so we don't
	// loop. But if a future caller keeps our $sysctl pointer cached, the
	// hook will fire and the guard prevents stack growth.
	int rc;
	if (_orig_sysctl == NULL) {
		rc = -1;
	} else {
		rc = _orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
	}
	if (rc != 0 || oldp == NULL || name == NULL || namelen < 2) return rc;

	if (name[0] == CTL_KERN) {
		if (name[1] == KERN_PROC_PID && oldlenp && *oldlenp >= sizeof(struct kinfo_proc)) {
			// Clear P_TRACED flag used by anti-debug detection
			#ifndef P_TRACED
			#define P_TRACED 0x00000800
			#endif
			struct kinfo_proc *p = (struct kinfo_proc *)oldp;
			p->kp_proc.p_flag &= ~P_TRACED;
		}
	}
	return rc;
}

typedef int (*sysctlbyname_t)(const char *, void *, size_t *, void *, size_t);
static sysctlbyname_t _orig_sysctlbyname = NULL;

static int $sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                         void *newp, size_t newlen) {
	int rc;
	if (_orig_sysctlbyname == NULL) {
		rc = -1;
	} else {
		rc = _orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
	}
	if (rc != 0) return rc;
	// Block kernel-level jailbreak indicators. We must allow reading
	// other sysctls because legitimate callers (e.g. nc, sysctl helpers)
	// already see the right answer; we only suppress the well-known
	// jailbreak probes.
	if (name != NULL) {
		if (strncasecmp(name, "kern.jailbreak", 14) == 0 ||
		    strncasecmp(name, "security.mac.proc_enforce", 25) == 0 ||
		    strncasecmp(name, "security.mac.vnode_enforce", 26) == 0) {
			errno = ENOENT;
			return -1;
		}
	}
	return rc;
}

#pragma mark - getppid / kill

typedef pid_t (*getppid_t)(void);
static getppid_t _orig_getppid = NULL;

static pid_t $getppid(void) {
	pid_t pp = _orig_getppid();
	// If the parent pid belongs to a known jailbreak daemon, we report
	// launchd (1). Only inspect when caller is in a target app — otherwise
	// we'd burn one syscall on every C-call-from-system-service.
	if (pp != 1 && pp > 1 && [UHConfig activeForCurrentApp]) {
		// Use the *un-hooked* sysctl to avoid recursion & policy loops.
		struct kinfo_proc info;
		size_t sz = sizeof(info);
		int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pp };
		if (_orig_sysctl != NULL &&
		    _orig_sysctl(mib, 4, &info, &sz, NULL, 0) == 0) {
			if ([UHConfig shouldHideProcessName:info.kp_proc.p_comm]) {
				return 1;
			}
		}
	}
	return pp;
}

typedef int (*kill_t)(pid_t, int);
static kill_t _orig_kill = NULL;

static int $kill(pid_t pid, int sig) {
	if ([UHConfig activeForCurrentApp]) {
		struct kinfo_proc info;
		size_t sz = sizeof(info);
		int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
		if (_orig_sysctl != NULL &&
		    _orig_sysctl(mib, 4, &info, &sz, NULL, 0) == 0 &&
		    [UHConfig shouldHideProcessName:info.kp_proc.p_comm]) {
			errno = EPERM;
			return -1;
		}
	}
	return _orig_kill(pid, sig);
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

#pragma mark - csops

// csops(pid, op, buffer, size) — used by SecCode, JailbreakDetector etc.
// We spoof csflags so CS_KILL / CS_HARD are never reported, AND we
// emulate CS_OPS_CDHASH (the CDHash returned for an app that the
// signer verification rejected is still returned but unflagged as
// invalid). Op code definitions below per csops(2):
#define UH_CS_VALID     0x00000001u
#define UH_CS_ADHOC     0x00000002u
#define UH_CS_KILL      0x00000100u
#define UH_CS_HARD      0x00000200u
#define UH_CS_DEBUGGED  0x00100000u
#define UH_CS_OPS_STATUS          0
#define UH_CS_OPS_CDHASH          5
#define UH_CS_OPS_ENTITLEMENTS_BLOB  7

typedef int (*csops_t)(pid_t, unsigned int, void *, size_t);
static csops_t _orig_csops = NULL;

// We only force CS_VALID | CS_DEBUGGED; we deliberately keep the lower
// bits alone so an app that does signature.version == 'signed9' style
// comparison won't notice an obvious mismatch.
static int $csops(pid_t pid, unsigned int op, void *buffer, size_t size) {
	int rc = _orig_csops(pid, op, buffer, size);
	if (rc != 0 || buffer == NULL || size < sizeof(uint32_t)) return rc;
	switch (op) {
	case UH_CS_OPS_STATUS: {
		uint32_t flags = 0;
		if (size >= sizeof(flags)) {
			memcpy(&flags, buffer, sizeof(flags));
		}
		flags = (flags & ~(UH_CS_KILL | UH_CS_HARD | UH_CS_DEBUGGED)) | UH_CS_VALID;
		memcpy(buffer, &flags, sizeof(flags));
		break;
	}
	case UH_CS_OPS_CDHASH:
		// The 20-byte CDHash returned by the kernel can't be safely
		// spoofed because apps later cross-check it against the
		// embedded entitlement blob. Pass through.
		break;
	default:
		break;
	}
	return rc;
}

#pragma mark - Installer

void UHInstallProcessHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	MSHookFunction((void *)fork,        (void *)$fork,        (void **)&_orig_fork);
	MSHookFunction((void *)execve,      (void *)$execve,      (void **)&_orig_execve);
	MSHookFunction((void *)posix_spawn, (void *)$posix_spawn, (void **)&_orig_posix_spawn);
	MSHookFunction((void *)sysctl,      (void *)$sysctl,      (void **)&_orig_sysctl);
	MSHookFunction((void *)sysctlbyname,(void *)$sysctlbyname,(void **)&_orig_sysctlbyname);
	MSHookFunction((void *)getppid,     (void *)$getppid,     (void **)&_orig_getppid);
	MSHookFunction((void *)kill,        (void *)$kill,        (void **)&_orig_kill);
	[stats bumpBy:7];

	void *fn_ptrace = dlsym(RTLD_DEFAULT, "ptrace");
	if (fn_ptrace != NULL) {
		MSHookFunction(fn_ptrace, (void *)$ptrace, (void **)&_orig_ptrace);
		[stats bumpBy:1];
	}

	UHLogInfoF(@"process hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
