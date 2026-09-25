ARCHS = arm64
TARGET = iphone:clang:18.6:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = UltraHidePro
UltraHidePro_FILES = main.m UHAppDelegate.m UHTargetAppsViewController.m
UltraHidePro_FRAMEWORKS = UIKit CoreGraphics Foundation
UltraHidePro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
UltraHidePro_CODESIGN_FLAGS = -Sentitlements.plist
UltraHidePro_RESOURCE_DIRS = Resources

include $(THEOS)/makefiles/application.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Applications/UltraHidePro.app
	cp -f Info.plist $(THEOS_STAGING_DIR)/Applications/UltraHidePro.app/Info.plist 2>/dev/null || true
	cp -f Resources/Info.plist $(THEOS_STAGING_DIR)/Applications/UltraHidePro.app/Info.plist 2>/dev/null || true
	mkdir -p $(THEOS_STAGING_DIR)/var/jb/Applications/UltraHidePro.app
	cp -f Info.plist $(THEOS_STAGING_DIR)/var/jb/Applications/UltraHidePro.app/Info.plist 2>/dev/null || true
	cp -f Resources/Info.plist $(THEOS_STAGING_DIR)/var/jb/Applications/UltraHidePro.app/Info.plist 2>/dev/null || true
	chmod 0644 $(THEOS_STAGING_DIR)/Applications/UltraHidePro.app/Info.plist 2>/dev/null || true
	chmod 0644 $(THEOS_STAGING_DIR)/var/jb/Applications/UltraHidePro.app/Info.plist 2>/dev/null || true
