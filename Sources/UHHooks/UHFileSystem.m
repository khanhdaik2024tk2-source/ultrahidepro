#import "UHFileSystem.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>
#import <stdio.h>
#import <dirent.h>
#import <errno.h>
#import <string.h>
#import <limits.h>
#import <dlfcn.h>

#pragma mark - Common helpers

static inline bool UHPathBlocked(const char *path) {
	if (path == NULL) return false;
	NSString *s = [NSString stringWithUTF8String:path];
	if (s == nil) return false;
	return [UHConfig shouldBlockPath:s];
}

#pragma mark - NSFileManager hooks (Objective-C)

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
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) {
		return NO;
	}
	return _orig_NSFileManager_fileExistsAtPath_(self, _cmd, path);
}

static BOOL $NSFileManager_fileExistsAtPath_isDirectory_(id self, SEL _cmd,
	NSString *path, BOOL *isDir) {
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) {
		if (isDir != NULL) *isDir = NO;
		return NO;
	}
	return _orig_NSFileManager_fileExistsAtPath_isDirectory_(self, _cmd, path, isDir);
}

static NSDictionary *$NSFileManager_attributesOfItemAtPath_error_(id self, SEL _cmd,
	NSString *path, NSError **error) {
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) {
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
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
		return nil;
	}
	NSArray *items = _orig_NSFileManager_contentsOfDirectoryAtPath_error_(self, _cmd, path, error);
	if (!items || ![UHConfig activeForCurrentApp]) return items;
	NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
	for (NSString *item in items) {
		NSString *full = [path stringByAppendingPathComponent:item];
		if ([path isEqualToString:@"/var"] && [item isEqualToString:@"jb"]) continue;
		if ([path isEqualToString:@"/private/var"] && [item isEqualToString:@"jb"]) continue;
		if ([UHConfig shouldBlockPath:full]) continue;
		[filtered addObject:item];
	}
	return [filtered copy];
}

static NSArray *$NSFileManager_contentsOfDirectoryAtURL_includingPropertiesForKeys_options_error_(id self, SEL _cmd,
	NSURL *url, NSArray *keys, NSUInteger mask, NSError **error) {
	if (UH_UNLIKELY(url != nil && [UHConfig shouldBlockPath:url.path])) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
		return nil;
	}
	NSArray *items = _orig_NSFileManager_contentsOfDirectoryAtURL_includingPropertiesForKeys_options_error_(self, _cmd, url, keys, mask, error);
	if (!items || ![UHConfig activeForCurrentApp]) return items;
	NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
	for (NSURL *u in items) {
		if (u.path != nil && [UHConfig shouldBlockPath:u.path]) continue;
		[filtered addObject:u];
	}
	return [filtered copy];
}

static NSArray *$NSFileManager_subpathsAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) return nil;
	NSArray *items = _orig_NSFileManager_subpathsAtPath_(self, _cmd, path);
	if (!items || ![UHConfig activeForCurrentApp]) return items;
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
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) {
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
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) return NO;
	return _orig_NSFileManager_isReadableFileAtPath_(self, _cmd, path);
}

static BOOL $NSFileManager_isWritableFileAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) return NO;
	// Block write probe to root or /private
	if (path != nil && ([path isEqualToString:@"/private"] || [path isEqualToString:@"/"])) return NO;
	return _orig_NSFileManager_isWritableFileAtPath_(self, _cmd, path);
}

static BOOL $NSFileManager_isExecutableFileAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) return NO;
	return _orig_NSFileManager_isExecutableFileAtPath_(self, _cmd, path);
}

static BOOL $NSFileManager_isDeletableFileAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) return NO;
	return _orig_NSFileManager_isDeletableFileAtPath_(self, _cmd, path);
}

#pragma mark - libc hooks

typedef FILE *(*fopen_t)(const char *, const char *);
static fopen_t _orig_fopen = NULL;
static FILE *$fopen(const char *path, const char *mode) {
	if (UH_UNLIKELY(UHPathBlocked(path))) {
		errno = ENOENT;
		return NULL;
	}
	return _orig_fopen(path, mode);
}

typedef int (*open_t)(const char *, int, ...);
static open_t _orig_open = NULL;
static int $open(const char *path, int flags, ...) {
	mode_t mode = 0;
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}
	if (UH_UNLIKELY(UHPathBlocked(path))) {
		errno = ENOENT;
		return -1;
	}
	if (flags & O_CREAT) return _orig_open(path, flags, mode);
	return _orig_open(path, flags);
}

typedef int (*openat_t)(int, const char *, int, ...);
static openat_t _orig_openat = NULL;
static int $openat(int fd, const char *path, int flags, ...) {
	mode_t mode = 0;
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}
	if (UH_UNLIKELY(UHPathBlocked(path))) {
		errno = ENOENT;
		return -1;
	}
	if (flags & O_CREAT) return _orig_openat(fd, path, flags, mode);
	return _orig_openat(fd, path, flags);
}

typedef int (*stat_t)(const char *, struct stat *);
static stat_t _orig_stat = NULL;
static int $stat(const char *path, struct stat *buf) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return -1; }
	return _orig_stat(path, buf);
}

typedef int (*lstat_t)(const char *, struct stat *);
static lstat_t _orig_lstat = NULL;
static int $lstat(const char *path, struct stat *buf) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return -1; }
	return _orig_lstat(path, buf);
}

typedef int (*fstatat_t)(int, const char *, struct stat *, int);
static fstatat_t _orig_fstatat = NULL;
static int $fstatat(int fd, const char *path, struct stat *buf, int flag) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return -1; }
	return _orig_fstatat(fd, path, buf, flag);
}

typedef int (*access_t)(const char *, int);
static access_t _orig_access = NULL;
static int $access(const char *path, int mode) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return -1; }
	return _orig_access(path, mode);
}

typedef int (*faccessat_t)(int, const char *, int, int);
static faccessat_t _orig_faccessat = NULL;
static int $faccessat(int fd, const char *path, int mode, int flag) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return -1; }
	return _orig_faccessat(fd, path, mode, flag);
}

typedef ssize_t (*readlink_t)(const char *, char *, size_t);
static readlink_t _orig_readlink = NULL;
static ssize_t $readlink(const char *path, char *buf, size_t bufsiz) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return -1; }
	return _orig_readlink(path, buf, bufsiz);
}

typedef ssize_t (*readlinkat_t)(int, const char *, char *, size_t);
static readlinkat_t _orig_readlinkat = NULL;
static ssize_t $readlinkat(int fd, const char *path, char *buf, size_t bufsiz) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return -1; }
	return _orig_readlinkat(fd, path, buf, bufsiz);
}

typedef char *(*realpath_t)(const char *, char *);
static realpath_t _orig_realpath = NULL;
static char *$realpath(const char *path, char *resolved_path) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return NULL; }
	char *res = _orig_realpath(path, resolved_path);
	if (res != NULL && UHPathBlocked(res)) {
		errno = ENOENT;
		return NULL;
	}
	return res;
}

typedef DIR *(*opendir_t)(const char *);
static opendir_t _orig_opendir = NULL;
static DIR *$opendir(const char *path) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return NULL; }
	return _orig_opendir(path);
}

typedef struct dirent *(*readdir_t)(DIR *);
static readdir_t _orig_readdir = NULL;

typedef struct {
	DIR *key;
	const char *parent;
} UHReadDirEntry;

#define UH_READDIR_BUCKETS 16
#define UH_READDIR_MAX_ITER 4096
static UHReadDirEntry gReadDirCache[UH_READDIR_BUCKETS];

static const char *UHReadDirRememberParent(DIR *dirp) {
	if (dirp == NULL) return NULL;
	uintptr_t idx = ((uintptr_t)dirp >> 4) % UH_READDIR_BUCKETS;
	UHReadDirEntry *e = &gReadDirCache[idx];
	if (e->key == dirp && e->parent != NULL) return e->parent;

	int fd = dirfd(dirp);
	char path[PATH_MAX] = {0};
	if (fd >= 0) {
		if (fcntl(fd, F_GETPATH, path) != 0) return NULL;
	}
	e->key = dirp;
	e->parent = strdup(path);
	return e->parent;
}

static bool UHReadDirIsParentBlacklisted(const char *parent) {
	if (parent == NULL || parent[0] == '\0') return false;
	if (strcmp(parent, "/var") == 0) return true;
	if (strcmp(parent, "/private/var") == 0) return true;
	if (strcmp(parent, "/private/preboot") == 0) return true;
	if (strcmp(parent, "/") == 0) return true;
	if (strcmp(parent, "/Applications") == 0) return true;
	if (strcmp(parent, "/var/jb/Applications") == 0) return true;
	if (strcmp(parent, "/var/jb/usr/lib") == 0) return true;
	if (strcmp(parent, "/var/jb/Library") == 0) return true;
	if (strcmp(parent, "/Library") == 0) return true;
	if (strstr(parent, "Library/Preferences") != NULL) return true;
	if (strstr(parent, "Library/Caches") != NULL) return true;
	return false;
}

static struct dirent *$readdir(DIR *dirp) {
	const char *parent = UHReadDirRememberParent(dirp);
	if (!UHReadDirIsParentBlacklisted(parent)) {
		return _orig_readdir(dirp);
	}
	for (int iter = 0; iter < UH_READDIR_MAX_ITER; iter++) {
		struct dirent *e = _orig_readdir(dirp);
		if (e == NULL) return NULL;
		if (e->d_name[0] == '.') {
			if (e->d_name[1] == '\0' ||
			    (e->d_name[1] == '.' && e->d_name[2] == '\0')) {
				return e;
			}
		}
		if (parent != NULL) {
			if ((strcmp(parent, "/var") == 0 || strcmp(parent, "/private/var") == 0) &&
			    strcmp(e->d_name, "jb") == 0) {
				continue;
			}
			if (strcmp(parent, "/private/preboot") == 0 &&
			    (strstr(e->d_name, "dopamine") != NULL || strstr(e->d_name, "jb") != NULL)) {
				continue;
			}
		}
		NSString *full = [NSString stringWithFormat:@"%s/%s", parent ?: "", e->d_name];
		if (![UHConfig shouldBlockPath:full]) {
			return e;
		}
	}
	return NULL;
}

static id (*_orig_NSBundle_bundleWithPath_)(id, SEL, NSString *) = NULL;
static id (*_orig_NSBundle_bundleWithURL_)(id, SEL, NSURL *) = NULL;

static id $NSBundle_bundleWithPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path ?: @""])) {
		return nil;
	}
	return _orig_NSBundle_bundleWithPath_(self, _cmd, path);
}

static id $NSBundle_bundleWithURL_(id self, SEL _cmd, NSURL *url) {
	if (UH_UNLIKELY(url != nil && [UHConfig shouldBlockPath:url.path ?: @""])) {
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

	MSHookFunction((void *)fopen,      (void *)$fopen,      (void **)&_orig_fopen);
	MSHookFunction((void *)open,       (void *)$open,       (void **)&_orig_open);
	MSHookFunction((void *)openat,     (void *)$openat,     (void **)&_orig_openat);
	MSHookFunction((void *)stat,       (void *)$stat,       (void **)&_orig_stat);
	MSHookFunction((void *)lstat,      (void *)$lstat,      (void **)&_orig_lstat);
	MSHookFunction((void *)fstatat,    (void *)$fstatat,    (void **)&_orig_fstatat);
	MSHookFunction((void *)access,     (void *)$access,     (void **)&_orig_access);
	MSHookFunction((void *)faccessat,  (void *)$faccessat,  (void **)&_orig_faccessat);
	MSHookFunction((void *)readlink,   (void *)$readlink,   (void **)&_orig_readlink);
	MSHookFunction((void *)readlinkat, (void *)$readlinkat, (void **)&_orig_readlinkat);
	MSHookFunction((void *)realpath,   (void *)$realpath,   (void **)&_orig_realpath);
	MSHookFunction((void *)opendir,    (void *)$opendir,    (void **)&_orig_opendir);
	MSHookFunction((void *)readdir,    (void *)$readdir,    (void **)&_orig_readdir);
	[stats bumpBy:13];

	// INODE64 / 64-bit stat variants
	void *fn_stat64 = dlsym(RTLD_DEFAULT, "stat64");
	if (fn_stat64 != NULL && fn_stat64 != (void *)stat) {
		stat_t _orig_s64 = NULL;
		MSHookFunction(fn_stat64, (void *)$stat, (void **)&_orig_s64);
		[stats bumpBy:1];
	}
	void *fn_lstat64 = dlsym(RTLD_DEFAULT, "lstat64");
	if (fn_lstat64 != NULL && fn_lstat64 != (void *)lstat) {
		lstat_t _orig_ls64 = NULL;
		MSHookFunction(fn_lstat64, (void *)$lstat, (void **)&_orig_ls64);
		[stats bumpBy:1];
	}

	Class bundleCls = NSClassFromString(@"NSBundle");
	if (bundleCls != NULL) {
		MSHookMessageEx(bundleCls, @selector(bundleWithPath:),
			(IMP)$NSBundle_bundleWithPath_, (IMP *)&_orig_NSBundle_bundleWithPath_);
		MSHookMessageEx(bundleCls, @selector(bundleWithURL:),
			(IMP)$NSBundle_bundleWithURL_, (IMP *)&_orig_NSBundle_bundleWithURL_);
		[stats bumpBy:2];
	}

	UHLogInfoF(@"File system hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
