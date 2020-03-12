
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
    struct dma_fence* moving: Fence set when BO is moving
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

# ttm_bo_mmap

vma->vm_pgoff is the fake-offset leads to ttm_buffer_object behind it.
ttm_bo_vm_ops was installed to vma->vm_ops, among which ttm_bo_vm_fault() is the magic one.

# ttm_bo_vm_fault

this one is meant to insert pfn and thus setup page table for the missing/faulting page
being accessed by user-process.






