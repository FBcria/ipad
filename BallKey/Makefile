TARGET := iphone:clang:16.5:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MobileInput
MobileInput_FILES = Tweak.m
MobileInput_CFLAGS = -fobjc-arc -Wno-error=unguarded-availability-new -Wno-error=objc-method-access -Wno-error=int-conversion
MobileInput_FRAMEWORKS = UIKit GameController IOKit CoreFoundation
include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
