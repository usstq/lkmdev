
-------------------------------------------------------------------
##in Device tree, what the difference between "ranges" & "dma-ranges"

they both encoded arbitrary number of (child-bus-address, parent-bus-address, length) triplets.
but ranges is about the downstream access, means access master on parent-bus, slave on child-bus
and dma-ranges is about the opposite direction, master on child-bus, slave on parent-bus.

there are usually separate 2 set of HW path and so address mappings for these 2 access directions.

-------------------------------------------------------------------
##How DMA is configured by device tree?

1.platform_bus_type.dma_configure callback(platform_dma_configure) is responsible for that.
2.driver_probe_device() will call that callback when binding a device on a platform bus
3.in platform_dma_configure, of_dma_configure() is called when device has of_node(comes from device tree)
4.of_dma_configure() will do following things:

    1. find dma parent of the device (it should be some bus)
       and read "dma-ranges" property from it.
       it does this process recursively to upper parent bus if
       an empty "dma-ranges" is met.

    2. derive the offset between <device dma address> & <parent bus address>
       from "dma-ranges" set offset to zero when no "dma-ranges" is provided
       (assume 1:1 mapping), this offset is recorded into per device varible
       dev->dma_pfn_offset, which is used for phys_to_dma/dma_to_phys.
    3. derive or limit the per device dma_mask & coherent_dma_mask by
       the size specified in "dma-ranges".
       the dma_mask & coherent_dma_mask are compared with dma addresses
       for checking if some memory page can be accessed by dev's DMA.

    4. get "dma-coherent" & "iommus"
       if "iommus" is set in dt, of_iommu_configure() will be called, and
       "dma-ranges" will be ignored (every code related to it will be branched
       unless the iommu mster referenced is disabled), of_iommu_xlate() will be called

       the referenced iommu master is searched from iommu_device_list, and it's ops (iommu_ops)
       will be used for setting dev->iommu_fwspec->ops, finally the ops->of_xlate() is called on dev.
       (in arm smmu v3 case, arm_smmu_ops defined in arm-smmu-v3.c is the ops of the iommu master)

       iommu_probe_device() is also called in case the device is not mapped into any
       iommu group yet, it's just calling dev->bus->iommu_ops->add_device(). in arm smmu v3 case,
       arm_smmu_add_device() is called, and the device group is allocated by arm_smmu_device_group()
       with new domain attached to the group.

    5. call arch_setup_dma_ops() to set dev->dma_coherent and
       if iommu is ready, also set dev->dma_ops to iommu_dma_ops, so any DMA API will go though iommu
       instead of DMA direct API.

-------------------------------------------------------------------
##How does dma_alloc_coherent() guareentee the output buffer is really coherent?

there are 3 branches in dma_alloc_coherent()

1.dma_alloc_from_dev_coherent(): alloc from device coherent pool dev->dma_mem
  the dev->dma_mem can be configured by set "memory-region" attr referencing
  a "no-map" type reserved_memory. during device probe, the specific device driver
  will call of_reserved_mem_device_init_by_idx() to assign reserved memory region
  to a given device, this function will call rmem->ops->device_init(), in this case
  it's rmem_dma_device_init(), dma_init_coherent_memory() will be called to build the
  mem-mapping. and it uses memremap(MEMREMAP_WC) to:
     allocate a vma from kernel address space and map the physical mem as write-combine(non-cached).

  note memremap() does very careful checking to:
    a. not remap mixed regions
    b. only return ok when remap on RAM with write-back, and also no
       actuall remap is done, just return the logic mapping already estanblished
       (the just offseted 1:1 mapping between physical addr and kernel virtual addr).
    c. fail when trying to remap a RAM with WT/WC type

  basically, OS should not allow mapping of same piece of RAM into virtual space regions
  with different in-consistent cache-ability prot. to avoid coherent problem.

2.dma_direct_alloc(): if dev->dma_ops isn't set, it's general cases for no-iommu platform device
                       there are futher 2 cases (don't consider CONFIG_ARCH_HAS_UNCACHED_SEGMENT):
                       but both of them will call __dma_direct_alloc_pages() which call CMA/buddy
                       allocator, the difference is mainly in how the virtual kernel space mapping
                       is generated based on the cache-ability required for the buffer being allocated.

      a).arch_dma_alloc():          the result virtual address is returned from dma_common_contiguous_remap()
                                   which created a coherent(non-cachable) mapping for the buffer.
      b).dma_direct_alloc_pages():  the result virtual address is just the logic kernel mapping (so it's cached, WB).

    in case a), we can see logical kernal mapping is still there, but allocator will make sure no one will
    access the buffer through this cached mapping, kernel/driver can only access it through the new mapping
    with caching disabled.

3.dev->dma_ops->alloc(), if dev->dma_ops is set, usually it will be set to iommu_dma_ops if "iommus" in device tree
                          is specified.

   check dma-iommu.c please.

   iommu_dma_alloc() will be called, it basically does the same when allocating memory pages, but it will
   also allocate the IOVA address and call the iommu driver to do the final maping into device's VA space.

   as for the cpu side vaddr coherency, it will do remap only when the device itself is not coherent.


-------------------------------------------------------------------
##DMA-Buf only support memory with struct page?

we can see DMABuf use scatterlist to do import, but scatterlist is build upon the
page data structure, the no-map type reserved-memory do not have page structure,we
can check here:

   set a breakpoint at start_kernel(), when it got hit,set an watchpoint at memblock.memory.regions[4].base
   we can find out __reserved_mem_reserve_reg() is for initialization of the initial memblocks:
   and this function calls memblock_remove() to remove no-map range from memblocks.
   that means no-map will have no logic address & struct page at all.
   this will also prevent we use DMABuf API, because DMABuf rely on scatterlist which requires page struct
   for underlying memory. so we cannot use no-map. fortunately, ARM64 supports it (but not ARM).

see https://www.kernel.org/doc/html/latest/vm/memory-model.html, the memory module
we used for ARM64 is CONFIG_SPARSEMEM_VMEMMAP, so there is a vmemmap
    /* memmap is virtually contiguous.  */
    #define __pfn_to_page(pfn)  (vmemmap + (pfn))
    #define __page_to_pfn(page) (unsigned long)((page) - vmemmap)

-------------------------------------------------------------------
##How PA space is managed in aarch64-linux? What's resource in linux kernel?
the configuration comes directly from device tree (or dynamically configured in case of PCIE).

resource is a very specific jargon. we know in PC world, the only way (except INT) for CPU to
the outside world is IO/MEM read/write, so the IO address space & MEM address space region is
the "resource". kernel has these resource API for house-keeping.
Prevent drivers accessing same region at the same time, but enforcement is not possible,
kernel driver can always force access any IO or MEM in PA space by ioremap (internally get_vm_area())

see: https://www.oreilly.com/library/view/linux-device-drivers/0596000081/ch02s05.html
src: kernel-source/kernel/resource.c
chk: sudo cat /proc/ioports
chk: sudo cat /proc/iomem

these IO/MEM regions(resources) are requested by driver after the real hardware is probed.
and kernel do not think of these regions as memory (like no-map), so for these kind of regions
kernel will not setup mappings or manage them as memory, driver will do that using API like
devm_ioremap/devm_ioremap_wc.

-------------------------------------------------------------------
##How VA space is managed in aarch64-linux?
see: kernel-source/Documentation/arm64/memory.rst
AArch64 Linux memory layout with 4KB pages + 4 levels (48-bit)::
  Start     End     Size    Use
  -----------------------------------------------------------------------
  0000000000000000  0000ffffffffffff   256TB    user
  ffff000000000000  ffff7fffffffffff   128TB    kernel logical memory map
  ffff800000000000  ffff9fffffffffff    32TB    kasan shadow region
  ffffa00000000000  ffffa00007ffffff   128MB    bpf jit region
  ffffa00008000000  ffffa0000fffffff   128MB    modules
  ffffa00010000000  fffffdffbffeffff   ~93TB    vmalloc
  fffffdffbfff0000  fffffdfffe5f8fff  ~998MB    [guard region]
  fffffdfffe5f9000  fffffdfffe9fffff  4124KB    fixed mappings
  fffffdfffea00000  fffffdfffebfffff     2MB    [guard region]
  fffffdfffec00000  fffffdffffbfffff    16MB    PCI I/O space
  fffffdffffc00000  fffffdffffdfffff     2MB    [guard region]
  fffffdffffe00000  ffffffffffdfffff     2TB    vmemmap
  ffffffffffe00000  ffffffffffffffff     2MB    [guard region]

prerequisite concepts:
  logical memory mapping (1:1 map):
    https://stackoverflow.com/questions/8708463/difference-between-kernel-virtual-address-and-kernel-logical-address
    virt_to_phys, phys_to_virt, kmalloc
  ARMv8-A Address Translation
    ASID, TTBR0_EL1, TTBR1_EL1
    https://static.docs.arm.com/100940/0100/armv8_a_address%20translation_100940_0100_en.pdf chapter11
  PAN: Privileged Access Never
    When enabled, this feature causes a permission fault if the kernel attempts to access memory
    that is also accessible by userspace - instead the PAN bit must be cleared when accessing userspace memory.
    A new Privileged Access Never (PAN) state bit.
      This bit provides control that prevents privileged access to user data
      unless explicitly enabled; an additional security mechanism against possible software attacks.
    CONFIG_ARM64_PAN,CONFIG_ARM64_SW_TTBR0_PAN
    https://lwn.net/Articles/651614/
    https://kernsec.org/wiki/index.php/Exploit_Methods/Userspace_data_usage
    __uaccess_ttbr0_disable, __uaccess_ttbr0_enable
  KASAN: Kernal Address Sanitizer
    https://en.wikipedia.org/wiki/AddressSanitizer
    https://lwn.net/Articles/612153/
    kernel-source/Documentation/dev-tools/kasan.rst
  SPARSEMEM: one of Linux memory models
    kernel-source/Documentation/vm/memory-model.rst
    CONFIG_SPARSEMEM_VMEMMAP, vmemmap, __pfn_to_page, __page_to_pfn
  vmalloc:
    ioremap, get_vm_area, vmalloc, kmap, vmap

though 48-bit VA has only 256TB space, bit 63:48 can choose between TTBR0_EL1 & TTBR1_EL1.
so kernel can also have 256TB space, and the regions depending on the VA size are:
    1.logical memory mapping (for direct kernel access to physical memory)
    2.kasan shadow (Kernal Address Sanitizer shadow)
    3.vmemmap (for struct page array in SPARCEMEM mode, check arm64_memblock_init())
the rest can be used for:
    1.dynamic mapping of discontinous memory(vmalloc)
    2.dynamic mapping of physical device's IO/MEM space.

-------------------------------------------------------------------
##What's the memblock?
Memblock is a method of managing memory regions during the early boot period when the usual
kernel memory allocators are not up and running.
Memblock views the system memory as collections of contiguous regions.

see: https://www.kernel.org/doc/html/latest/core-api/boot-time-mm.html

The early architecture setup should tell memblock what the physical memory layout is by using
memblock_add(), and then others can alloc from it using memblock_phys_alloc/memblock_alloc.
As the system boot progresses, the architecture specific mem_init() function frees all the
memory to the buddy page allocator.


1. setup_arch() call memblock_reserve() to reserve the memory for kernel's text&data at (_text~_end)
2. setup_arch() calls (indirectly) early_init_dt_scan_memory(), which does few things like
   parse commandline from "chosen" node, parse cell-size attr, and scan "memory" nodes
   by early_init_dt_scan_memory(). and then it calls memblock API to add memory node into MEMBLOCK
   subsystem.

-------------------------------------------------------------------
##The memory node in device tree begin at 0x10_0000_0000, but we saw memblock.memory.region[0].base
is 0x10_0a00_0000, why?

1.There is a "mmio-sram" node, which reserved a DDR memory region 0x1004000000 ~ 0x1006000000.
2.uboot load device tree at physical address 0x000000108fffa000~000000108ffff382, it passes into kernel
  th dt_phys, kernel will setup mapping then access it.

   after some debug we found it's the bootloader who modified the memory@1000000000 to be start at
   0x100a000000, the memory it reserved is for it's own good maybe.

   check on simics script we found that it instructs u-boot to load kernel to 0x1060000000
   and then device_tree to 0x0x1080000000

-------------------------------------------------------------------
## Loop device
In Unix-like operating systems, a loop device, vnd (vnode disk), or lofi (loop file interface) is
a pseudo-device that makes a file accessible as a block device.

https://en.wikipedia.org/wiki/Loop_device

losetup: the user interface for loop device
  * losetup [-l] [-a]
    - show all loop device attached to file
  * losetup [-o offset] [--sizelimit size] [-Pr] [--show] -f|loopdev file
    - attach a file to a loopdev (/dev/loop0,/dev/loop1,...,/dev/loopN)
  * losetup -d loopdev
    - detach a file from the loopdev

-------------------------------------------------------------------
## Device mapper
The device mapper is a framework provided by the Linux kernel for mapping physical block devices
onto higher-level virtual block devices. It forms the foundation of the logical volume manager (LVM),
software RAIDs and dm-crypt disk encryption, and offers additional features such as file system snapshots.

https://en.wikipedia.org/wiki/Device_mapper
https://www.ibm.com/developerworks/cn/linux/l-devmapper/index.html

The framework adds another (maybe many & recursive) layers of abstraction build upon physical block devices
to provide logic block device (or logic volume) with additonal features that is hard to archive with orginal
physical ones. framwork doing so by having many different "mapping target":

mapping targets:
  Documentation/admin-guide/device-mapper/linear.rst
  Documentation/admin-guide/device-mapper/striped.rst
    https://en.wikipedia.org/wiki/Data_striping
    https://www.cnblogs.com/ivictor/p/6099807.html (striped/RAID-0)
  Documentation/admin-guide/device-mapper/cache.rst
  Documentation/admin-guide/device-mapper/dm-raid.rst
    https://en.wikipedia.org/wiki/RAID
-------------------------------------------------------------------
## Do some experiments on device mapper

https://wiki.gentoo.org/wiki/Device-mapper

generate a sparse file for test purpose:
```
dd if=/dev/null of=nameX.img seek=1961317
stat nameX.img
```
/dev/null: drop all writes, read generate EOF, so above command generate a sparse file with 1961317 as the number of 512-bytes sectors
stat will tell us the size is 1004194304 (1961317*512) but the blocks consumed is zero. use losetup to attach it to a loop block device
```
losetup /dev/loop0 ./nameX.img
dmsetup create test-linear --table '0 1961317 linear /dev/loop0 0'    # create a logic volume which is identity mapping to /dev/loop0
dmsetup table                                                         # show current mapping table
echo -e '0 10 linear /dev/loop0 0'\\n'10 20 linear /dev/loop0 0' | dmsetup create test-linear   # this mapping duplicates the first 10 sector of /dev/loop0
wxHexEditor nameX.img                                # now change the content of first 10 sectors
xxd /dev/mapper/test-linear | less                   # we will found two changes because of the duplicated mapping
```



-------------------------------------------------------------------
## dm-verity

It maintains a hash tree (Merkle tree) of the whole devices, and add a light-weight
hash checking on each block's first loading into page-cache.
  https://source.android.com/security/verifiedboot/dm-verity
  Documentation/admin-guide/device-mapper/verity.rst
  https://www.kynetics.com/docs/2018/introduction-to-dm-verity-on-android/

hash function:
  https://en.wikipedia.org/wiki/Hash_function#Properties
hash digest (hash value/hashes):
  the fixed-sized output of hash function, usually much smaller than the variable-length input contents
cryptographic hash:
  hash function with following properties, so it can safely be used to validate the integraty
  * it is deterministic, meaning that the same message always results in the same hash
  * it is quick to compute the hash value for any given message
  * it is infeasible to generate a message that yields a given hash value
  * it is infeasible to find two different messages with the same hash value
  * a small change to a message should change the hash value so extensively that
    the new hash value appears uncorrelated with the old hash value (avalanche effect)
Merkle tree(hash tree) and against attacks (modify the content w/o being spoted) :
  https://en.wikipedia.org/wiki/Merkle_tree
  https://flawed.net.nz/2018/02/21/attacking-merkle-trees-with-a-second-preimage-attack/

-------------------------------------------------------------------
##How to debug kernel with gdb
basic steps  : kernel-source/Documentation/dev-tools/gdb-kernel-debugging.rst
don't forget : make scripts-gdb
a helper bash: as following, ensure a gdb server is running on locahost:1234, then pass the kernel-tree root
```
#!/bin/bash
echo "Don't forgot provide KDIR arg: " $1
KDIR=`realpath $1`
gdb-multiarch  \
    -ex "set debug auto-load on" \
    -ex "add-auto-load-safe-path $KDIR" \
    -ex "file $KDIR/vmlinux" \
    -ex "target remote :1234" \
    -ex "lx-symbols" \
    -ex "b start_kernel"
```

useful python commands:
  lx-dmesg,lx-cmdline,lx-lsmod,lx-fdtdump

-------------------------------------------------------------------
##After increase vpu reserved memory to 1GB, kernel hangs at "Starting kernel ...", Why?

The easiest way to debug is check the early printk result which is not shown before
serial driver is ready, there are few ways:
1.enable CONFIG_EARLY_PRINTK and pass "earlyprintk=serial,ttyS0,115200" commandline args
2.with gdb python command "lx-dmesg", but you need to run "make scripts-gdb".

Here I took a much difficult way, the gdb debugger instead of dmesg:

By ctrl+c at gdb after hangs, we found it panics by do_mem_abort() exception handler,
in that handler, there is a arg called pt_regs, we saw the $sp $pc register values of the
exception process, by trying jump *0x??? to the pc then "set $pc=0x???" and "set $sp=0x???"
we recovered the callstack rising exception.
```
#0  0xffffffc010511e80 in _find_next_bit (invert=<optimized out>, start=0, nbits=<optimized out>, addr2=<optimized out>, addr1=<optimized out>) at lib/find_bit.c:39
#1  find_next_zero_bit (addr=0xffffffc011013ea0, size=18446743799116824600, offset=<optimized out>) at lib/find_bit.c:79
#2  0xffffffc010adb0fc in default_idle_call () at kernel/sched/idle.c:94
#3  0xffffffc0102f23ac in cma_alloc (cma=0xffffffc011013ea0, count=18446743799116824600, align=<optimized out>, no_warn=<optimized out>) at mm/cma.c:447
#4  0xffffffc0122aed40 in cma_areas ()
```

but the callstack seems to be corrupted, so we reproduced it again with an presumed breakpoint at cma_alloc.
```
#0  cma_alloc (cma=0xffffffc0122aed40 <cma_areas+232>, count=64, align=6, no_warn=false) at mm/cma.c:428
#1  0xffffffc010190074 in dma_alloc_from_contiguous (dev=<optimized out>, count=<optimized out>, align=<optimized out>, no_warn=<optimized out>) at ./include/linux/dma-contiguous.h:66
#2  0xffffffc010f445d0 in dma_atomic_pool_init () at kernel/dma/remap.c:132
#3  0xffffffc01008565c in do_one_initcall (fn=0xffffffc010f4456c <dma_atomic_pool_init>) at init/main.c:939
#4  0xffffffc010f311b8 in do_initcall_level (level=<optimized out>) at ./include/linux/compiler.h:310
#5  do_initcalls () at init/main.c:1015
#6  do_basic_setup () at init/main.c:1032
#7  kernel_init_freeable () at init/main.c:1194
#8  0xffffffc010ad2eac in kernel_init (unused=<optimized out>) at init/main.c:1110
#9  0xffffffc010087348 in ret_from_fork () at arch/arm64/kernel/entry.S:1169
```
then single step through the code we confirm it's this first call into cma_alloc triggered the problem.
it's allocting from dma_contiguous_default_area, at pfn 0x10ff000 and 4K pages(16MB), but with bitmap NULL.
we notice the address is:
```
 p dma_contiguous_default_area
$6 = (struct cma *) 0xffffffc0122aed40 <cma_areas+232>
```
so we reproduce it again with a watch point added to see who is generating it, turns out to be:
```
#0  0xffffffc010f55594 in cma_init_reserved_mem (base=<optimized out>, size=<optimized out>, order_per_bit=0, name=0xffffffc010dac670 "reserved", res_cma=0xffffffc01229f360 <dma_contiguous_default_area>) at mm/cma.c:218
#1  0xffffffc010f5584c in cma_declare_contiguous (base=72997666816, size=16777216, limit=73014444032, alignment=4194304, order_per_bit=0, fixed=96, name=0xffffffc010dac670 "reserved", res_cma=0xffffffc01229f360 <dma_contiguous_default_area>) at mm/cma.c:363
#2  0xffffffc010f43da0 in dma_contiguous_reserve_area (size=<optimized out>, base=<optimized out>, limit=<optimized out>, res_cma=0xffffffc01229f360 <dma_contiguous_default_area>, fixed=<optimized out>) at kernel/dma/contiguous.c:168
#3  0xffffffc010f43eb4 in dma_contiguous_reserve (limit=73014444032) at kernel/dma/contiguous.c:138
#4  0xffffffc010f35580 in arm64_memblock_init () at arch/arm64/mm/init.c:433
#5  0xffffffc010f333d4 in setup_arch (cmdline_p=<optimized out>) at arch/arm64/kernel/setup.c:315
#6  0xffffffc010f30b20 in start_kernel () at init/main.c:598
#7  0x0000000000000000 in ?? ()
```
from the code of cma_init_reserved_mem(), it really didn't "init" a cma, most of init is done in cma_activate_area()
later on when buddy allocator is ready, cma_init_reserved_areas() will call cma_activate_area() on all cma.
Note cma_init_reserved_areas function is registered as initcall by core_initcall(cma_init_reserved_areas);
but there is no error check on it.
```
#0  cma_init_reserved_areas () at mm/cma.c:152
#1  0xffffffc01008565c in do_one_initcall (fn=0xffffffc010f552e8 <cma_init_reserved_areas>) at init/main.c:939
#2  0xffffffc010f311b8 in do_initcall_level (level=<optimized out>) at ./include/linux/compiler.h:310
#3  do_initcalls () at init/main.c:1015
#4  do_basic_setup () at init/main.c:1032
#5  kernel_init_freeable () at init/main.c:1194
#6  0xffffffc010ad2eac in kernel_init (unused=<optimized out>) at init/main.c:1110
#7  0xffffffc010087348 in ret_from_fork () at arch/arm64/kernel/entry.S:1169
```


