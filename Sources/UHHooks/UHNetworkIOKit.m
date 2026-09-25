#import "UHNetworkIOKit.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#if __has_include(<IOKit/IOKitLib.h>)
#import <IOKit/IOKitLib.h>
#else
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
#endif
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
	if (rc != 0 || ifap == NULL || *ifap == NULL) return rc;

	struct ifaddrs *head = *ifap;
	struct ifaddrs *prev = NULL;
	struct ifaddrs *cur = head;

	while (cur != NULL) {
		if (cur->ifa_name != NULL && [UHConfig shouldHideInterfaceName:cur->ifa_name]) {
			if (prev == NULL) {
				head = cur->ifa_next;
			} else {
				prev->ifa_next = cur->ifa_next;
			}
			cur = cur->ifa_next;
			continue;
		}
		prev = cur;
		cur = cur->ifa_next;
	}
	*ifap = head;
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
	// Intentionally do not hook getifaddrs or MGCopyAnswer:
	// 1. Darwin getifaddrs uses a single contiguous malloc buffer; modifying the list head causes freeifaddrs to crash with SIGABRT (malloc error).
	// 2. MGCopyAnswer in libMobileGestalt is heavily called by UIKit/CoreTelephony on startup; returning NULL for hardware keys causes immediate unhandled exceptions.
	UHLogInfoF(@"network/IOKit layer initialized (safe mode)");
}
