
# TTM, GEM, DRM
https://en.wikipedia.org/wiki/Direct_Rendering_Manager
https://en.wikipedia.org/wiki/Graphics_Core_Next

# GART/GTT     : IOMMU used by AGP/PCIe graphics cards.
https://en.wikipedia.org/wiki/Graphics_address_remapping_table
# Aperture     : system memory made available to AGP/PCIe graphics cards by GART/GTT.
https://en.wikipedia.org/wiki/Accelerated_Graphics_Port#APERTURE
# fence/barrier: (partialy/explicitly) order things happened in time
https://en.wikipedia.org/wiki/Memory_barrier

this pertains to parallel execution. like the multi-threading in high-level language,
order is ensured by advance concepts like mutex/semophor, but when the work/job is
done by low-level hardwares capable of queue input works and execute them in parallel,
the order must be implemented by a more simple/explicit method. fence is invented
for that purpose, it's designed for:

1. being attached to buffer/work/job
2. indicating finished/un-finished states
3. being on-shot, only one transition from un-finished to finished is allowed on it.

on-shot feature is important and makes the design/imlpementation/usecase/usage much simpler.
also you can re-use it by re-initialize, thus also no loose in flexibility.
so fence is like a new synchronize primitive invented for all HWs, not just for CPU.

reservation object is building RW-lock mechanism based on fence.


# memory types that TTM handles

TTM_PL_SYSTEM   0: systemRAM-based, not GPU addressible
TTM_PL_TT       1: systemRAM-based, with GPU address/GTT
TTM_PL_VRAM     2: video-onCardRAM-based, with no CPU side address/shadow

# what ttm means?

ttm is not about VRAM, ttm is for system RAM with possible GTT/IOMMU mappings thus accessible to GPU too.
it has both CPU side pages(in ttm_tt) and possibly GPU side address/mapping/binding (mm_node).

pure VRAM is much simpler than ttm, no ttm_tt is required and only GPU side mm_node is enough.

ttm_bo_move_ttm

# What is ttm_tt
src: drivers/gpu/drm/ttm/ttm_tt.c

struct ttm_tt:
    This is a structure holding the pages, caching- and aperture binding status
    for a buffer object that isn't backed by fixed (VRAM / AGP) memory.
    so it's backed by system memory, and also accessible to GPU if "bound"
    (aperture binding means GART/IOMMU mapping)

the major states of a ttm_tt:
enum {
	tt_bound,       : ttm_backend_func::bind() executed successfully, checking amdgpu_ttm_backend_bind
	                  we can see it binds pages into GART page tables so GPU can access it.
	                  
	                  there is a generic fallback ttm_populate_and_map_pages() which using dma_map_page()
	                  to setup system IOMMU mapping for GPU (including allocate virt-addr on device side & setup maaping)
	                  and tt->dma_address[] will be the GPU-side address.
	                  
	                  But for amdgpu, it provides its own bind() callback - amdgpu_ttm_backend_bind, which handles
	                  special cases (late binding) and amdgpu's GART hardware.
	                  
	tt_unbound,     :
	tt_unpopulated, : no pages allocated yet.
} state;


there is maximum one fixed tt for each bo, created by ttm_tt_create() when:
    1.ttm_bo_handle_move_mem(), moving bo to non-VRAM(tt) places
    2.ttm_bo_evict(), when no placement was returned by ttm_bo_driver::evict_flags(). after ttm_bo_pipeline_gutting is called
    3.ttm_bo_validate(), when bo->mem is SYSTEM.



# what is ttm_place
check amdgpu_bo_placement_from_domain() in /drivers/gpu/drm/amd/amdgpu/amdgpu_object.c
we can see that for different (RAM) placement fpfn are page frame numbers start from zero,
thus it's local to the specific RAM location/places, together with flags (TTM_PL_FLAG_xxx)
they determine the true place of the RAM.

the most strange fact is that fpfn is zero even for CPU domain(system RAM). so we know that
bo->mem.start also lives in this zero-based local pfn domain.

# what is ttm_mem_reg
Structure indicating the placement and space resources used by a buffer object.

    unsigned long start;
    void *mm_node;

mm_node is a opeque pointer usually pointing to a drm_mm_node, but it can be derived type or an array.
start only meaningful when mm_node is nor null. and also start/start+size cannot represent the true
location of the mem, thus this kind of representation is almost useless/obsoleted, mm_node is the only
meaningful way to represent the true location of mem.

both start/mm_node are only meaningful for particular mem_type/ttm_mem_type_manager::func, so TTM framework accesses
start/mm_node mainly by this ttm_mem_type_manager::func callback, get_node/put_node

for example, amdgpu_vram_mgr_func is able to allocate multiple dis-continuous mm_nodes thus becomes more complex than
what a simple start/size pair can represent. amdgpu_gtt_mgr_func, on the other hand, use AMDGPU_BO_INVALID_OFFSET to
delay the real allocation until GPU needs to access it.

# what does bo->mem.start means ?

inside ttm_bo_mem_space(called by ttm_bo_validate), we can see that the mem_manager specified
by mem->mem_type will finally call ttm_mem_type_manager::get_node() to allocate mem.start.
this function has an input arg "const struct ttm_place *place" specifies where to allocate
from, one example is ttm_bo_man_get_node() which call DRM MM (range allocator) to do allocation.

in amdgpu_vram_mgr_new(amdgpu's get_node callback for VRAM type), we see that the allocation
can be non-contiguous if TTM_PL_FLAG_CONTIGUOUS is not present, in that case, mem.start is zero
and mem->mm_node points to node array, each node has multiple pages allocated in discontinous way.

in amdgpu_gtt_mgr_new(amdgpu's get_node callback for GTT type), we see it's a dummy allocation,
mem->mm_node->node.start and mem->start are both AMDGPU_BO_INVALID_OFFSET. the reason behind it is
simply that GTT bind or address space is scarce resource, it should be allocated only when GPU is
really about to access it (deferred allocation, on use rather than on create).


# ttm_mem_reg_is_pci

TTM_MEMTYPE_FLAG_FIXED:     yes
TTM_MEMTYPE_FLAG_CMA:       no
TTM_PL_SYSTEM:              no

TTM_MEMTYPE_FLAG_MAPPABLE:  depending on caching flags
    TTM_PL_FLAG_CACHED:      no
    otherwise         :      yes



# why there is no ttm_mem_type_manager for SYSTEM type mem

amdgpu_init_mem_type() did not install ttm_mem_type_manager::func callback for TTM_PL_SYSTEM.
inside ttm_bo_mem_space(), we can see get_node() will be skiped for TTM_PL_SYSTEM type of memory.
every call to ttm_mem_type_manager::func was skipped for TTM_PL_SYSTEM type actually.

This is because ttm_mem_reg is designed for GPU side address space in VRAM/GTT, there is no such
needs for TTM_PL_SYSTEM. and ttm_tt was designed to handle system ram backed (not backed by fixed (VRAM / AGP) memory).



# what is ttm_buffer_object

/include/drm/ttm/ttm_bo_api.h

enum ttm_bo_type
ttm_bo_type_device:
    These are 'normal' buffers that can be mmapped by user space.
    Each of these bos occupy a slot in the device address space,
    that can be used for normal vm operations.

ttm_bo_type_kernel:
    These buffers are like ttm_bo_type_device buffers,
    but they cannot be accessed from user-space. For kernel-only use.

ttm_bo_type_sg:
    Buffer made from dmabuf sg table shared with another driver.


it's derived from "struct drm_gem_object", which has reservation object (dma_resv) associated.
and also support fake-offset-based user-space mmap, dmabuf import/export.

second, it has following data: 
    struct ttm_mem_reg   mem: describing current placement
	                    void *mm_node;                  Memory manager node
	                    unsigned long start;            the placement pfn offset
	                    unsigned long size;             Requested size of memory region
	                    unsigned long num_pages;        Actual size of memory region in pages
	                    uint32_t page_alignment;        the alignment in unit of pages, of the start pfn
	                    uint32_t mem_type;
	                    uint32_t placement;             TTM_PL_FLAG_xxx, together with "start"
	                                                    we now where the BO exactly is.
	                    
	                    struct ttm_bus_placement bus;       Placement on io bus accessible to the CPU
	                        	void		*   addr;       mapped virtual address (CPU)
	                            phys_addr_t	    base;       bus base address (GPU addr)
	                            unsigned long	size;       size in byte
	                            unsigned long	offset;     offset from the base address
	                            bool		    is_iomem;   is this io memory ?
	                            bool		    io_reserved_vm; 
	                            uint64_t        io_reserved_count;

    struct ttm_tt*       ttm: TTM structure holding system pages
    bool             evicted: Whether the object was evicted without user-space knowing.
    struct dma_fence* moving: Fence set when BO is moving, this fence is setup by ttm_bo_pipeline_move/ttm_bo_move_accel_cleanup
                              and this fence is also the write fence of the moving dest.
    uint64_t          offset: The current GPU offset

and major supported operations:

===========================================================================================
# KEYFEATURE: Validate/Relocate

# ttm_bo_validate()
Changes placement and caching policy of the buffer object according proposed placement.

This is the most powerful ttm operation, it relocate the buffer between different
memory types: 

check if we need to actually move the buffer (otherwise nothing needs to be done)
ttm_bo_mem_compat():  just check if mem already in required placement
	                  done by check if mem's (start, start+num_pages) falls inside place's (fpfn,lpfn)
	                  the check consider zero lpfn to present no limit. but as we know, these checks
	                  are kind of meaningless in amdgpu code since fpfn==lpfn==0 for every placement.
	                  and mm_node represent multiple dis-continuous nodes thus mem->start and mem->start+mem->size
	                  cannot truely represent the memory location anymore, thus these checks are
	                  made meaningless deliberately by setting fpfn==lpfn==0.
	                  
	                  so it also checks the placement flags to see if they matches in
	                  caching config & mem_type, this check is more meaningful.

if current place in mem is not compatible with requirements, move it by ttm_bo_move_buffer


#-ttm_bo_move_buffer()

#--ttm_bo_mem_space()
allocate GPU side memory space (VRAM/GTT) address, and ttm_bo_add_move_fence()

#--ttm_bo_handle_move_mem(): 
    call ttm_bo_move_ttm() when both old/new mem are system ram based, thus only need to re-bind GTT
    call bdev->driver->move or ttm_bo_move_memcpy when there is at least one of old/new mem is VRAM backed.

#-----ttm_bo_move_memcpy
move by CPU-based copying. basically it maps VRAM's AGP/PCI physical address into CPU's virtual address space then copy.

KEY operations done:

wait GPU/CPU finish access to the bo, ttm_bo_wait()
map VRAM based bo into kernel: ttm_mem_reg_ioremap
    get physical address of the bo : ttm_mem_io_reserve/bdev->driver->io_mem_reserve/amdgpu_ttm_io_mem_reserve
    map into CPU address space     :ioremap_wc/ioremap_nocache
do the copy: ttm_copy_ttm_io_page/ttm_copy_io_page
release the mapping: ttm_mem_reg_iounmap

#-----ttm_bo_move_ttm
pre-assumption     : this function handles only ttm backed bo, thus
                          1. both old/new mem is of type TTM_PL_SYSTEM/TTM_PL_TT.
                          2. ttm_tt must exists in bo
semantics function  : switch the bo between TTM_PL_SYSTEM and TTM_PL_TT, also change cache flags.

for TTM_PL_TT     => TTM_PL_SYSTEM, it's just about release GTT binding
    ttm_bo_wait             wait for GPU to finish the access
    ttm_tt_unbind           GTT unbind/unmapping 
    ttm_bo_free_old_node    release the GPU side address space i.e. the mm_node

for TTM_PL_SYSTEM => TTM_PL_TT, it's just about do a new GTT binding
    just call ttm_tt_bind() on new_mem

for TTM_PL_TT     => TTM_PL_TT, it's the combination of realease old GTT binding and do a new one
    the combine of above two ops, first TT=>SYSTEM, then SYSTEM->TT

#----amdgpu_bo_move()
    VRAM   => SYSTEM amdgpu_move_vram_ram()
    SYSTEM => VRAM   amdgpu_move_ram_vram()
    VRAM   => VRAM   amdgpu_move_blit()

##---------amdgpu_move_vram_ram

amdgpu_move_vram_ram() uses GPU to move, so the RAM/ttm_tt has to be bound to GTT before accessible by GPU:
1.allocate memory region from GTT address space by calling ttm_bo_mem_space() with TTM_PL_FLAG_TT
2.allocate system-ram backed pages and bind them to GTT by calling ttm_tt_bind()
3.instruct GPU to do the copy by calling amdgpu_move_blit(), inside amdgpu_ttm_copy_mem_to_mem, we can see
  
  the code considered the possibility of multiple disjoint mem_nodes and issues multiple copy op.
  
  it generates a serias OPs with params in a job description then submit the job to the ring buffer for GPU to execute.
  
  it consider the possibility of AMDGPU_BO_INVALID_OFFSET for src or dst mem, this means a deferred GTT address space
  allocation was using for src/dst mem, in this case the copy-code keep the deferred allocation strategy and only make
  a temporary mapping window large enough for copy operation only.

4.wait for all reader/write to complete (by calling ttm_bo_wait) before release old bo->mem (by ttm_tt_unbind/ttm_bo_free_old_node).
5.make sure new mem is accessible to GPU if not of TTM_PL_SYSTEM type (by ttm_tt_bind) and then reset bo->mem to new mem.

##---------amdgpu_move_ram_vram
amdgpu_move_ram_vram() also uses GPU to move, thus the old mem must be be bound to GTT before accessible by GPU:
1.allocate GTT memory region (actually deferred allocation)
2.bind the SYSTEM ttm_tt to GTT mem just allocated by calling ttm_bo_move_ttm 
3.instruct GPU to do the copy by calling amdgpu_move_blit()

##---------amdgpu_move_blit
amdgpu_move_blit() emit copy operations/cmds into job, then submit job to GPU
to execute async, and:
     1. pass-in reservation object for GPU to wait before start its work.
     2. return a fence as a way for sync, this fence will be signaled by GPU automatically.

ttm_bo_pipeline_move() will be invoked with this fence.

##---------ttm_bo_pipeline_move
Function for pipelining accelerated moves. Either free the (src/old) memory immediately or hang it on a temporary buffer object.

This function shows how GPU jobs are cooperated with CPU side asynchronously, when a buffer is delivered to GPU-side,
GPU is taking a ownership of the src buffer, after move operation on CPU side returned:

    1.the src buffer should be invisible to CPU side and only accessible to GPU side,
      and should be freed after GPU completed it's access. 
      this is done by CPU side deferred destrocution queue and a GPU-fence(name it as GF).
      
      in detail, build a temporary ghost bo with (old_ttm + GPU_copyfence) attached,
      and then ttm_bo_put it, if the fence in resv is not signaled yet, it will not be deleted
      in the ttm_bo_put().
      
      instead ttm_bo_put/ttm_bo_release/ttm_bo_cleanup_refs_or_queue() logic will add it into the ddestroy (deferred destroy) queue,
      a delayed workqueue will be triggered at 1/100 second interval and test resv of each deferred bo (by dma_resv_test_signaled_rcu),
      if success, it means GPU has done the copy and it can be deleted safely then.

    2.the dst/to/new mem should be in "writing" state thus preventing other "writer"/"reader" to access.
      this is done by also add GPU-fence to dst buffer's reservation object as exclusive fence.

      in detail, copy new_mem into bo->mem, thus from now on, bo is referring new place but
      maybe not readable until the explicit fence in reservation object are signaled.(thus any read-operation
      should be preceded by exclusive fence wait, this also applicable to GPU).

      so it should be the one doing the job who wait_for/test fences, and it should be waited/tested exactly before
      the actual read/write operation to reduce the latency.

## fence
https://lwn.net/Articles/510125/

all those function are async, trigger GPU to move and emit a fence to GPU, the fence will also be
returned and added as exclusive into bo->base.resv(drm_gem_object's reservation object).

thus any other R&W operation to the bo will wait for the fence (e.g. using ttm_bo_wait()).
https://youtu.be/HpmzJGHqObs?t=365

===========================================================================================
# KEYFEATURE: Mmap to user-space

# basic execution flow

1.get fake offset
    user-space:   DRM_IOCTL_MODE_MAP_DUMB
    kernel-space: drm_mode_mmap_dumb_ioctl() / dev->driver->dumb_map_offset /  drm_gem_dumb_map_offset
    
    first the fake offset needs to be created by drm_vma_offset_add, then it was returned to user-space.
    this operation seems to be done each time drm_mode_mmap_dumb_ioctl() was called but actually it
    check for duplicate calling and ensure only one fake-offset is allocated for a drm bo.

    note ttm_bo_init_reserved() also calls drm_vma_offset_add.

2.mmap
    user-space:   mmap from the fake-offset
    kernel-space: register mmap callback in file_operations, inside mmap, call drm_vma_offset_lock_lookup/drm_vma_offset_exact_lookup_locked/drm_vma_offset_unlock_lookup
      to find the drm_gem_object by the fake-offset passed in, then setup the pfns into page-table in vma corresponding to that gem object.

The best way to mmap is use pagefault handler, so the pfn only setup when pagefault happens. inside pagefault handler,
driver can trigger the copy process and wait/retry until the copy has completed, then setup pfn after that.
    
# ttm_bo_mmap

vma->vm_pgoff is the fake-offset leads to ttm_buffer_object behind it.
ttm_bo_vm_ops was installed to vma->vm_ops, among which ttm_bo_vm_fault() is the magic one.

# ttm_bo_vm_fault

this one is meant to insert pfn and thus setup page table for the missing/faulting page
being accessed by user-process.

there are two different ways to do that depending bo->mem.bus.is_iomem:

1.bo->mem.bus.is_iomem is true: the bo is VRAM backed and currently mapped in IOMEM space
2.bo->mem.bus.is_iomem is false: the bo is TTM_TT backed and currently populated thus avaliable through ttm->pages

bo driver can decide which path to go in fault_reserve_notify().

for example, amdgpu_fault_reserve_notify only triggers the move by calling ttm_bo_validate() when VRAM is not visible.
and ttm_bo_validate() will setup bo->mem to the destination place when successfully return, thus the actually vma mapping
setup code knows to get the pfn from ttm_tt->pages rather than calling io_mem_pfn() callback.


===========================================================================================
# KEYFEATURE on DMABuf/PRIME fd sharing: break the device boundary

sharing buffer with other devices looks like a simple stuff, just passing system pointer between devices.
actually it's not the correct way, because relying on system pointer means something not absolute necessary:
 1. CPU can & need to access it (not necessary)
 2. CPU needs to synchronize with HW devices sharing the buffer. (not necessary)
 3. CPU/user-space process also needs to manage the life cycle of the buffer since it has pointer.

DMABuf (PRIME fd) is designed for a better/standard/advanced way to implement that w/o relying on system pointer.

libDRM/BO API is enough if no need to cross device boundary, but if we want to cross device boundary, DMABuf/PRIME fd is the only choice.

obviously VRAM based bo cannot be exported/accessed by other devices, it have to be on SYSRAM/visible_VRAM for sharing.

callbacks in struct drm_driver:
.prime_handle_to_fd = drm_gem_prime_handle_to_fd,
.prime_fd_to_handle = drm_gem_prime_fd_to_handle,
.gem_prime_export = amdgpu_gem_prime_export,
.gem_prime_import = amdgpu_gem_prime_import,
.gem_prime_get_sg_table = amdgpu_gem_prime_get_sg_table,
.gem_prime_import_sg_table = amdgpu_gem_prime_import_sg_table,
.gem_prime_vmap = amdgpu_gem_prime_vmap,
.gem_prime_vunmap = amdgpu_gem_prime_vunmap,
.gem_prime_mmap = amdgpu_gem_prime_mmap,

one fact is, once the bo is related to a DMABuf fd, either through export or import, it must be accessible to others (not invisible VRAM)
and can no longer moves if someone attached to it. in this case the ttm_bo/ttm_tt is "SG" type.

for this type of ttm, 

===========================================================================================
# KEYFEATURE on DMABuf sharing: export PRIME fd
under DRM framework, just call drm_gem_prime_handle_to_fd, which is very robust.
amdgpu overrides some ops to make sure the ttm bo was pinned at correct location when
sharing_it_with/it_was_attached_by other devices/CPU. this also means, in this case
we cannot move it around unless we do that with fence holding, especially for write/update
dmabuf, we can duplicate a copy to VRAM with write fence holded, but we must be sure
to copy it back before release the fence, otherwise no one can read it.


	export_and_register_object
    	dev->driver->gem_prime_export(obj, flags);
    	    amdgpu_gem_prime_export               : install following dma_buf_ops 
               	struct dma_buf_ops amdgpu_dmabuf_ops 
               		.attach = amdgpu_dma_buf_map_attach,=======================
	                .detach = amdgpu_dma_buf_map_detach,=======================
	                
    	                in addition to drm_gem_map_attach,
	                    this pair of overrides moves the bo into good place and pin it there.
	                    
               		    amdgpu_bo_pin(bo, AMDGPU_GEM_DOMAIN_GTT);// prevent moving

	                .map_dma_buf = drm_gem_map_dma_buf,
	                .unmap_dma_buf = drm_gem_unmap_dma_buf,
	                .release = drm_gem_dmabuf_release,
	                
	                .begin_cpu_access = amdgpu_dma_buf_begin_cpu_access,=======
	                    
	                    in addition to drm_gem_map_attach,
	                    also moves the bo into good place and pin it there.

	                .mmap = drm_gem_dmabuf_mmap,
	                .vmap = drm_gem_dmabuf_vmap,
	                .vunmap = drm_gem_dmabuf_vunmap,

when sharing DMABuf among possible multiple processes/parties, reservation_object/fences are used to sync between them.
so before you want to write to it, you must aquire execlusive fence, and only release it when you finished writting to
it, for our case, this means, if you want our HW device to write/update it, we must ensure following sequence:

1.add execlusive fence to the buffer.
2.move it to VRAM and trigger HW to update it.
3.return buffer to user-space app, app shares it with other device.
4.other device will import it on demand of user app.
4.other device as reader waiting on the fence before access (they don't know the processing is actually doing on a copy in VRAM).
5.our HW finished the processing and tells the driver by interrupt.
6.driver copy the data back to the SYSREM identified by sg_table.
7.signal the fence to allow other device start access.

what if the buffer is not sharing with other device? in that case we don't have to copy it back to SYSRAM.

===========================================================================================
# KEYFEATURE on DMABuf sharing: import PRIME fd


when importing DMABuf fd, we must use ttm_bo_type_sg, so:

* ttm_tt_create() sets TTM_PAGE_FLAG_SG flag before calling bdev->driver->ttm_tt_create()
* ttm_bo_driver::ttm_tt_create() callback will allocate ttm_dma_tt based tt and init it with ttm_sg_tt_init()
* ttm_sg_tt_init() calls ttm_sg_tt_alloc_page_directory() which internally allocate dma_address[] array based on bo->num_pages
  otherwise, it calls ttm_dma_tt_alloc_page_directory which also allocate pages[] array along with dma_address[] array
  because it will use it when "populate", but for sg based tt, the memory is already allocated and no need to "populate"/"unpopulate"
* ttm_bo_driver::ttm_tt_populate() callback will not allocate pages for SG type tt, but only create pages to represent them






drm_driver.prime_fd_to_handle = drm_gem_prime_fd_to_handle
    dev->driver->gem_prime_import
        amdgpu_gem_prime_import
            drm_gem_prime_import
                drm_gem_prime_import_dev
                    dma_buf_attach
                        dmabuf->ops->attach
                            amdgpu_dma_buf_map_attach
                                drm_gem_map_attach
                                amdgpu_bo_reserve
                                    __ttm_bo_reserve                : Locks a buffer object for validation
                                        dma_resv_lock(bo->base.resv 

                    dma_buf_map_attachment
                        dmabuf->ops->map_dma_buf
                            drm_gem_map_dma_buf
                                obj->dev->driver->gem_prime_get_sg_table
                                    amdgpu_gem_prime_get_sg_table()
                                        drm_prime_pages_to_sg(bo->tbo.ttm->pages, npages)
                                dma_map_sg_attrs

                    dev->driver->gem_prime_import_sg_table  //
                        amdgpu_gem_prime_import_sg_table    // Imports shared DMA buffer memory (sg_table) exported by another device
                            amdgpu_bo_create with AMDGPU_GEM_DOMAIN_CPU/ttm_bo_type_sg/
                        	bo->tbo.sg = sg;
                        	bo->tbo.ttm->sg = sg;

===========================================================================================
# KEYFEATURE on imported BO: user-space access


===========================================================================================
# KEYFEATURE on imported BO: move to VRAM


so ttm_bo_type_sg means 



# API:ttm_bo_device_init

int ttm_bo_device_init(struct ttm_bo_device *bdev,  // return value
		       struct ttm_bo_driver *driver,        // callback ttm bo driver
		       struct address_space *mapping,       // drm inode address_space, for evict/swap-out 
		       bool need_dma32)                     // if system ram backed bo needs DMA32 type

struct ttm_bo_driver is callbacks customize ttm bo driver's behaviour:

static struct ttm_bo_driver amdgpu_bo_driver = {
	.ttm_tt_create = &amdgpu_ttm_tt_create,             // constructor of ttm_buffer_object, driver can constructe container of ttm bo as derived
	.ttm_tt_populate = &amdgpu_ttm_tt_populate,         // ttm_tt_populate() rely on this to allocate pages for back the SYSTEM/GTT type BO
	.ttm_tt_unpopulate = &amdgpu_ttm_tt_unpopulate,     // release pages
	.invalidate_caches = &amdgpu_invalidate_caches,     // only used when bo is evicted (usually don't need to care)
	.init_mem_type = &amdgpu_init_mem_type,             // setup ttm_mem_type_manager for TTM_PL_SYSTEM/TTM_PL_TT/TTM_PL_VRAM/ ...
	                                                       the manager is responsible for non-system-RAM based mem allocation get_node/put_node 
	                                                       
	.eviction_valuable = amdgpu_ttm_bo_eviction_valuable, // Check with the driver if it is valuable to evict a BO to make room for a certain placement.
	.evict_flags = &amdgpu_evict_flags,
	.move = &amdgpu_bo_move,                            // GPU accellerated move
	.verify_access = &amdgpu_verify_access,             //  just call drm_vma_node_verify_access
	.move_notify = &amdgpu_bo_move_notify,
	.release_notify = &amdgpu_bo_release_notify,
	.fault_reserve_notify = &amdgpu_bo_fault_reserve_notify,
	.io_mem_reserve = &amdgpu_ttm_io_mem_reserve,       // only useful if the VRAM-backed BO mem was needed to be accessed by CPU
	.io_mem_free = &amdgpu_ttm_io_mem_free,
	.io_mem_pfn = amdgpu_ttm_io_mem_pfn,
	.access_memory = &amdgpu_ttm_access_memory,         // ???
	.del_from_lru_notify = &amdgpu_vm_del_from_lru_notify
};

		int amdgpu_ttm_init(struct amdgpu_device *adev)       
	/* No others user of address space so set it to 0 */
	r = ttm_bo_device_init(&adev->mman.bdev,
			       &amdgpu_bo_driver,
			       adev->ddev->anon_inode->i_mapping,
			       dma_addressing_limited(adev->dev));
	if (r) {
		DRM_ERROR("failed initializing buffer object driver(%d).\n", r);
		return r;
	}
	adev->mman.initialized = true;

	/* We opt to avoid OOM on system pages allocations */
	adev->mman.bdev.no_retry = true;

	/* Initialize VRAM pool with all of VRAM divided into pages */
	r = ttm_bo_init_mm(&adev->mman.bdev, TTM_PL_VRAM, adev->gmc.real_vram_size >> PAGE_SHIFT);
	if (r) {
		DRM_ERROR("Failed initializing VRAM heap.\n");
		return r;
	}

ttm_mem_io_reserve_vm
ttm_mem_reg_ioremap
ttm_bo_kmap














int ttm_pool_populate(struct ttm_tt *ttm, struct ttm_operation_ctx *ctx)
{
	struct ttm_mem_global *mem_glob = ttm->bdev->glob->mem_glob;
	unsigned i;
	int ret;

	if (ttm->state != tt_unpopulated)
		return 0;

	if (ttm_check_under_lowerlimit(mem_glob, ttm->num_pages, ctx))
		return -ENOMEM;

	ret = ttm_get_pages(ttm->pages, ttm->num_pages, ttm->page_flags,
			    ttm->caching_state);
	if (unlikely(ret != 0)) {
		ttm_pool_unpopulate_helper(ttm, 0);
		return ret;
	}

	for (i = 0; i < ttm->num_pages; ++i) {
		ret = ttm_mem_global_alloc_page(mem_glob, ttm->pages[i],
						PAGE_SIZE, ctx);
		if (unlikely(ret != 0)) {
			ttm_pool_unpopulate_helper(ttm, i);
			return -ENOMEM;
		}
	}

	if (unlikely(ttm->page_flags & TTM_PAGE_FLAG_SWAPPED)) {
		ret = ttm_tt_swapin(ttm);
		if (unlikely(ret != 0)) {
			ttm_pool_unpopulate(ttm);
			return ret;
		}
	}

	ttm->state = tt_unbound;
	return 0;
}
EXPORT_SYMBOL(ttm_pool_populate);









