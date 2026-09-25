#ifndef UH_LOG_H
#define UH_LOG_H

#import "UHCommon.h"
#import <os/log.h>
#import <os/signpost.h>

NS_ASSUME_NONNULL_BEGIN

/// Severity levels used by UltraHide Pro. Mapped 1:1 to os_log_type_t so
/// filtering from console.app works as expected.
typedef NS_ENUM(NSInteger, UHLogLevel) {
	UHLogLevelDebug = 0,
	UHLogLevelInfo  = 1,
	UHLogLevelWarn  = 2,
	UHLogLevelError = 3,
};

/// Lightweight os_log wrapper. We avoid NSLog because:
/// 1) NSLog triggers unified-logging back-pressure on hot paths.
/// 2) NSLog cannot be filtered by subsystem.
/// 3) os_log lets users grep with `log stream --predicate ...`.
UH_EXPORT
@interface UHLog : NSObject

/// Set / get the active level. Can be overridden by the `UHLOG_LEVEL` env var.
+ (void)setLevel:(UHLogLevel)level;
+ (UHLogLevel)level;
+ (BOOL)isEnabled:(UHLogLevel)level;

+ (void)debug:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2);
+ (void)info:(NSString *)fmt, ...  NS_FORMAT_FUNCTION(1, 2);
+ (void)warn:(NSString *)fmt, ...  NS_FORMAT_FUNCTION(1, 2);
+ (void)error:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2);

@end

// Short-circuit macros — arguments are not evaluated when the level is
// filtered, so callers can pass expensive-to-format strings for free.
#define UHLogDebugF(fmt, ...) do { if ([UHLog isEnabled:UHLogLevelDebug]) [UHLog debug:fmt, ##__VA_ARGS__]; } while (0)
#define UHLogInfoF(fmt, ...)  do { if ([UHLog isEnabled:UHLogLevelInfo])  [UHLog info:fmt, ##__VA_ARGS__]; } while (0)
#define UHLogWarnF(fmt, ...)  do { if ([UHLog isEnabled:UHLogLevelWarn])  [UHLog warn:fmt, ##__VA_ARGS__]; } while (0)
#define UHLogErrorF(fmt, ...) do { if ([UHLog isEnabled:UHLogLevelError]) [UHLog error:fmt, ##__VA_ARGS__]; } while (0)

NS_ASSUME_NONNULL_END

#endif // UH_LOG_H
