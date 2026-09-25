ARCHS = arm64
TARGET = iphone:clang:18.6:15.0

# Rootless scheme — Dopamine 3.0.9 + iOS 18.6.2 (A8-A13, arm64).
# We intentionally only build arm64 here because Dopamine 3.0.9 has no
# working Momentarius bypass for arm64e on iOS 18.6.2 yet.
THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE = 1

# 'make analyze=1' turns on clang static analysis (scan-build). It's used
# by .github/workflows/build.yml; off by default because it's slow.
ifeq ($(analyze),1)
UltraHidePro_CFLAGS = -fobjc-arc \
                      -fno-modules \
                      -std=gnu11 \
                      -I$(THEOS_PROJECT_DIR)/Sources \
                      -Wno-deprecated-declarations \
                      -Wno-unused-parameter \
                      -Werror=implicit-function-declaration \
                      -Werror=return-type \
                      -Wall
else
UltraHidePro_CFLAGS = -fobjc-arc \
                      -fno-modules \
                      -std=gnu11 \
                      -I$(THEOS_PROJECT_DIR)/Sources \
                      -Wno-deprecated-declarations \
                      -Wno-unused-parameter
endif

# Linker: leave kcall/kexec/kreadbuf/kwritebuf unresolved at link time; the
# symbols are resolved by libjailbreak.dylib at runtime (which is loaded
# before our constructor runs thanks to DYLD_INSERT_LIBRARIES ordering).
UltraHidePro_LDFLAGS = -Wl,-U,_kcall \
                       -Wl,-U,_kexec \
                       -Wl,-U,_kreadbuf \
                       -Wl,-U,_kwritebuf \
                       -Wl,-U,_kread64 \
                       -Wl,-U,_kwrite64 \
                       -Wl,-U,_kread_ptr \
                       -Wl,-U,_kwrite_ptr \
                       -Wl,-U,_kalloc \
                       -Wl,-U,_kfree \
                       -lsubstrate

UltraHidePro_FRAMEWORKS = Foundation CoreFoundation Security IOKit

# We install into /var/jb because Dopamine is rootless.
THEOS_PACKAGE_INSTALL_PREFIX = /var/jb

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UltraHidePro
UltraHidePro_FILES = Tweak.x \
                     $(wildcard Sources/UHCore/*.m) \
                     $(wildcard Sources/UHHooks/*.m) \
                     $(wildcard Sources/UHKernel/*.m) \
                     $(wildcard Sources/UHRules/*.m) \
                     $(wildcard Sources/UHTests/*.m)

include $(THEOS)/makefiles/tweak.mk

internal-package::
	mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	cp control $(THEOS_STAGING_DIR)/DEBIAN/control
	mkdir -p $(THEOS_STAGING_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries
	cp entry.plist $(THEOS_STAGING_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/UltraHidePro.plist 2>/dev/null || true
	mkdir -p $(THEOS_STAGING_DIR)/var/jb/Library/UltraHidePro
	cp Resources/config.plist $(THEOS_STAGING_DIR)/var/jb/Library/UltraHidePro/config.plist || true
	cp Resources/vectors.json $(THEOS_STAGING_DIR)/var/jb/Library/UltraHidePro/vectors.json || true
