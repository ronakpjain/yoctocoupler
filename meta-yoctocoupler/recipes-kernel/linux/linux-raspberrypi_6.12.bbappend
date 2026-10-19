FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# Keep the Raspberry Pi BSP and add RT and hardware CAN support.
SRC_URI += "file://yoctocoupler-rt.cfg file://yoctocoupler-can.cfg"
SRC_URI:append = "${@bb.utils.contains('YOCTOCOUPLER_QEMU', '1', ' file://yoctocoupler-qemu-igb.cfg', '', d)}"

LINUX_VERSION_EXTENSION:append = "-yoctocoupler-rt"
