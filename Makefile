TARGET := iphone:clang:latest:14.0
ARCHS := arm64

INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatChangeTime
WeChatChangeTime_FILES = Tweak.xm
WeChatChangeTime_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WeChatChangeTime_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
