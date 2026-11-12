export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BallKey
BallKey_FILES = Tweak.x
BallKey_CFLAGS = -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations
BallKey_FRAMEWORKS = UIKit Foundation CoreGraphics GameController

include $(THEOS_MAKE_PATH)/tweak.mk
