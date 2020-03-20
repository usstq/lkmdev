/*
for transfer file into simic virtual machine through physical memory reserved area directly
after compile this tool on linux inside simic, use following simics scrips to trigger the transfer



read-configuration afterbootE0

$a=/home/hddl/hd2/simics-5/yocto/WW46/kernel-source/drivers/misc/vpusmm/vpusmmx_driver.ko
tbh.soc.phys_mem.load-file $a 0x1184800000
@simenv.a=os.stat(simenv.a).st_size
tbh.console0.con.input "./devmem-rx 0x1184800000 " + $a + " vpusmmx_driver.ko\n"
tbh.console0.con.input "insmod ./vpusmmx_driver.ko"



*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/time.h>
#include <unistd.h>

#include <immintrin.h>
#include <smmintrin.h>
//  CopyFrame( )
//
//  COPIES VIDEO FRAMES FROM USWC MEMORY TO WB SYSTEM MEMORY VIA CACHED BUFFER
//    ASSUMES PITCH IS A MULTIPLE OF 64B CACHE LINE SIZE, WIDTH MAY NOT BE

typedef		unsigned int		UINT;
#define		CACHED_BUFFER_SIZE	4096	

char CacheBlock[CACHED_BUFFER_SIZE] __attribute__((aligned(64)));

void	CopyFrame( void * pSrc, void * pDest, void * pCacheBlock, 
					UINT width, UINT height, UINT pitch )
{
	__m128i		x0, x1, x2, x3;
	__m128i		*pLoad;
	__m128i		*pStore;
	__m128i		*pCache;
	UINT		x, y, yLoad, yStore;
	UINT		rowsPerBlock;
	UINT		width64;
	UINT		extraPitch;
	

	rowsPerBlock = CACHED_BUFFER_SIZE / pitch;
	width64 = (width + 63) & ~0x03f;
	extraPitch = (pitch - width64) / 16;

	pLoad  = (__m128i *)pSrc;
	pStore = (__m128i *)pDest;

	//  COPY THROUGH 4KB CACHED BUFFER
	for( y = 0; y < height; y += rowsPerBlock  )
	{
		//  ROWS LEFT TO COPY AT END
		if( y + rowsPerBlock > height )
			rowsPerBlock = height - y;

		pCache = (__m128i *)pCacheBlock;

		_mm_mfence();				
		
		// LOAD ROWS OF PITCH WIDTH INTO CACHED BLOCK
		for( yLoad = 0; yLoad < rowsPerBlock; yLoad++ )
		{
			// COPY A ROW, CACHE LINE AT A TIME
			for( x = 0; x < pitch; x +=64 )
			{
				x0 = _mm_stream_load_si128( pLoad +0 );
				x1 = _mm_stream_load_si128( pLoad +1 );
				x2 = _mm_stream_load_si128( pLoad +2 );
				x3 = _mm_stream_load_si128( pLoad +3 );

				_mm_store_si128( pCache +0,	x0 );
				_mm_store_si128( pCache +1, x1 );
				_mm_store_si128( pCache +2, x2 );
				_mm_store_si128( pCache +3, x3 );

				pCache += 4;
				pLoad += 4;
			}
		}

		_mm_mfence();

		pCache = (__m128i *)pCacheBlock;

		// STORE ROWS OF FRAME WIDTH FROM CACHED BLOCK
		for( yStore = 0; yStore < rowsPerBlock; yStore++ )
		{
			// copy a row, cache line at a time
			for( x = 0; x < width64; x +=64 )
			{
				x0 = _mm_load_si128( pCache );
				x1 = _mm_load_si128( pCache +1 );
				x2 = _mm_load_si128( pCache +2 );
				x3 = _mm_load_si128( pCache +3 );

				_mm_stream_si128( pStore,	x0 );
				_mm_stream_si128( pStore +1, x1 );
				_mm_stream_si128( pStore +2, x2 );
				_mm_stream_si128( pStore +3, x3 );

				pCache += 4;
				pStore += 4;
			}

			pCache += extraPitch;
			pStore += extraPitch;
		}
	}
}


int main(int argc, char * argv[])
{
    struct timeval start, end;
    double mtime, seconds, useconds; 
    int fd;
    int n,N=1;
    FILE * fp=NULL;
    off_t    offset;
    size_t   size;
    size_t   act_size;
    size_t   total_size;
    char *   targetfile;
    void * p;
    char * mem;
    int write_to_file = 0;
    int use_trick=0;
    
    if(argc < 2){
        printf("Usage: devmem3 r|w offset size targetfile\n");
        exit(1);
    }
    
    write_to_file = argv[1][0]=='w'?1:0;
    
    offset = strtoll(argv[2], NULL, 0);
    size   = strtoll(argv[3], NULL, 0);
    targetfile = argc >=5 ? argv[4]:NULL;
    N = atoi(getenv("N")?:"1");
    use_trick = atoi(getenv("T")?:"0");
    
    if(targetfile){
        fp = fopen(targetfile, write_to_file?"wb":"rb");
        if(!fp){
            printf("%s Open failed\n", targetfile);
            exit(1);
        }
    }else{
        fp = write_to_file?stdout:stdin;
    }
    
    fd = open("/dev/mem", O_RDWR|O_SYNC);
    if(fd < 0){
        printf("/dev/mem Open failed\n");
        exit(1);
    }
    
    
    p = mmap(NULL, ((size+4095)/4096)*4096, write_to_file? PROT_READ:PROT_WRITE, MAP_SHARED, fd, (offset/4096)*4096);
    if(p == MAP_FAILED){
        printf("mmap(size=%zu, offset=%ld ... ) failed\n", size, offset);
        exit(1);
    }

    fprintf(stderr, "Successfully mapped /dev/mem @0x%lx, size=%lu\r\n", offset, size);

    mem = malloc(size);
    if(!mem){
        printf("malloc %zu bytes failed\n", size);
        exit(1);
    }

    gettimeofday(&start, NULL);
    for(n=0;n<N;n++){
        if(!write_to_file){
            if((act_size=fread(p + (offset%4096), size,1, fp)) != 1){
                printf("fread failed (size=%zu, act_size=%zu\n", size,act_size);
                exit(1);
            }
        }else{
            if(use_trick)
                CopyFrame(p + (offset%4096), mem, CacheBlock, 4096, size/4096, 4096);
            else
                memcpy(mem, p + (offset%4096), size);
            if((act_size=fwrite(mem, size,1, fp)) != 1){
                printf("fwrite failed (size=%zu, act_size=%zu\n", size,act_size);
                exit(1);
            }
        }
    }

    free(mem);

    gettimeofday(&end, NULL);
    seconds  = end.tv_sec  - start.tv_sec;
    useconds = end.tv_usec - start.tv_usec;
    mtime = ((seconds) * 1000 + useconds/1000.0) + 0.5;
    fprintf(stderr, "Elapsed time: %.1f milliseconds   %.1fMB/s\n", mtime, (double)N*(double)size/mtime/1024.0);
    
    fclose(fp);
    printf("%zu bytes from physical mem 0x%lx is written to %s\n", size, offset, targetfile);
    return 0;
}



