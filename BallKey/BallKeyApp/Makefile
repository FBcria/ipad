TARGET := iphone:clang:16.5:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := BallKeyApp
BallKeyApp_FILES := main.m
BallKeyApp_CFLAGS := -fobjc-arc
BallKeyApp_FRAMEWORKS := UIKit Foundation
BallKeyApp_CODESIGN_FLAGS := -Sentitlements.plist
BallKeyApp_INSTALL_PATH := /Applications

include $(THEOS)/makefiles/application.mk
