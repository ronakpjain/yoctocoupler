SUMMARY = "Minimal real-time image for the Raspberry Pi Compute Module 5"
DESCRIPTION = "A minimal systemd image for the Raspberry Pi CM5 IO Board with PREEMPT_RT, DHCP networking, OpenSSH, and real-time test tools."

LICENSE = "MIT"

require recipes-core/images/core-image-minimal.bb

IMAGE_FEATURES += "ssh-server-openssh"
IMAGE_INSTALL:append = " pps-tools rt-tests yoctocoupler-networkd"

# Inject a key only when explicitly supplied; never create a default credential.
YOCTOCOUPLER_SSH_PUBLIC_KEY ?= ""

ROOTFS_POSTPROCESS_COMMAND:append = " yoctocoupler_install_ssh_key;"

yoctocoupler_install_ssh_key() {
    if [ -z "${YOCTOCOUPLER_SSH_PUBLIC_KEY}" ]; then
        return
    fi

    install -d -m 0700 "${IMAGE_ROOTFS}/root/.ssh"
    printf '%s\n' "${YOCTOCOUPLER_SSH_PUBLIC_KEY}" > "${IMAGE_ROOTFS}/root/.ssh/authorized_keys"
    chmod 0600 "${IMAGE_ROOTFS}/root/.ssh/authorized_keys"
}
