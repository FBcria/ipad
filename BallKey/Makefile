TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
include $(THEOS)/makefiles/common.mk

TWEAK_NAME := BallKey
BallKey_FILES := Tweak.x
BallKey_CFLAGS := -fobjc-arc -Wno-deprecated-declarations
BallKey_FRAMEWORKS := UIKit Foundation GameController
include $(THEOS_MAKE_PATH)/tweak.mk
