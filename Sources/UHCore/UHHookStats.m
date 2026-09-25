#import "UHHookStats.h"
#import <stdint.h>

@implementation UHHookStats {
	volatile int64_t _count;
}

+ (instancetype)sharedInstance {
	static UHHookStats *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [UHHookStats new]; });
	return s;
}

- (instancetype)init {
	if ((self = [super init])) {
		_count = 0;
	}
	return self;
}

- (NSUInteger)activeCount {
	return (NSUInteger)__sync_fetch_and_add(&_count, 0);
}

- (void)bumpBy:(NSUInteger)delta {
	if (delta == 0) return;
	__sync_fetch_and_add(&_count, (int64_t)delta);
}

- (void)reset {
	__sync_lock_test_and_set(&_count, 0);
}

@end
