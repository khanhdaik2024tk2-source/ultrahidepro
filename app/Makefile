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
	find $(THEOS_STAGING_DIR) -name "UltraHidePro.app" -type d -exec cp -f Info.plist {}/Info.plist \; 2>/dev/null || true
	find $(THEOS_STAGING_DIR) -name "Info.plist" -type f -exec chmod 0644 {} \; 2>/dev/null || true
