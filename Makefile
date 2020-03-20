.RECIPEPREFIX +=

IMG_NAME = lkmdev

.PHONY: default  docker_build docker_save docker_load docker_run chown

default: docker_run

docker_init:
     if docker -v ; then \
      echo "======== docker-ce has been installed ==========="; \
     else \
      mikdir -p docker; \
      wget https://download.docker.com/linux/ubuntu/dists/bionic/pool/stable/amd64/containerd.io_1.2.6-3_amd64.deb; \
      wget https://download.docker.com/linux/ubuntu/dists/bionic/pool/stable/amd64/docker-ce-cli_19.03.6~3-0~ubuntu-bionic_amd64.deb; \
      wget https://download.docker.com/linux/ubuntu/dists/bionic/pool/stable/amd64/docker-ce_19.03.6~3-0~ubuntu-bionic_amd64.deb; \
      sudo apt install ./*.deb; \
     fi
     @echo "======== Configure http proxy for docker ==========="
     sudo mkdir -p /etc/systemd/system/docker.service.d
     echo "[Service]" >   http-proxy.conf
     echo Environment=\"HTTP_PROXY=${HTTP_PROXY}\" >>   http-proxy.conf
     echo Environment=\"NO_PROXY=${NO_PROXY}\" >> http-proxy.conf
     sudo mv http-proxy.conf /etc/systemd/system/docker.service.d/
     @echo "======== Configure mirror for dockerhub ==========="
     echo {\"registry-mirrors\": [\"https://dockerhub.azk8s.cn\",\"https://reg-mirror.qiniu.com\"]} > daemon.json
     sudo mv daemon.json /etc/docker/
     sudo systemctl daemon-reload
     sudo systemctl restart docker
     @echo "======== Verify proxy settings ==========="
     sudo systemctl show --property Environment docker
     @echo "======== Configure docker without sudo ==========="
     sudo groupadd docker || echo "docker groups is exist"
     sudo gpasswd -a ${USER} docker
     @echo "======== Run hello-world ==========="
     sudo docker run hello-world
     @echo "======== Done ========="

docker_build:
     # --no-cache --pull
     docker build --network=host -t $(IMG_NAME) .

docker_save:
     docker save -o $(IMG_NAME).docker_img $(IMG_NAME)

docker_load:
     docker load -i $(IMG_NAME).docker_img

# we assume pwd is the workspace, so we map it

docker_run:
     #cp ~/.gitconfig ./host_gitconfig
     #xhost +
     # -p 1234:1234 (all instance of a container share the same namespace?) \
     docker run --network=host --privileged --rm \
          -v /dev:/dev \
          -v ${HOME}:${HOME} \
          -v `echo ~`/.ssh:/root/host.ssh \
          --env HOME_DIR=${HOME} \
          --env HOST_USER=${USER} \
          -v /lib/modules/$(shell uname -r)/:/lib/modules/$(shell uname -r)/ \
          -v /usr/src:/usr/src \
          -v ~/.Xauthority:/root/.Xauthority \
          -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
          -e DISPLAY=${DISPLAY} \
          --workdir=`pwd` \
          -it $(IMG_NAME) /bin/bash --init-file init-file.sh
     #xhost -

#==========================================================================
# after we get inside the docker, just follow the suggestion in this DOC
#
#                     https://www.kernel.org/doc/html/v4.10/dev-tools/gdb-kernel-debugging.html
#  (with more detail) http://nickdesaulniers.github.io/blog/2018/10/24/booting-a-custom-linux-kernel-in-qemu-and-debugging-it-with-gdb/
#
# we can use ubuntu cloud qcow2 image instead of build own rootfs, refer to:
#
#   https://askubuntu.com/questions/281763/is-there-any-prebuilt-qemu-ubuntu-image32bit-online/1081171#1081171
#   https://cloud-images.ubuntu.com/releases/bionic/release/
#
# compile kernel can be done faster when outside of KVM.
#   (https://wiki.qemu.org/Documentation/9psetup)
#
#        make defconfig
#        ./scripts/config -e NET_9P -e NET_9P_VIRTIO -e VIRTIO -e VIRTIO_PCI -e VIRTIO_PCI_LEGACY -e VIRTIO_MMIO -e DEBUG_INFO -e GDB_SCRIPTS
#        make -j8
#        make scripts_gdb # generate vmlinux-gdb.py
#
# then install the kernel inside kvm:
#
#        make modules_install install; update-initramfs -c -k 5.4.0;  update-grub
#
# kernel command line "nokaslr" is vital for gdb debug, thus make sure add it to /etc/default/grub, then update-grub.
#
#        -append 'console=ttyS0 nokaslr cma=128M'
#
# inside QEMU/KVM, after OS bootup, mount host's dir with:
# (https://wiki.qemu.org/Documentation/9psetup)
#
#         mount -t 9p -o trans=virtio,version=9p2000.L host0 dst_folder
#
# kernel module debug inside QEMU:
#    https://stackoverflow.com/questions/28607538/how-to-debug-linux-kernel-modules-with-qemu
# "====== in QEMU/KVM: insmod xxx.ko; cat /proc/modules; # you will find the address 0xyz
# "====== in GDB:      add-symbol-file $(KSRC_DIR)/drivers/misc/xxx/xxx.ko 0xyz"
#  now you can add breakpoint to the kernel modules"



KSRC?=./_dev/kernel/

pull:
     mkdir -p ./_dev && \
          cd _dev && \
          git clone -b hantro-x86 ssh://git@gitlab.devtools.intel.com:29418/kmb_integration/vpusmm_driver.git kernel && \
          git clone ssh://git@gitlab.devtools.intel.com:29418/tingqian/libdrm.git

kernel:
     cp .config-5.4-qemu ./_dev/kernel/.config
     cd ./_dev/kernel/ && make -j8 && make scripts_gdb

libdrm:
     (cd ./_dev/libdrm && chmod +x ./autogen.sh && ./autogen.sh --enable-debug --prefix=/usr && make -j8)

install:
     (cd ./_dev/kernel/; make modules_install install; update-initramfs -c -k 5.4.0;  update-grub)
     @echo "======================================================================================"
     @echo "FOR DEBUG: Please add nokaslr to kernel cmdline in /etc/default/grub, then update-grub"

run:
    kvm  -nographic \
      -drive "file=./ubuntu-18.04-server-cloudimg-amd64.img,format=qcow2" \
      -device rtl8139,netdev=net0 `# for apt install inside qemu` \
      -netdev user,id=net0 \
      -m 1G \
      -serial mon:stdio \
      -smp 1 \
      -virtfs local,path=${HOME_DIR},mount_tag=host0,security_model=passthrough,id=host0 `# add virtfs 9p based device` \
      -s `# start GDB server on localhost:1234`

debug:
     gdb  \
          -ex "set debug auto-load on" \
          -ex "add-auto-load-safe-path $(KSRC)" \
          -ex "file $(KSRC)/vmlinux" \
          -ex "target remote :1234" \
          -ex "hbreak start_kernel" \
          -ex "lx-symbols"
