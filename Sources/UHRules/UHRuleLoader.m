#import "UHRuleLoader.h"
#import "UHCommon.h"
#import "UHCore/UHLog.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHHookStats.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

// The watchdog polls every 5 seconds. We deliberately don't use kqueue
// here because not every tweak host process has the necessary entitlements
// for EVFILT_VNODE — polling via stat() works everywhere.

@interface UHRuleLoader () {
	dispatch_source_t _timer;
	NSDictionary *_cachedVectors;
	NSTimeInterval _lastMtime;
	NSString *_resolvedPath;
}
@end

@implementation UHRuleLoader

+ (instancetype)sharedInstance {
	static UHRuleLoader *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [UHRuleLoader new]; });
	return s;
}

- (instancetype)init {
	if ((self = [super init])) {
		_vectors = @{};
		_filePath = @"/var/jb/Library/UltraHidePro/vectors.json";
		_resolvedPath = _filePath;
		_lastMtime = 0;
	}
	return self;
}

- (NSString *)resolveExistingPath {
	NSArray<NSString *> *candidates = @[
		@"/var/jb/Library/UltraHidePro/vectors.json",
		@"/Library/UltraHidePro/vectors.json",
	];
	for (NSString *p in candidates) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
			return p;
		}
	}
	return candidates.firstObject;
}

- (void)reloadFromDisk {
	NSString *path = [self resolveExistingPath];
	_resolvedPath = path;
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (data == nil) {
		UHLogWarnF(@"vectors.json missing or unreadable at %@", path);
		return;
	}
	NSError *err = nil;
	NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
	if (json == nil || ![json isKindOfClass:[NSDictionary class]]) {
		UHLogWarnF(@"vectors.json missing or malformed at %@: %@", path, err.localizedDescription);
		return;
	}
	id vecs = json[@"vectors"];
	if (![vecs isKindOfClass:[NSArray class]]) {
		UHLogWarnF(@"vectors.json 'vectors' must be an array; got %@",
			NSStringFromClass([vecs class]));
		return;
	}
	NSMutableArray<NSDictionary *> *validated =
		[NSMutableArray arrayWithCapacity:[(NSArray *)vecs count]];
	for (id v in (NSArray *)vecs) {
		if (![v isKindOfClass:[NSDictionary class]]) continue;
		NSDictionary *entry = (NSDictionary *)v;
		id idVal = entry[@"id"];
		if (![idVal isKindOfClass:[NSString class]]) continue;
		id risk = entry[@"risk"];
		if (![risk isKindOfClass:[NSString class]]) {
			NSMutableDictionary *m = [entry mutableCopy];
			m[@"risk"] = @"unknown";
			[validated addObject:[m copy]];
			continue;
		}
		[validated addObject:entry];
	}
	_cachedVectors = [validated copy];
	_vectors = _cachedVectors;
	UHLogInfoF(@"Loaded %lu dynamic rules from %@",
		(unsigned long)_cachedVectors.count, path);
}

- (void)activate {
	[self reloadFromDisk];

	__weak typeof(self) weakSelf = self;
	_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
		dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	dispatch_source_set_timer(_timer,
		dispatch_time(DISPATCH_TIME_NOW, 0),
		(uint64_t)(5.0 * NSEC_PER_SEC),
		(uint64_t)(1.0 * NSEC_PER_SEC));
	dispatch_source_set_event_handler(_timer, ^{
		__strong typeof(weakSelf) self_ = weakSelf;
		if (self_ == nil) return;
		NSString *p = [self_ resolveExistingPath];
		struct stat st;
		if (stat([p UTF8String], &st) == 0) {
			NSTimeInterval m = (NSTimeInterval)st.st_mtime;
			if (m != _lastMtime) {
				_lastMtime = m;
				[self_ reloadFromDisk];
			}
		}
	});
	dispatch_resume(_timer);
	UHLogInfoF(@"Rule watchdog active");
}

- (NSString *)riskForVector:(NSString *)vectorID {
	for (NSDictionary *v in _cachedVectors) {
		if ([v[@"id"] isEqualToString:vectorID]) {
			return v[@"risk"];
		}
	}
	return nil;
}

- (NSUInteger)vectorCount {
	return _cachedVectors.count;
}

@end
