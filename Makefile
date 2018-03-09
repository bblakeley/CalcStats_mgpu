NVCC = /usr/local/cuda/bin/nvcc
NVCC_FLAGS = -g -G -Xcompiler -Wall -arch=sm_60	## Requires -arch=sm_60 flag to perform Atomics on double precision arrays
LIBRARIES = -L/usr/local/cuda/lib -lcufft 
INCLUDES = -I/usr/local/cuda/samples/common/inc -I/usr/local/cuda/inc

main.exe: CalcStats_mgpu.cu
	$(NVCC) $(NVCC_FLAGS) $^ -o $@ $(INCLUDES) $(LIBRARIES)

clean:
	rm -f *.o *.exe
