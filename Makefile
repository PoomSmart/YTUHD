TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube
PACKAGE_VERSION = 1.2.2

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTUHD
$(TWEAK_NAME)_FILES = Common.x Tweak.x Settings.x
$(TWEAK_NAME)_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
