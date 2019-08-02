#!/bin/bash

#init-file.sh
echo "========= QEMU based ARM64 kernel module dev env ========="

# RUN kernel on qemu arm64 a53
function ldd-run-a53(){
	DEF_CFG="-M virt -m 1024 -smp 1 -cpu cortex-a53 -nographic"
	if [ $# -ne "2" ]
    then
      echo "Run QEMU aarch64 on specified vmlinuz-kernel-image and qcow2-disk-file"
      echo "    the qcow2-disk-file can be made from rootfs.tar.bz2 file by function qcow2-from-tarbz2"
      echo "default config is ${DEF_CFG}"
      echo "Usage: `basename $0` VMLINUXZ DRIVE_FILE"
      return 112
    fi
    VMLINUXZ=$1
    DRIVE_FILE=$2

    [ -f ${VMLINUXZ} ] || { echo "kernel image ${VMLINUXZ} does not exist"; return 1; }
    [ -f ${DRIVE_FILE} ] || { echo "qcow2 disk image ${DRIVE_FILE} does not exist"; return 2; }

    echo "DEF_CFG=${DEF_CFG} VMLINUXZ=${VMLINUXZ}, DRIVE_FILE=${DRIVE_FILE}"
    #return 0

	qemu-system-aarch64  ${DEF_CFG} \
      -kernel $VMLINUXZ \
      -append 'root=/dev/vda1 console=ttyAMA0 panic=1 cma=128M' \
      -drive if=none,file=${DRIVE_FILE},format=qcow2,id=hd0                          `# add a hard drive virtual-disk-file named as hd0` \
      -netdev user,id=network0 -device e1000,netdev=network0,mac=52:54:00:12:34:56   `# add a network card` \
      -device virtio-blk-pci,drive=hd0                                               `# add a block device backed by hd0` \
      -virtfs local,path=${HOME},mount_tag=host0,security_model=passthrough,id=host0 `# add virtfs 9p based device` \
      -s `# start GDB server on localhost:1234`
}

# gdb debug kernel running in Qemu
function ldd-gdb
{
	KSRC_DIR=$1
	[ -d  "${KSRC_DIR}" ] || { echo "kernel source dir ${KSRC_DIR} not provided or incorrect"; return 1;}
	[ -f ${KSRC_DIR}/vmlinux ] || { echo "kernel executable ${KSRC_DIR}/vmlinux not exist"; return 2; }
	echo "kernel module debug inside QEMU tips"
	echo "====== in QEMU: insmod and see where kernel modules are loaded ==== "
	echo "cat /proc/modules"
	echo
	echo "====== in GDB: load symbol file (modify the address as shown by above command) ==== "
	echo "add-symbol-file $(KSRC_DIR)/drivers/misc/xxx/xxx.ko 0xffff000008bd0000"
	echo
	echo "now you can add breakpoint to the kernel modules"
	echo "$(KSRC_DIR)/vmlinux-gdb.py only generated when executed 'make scripts_gdb'"
	echo "lx-symbols will load all symbols"
	gdb-multiarch  \
					-ex "set debug auto-load on" \
					-ex "add-auto-load-safe-path ${KSRC_DIR}" \
					-ex "file ${KSRC_DIR}/vmlinux" \
					-ex "target remote :1234" \
					-ex "lx-symbols"
}

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

ldd-help

