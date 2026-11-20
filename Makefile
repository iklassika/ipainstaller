THEOS ?= $(HOME)/theos
TARGET_SDK ?= 16.5
TARGET = iphone:clang:$(TARGET_SDK):5.1
ARCHS = armv7 arm64
GO_EASY_ON_ME=1
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = libipainstaller
libipainstaller_FILES = \
					ZipArchive/minizip/ioapi.c \
					ZipArchive/minizip/mztools.c \
					ZipArchive/minizip/unzip.c \
					ZipArchive/minizip/zip.c \
					ZipArchive/ZipArchive.mm \
					UIDevice-Capabilities/UIDevice-Capabilities.m \
					IPAInstaller.mm
libipainstaller_FRAMEWORKS = Foundation UIKit ImageIO CoreGraphics
libipainstaller_PRIVATE_FRAMEWORKS = GraphicsServices MobileCoreServices
libipainstaller_LINKAGE_TYPE = static
libipainstaller_INSTALL_PATH = /usr/lib
libipainstaller_INSTALL = 0

include $(THEOS_MAKE_PATH)/library.mk

VERSION.INC_BUILD_NUMBER = 1

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/usr/include/IPAInstaller
	mkdir -p $(THEOS_STAGING_DIR)/usr/lib
	cp IPAInstaller.h $(THEOS_STAGING_DIR)/usr/include/IPAInstaller/
	cp $(THEOS_OBJ_DIR)/libipainstaller.a $(THEOS_STAGING_DIR)/usr/lib/
