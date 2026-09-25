#ifndef UH_RULE_LOADER_H
#define UH_RULE_LOADER_H

#import "UHCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Parses `Resources/vectors.json` and applies / refreshes hook decisions
/// at runtime. The watchdog (UHWatchdog) calls -[reloadFromDisk] whenever
/// the file changes.
UH_EXPORT
@interface UHRuleLoader : NSObject

@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *vectors;
@property (nonatomic, copy, readonly) NSString *filePath;

+ (instancetype)sharedInstance;

/// Activate the loader (idempotent — parses vectors.json + starts watchdog).
- (void)activate;

/// Re-read the JSON file and rebuild the in-memory vector table.
- (void)reloadFromDisk;

/// Look up the risk level for a given vector id.
- (nullable NSString *)riskForVector:(NSString *)vectorID;

/// Total number of vectors currently registered.
- (NSUInteger)vectorCount;

@end

NS_ASSUME_NONNULL_END

#endif // UH_RULE_LOADER_H
