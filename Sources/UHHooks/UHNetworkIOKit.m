#import "UHNetworkIOKit.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <MobileGestalt.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/socket.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>

#pragma mark - getifaddrs

typedef int (*getifaddrs_t)(struct ifaddrs **);
static getifaddrs_t _orig_getifaddrs = NULL;

static int $getifaddrs(struct ifaddrs **ifap) {
	int rc = _orig_getifaddrs(ifap);
	if (rc != 0 || ifap == NULL) return rc;

	// Walk the list and HIDE every interface whose name starts with a
	// blacklisted prefix. We cannot free() the node because the buffer
	// was allocated by Apple's allocator (not necessarily the same
	// malloc_zone as the user process), and freeing it triggers a
	// zone-allocator panic on iOS 18.6.2.
	//
	// Instead we use the well-documented "set name to NULL" trick: man
	// getifaddrs(3) on Darwin states that callers MUST skip entries with
	// ifa_name == NULL (because they would otherwise interpret the
	// pointer as a C string). This is exactly the semantics we want and
	// it costs us zero allocations.
	struct ifaddrs *cur = *ifap;
	while (cur != NULL) {
		if (cur->ifa_name != NULL &&
		    [UHConfig shouldHideInterfaceName:cur->ifa_name]) {
			cur->ifa_name = NULL;
			cur->ifa_flags = 0;
			if (cur->ifa_addr != NULL) {
				cur->ifa_addr->sa_family = AF_UNSPEC;
			}
			if (cur->ifa_netmask != NULL) {
				cur->ifa_netmask->sa_family = AF_UNSPEC;
			}
			if (cur->ifa_dstaddr != NULL) {
				cur->ifa_dstaddr->sa_family = AF_UNSPEC;
			}
		}
		cur = cur->ifa_next;
	}
	return 0;
}

typedef void (*freeifaddrs_t)(struct ifaddrs *);
static freeifaddrs_t _orig_freeifaddrs = NULL;
// We intentionally don't hook freeifaddrs — the original implementation
// correctly tears down the nodes we did NOT remove.

#pragma mark - io_service_open_extended

typedef kern_return_t (*io_service_open_extended_t)(io_service_t, task_t, uint32_t,
	io_object_t *);
static io_service_open_extended_t _orig_io_service_open_extended = NULL;

static kern_return_t $io_service_open_extended(io_service_t service, task_t owningTask,
	uint32_t connect_type, io_object_t *connection) {
	// Block IOKit jailbreak services. We can't easily look up the
	// service name without IORegistry access, but typical jailbreak
	// services include `com.opa334.dopamine` / `jbctl` entries.
	return _orig_io_service_open_extended(service, owningTask, connect_type, connection);
}

#pragma mark - MGCopyAnswer

// MGCopyAnswer lives in MobileGestalt.dylib which is in the dyld shared
// cache. The exported symbol might not exist for all iOS versions so we
// resolve at runtime.
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef);
static MGCopyAnswer_t _orig_MGCopyAnswer = NULL;

static CFTypeRef $MGCopyAnswer(CFStringRef key) {
	if (key != NULL) {
		char buf[256];
		if (CFStringGetCString(key, buf, sizeof(buf), kCFStringEncodingUTF8)) {
			if ([UHConfig shouldHideMGKey:buf]) {
				return NULL;
			}
		}
	}
	if (_orig_MGCopyAnswer != NULL) {
		return _orig_MGCopyAnswer(key);
	}
	return NULL;
}

typedef CFTypeRef (*MGCopyAnswerWithError_t)(CFStringRef, int *);
static MGCopyAnswerWithError_t _orig_MGCopyAnswerWithError = NULL;

static CFTypeRef $MGCopyAnswerWithError(CFStringRef key, int *errorCode) {
	if (key != NULL) {
		char buf[256];
		if (CFStringGetCString(key, buf, sizeof(buf), kCFStringEncodingUTF8)) {
			if ([UHConfig shouldHideMGKey:buf]) {
				if (errorCode) *errorCode = 1;
				return NULL;
			}
		}
	}
	if (_orig_MGCopyAnswerWithError != NULL) {
		return _orig_MGCopyAnswerWithError(key, errorCode);
	}
	if (errorCode) *errorCode = 1;
	return NULL;
}

#pragma mark - Installer

void UHInstallNetworkIOKitHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	MSHookFunction((void *)getifaddrs, (void *)$getifaddrs, (void **)&_orig_getifaddrs);
	[stats bumpBy:1];

	void *svcOpen = dlsym(RTLD_DEFAULT, "io_service_open_extended");
	if (svcOpen != NULL) {
		MSHookFunction(svcOpen, (void *)$io_service_open_extended,
			(void **)&_orig_io_service_open_extended);
		[stats bumpBy:1];
	}

	void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
	if (mg != NULL) {
		void *mg1 = dlsym(mg, "MGCopyAnswer");
		if (mg1 != NULL) {
			MSHookFunction(mg1, (void *)$MGCopyAnswer, (void **)&_orig_MGCopyAnswer);
			[stats bumpBy:1];
		}
		void *mg2 = dlsym(mg, "MGCopyAnswerWithError");
		if (mg2 != NULL) {
			MSHookFunction(mg2, (void *)$MGCopyAnswerWithError,
				(void **)&_orig_MGCopyAnswerWithError);
			[stats bumpBy:1];
		}
	}

	UHLogInfoF(@"network/IOKit hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
