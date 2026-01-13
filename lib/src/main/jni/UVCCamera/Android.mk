#/*
# * UVCCamera
# * library and sample to access to UVC web camera on non-rooted Android device
# * 
# * Copyright (c) 2014-2017 saki t_saki@serenegiant.com
# * 
# * File name: Android.mk
# * 
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# *  You may obtain a copy of the License at
# * 
# *     http://www.apache.org/licenses/LICENSE-2.0
# * 
# *  Unless required by applicable law or agreed to in writing, software
# *  distributed under the License is distributed on an "AS IS" BASIS,
# *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# *  See the License for the specific language governing permissions and
# *  limitations under the License.
# * 
# * All files in the folder are under this Apache License, Version 2.0.
# * Files in the jni/libjpeg, jni/libusb, jin/libuvc, jni/rapidjson folder may have a different license, see the respective files.
#*/

######################################################################
# Make shared library libUVCCamera.so
######################################################################
LOCAL_PATH	:= $(call my-dir)
include $(CLEAR_VARS)

######################################################################
# Make shared library libUVCCamera.so
######################################################################
CFLAGS := -Werror

LOCAL_C_INCLUDES := \
		$(LOCAL_PATH)/ \
		$(LOCAL_PATH)/../ \
		$(LOCAL_PATH)/../rapidjson/include \

LOCAL_CFLAGS := $(LOCAL_C_INCLUDES:%=-I%)
LOCAL_CFLAGS += -DANDROID_NDK
LOCAL_CFLAGS += -DLOG_NDEBUG
LOCAL_CFLAGS += -DACCESS_RAW_DESCRIPTORS
LOCAL_CFLAGS += -O3 -fstrict-aliasing -fprefetch-loop-arrays

# Build ID defines (DECISION-017)
# These are set by sync_to_engine.sh or can be overridden
UVC_GIT_SHA ?= $(shell cd $(LOCAL_PATH) && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
UVC_BUILD_TIME ?= $(shell date -u +%Y%m%dT%H%M%SZ)
UVC_GIT_DIRTY ?= $(shell cd $(LOCAL_PATH) && git diff --quiet HEAD 2>/dev/null || echo "-dirty")
LOCAL_CFLAGS += -DUVC_GIT_SHA=\"$(UVC_GIT_SHA)\"
LOCAL_CFLAGS += -DUVC_BUILD_TIME=\"$(UVC_BUILD_TIME)\"
LOCAL_CFLAGS += -DUVC_GIT_DIRTY=\"$(UVC_GIT_DIRTY)\"

LOCAL_LDLIBS := -L$(SYSROOT)/usr/lib -ldl
LOCAL_LDLIBS += -llog
LOCAL_LDLIBS += -landroid
LOCAL_LDLIBS += -lnativewindow
LOCAL_LDLIBS += -lEGL
LOCAL_LDLIBS += -lGLESv2

LOCAL_SHARED_LIBRARIES += usb100 uvc

# Link libjpeg-turbo for captureToFd JPEG encoding (Phase 4)
LOCAL_STATIC_LIBRARIES += jpeg-turbo1500_static

LOCAL_ARM_MODE := arm

LOCAL_SRC_FILES := \
		_onload.cpp \
		utilbase.cpp \
		HandleManager.cpp \
		UVCCamera.cpp \
		UVCPreview.cpp \
		UVCButtonCallback.cpp \
		UVCStatusCallback.cpp \
		UVCReadinessCallback.cpp \
		Parameters.cpp \
		FrameBufferRing.cpp \
		FrameBufferJNI.cpp \
		LayoutContract.cpp \
		EGLImageHelperJNI.cpp \
		serenegiant_usb_UVCCamera.cpp \
		uvc_build_id.c

LOCAL_MODULE    := UVCCamera
include $(BUILD_SHARED_LIBRARY)
