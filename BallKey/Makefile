TARGET := iphone:clang:16.5:13.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME := ballkey
ballkey_FILES := Tweak.x
ballkey_CFLAGS := -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-parameter
ballkey_FRAMEWORKS := UIKit Foundation GameController
ballkey_LDFLAGS := -Wl,-install_name,@rpath/libballkey.dylib

include $(THEOS_MAKE_PATH)/library.mk
