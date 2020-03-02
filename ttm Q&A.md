
# TTM, GEM, DRM
https://en.wikipedia.org/wiki/Direct_Rendering_Manager
https://en.wikipedia.org/wiki/Graphics_Core_Next

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
	                  to setup IOMMU mapping for GPU (including allocate virt-addr on device side & setup maaping)
	                  and tt->dma_address[] will be the GPU-side address.
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

# what does bo->mem.start means ?

inside ttm_bo_mem_space(called by ttm_bo_validate), we can see that the mem_manager specified
by mem->mem_type will finally call ttm_mem_type_manager::get_node() to allocate mem.start.
this function has an input arg "const struct ttm_place *place" specifies where to allocate
from, one example is ttm_bo_man_get_node() which call DRM MM (range allocator) to do allocation.

AMDGPU defined 2 ttm_mem_type_managers to do such "range allocation" for GTT & VRAM.

inside ttm_bo_mem_space(), we can see get_node() will be skiped for TTM_PL_SYSTEM type of memory,
actually no ttm_mem_type_manager::func to be called for TTM_PL_SYSTEM type. because 


# what is ttm_buffer_object
/include/drm/ttm/ttm_bo_api.h

first it's derived from "struct drm_gem_object", which has reservation object (dma_resv) associated.
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

## ttm_bo_validate()
Changes placement and caching policy of the buffer object according proposed placement.

check if we need to actually move the buffer (otherwise nothing needs to be done)
ttm_bo_mem_compat():  just check if mem already in required placement
	                  done by check if mem's (start, start+num_pages) falls inside place's (fpfn,lpfn)
	                  the check considered that lpfn can be zero to present no limit.
	                  and also checks the placement flags are also the same about caching












this api make sure the bo's content was 
