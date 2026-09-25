#ifndef UH_HOOK_STATS_H
#define UH_HOOK_STATS_H

#import "UHCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Tiny counter that records how many of our hooks have been installed.
/// Used both for diagnostics and to expose `ULTRAHIDE_ACTIVE_HOOKS` env var
/// so external tools (e.g. Choicy or Sileo post-install scripts) can verify
/// the tweak is actually running.
UH_EXPORT
@interface UHHookStats : NSObject

@property (atomic, assign, readonly) NSUInteger activeCount;

+ (instancetype)sharedInstance;

/// Increment the counter when a hook is installed successfully. Passing 0
/// is a no-op.
- (void)bumpBy:(NSUInteger)delta;

/// Reset (used by UHConfig reload + dynamic rule loader).
- (void)reset;

@end

NS_ASSUME_NONNULL_END

#endif // UH_HOOK_STATS_H
