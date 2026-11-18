TARGET := iphone:clang:16.5:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := NativeInput
NativeInput_FILES := Tweak.m
NativeInput_FRAMEWORKS := UIKit Foundation GameController IOKit
NativeInput_CFLAGS := -fobjc-arc -O2 -fvisibility=hidden -Wno-deprecated-declarations -Wno-unused-function -Wno-error=unguarded-availability-new
NativeInput_LDFLAGS := -Wl,-install_name,@rpath/libNativeInput.dylib -Wl,-dead_strip -Wl,-x

include $(THEOS_MAKE_PATH)/tweak.mk
