#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=gst1-rtsp-server
PKG_VERSION:=1.26.4
PKG_RELEASE:=1

PKG_SOURCE:=gst-rtsp-server-$(PKG_VERSION).tar.xz
PKG_SOURCE_URL:=https://gstreamer.freedesktop.org/src/gst-rtsp-server
PKG_HASH:=ae47a21ae8478311d37f648ddd1319aa7a13f4b34cbe467d2a90f185866d0061
PKG_BUILD_DIR:=$(BUILD_DIR)/gst-rtsp-server-$(PKG_VERSION)

PKG_LICENSE:=LGPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING
PKG_CPE_ID:=cpe:/a:gstreamer:gst-rtsp-server

GST_VERSION:=1.0

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/meson.mk

define Package/libgst1rtspserver
  CATEGORY:=Multimedia
  SECTION:=multimedia
  TITLE:=GStreamer RTSP server library
  URL:=https://gstreamer.freedesktop.org/
  DEPENDS:=+libgstreamer1 +libgst1app +libgst1net +libgst1rtp +libgst1rtsp +libgst1sdp
endef

define Package/libgst1rtspserver/description
 GStreamer open source multimedia framework
 .
 This package contains the GStreamer RTSP server library
 (libgstrtspserver), required by the rtspclientsink plugin.
endef

define Package/gst1-mod-rtspclientsink
  CATEGORY:=Multimedia
  SECTION:=multimedia
  TITLE:=GStreamer rtspclientsink plugin
  URL:=https://gstreamer.freedesktop.org/
  DEPENDS:=+libgst1rtspserver
endef

define Package/gst1-mod-rtspclientsink/description
 GStreamer open source multimedia framework
 .
 This package contains the rtspclientsink element, which records
 a media stream to an RTSP server using RECORD.
endef

MESON_ARGS += \
	-Drtspclientsink=enabled \
	-Dexamples=disabled \
	-Dtests=disabled \
	-Dintrospection=disabled \
	-Ddoc=disabled

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include/gstreamer-$(GST_VERSION)
	$(CP) $(PKG_INSTALL_DIR)/usr/include/gstreamer-$(GST_VERSION)/* \
		$(1)/usr/include/gstreamer-$(GST_VERSION)/
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libgstrtspserver-$(GST_VERSION).so* \
		$(1)/usr/lib/
	$(INSTALL_DIR) $(1)/usr/lib/pkgconfig
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/pkgconfig/gstreamer-rtsp-server-$(GST_VERSION).pc \
		$(1)/usr/lib/pkgconfig/
endef

define Package/libgst1rtspserver/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libgstrtspserver-$(GST_VERSION).so.* \
		$(1)/usr/lib/
endef

define Package/gst1-mod-rtspclientsink/install
	$(INSTALL_DIR) $(1)/usr/lib/gstreamer-$(GST_VERSION)
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/gstreamer-$(GST_VERSION)/libgstrtspclientsink.so \
		$(1)/usr/lib/gstreamer-$(GST_VERSION)/
endef

$(eval $(call BuildPackage,libgst1rtspserver))
$(eval $(call BuildPackage,gst1-mod-rtspclientsink))
