FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# Keep the Raspberry Pi BSP and add only the RT policy as a config fragment.
SRC_URI += "file://yoctocoupler-rt.cfg"

LINUX_VERSION_EXTENSION:append = "-yoctocoupler-rt"
