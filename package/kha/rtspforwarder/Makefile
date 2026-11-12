include $(TOPDIR)/rules.mk

PKG_NAME:=rtspforwarder
PKG_VERSION:=2.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/rtspforwarder
  SECTION:=utils
  CATEGORY:=KHA
  TITLE:=UDP MPEG-TS to RTSP forwarder (GStreamer) with LuCI page
  DEPENDS:=+gstreamer1-utils +gst1-mod-udp +gst1-mod-mpegtsdemux \
	+gst1-mod-rtp +gst1-mod-rtpmanager +gst1-mod-rtspclientsink \
	+rpcd +rpcd-mod-ucode +ucode-mod-uci +ucode-mod-ubus +ucode-mod-fs \
	+luci-base
  PKGARCH:=all
endef

define Package/rtspforwarder/description
 procd service that runs a gst-launch-1.0 pipeline
   udpsrc ! queue ! tsparse ! rtspclientsink
 to push an MPEG-TS stream received over UDP to an RTSP server as one RTP
 stream (MP2T payload), so video and KLV metadata travel together,
 its uci config (/etc/config/rtspforwarder), the LuCI
 "Services > RTSP Forwarder" page and a /root/status.sh section.
 Part of both image variants (config.seed).
endef

define Package/rtspforwarder/conffiles
/etc/config/rtspforwarder
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

# Files that must be 0755 on the device; everything else is 0644, dirs 0755.
RTSPFORWARDER_EXEC:= \
	/etc/init.d/rtspforwarder \
	/etc/uci-defaults/95-rtspforwarder-gst

define Package/rtspforwarder/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
	chmod 0755 $(addprefix $(1),$(RTSPFORWARDER_EXEC))
	# gst-launch runs through this name so procd tags its syslog lines
	# "rtspforwarder[pid]" rather than "gst-launch-1.0[pid]".
	$(INSTALL_DIR) $(1)/usr/libexec
	$(LN) ../bin/gst-launch-1.0 $(1)/usr/libexec/rtspforwarder
endef

define Package/rtspforwarder/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,rtspforwarder))
