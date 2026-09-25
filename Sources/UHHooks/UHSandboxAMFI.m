#import "UHSandboxAMFI.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <sandbox.h>
#import <xpc/xpc.h>
#import <stdint.h>

#pragma mark - sandbox_check

// sandbox_check signature differs between iOS versions. We resolve it via
// dlsym because the public header on the SDK we link against is incomplete.
typedef int (*sandbox_check_t)(pid_t, const char *, int);
static sandbox_check_t _orig_sandbox_check = NULL;

static int $sandbox_check(pid_t pid, const char *operation, int filter_type) {
	// If the operation is one of the few sandbox verbs that gate access to
	// jailbreak-related paths, return 0 (allowed).
	if (operation != NULL) {
		NSString *op = [NSString stringWithUTF8String:operation];
		NSString *l = [op lowercaseString];
		if ([l containsString:@"file-write"] ||
		    [l containsString:@"file-read"] ||
		    [l containsString:@"process-exec"]) {
			return 0;
		}
	}
	if (_orig_sandbox_check != NULL) {
		return _orig_sandbox_check(pid, operation, filter_type);
	}
	return 0;
}

#pragma mark - SecCode*

typedef struct __SecTask *SecTaskRef;
typedef const struct __SecCode *SecStaticCodeRef;
typedef const struct __SecRequirement *SecRequirementRef;
typedef uint32_t SecCSFlags;

typedef OSStatus (*SecCodeCopySigningInformation_t)(SecStaticCodeRef, SecCSFlags, CFDictionaryRef *);
static SecCodeCopySigningInformation_t _orig_SecCodeCopySigningInformation = NULL;

static OSStatus $SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags,
	CFDictionaryRef *info) {
	OSStatus s = _orig_SecCodeCopySigningInformation(code, flags, info);
	if (s == errSecSuccess && info != NULL && *info != NULL) {
		// Strip CS_ADHOC, force CS_VALID.
		CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(
			kCFAllocatorDefault, 0, *info);
		// kSecCodeInfoFlags -> set to a clean value.
		CFDictionarySetValue(m, CFSTR("flags"),
			(__bridge CFNumberRef)(@(1)));
		CFRelease(*info);
		*info = m;
	}
	return s;
}

typedef OSStatus (*SecCodeCheckValidity_t)(SecStaticCodeRef, SecCSFlags, SecRequirementRef);
static SecCodeCheckValidity_t _orig_SecCodeCheckValidity = NULL;

static OSStatus $SecCodeCheckValidity(SecStaticCodeRef code, SecCSFlags flags,
	SecRequirementRef requirement) {
	// Always report success for any app check.
	return errSecSuccess;
}

#pragma mark - SecTaskCopyValueForEntitlement

typedef CFTypeRef (*SecTaskCopyValueForEntitlement_t)(SecTaskRef, CFStringRef, CFErrorRef *);
static SecTaskCopyValueForEntitlement_t _orig_SecTaskCopyValueForEntitlement = NULL;

static CFTypeRef $SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement,
	CFErrorRef *error) {
	if (entitlement != NULL) {
		NSString *e = (__bridge NSString *)entitlement;
		if ([e isEqualToString:@"com.apple.security.cs.allow-jit"] ||
		    [e isEqualToString:@"get-task-allow"] ||
		    [e isEqualToString:@"com.apple.private.security.no-sandbox"]) {
			return NULL;
		}
	}
	if (_orig_SecTaskCopyValueForEntitlement != NULL) {
		return _orig_SecTaskCopyValueForEntitlement(task, entitlement, error);
	}
	return NULL;
}

#pragma mark - MISValidateSignature

typedef int (*MISValidateSignature_t)(CFStringRef, CFDictionaryRef);
static MISValidateSignature_t _orig_MISValidateSignature = NULL;
static int $MISValidateSignature(CFStringRef path, CFDictionaryRef opts) {
	return 0; // always "valid"
}

typedef int (*MISValidateSignatureAndCopyInfo_t)(CFStringRef, CFDictionaryRef, CFDictionaryRef *);
static MISValidateSignatureAndCopyInfo_t _orig_MISValidateSignatureAndCopyInfo = NULL;
static int $MISValidateSignatureAndCopyInfo(CFStringRef path, CFDictionaryRef opts,
	CFDictionaryRef *outInfo) {
	if (outInfo != NULL) *outInfo = NULL;
	return 0;
}

#pragma mark - xpc_connection_create

typedef xpc_connection_t (*xpc_connection_create_t)(const char *, dispatch_queue_t);
static xpc_connection_create_t _orig_xpc_connection_create = NULL;

static xpc_connection_t $xpc_connection_create(const char *name, dispatch_queue_t targetq) {
	if (name != NULL) {
		NSString *n = [NSString stringWithUTF8String:name];
		if ([n hasPrefix:@"com.apple.dt.xcode"] ||
		    [n hasPrefix:@"com.opa334.dopamine"] ||
		    [n hasPrefix:@"com.saurik"]) {
			// Hand back a never-connecting dummy connection so the
			// caller doesn't dereference NULL when it later tries to
			// send a message. We need a real heap-allocated object.
			static xpc_connection_t sDummy = NULL;
			static dispatch_once_t once;
			dispatch_once(&once, ^{
				sDummy = xpc_connection_create(NULL, NULL);
			});
			return sDummy;
		}
	}
	return _orig_xpc_connection_create(name, targetq);
}

#pragma mark - Installer

void UHInstallSandboxAMFIHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	void *sbl = dlsym(RTLD_DEFAULT, "sandbox_check");
	if (sbl != NULL) {
		MSHookFunction(sbl, (void *)$sandbox_check, (void **)&_orig_sandbox_check);
		[stats bumpBy:1];
	}

	void *sec_csi = dlsym(RTLD_DEFAULT, "SecCodeCopySigningInformation");
	if (sec_csi != NULL) {
		MSHookFunction(sec_csi,
			(void *)$SecCodeCopySigningInformation,
			(void **)&_orig_SecCodeCopySigningInformation);
		[stats bumpBy:1];
	}

	void *sec_ccv = dlsym(RTLD_DEFAULT, "SecCodeCheckValidity");
	if (sec_ccv != NULL) {
		MSHookFunction(sec_ccv,
			(void *)$SecCodeCheckValidity,
			(void **)&_orig_SecCodeCheckValidity);
		[stats bumpBy:1];
	}

	void *sec_tve = dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
	if (sec_tve != NULL) {
		MSHookFunction(sec_tve,
			(void *)$SecTaskCopyValueForEntitlement,
			(void **)&_orig_SecTaskCopyValueForEntitlement);
		[stats bumpBy:1];
	}

	void *mis1 = dlsym(RTLD_DEFAULT, "MISValidateSignature");
	if (mis1 != NULL) {
		MSHookFunction(mis1, (void *)$MISValidateSignature, (void **)&_orig_MISValidateSignature);
		[stats bumpBy:1];
	}
	void *mis2 = dlsym(RTLD_DEFAULT, "MISValidateSignatureAndCopyInfo");
	if (mis2 != NULL) {
		MSHookFunction(mis2, (void *)$MISValidateSignatureAndCopyInfo,
			(void **)&_orig_MISValidateSignatureAndCopyInfo);
		[stats bumpBy:1];
	}

	MSHookFunction((void *)xpc_connection_create,
		(void *)$xpc_connection_create,
		(void **)&_orig_xpc_connection_create);
	[stats bumpBy:1];

	UHLogInfoF(@"sandbox/AMFI hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
