TARGET := iphone:clang:16.5:13.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := BallKey
BallKey_FILES := Tweak.x
BallKey_FRAMEWORKS := UIKit Foundation GameController IOKit
BallKey_CFLAGS := -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable

include $(THEOS_MAKE_PATH)/tweak.mk
