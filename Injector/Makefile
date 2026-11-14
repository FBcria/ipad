TARGET := iphone:clang:16.5:13.0
ARCHS := arm64
INSTALL_PATH := /Applications

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := BallKeyInjector
BallKeyInjector_FILES := main.m
BallKeyInjector_FRAMEWORKS := UIKit Foundation
BallKeyInjector_CFLAGS := -fobjc-arc -Wno-deprecated-declarations -O2
BallKeyInjector_CODESIGN_FLAGS := -SInjector/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
