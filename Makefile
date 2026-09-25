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
                      -Wno-unused-variable \
                      -Wno-unused-function \
                      -Werror=implicit-function-declaration \
                      -Werror=return-type \
                      -Wall
else
UltraHidePro_CFLAGS = -fobjc-arc \
                      -fno-modules \
                      -std=gnu11 \
                      -I$(THEOS_PROJECT_DIR)/Sources \
                      -Wno-deprecated-declarations \
                      -Wno-unused-parameter \
                      -Wno-unused-variable \
                      -Wno-unused-function
endif

UltraHidePro_LDFLAGS = -lsubstrate

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

SUBPROJECTS += app
include $(THEOS)/makefiles/aggregate.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/UltraHidePro
	cp -f Resources/config.plist $(THEOS_STAGING_DIR)/Library/UltraHidePro/config.plist 2>/dev/null || true
	cp -f Resources/vectors.json $(THEOS_STAGING_DIR)/Library/UltraHidePro/vectors.json 2>/dev/null || true
	mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	cp -f layout/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postinst 2>/dev/null || true
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst 2>/dev/null || true
	cp -f layout/DEBIAN/prerm $(THEOS_STAGING_DIR)/DEBIAN/prerm 2>/dev/null || true
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/prerm 2>/dev/null || true
