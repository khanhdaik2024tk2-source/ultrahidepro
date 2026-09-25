#import "UHFileSystem.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - NSFileManager hooks (100% Safe Objective-C Swizzling)

static BOOL (*_orig_NSFileManager_fileExistsAtPath_)(id, SEL, NSString *) = NULL;
static BOOL (*_orig_NSFileManager_fileExistsAtPath_isDirectory_)(id, SEL, NSString *, BOOL *) = NULL;
static NSDictionary *(*_orig_NSFileManager_attributesOfItemAtPath_error_)(id, SEL, NSString *, NSError **) = NULL;
static BOOL (*_orig_NSFileManager_createFileAtPath_contents_attributes_)(id, SEL, NSString *, NSData *, NSDictionary *) = NULL;
static NSArray *(*_orig_NSFileManager_contentsOfDirectoryAtPath_error_)(id, SEL, NSString *, NSError **) = NULL;
static NSArray *(*_orig_NSFileManager_contentsOfDirectoryAtURL_includingPropertiesForKeys_options_error_)(id, SEL, NSURL *, NSArray *, NSUInteger, NSError **) = NULL;
static NSArray *(*_orig_NSFileManager_subpathsAtPath_)(id, SEL, NSString *) = NULL;
static NSString *(*_orig_NSFileManager_destinationOfSymbolicLinkAtPath_error_)(id, SEL, NSString *, NSError **) = NULL;
static BOOL (*_orig_NSFileManager_isReadableFileAtPath_)(id, SEL, NSString *) = NULL;
static BOOL (*_orig_NSFileManager_isWritableFileAtPath_)(id, SEL, NSString *) = NULL;
static BOOL (*_orig_NSFileManager_isExecutableFileAtPath_)(id, SEL, NSString *) = NULL;
static BOOL (*_orig_NSFileManager_isDeletableFileAtPath_)(id, SEL, NSString *) = NULL;

static BOOL $NSFileManager_fileExistsAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) {
		return NO;
	}
	return _orig_NSFileManager_fileExistsAtPath_(self, _cmd, path);
}

static BOOL $NSFileManager_fileExistsAtPath_isDirectory_(id self, SEL _cmd,
	NSString *path, BOOL *isDir) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) {
		if (isDir != NULL) *isDir = NO;
		return NO;
	}
	return _orig_NSFileManager_fileExistsAtPath_isDirectory_(self, _cmd, path, isDir);
}

static NSDictionary *$NSFileManager_attributesOfItemAtPath_error_(id self, SEL _cmd,
	NSString *path, NSError **error) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:NSCocoaErrorDomain
			                             code:NSFileReadNoSuchFileError
			                         userInfo:nil];
		}
		return nil;
	}
	return _orig_NSFileManager_attributesOfItemAtPath_error_(self, _cmd, path, error);
}

static BOOL $NSFileManager_createFileAtPath_contents_attributes_(id self, SEL _cmd,
	NSString *path, NSData *data, NSDictionary *attr) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) {
		return NO;
	}
	return _orig_NSFileManager_createFileAtPath_contents_attributes_(self, _cmd, path, data, attr);
}

static NSArray *$NSFileManager_contentsOfDirectoryAtPath_error_(id self, SEL _cmd,
	NSString *path, NSError **error) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
		return nil;
	}
	NSArray *items = _orig_NSFileManager_contentsOfDirectoryAtPath_error_(self, _cmd, path, error);
	if (!items) return items;
	NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
	for (NSString *item in items) {
		NSString *full = [path stringByAppendingPathComponent:item];
		if ([path isEqualToString:@"/var"] && [item isEqualToString:@"jb"]) continue;
		if ([path isEqualToString:@"/private/var"] && [item isEqualToString:@"jb"]) continue;
		if ([path containsString:@"/private/preboot"] &&
		    ([item containsString:@"dopamine"] || [item containsString:@"jb"])) continue;
		if ([UHConfig shouldBlockPath:full]) continue;
		[filtered addObject:item];
	}
	return [filtered copy];
}

static NSArray *$NSFileManager_contentsOfDirectoryAtURL_includingPropertiesForKeys_options_error_(id self, SEL _cmd,
	NSURL *url, NSArray *keys, NSUInteger mask, NSError **error) {
	if (UH_UNLIKELY(url != nil && url.path != nil && [UHConfig shouldBlockPath:url.path])) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
		return nil;
	}
	NSArray *items = _orig_NSFileManager_contentsOfDirectoryAtURL_includingPropertiesForKeys_options_error_(self, _cmd, url, keys, mask, error);
	if (!items) return items;
	NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
	for (NSURL *u in items) {
		if (u.path != nil && [UHConfig shouldBlockPath:u.path]) continue;
		[filtered addObject:u];
	}
	return [filtered copy];
}

static NSArray *$NSFileManager_subpathsAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) return nil;
	NSArray *items = _orig_NSFileManager_subpathsAtPath_(self, _cmd, path);
	if (!items) return items;
	NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
	for (NSString *sub in items) {
		NSString *full = [path stringByAppendingPathComponent:sub];
		if ([UHConfig shouldBlockPath:full]) continue;
		[filtered addObject:sub];
	}
	return [filtered copy];
}

static NSString *$NSFileManager_destinationOfSymbolicLinkAtPath_error_(id self, SEL _cmd,
	NSString *path, NSError **error) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
		return nil;
	}
	NSString *dest = _orig_NSFileManager_destinationOfSymbolicLinkAtPath_error_(self, _cmd, path, error);
	if (dest != nil && [UHConfig shouldBlockPath:dest]) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
		return nil;
	}
	return dest;
}

static BOOL $NSFileManager_isReadableFileAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) return NO;
	return _orig_NSFileManager_isReadableFileAtPath_(self, _cmd, path);
}

static BOOL $NSFileManager_isWritableFileAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) return NO;
	if (path != nil && ([path isEqualToString:@"/private"] || [path isEqualToString:@"/"])) return NO;
	return _orig_NSFileManager_isWritableFileAtPath_(self, _cmd, path);
}

static BOOL $NSFileManager_isExecutableFileAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) return NO;
	return _orig_NSFileManager_isExecutableFileAtPath_(self, _cmd, path);
}

static BOOL $NSFileManager_isDeletableFileAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY(path != nil && [UHConfig shouldBlockPath:path])) return NO;
	return _orig_NSFileManager_isDeletableFileAtPath_(self, _cmd, path);
}

#pragma mark - NSBundle hooks

static id (*_orig_NSBundle_bundleWithPath_)(id, SEL, NSString *) = NULL;
static id (*_orig_NSBundle_bundleWithURL_)(id, SEL, NSURL *) = NULL;

static id $NSBundle_bundleWithPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY(path != nil && UHPathBlockedFast([path UTF8String]))) {
		return nil;
	}
	return _orig_NSBundle_bundleWithPath_(self, _cmd, path);
}

static id $NSBundle_bundleWithURL_(id self, SEL _cmd, NSURL *url) {
	if (UH_UNLIKELY(url != nil && url.path != nil && UHPathBlockedFast([url.path UTF8String]))) {
		return nil;
	}
	return _orig_NSBundle_bundleWithURL_(self, _cmd, url);
}

#pragma mark - Installer

void UHInstallFileSystemHooks(void) {
	UHHookStats *stats = [UHHookStats sharedInstance];
	NSUInteger before = stats.activeCount;

	Class fm = NSClassFromString(@"NSFileManager");
	if (fm != NULL) {
		MSHookMessageEx(fm, @selector(fileExistsAtPath:),
			(IMP)$NSFileManager_fileExistsAtPath_, (IMP *)&_orig_NSFileManager_fileExistsAtPath_);
		MSHookMessageEx(fm, @selector(fileExistsAtPath:isDirectory:),
			(IMP)$NSFileManager_fileExistsAtPath_isDirectory_, (IMP *)&_orig_NSFileManager_fileExistsAtPath_isDirectory_);
		MSHookMessageEx(fm, @selector(attributesOfItemAtPath:error:),
			(IMP)$NSFileManager_attributesOfItemAtPath_error_, (IMP *)&_orig_NSFileManager_attributesOfItemAtPath_error_);
		MSHookMessageEx(fm, @selector(createFileAtPath:contents:attributes:),
			(IMP)$NSFileManager_createFileAtPath_contents_attributes_, (IMP *)&_orig_NSFileManager_createFileAtPath_contents_attributes_);
		MSHookMessageEx(fm, @selector(contentsOfDirectoryAtPath:error:),
			(IMP)$NSFileManager_contentsOfDirectoryAtPath_error_, (IMP *)&_orig_NSFileManager_contentsOfDirectoryAtPath_error_);
		MSHookMessageEx(fm, @selector(contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:),
			(IMP)$NSFileManager_contentsOfDirectoryAtURL_includingPropertiesForKeys_options_error_, (IMP *)&_orig_NSFileManager_contentsOfDirectoryAtURL_includingPropertiesForKeys_options_error_);
		MSHookMessageEx(fm, @selector(subpathsAtPath:),
			(IMP)$NSFileManager_subpathsAtPath_, (IMP *)&_orig_NSFileManager_subpathsAtPath_);
		MSHookMessageEx(fm, @selector(destinationOfSymbolicLinkAtPath:error:),
			(IMP)$NSFileManager_destinationOfSymbolicLinkAtPath_error_, (IMP *)&_orig_NSFileManager_destinationOfSymbolicLinkAtPath_error_);
		MSHookMessageEx(fm, @selector(isReadableFileAtPath:),
			(IMP)$NSFileManager_isReadableFileAtPath_, (IMP *)&_orig_NSFileManager_isReadableFileAtPath_);
		MSHookMessageEx(fm, @selector(isWritableFileAtPath:),
			(IMP)$NSFileManager_isWritableFileAtPath_, (IMP *)&_orig_NSFileManager_isWritableFileAtPath_);
		MSHookMessageEx(fm, @selector(isExecutableFileAtPath:),
			(IMP)$NSFileManager_isExecutableFileAtPath_, (IMP *)&_orig_NSFileManager_isExecutableFileAtPath_);
		MSHookMessageEx(fm, @selector(isDeletableFileAtPath:),
			(IMP)$NSFileManager_isDeletableFileAtPath_, (IMP *)&_orig_NSFileManager_isDeletableFileAtPath_);
		[stats bumpBy:12];
	}

	Class bundleCls = NSClassFromString(@"NSBundle");
	if (bundleCls != NULL) {
		MSHookMessageEx(bundleCls, @selector(bundleWithPath:),
			(IMP)$NSBundle_bundleWithPath_, (IMP *)&_orig_NSBundle_bundleWithPath_);
		MSHookMessageEx(bundleCls, @selector(bundleWithURL:),
			(IMP)$NSBundle_bundleWithURL_, (IMP *)&_orig_NSBundle_bundleWithURL_);
		[stats bumpBy:2];
	}

	UHLogInfoF(@"FileSystem layer initialized (14 pure ObjC swizzling hooks)");
}
