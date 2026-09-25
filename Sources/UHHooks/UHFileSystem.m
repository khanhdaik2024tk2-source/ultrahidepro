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

#pragma mark - Common helpers

// Mirror of UHConfig::shouldBlockPath for the C-level hooks (which can't
// easily call back into Objective-C). The blacklist is already loaded into
// the UHConfig singleton so we just forward.
static inline bool UHPathBlocked(const char *path) {
	if (path == NULL) return false;
	NSString *s = [NSString stringWithUTF8String:path];
	return [UHConfig shouldBlockPath:s];
}

#pragma mark - NSFileManager hooks (Objective-C)

// Original IMPs.
static BOOL (*_orig_NSFileManager_fileExistsAtPath_)(id, SEL, NSString *) = NULL;
static BOOL (*_orig_NSFileManager_fileExistsAtPath_isDirectory_)(id, SEL, NSString *, BOOL *) = NULL;
static NSDictionary *(*_orig_NSFileManager_attributesOfItemAtPath_error_)(id, SEL, NSString *, NSError **) = NULL;

static BOOL $NSFileManager_fileExistsAtPath_(id self, SEL _cmd, NSString *path) {
	if (UH_UNLIKELY([UHConfig shouldBlockPath:path])) {
		UHLogDebugF(@"NSFileManager.fileExistsAtPath: blocked %@", path);
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

#pragma mark - libc hooks (fishhook-style via MSHookFunction)

// fopen
typedef FILE *(*fopen_t)(const char *, const char *);
static fopen_t _orig_fopen = NULL;
static FILE *$fopen(const char *path, const char *mode) {
	if (UH_UNLIKELY(UHPathBlocked(path))) {
		errno = ENOENT;
		return NULL;
	}
	return _orig_fopen(path, mode);
}

// open
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

// stat / lstat
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

// access
typedef int (*access_t)(const char *, int);
static access_t _orig_access = NULL;
static int $access(const char *path, int mode) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return -1; }
	return _orig_access(path, mode);
}

// opendir
typedef DIR *(*opendir_t)(const char *);
static opendir_t _orig_opendir = NULL;
static DIR *$opendir(const char *path) {
	if (UH_UNLIKELY(UHPathBlocked(path))) { errno = ENOENT; return NULL; }
	return _orig_opendir(path);
}

// readdir — filter blacklisted entries from inside allowed directories.
// We MUST avoid recursion: a recursive call site is not safe because:
//
//   1. On iOS 18 the fused file system can hand back the same dirent in
//      certain edge cases (e.g. some jailbreak symlinks), causing us to
//      loop forever and blow the stack.
//   2. fcntl(F_GETPATH) on a DIR* is documented as an "unsupported" BSD
//      extension; iOS 18.6.2 returns ENOTSUP for some FDs opened by
//      libsystem's getdirentries so we cannot rely on it.
//
// We therefore:
//   * Cache the parent path the first time we see it for a given DIR*.
//     That cache is keyed on the DIR* pointer itself; entries are
//     released lazily and the table is small.
//   * Iterate with a hard upper bound (UH_READDIR_MAX_ITER) so a runaway
//     filesystem can't take the process down.
typedef struct dirent *(*readdir_t)(DIR *);
static readdir_t _orig_readdir = NULL;

// Hash-table of recently-seen DIR* → parent-path. Tiny (16 buckets) is
// more than enough because UHHook callers re-open, not re-seek.
typedef struct {
	DIR *key;
	const char *parent; // heap-allocated, never freed (process lifetime)
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
		// fcntl(F_GETPATH) is the only API that returns the real VFS
		// path for an FD on Darwin. On iOS 18 some FDs return -1 with
		// ENOTSUP — fall back to the original (less precise) "no parent"
		// semantics instead of skipping every entry.
		if (fcntl(fd, F_GETPATH, path) != 0) return NULL;
	}
	if (e->parent != NULL) {
		// Stale entry — overwrite.
	}
	e->key = dirp;
	e->parent = strdup(path); // process-lifetime leak; bounded by 16.
	return e->parent;
}

static bool UHReadDirIsParentBlacklisted(const char *parent) {
	if (parent == NULL || parent[0] == '\0') return false;
	// Hard list of paths inside which we'll filter entries.
	// Compared case-sensitive because /Applications is canonical.
	if (strcmp(parent, "/Applications") == 0) return true;
	if (strcmp(parent, "/var/jb/Applications") == 0) return true;
	if (strcmp(parent, "/var/jb/usr/lib") == 0) return true;
	if (strcmp(parent, "/var/jb/Library") == 0) return true;
	if (strcmp(parent, "/Library") == 0) return true;
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
		// Reject dotted entries early so . and .. always pass.
		if (e->d_name[0] == '.') {
			if (e->d_name[1] == '\0' ||
			    (e->d_name[1] == '.' && e->d_name[2] == '\0')) {
				return e;
			}
		}
		NSString *full = [NSString stringWithFormat:@"%s/%s", parent, e->d_name];
		if (![UHConfig shouldBlockPath:full]) {
			return e;
		}
		// Otherwise loop and ask for the next entry.
	}
	UHLogWarnF(@"readdir: iteration cap reached under %s; bailing out", parent);
	return NULL;
}

// NSBundle +bundleWithPath:/-bundleWithURL: are commonly used to detect
// jailbreak helper bundles by probing whether the app can "see" them.
// We hook the API here because the implementation lives alongside the
// other NSFileManager/NSBundle detection vectors.
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

	// Objective-C hooks (3)
	Class fm = NSClassFromString(@"NSFileManager");
	if (fm != NULL) {
		MSHookMessageEx(fm,
			@selector(fileExistsAtPath:),
			(IMP)$NSFileManager_fileExistsAtPath_,
			(IMP *)&_orig_NSFileManager_fileExistsAtPath_);
		MSHookMessageEx(fm,
			@selector(fileExistsAtPath:isDirectory:),
			(IMP)$NSFileManager_fileExistsAtPath_isDirectory_,
			(IMP *)&_orig_NSFileManager_fileExistsAtPath_isDirectory_);
		MSHookMessageEx(fm,
			@selector(attributesOfItemAtPath:error:),
			(IMP)$NSFileManager_attributesOfItemAtPath_error_,
			(IMP *)&_orig_NSFileManager_attributesOfItemAtPath_error_);
		[stats bumpBy:3];
	}

	// libc hooks via ElleKit / substrate.
	MSHookFunction((void *)fopen,   (void *)$fopen,   (void **)&_orig_fopen);
	MSHookFunction((void *)open,    (void *)$open,    (void **)&_orig_open);
	MSHookFunction((void *)stat,    (void *)$stat,    (void **)&_orig_stat);
	MSHookFunction((void *)lstat,   (void *)$lstat,   (void **)&_orig_lstat);
	MSHookFunction((void *)access,  (void *)$access,  (void **)&_orig_access);
	MSHookFunction((void *)opendir, (void *)$opendir, (void **)&_orig_opendir);
	MSHookFunction((void *)readdir, (void *)$readdir, (void **)&_orig_readdir);
	[stats bumpBy:7];

	// NSBundle detection-vector hooks.
	Class bundleCls = NSClassFromString(@"NSBundle");
	if (bundleCls != NULL) {
		MSHookMessageEx(bundleCls, @selector(bundleWithPath:),
			(IMP)$NSBundle_bundleWithPath_,
			(IMP *)&_orig_NSBundle_bundleWithPath_);
		MSHookMessageEx(bundleCls, @selector(bundleWithURL:),
			(IMP)$NSBundle_bundleWithURL_,
			(IMP *)&_orig_NSBundle_bundleWithURL_);
		[stats bumpBy:2];
	}

	UHLogInfoF(@"File system hooks installed (%lu total)",
		(unsigned long)(stats.activeCount - before));
}
