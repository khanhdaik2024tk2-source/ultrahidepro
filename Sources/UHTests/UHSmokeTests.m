#import "UHSmokeTests.h"
#import "UHCommon.h"
#import "UHCore/UHConfig.h"
#import "UHCore/UHLog.h"

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>

typedef struct {
	const char *name;
	bool (*run)(void);
} UHTestCase;

static bool Test_configLoaded(void) {
	return [UHConfig sharedInstance] != nil;
}

static bool Test_fileManager_blocksCydia(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL exists = [fm fileExistsAtPath:@"/Applications/Cydia.app"];
	return exists == NO;
}

static bool Test_stat_blocksVarJB(void) {
	struct stat st;
	int rc = stat("/var/jb", &st);
	return rc == -1 && errno == ENOENT;
}

static bool Test_access_blocksBinBash(void) {
	int rc = access("/bin/bash", F_OK);
	return rc == -1;
}

static bool Test_getenv_blocksDYLD(void) {
	const char *v = getenv("DYLD_INSERT_LIBRARIES");
	return v == NULL;
}

static bool Test_fopen_blocksApplications(void) {
	FILE *f = fopen("/Applications/Cydia.app/Info.plist", "r");
	return f == NULL;
}

static bool Test_dyld_image_count_sane(void) {
	extern uint32_t _dyld_image_count(void);
	uint32_t n = _dyld_image_count();
	return n > 0 && n < 1024;
}

static bool Test_dyld_image_name_hides_tweak(void) {
	extern uint32_t _dyld_image_count(void);
	extern const char *_dyld_get_image_name(uint32_t);
	uint32_t n = _dyld_image_count();
	for (uint32_t i = 0; i < n; i++) {
		const char *name = _dyld_get_image_name(i);
		if (name == NULL) continue;
		if (strstr(name, "UltraHidePro") != NULL) {
			return false;
		}
	}
	return true;
}

static bool Test_setenv_blocks(void) {
	int rc = setenv("DYLD_INSERT_LIBRARIES", "/foo", 1);
	return rc == -1;
}

static const UHTestCase kTests[] = {
	{ "config_loaded",            Test_configLoaded            },
	{ "filemanager_blocks_cydia", Test_fileManager_blocksCydia },
	{ "stat_blocks_var_jb",       Test_stat_blocksVarJB        },
	{ "access_blocks_bin_bash",   Test_access_blocksBinBash    },
	{ "getenv_blocks_dyld",       Test_getenv_blocksDYLD       },
	{ "fopen_blocks_cydia",       Test_fopen_blocksApplications},
	{ "dyld_image_count_sane",    Test_dyld_image_count_sane   },
	{ "dyld_hides_tweak_path",    Test_dyld_image_name_hides_tweak },
	{ "setenv_blocks",            Test_setenv_blocks           },
};

int UHRunSmokeTests(void) {
	NSUInteger passed = 0, failed = 0;
	for (size_t i = 0; i < sizeof(kTests)/sizeof(kTests[0]); i++) {
		bool ok = kTests[i].run();
		if (ok) {
			UHLogInfoF(@"[PASS] %s", kTests[i].name);
			passed++;
		} else {
			UHLogErrorF(@"[FAIL] %s", kTests[i].name);
			failed++;
		}
	}
	UHLogInfoF(@"Smoke tests: %lu passed, %lu failed",
		(unsigned long)passed, (unsigned long)failed);
	return (int)failed;
}
