#!/bin/bash

#init-file.sh

mkdir -p /root/.ssh
cp -r /root/host.ssh/* /root/.ssh
chown root /root/.ssh/config
chmod 600 /root/.ssh/config

echo "========= QEMU based ARM64 kernel module dev env ========="

# load kernel module for mount qcow image
sudo modprobe nbd || sudo insmod /lib/modules/`uname -r`/kernel/drivers/block/nbd.ko || echo "!!!! nbd load failed !!!!"

# qcow2 disk-file related operations
function part_qemu_img
{
    sudo qemu-nbd -c /dev/nbd0 ./$1

    (
    echo g # Create a new empty Linux partition table
    echo n # Add a new partition
    echo e # Extended partition
    echo 1 # Partition number
    echo   # First sector (Accept default: 2048)
    echo   # Last sector (Accept default: varies)
    echo w # Write changes
    ) | sudo fdisk /dev/nbd0

    sudo fdisk -l /dev/nbd0
    sudo qemu-nbd -d /dev/nbd0
}

function qcow2-mount
{
	[ $# -lt 2 ] && echo "provide qemu-image & dir name" && return 1
	QCOW2_FILE=$1
	MNT_DIR=$2
	(
		set -e
		set -x

		sudo qemu-nbd -d /dev/nbd0
	    sudo qemu-nbd -c /dev/nbd0 ./${QCOW2_FILE}
	    mkdir -p ${MNT_DIR}
	    sudo mount -o rw /dev/nbd0p1 ./${MNT_DIR}
	    echo ${QCOW2_FILE} " is mounted to " ${MNT_DIR}
	)
}
function qcow2-umount
{
	[ $# -lt 1 ] && echo "provide dir name" && return 1
	MNT_DIR=$1
	(
		set -e
		set -x
		sudo umount ${MNT_DIR}
		sudo qemu-nbd -d /dev/nbd0
	)
}

function qcow2-from-tarbz2
{
	if [ $# -ne "1" ]
	then
	  echo "Please provide a rootfs.tar.bz2 file to convert into qcow2 format"
	  return 112
	fi

	TAR_ROOTFS=$1
	QCOW2_FILE=$(basename ${TAR_ROOTFS}).qcow2

	SIZE=4G
	(
		set -e # exit on any errors
		set -x # expands variables and prints a little + sign before the line
		# cleanup possible relics from last run
		sudo umount ./mnt/ || echo "umount failed"
		sudo qemu-nbd -d /dev/nbd0 || echo "detach failed"

		# create qcow disk image
		qemu-img create -f qcow2 ./${QCOW2_FILE} ${SIZE}

		# partition
		part_qemu_img ${QCOW2_FILE}

		sleep 1 # don't know why, but it works
		# format
		sudo qemu-nbd -c /dev/nbd0 ./${QCOW2_FILE}
		sleep 1
		sudo mkfs.ext4 /dev/nbd0p1

		# extract rootfs file into the qcow image
		mkdir -p ./mnt
		sudo mount -o rw /dev/nbd0p1 ./mnt/
		sudo tar -jxf ${TAR_ROOTFS} -C ./mnt/
		sudo umount ./mnt/
		sudo qemu-nbd -d /dev/nbd0
	)
	# you catch errors with this if
	if [ $? -ne 0 ]; then
	  echo "We have an error " $?
	  return $?
	fi
}


function ldd-help
{
	echo "command: "
	typeset -F

	echo "####  HOW to compile kernel"
	echo " make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- mrproper"
	echo " make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig"
	echo " make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- prepare"
	echo " make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image -j8"
	echo
	echo "#     ./vmlinux & ./arch/arm64/boot/Image will be generated"
	echo
	echo "####  HOW to compile one module only"
	echo " make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CONFIG_XXX=m M=drivers/xxx/xxx"
}

alias aarch64-make="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "
alias grep='grep --color=auto'
alias l='ls -CF'
alias la='ls -A'
alias ll='ls -alF'
alias ls='ls --color=auto'

