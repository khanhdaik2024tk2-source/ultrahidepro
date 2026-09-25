#ifndef UH_SMOKE_TESTS_H
#define UH_SMOKE_TESTS_H

#import "UHCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Runs a series of in-process sanity checks against the host. Each check
/// asserts a property of the bypass layer (e.g. "fileExistsAtPath: on a
/// blacklisted path returns NO"). When called inside a XCTest bundle the
/// checks raise on failure; otherwise they log pass/fail counts and
/// return.
UH_PRIVATE int UHRunSmokeTests(void);

#ifdef __cplusplus
}
#endif

#endif // UH_SMOKE_TESTS_H
