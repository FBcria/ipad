export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BallKeyEngine

BallKeyEngine_FILES = Tweak.x
BallKeyEngine_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/common -I$(THEOS_PROJECT_DIR)/../common -I$(THEOS)/vendor/include
BallKeyEngine_FRAMEWORKS = Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
