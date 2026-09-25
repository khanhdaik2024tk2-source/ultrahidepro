#import "UHHookStats.h"
#import <stdatomic.h>

@implementation UHHookStats {
	atomic_size_t _count;
}

+ (instancetype)sharedInstance {
	static UHHookStats *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [UHHookStats new]; });
	return s;
}

- (instancetype)init {
	if ((self = [super init])) {
		atomic_init(&_count, 0);
	}
	return self;
}

- (NSUInteger)activeCount {
	return atomic_load_explicit(&_count, memory_order_relaxed);
}

- (void)bumpBy:(NSUInteger)delta {
	if (delta == 0) return;
	atomic_fetch_add_explicit(&_count, delta, memory_order_relaxed);
}

- (void)reset {
	atomic_store_explicit(&_count, 0, memory_order_relaxed);
}

@end
