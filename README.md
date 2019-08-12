# Linux Kernel Module Development Enviroment

This docker image provides enviroment for compile & debug linux kernel/module with QEMU simulator.

Usage:

  1. install docker-ce, the "from-a-package" way is recomended:   https://docs.docker.com/install/linux/docker-ce/ubuntu/#install-from-a-package
  2. do initial setup of the docker by ```make docker_init```, this will setup PROXY and MIRROR for docker.
  3. build the docker image by ```make docker_build```.
  4. drop into bash in the docker by ```make```.
  5. HOME folder is mapped into docker, so now you can goto the kernel source tree and build your kernel image.
  6. inside the docker container,few helper functions are availiable through the init script init-file.sh, show the list by ```ldd-help```.

    * qcow2-from-tarbz2: convert tarbz2 rootfs into qcow2 disk file
    * ldd-run-a53: given a kernel image (vmlinux) and a qcow2-format rootfs, involke QEMU with gdb-server listenning on port 1234
    * ldd-gdb: run gdb-multiarch debugger connecting to port 1234, usually this command is running in another docker bash.

