TARGET = iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BallKeyOverlay
BallKeyOverlay_FILES = Tweak.x
BallKeyOverlay_CFLAGS = -fobjc-arc
BallKeyOverlay_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
