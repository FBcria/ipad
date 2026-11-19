TARGET := iphone:clang:16.5:14.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MobileInput
MobileInput_FILES = Tweak.m
MobileInput_CFLAGS = -fobjc-arc -Wno-error=unguarded-availability-new -Wno-error=objc-method-access -Wno-error=int-conversion
MobileInput_FRAMEWORKS = UIKit GameController IOKit CoreFoundation
MobileInput_LDFLAGS = -Wl,-install_name,@executable_path/Frameworks/libMobileInput.dylib -Wl,-weak_library,/usr/lib/libsubstrate.dylib
include $(THEOS)/makefiles/tweak.mk
