TARGET := iphone:clang:latest:11.0
ARCHS = arm64 arm64e
PACKAGE_VERSION = 0.0.3.2

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTUHD

YTUHD_FILES = Common.x SW.x
YTUHD_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
