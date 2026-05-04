ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET = iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	TARGET = iphone:clang:latest:15.0
else
	TARGET = iphone:clang:latest:11.0
endif
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

LIBVPX_BUILD = $(THEOS_PROJECT_DIR)/vendor/libvpx_ios
LIBVPX_A     = $(LIBVPX_BUILD)/libvpx.a

# Build libvpx if the static library doesn't exist yet.
$(LIBVPX_A):
	@echo "==> Building libvpx (first-time setup)..."
	$(THEOS_PROJECT_DIR)/vendor/build_libvpx.sh

TWEAK_NAME = YTUHD
$(TWEAK_NAME)_FILES = Tweak.xm Settings.x HAMVPXVideoDecoder.m
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DSIDELOAD=$(SIDELOAD) \
    -I$(THEOS_PROJECT_DIR)/vendor/libvpx \
    -I$(LIBVPX_BUILD)
$(TWEAK_NAME)_LDFLAGS = $(LIBVPX_A)
ifneq ($(SIDELOAD),1)
$(TWEAK_NAME)_LIBRARIES = undirect
endif
$(TWEAK_NAME)_FRAMEWORKS = VideoToolbox

# Ensure libvpx is built before compiling any tweak source.
$(THEOS_OBJ_DIR)/arm64/Tweak.xm.%.o \
$(THEOS_OBJ_DIR)/arm64/HAMVPXVideoDecoder.m.%.o \
$(THEOS_OBJ_DIR)/arm64/Settings.x.%.o: $(LIBVPX_A)

include $(THEOS_MAKE_PATH)/tweak.mk

# `make libvpx` target for an explicit rebuild of the library.
.PHONY: libvpx
libvpx:
	$(THEOS_PROJECT_DIR)/vendor/build_libvpx.sh
