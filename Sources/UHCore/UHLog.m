#import "UHLog.h"
#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <stdlib.h>

// One os_log handle per process is sufficient — os_log caches internally
// and we don't pay any per-call allocation.
static os_log_t UHLogHandle(void) {
	static os_log_t handle;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		handle = os_log_create("com.ultrahidepro.tweak", "core");
	});
	return handle;
}

@implementation UHLog {
	UHLogLevel _level;
}

+ (instancetype)sharedInstance {
	static UHLog *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		s = [UHLog new];
		const char *env = getenv("UHLOG_LEVEL");
		if (env != NULL) {
			int lvl = atoi(env);
			if (lvl >= 0 && lvl <= 3) {
				s->_level = (UHLogLevel)lvl;
			} else {
				s->_level = UHLogLevelInfo;
			}
		} else {
			s->_level = UHLogLevelInfo;
		}
	});
	return s;
}

+ (void)setLevel:(UHLogLevel)level {
	[UHLog sharedInstance]->_level = level;
}

+ (UHLogLevel)level {
	return [UHLog sharedInstance]->_level;
}

+ (BOOL)isEnabled:(UHLogLevel)level {
	return level >= [self level];
}

+ (void)emit:(UHLogLevel)level format:(NSString *)fmt args:(va_list)args {
	if (![self isEnabled:level]) return;

	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
	if (msg == nil) msg = @"<nil>";

	NSString *prefix;
	switch (level) {
		case UHLogLevelDebug: prefix = @"[UHDBG] "; break;
		case UHLogLevelInfo:  prefix = @"[UHINF] "; break;
		case UHLogLevelWarn:  prefix = @"[UHWRN] "; break;
		case UHLogLevelError: prefix = @"[UHERR] "; break;
		default:              prefix = @"[UH???] "; break;
	}

	NSString *line = [prefix stringByAppendingString:msg];
	const char *cstr = [line UTF8String];
	if (cstr == NULL) return;

	os_log_type_t type;
	if (level >= UHLogLevelError)      type = OS_LOG_TYPE_ERROR;
	else if (level >= UHLogLevelWarn)  type = OS_LOG_TYPE_DEFAULT;
	else if (level >= UHLogLevelInfo)  type = OS_LOG_TYPE_INFO;
	else                               type = OS_LOG_TYPE_DEBUG;

	os_log_with_type(UHLogHandle(), type, "%{public}s", cstr);
}

+ (void)debug:(NSString *)fmt, ... {
	va_list args;
	va_start(args, fmt);
	[self emit:UHLogLevelDebug format:fmt args:args];
	va_end(args);
}

+ (void)info:(NSString *)fmt, ... {
	va_list args;
	va_start(args, fmt);
	[self emit:UHLogLevelInfo format:fmt args:args];
	va_end(args);
}

+ (void)warn:(NSString *)fmt, ... {
	va_list args;
	va_start(args, fmt);
	[self emit:UHLogLevelWarn format:fmt args:args];
	va_end(args);
}

+ (void)error:(NSString *)fmt, ... {
	va_list args;
	va_start(args, fmt);
	[self emit:UHLogLevelError format:fmt args:args];
	va_end(args);
}

@end
