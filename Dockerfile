FROM ubuntu:18.04

# this is a docker image used for compile & debug, only neccessary tools are
# installed to give user an easy-to-use developing environment.
#
# inside the container, another bash will be reponsible for clone source & build
# to be flexible, the docker container is just used for build & run & debug, the
# working folder is shared with host for easily code editing, every modification
# is made only to the mounted external drive. so the container can be removed
# w/o problem.
#
# those user-space component not require rebuilt or debug can be put into dockerfile
# in binary/installed form so it becomes part of the image, saves user's time.
#

ENV http_proxy http://child-prc.intel.com:913/
ENV https_proxy http://child-prc.intel.com:913/

# install required packages
RUN \
  sed -i 's/# \(.*multiverse$\)/\1/g' /etc/apt/sources.list && \
  apt-get update && \
  apt-get -y upgrade

RUN DEBIAN_FRONTEND=noninteractive apt-get install -y autoconf automake bison flex autopoint libtool \
        libglib2.0-dev yasm nasm xutils-dev libpthread-stubs0-dev libpciaccess-dev libudev-dev \
        libfaac-dev libxrandr-dev libegl1-mesa-dev openssh-server git-core wget \
        build-essential gettext libgles2-mesa-dev vim-nox libshout3-dev libsoup2.4-dev \
        nginx libssl-dev sudo

RUN DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y pciutils cpio libtool lsb-release ca-certificates

#================== GDB ================
RUN apt-get install -y gdb gdb-multiarch libpixman-1-dev libcap-dev libattr1-dev

RUN apt-get install -y python python3

WORKDIR /home

#================== QEMU (this is slow, add new tools after it please) ================
ARG QEMU_VER=3.1.0
RUN wget -O - https://download.qemu.org/qemu-${QEMU_VER}.tar.xz | tar xJ; \
    cd qemu-${QEMU_VER}; \
    ./configure --target-list=aarch64-linux-user,arm-linux-user,arm-softmmu,aarch64-softmmu,x86_64-softmmu --enable-virtfs; \
    make -j8; \
    make install
    # /usr/local/bin/qemu-system-aarch64 is ready to use

#================== Cross-Compile ===========================
RUN apt-get install -y gcc-aarch64-linux-gnu libncurses5-dev

#================== For linux kernel compile ============================
RUN apt-get install -y bc

#================== For modprobe ============================
RUN apt-get install -y kmod

RUN apt-get install -y build-essential ncurses-dev xz-utils libssl-dev bc flex libelf-dev bison

#===========================================================================================================
# https://askubuntu.com/questions/281763/is-there-any-prebuilt-qemu-ubuntu-image32bit-online/1081171#1081171
RUN apt-get install -y cloud-image-utils
RUN apt-get install -y initramfs-tools-core
RUN apt-get install -y man-db

RUN apt-get install -y qemu qemu-kvm libvirt-bin  bridge-utils  virt-manager
