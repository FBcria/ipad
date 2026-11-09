TARGET = iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BallKeyEngine
BallKeyEngine_FILES = Tweak.x
BallKeyEngine_CFLAGS = -fobjc-arc
BallKeyEngine_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
