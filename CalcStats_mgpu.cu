// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <complex.h>

// includes, project
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <cufft.h>
#include <cuComplex.h>
#include <helper_functions.h>
#include <helper_cuda.h>
#include <timer.h>

// include parameters for DNS
#include "DNS_PARAMETERS.h"

#define size_Stats (nt/n_save + 1)
#define nu ( 1.0/((double)Re) )
#define RAD 1


int divUp(int a, int b) { return (a + b - 1) / b; }

__device__
int idxClip(int idx, int idxMax){
	return idx > (idxMax - 1) ? (idxMax - 1) : (idx < 0 ? 0 : idx);
}

__device__
int flatten(int col, int row, int stack, int width, int height, int depth){
	return idxClip(stack, depth) + idxClip(row, height)*depth + idxClip(col, width)*depth*height;
	// Note: using column-major indexing format
}

void displayDeviceProps(int numGPUs){
	int i, driverVersion = 0, runtimeVersion = 0;

	for( i = 0; i<numGPUs; ++i)
	{
		cudaSetDevice(i);

		cudaDeviceProp deviceProp;
		cudaGetDeviceProperties(&deviceProp, i);
		printf("  Device name: %s\n", deviceProp.name);

		cudaDriverGetVersion(&driverVersion);
		cudaRuntimeGetVersion(&runtimeVersion);
		printf("  CUDA Driver Version / Runtime Version          %d.%d / %d.%d\n", driverVersion/1000, (driverVersion%100)/10, runtimeVersion/1000, (runtimeVersion%100)/10);
		printf("  CUDA Capability Major/Minor version number:    %d.%d\n", deviceProp.major, deviceProp.minor);
	
		char msg[256];
		SPRINTF(msg, "  Total amount of global memory:                 %.0f MBytes \n",
				(float)deviceProp.totalGlobalMem/1048576.0f);
		printf("%s", msg);

		printf("  (%2d) Multiprocessors, (%3d) CUDA Cores/MP:     %d CUDA Cores\n",
			   deviceProp.multiProcessorCount,
			   _ConvertSMVer2Cores(deviceProp.major, deviceProp.minor),
			   _ConvertSMVer2Cores(deviceProp.major, deviceProp.minor) * deviceProp.multiProcessorCount);

		printf("\n");
	}

	return;
}

void writeDouble(double v, FILE *f)  {
	fwrite((void*)(&v), sizeof(v), 1, f);

	return;
}

void writeStats( const char* name, double *in, double val ) {
	int i;
	char title[0x100];
	// snprintf(title, sizeof(title), SaveLocation, (int) NX, (int) Re, name, val);
	snprintf(title, sizeof(title), SaveLocation, name, val);
	printf("Writing data to %s \n", title);
	FILE *out = fopen(title, "wb");
	for (i = 0; i <= size_Stats; ++i){
		writeDouble(in[i], out);
	}
	
	fclose(out);
}

double readDouble(FILE *f){
	double v;

	int flag = fread((void*)(&v), sizeof(double), 1, f);

	if(flag == 1)
		return v;
	else{
		return 0;
	}
}

void loadData(int nGPUs, int *start_x, int *NX_per_GPU, const int iter, const char *name, double **var)
{ // Function to read in velocity data into multiple GPUs

	int i, j, k, n, idx, N;
	char title[0x100];
	snprintf(title, sizeof(title), DataLocation, name, iter);
	printf("Reading data from %s \n", title);
	FILE *file = fopen(title, "rb");
	N = readDouble(file)/sizeof(double);
	printf("The size of N is %d\n",N);
        for (n = 0; n < nGPUs; ++n){
        	printf("Reading data for GPU %d\n",n);
            for (i = 0; i < NX_per_GPU[n]; ++i){
                for (j = 0; j < NY; ++j){
                    for (k = 0; k < NZ; ++k){
                            idx = k + 2*NZ2*j + 2*NZ2*NY*i;	
                            var[n][idx] = readDouble(file);
                    }
                }
            }
        }

	fclose(file);

	return;
}

void splitData(int numGPUs, int size, int *size_per_GPU, int *start_idx) {
	int i, n;
	if(size % numGPUs == 0){
		for (i=0;i<numGPUs;++i){
			size_per_GPU[i] = size/numGPUs;
			start_idx[i] = i*size_per_GPU[i];              
		}
	}
	else {
		printf("Warning: number of GPUs is not an even multiple of the data size\n");
		n = size/numGPUs;
		for(i=0; i<(numGPUs-1); ++i){
			size_per_GPU[i] = n;
			start_idx[i] = i*size_per_GPU[i];
		}
		size_per_GPU[numGPUs-1] = n + size % numGPUs;
		start_idx[numGPUs-1] = (numGPUs-1)*size_per_GPU[numGPUs-2];
	}
}

void importFields_mgpu(int nGPUs, int *start_x, int *NX_per_GPU, const int iter, double **h_u, double **h_v, double **h_w, double **h_z, cufftDoubleReal **u, cufftDoubleReal **v, cufftDoubleReal **w, cufftDoubleReal **z)
{	// Import data from file
	int n;

	// Import data from file to CPU memory
	loadData(nGPUs, start_x, NX_per_GPU, iter, "u", h_u);
	loadData(nGPUs, start_x, NX_per_GPU, iter, "v", h_v);
	loadData(nGPUs, start_x, NX_per_GPU, iter, "w", h_w);
	loadData(nGPUs, start_x, NX_per_GPU, iter, "z", h_z);

	// Copy data from host to device (from CPU memory distributed across GPU memory)
	printf("Copy results to GPU memory...\n");
	for(n=0; n<nGPUs; ++n){
		cudaSetDevice(n);
		cudaDeviceSynchronize();
		checkCudaErrors( cudaMemcpyAsync(u[n], h_u[n], sizeof(complex double)*NX_per_GPU[n]*NY*NZ2, cudaMemcpyDefault) );
		checkCudaErrors( cudaMemcpyAsync(v[n], h_v[n], sizeof(complex double)*NX_per_GPU[n]*NY*NZ2, cudaMemcpyDefault) );
		checkCudaErrors( cudaMemcpyAsync(w[n], h_w[n], sizeof(complex double)*NX_per_GPU[n]*NY*NZ2, cudaMemcpyDefault) );
		checkCudaErrors( cudaMemcpyAsync(z[n], h_z[n], sizeof(complex double)*NX_per_GPU[n]*NY*NZ2, cudaMemcpyDefault) );
	}

}

void importF(const int iter, const char *name, double *var)
{ // Function to read in velocity data
	int i;
	double N;

// Read in data
	char title[0x100];
	// snprintf(title, sizeof(title), Datalocation, (int) NX, (int) Re, name, iter);	// Concatenate filepath and filename
	snprintf(title, sizeof(title), DataLocation, name, iter);
	printf("Reading data from %s \n", title);
	FILE *file = fopen(title, "rb");	// Open file for reading binary data
	N = readDouble(file)/sizeof(double);	// number of double elements in the file
	printf("The size of N is %d\n", (int)N);
	for (i = 0; i < (int)N; ++i){
		var[i] = readDouble(file);		// read in each data point in series
	}

	fclose(file);

	return;
}

__global__
void waveNumber_kernel(double *waveNum)
{   // Creates the wavenumber vectors used in Fourier space
	const int i = blockIdx.x * blockDim.x + threadIdx.x;

	if (i >= NX) return;

	if (i < NX/2)
		waveNum[i] = (double)i;
	else
		waveNum[i] = (double)i - NX;

	return;
}

void initializeWaveNumbers(int nGPUs, double **waveNum)
{    // Initialize wavenumbers in Fourier space

	int n;
	for (n = 0; n<nGPUs; ++n){
		cudaSetDevice(n);

		waveNumber_kernel<<<divUp(NX,TX), TX>>>(waveNum[n]);
	}

	printf("Wave domain setup complete..\n");

	return;
}

void plan2dFFT(int nGPUs, int *NX_per_GPU, size_t *worksize_f, size_t *worksize_i, cufftDoubleComplex **workspace, cufftHandle *plan, cufftHandle *invplan){
// This function plans a 2-dimensional FFT to operate on the X and Y directions (assumes X-direction is contiguous in memory)
    int result;

    int n;
    for(n = 0; n<nGPUs; ++n){
        cudaSetDevice(n);

        //Create plan for 2-D cuFFT, set cuFFT parameters
        int rank = 2;
        int size[] = {NY,NZ};           
        int inembed[] = {NY,2*NZ2};         // inembed measures distance between dimensions of data
        int onembed[] = {NY,NZ2};     // Uses half the domain for a R2C transform
        int istride = 1;                        // istride is distance between consecutive elements
        int ostride = 1;
        int idist = NY*2*NZ2;                      // idist is the total length of one signal
        int odist = NY*NZ2;
        int batch = NX_per_GPU[n];                        // # of 2D FFTs to perform

        // Create empty plan handles
        cufftCreate(&plan[n]);
        cufftCreate(&invplan[n]);

        // Disable auto allocation of workspace memory for cuFFT plans
        result = cufftSetAutoAllocation(plan[n], 0);
        if ( result != CUFFT_SUCCESS){
                printf("CUFFT error: cufftSetAutoAllocation failed on line %d, Error code %d\n", __LINE__, result);
        return; }
        result = cufftSetAutoAllocation(invplan[n], 0);
        if ( result != CUFFT_SUCCESS){
                printf("CUFFT error: cufftSetAutoAllocation failed on line %d, Error code %d\n", __LINE__, result);
        return; }

        // Plan Forward 2DFFT
        result = cufftMakePlanMany(plan[n], rank, size, inembed, istride, idist, onembed, ostride, odist, CUFFT_D2Z, batch, &worksize_f[n]);
        if ( result != CUFFT_SUCCESS){
            fprintf(stderr, "CUFFT error: cufftPlanforward 2D failed");
            printf(", Error code %d\n", result);
        return; 
        }

        // Plan inverse 2DFFT
        result = cufftMakePlanMany(invplan[n], rank, size, onembed, ostride, odist, inembed, istride, idist, CUFFT_Z2D, batch, &worksize_i[n]);
        if ( result != CUFFT_SUCCESS){
            fprintf(stderr, "CUFFT error: cufftPlanforward 2D failed");
            printf(", Error code %d\n", result);
        return; 
        }

        printf("The workspace size required for the forward transform is %lu.\n", worksize_f[n]);
        printf("The workspace size required for the inverse transform is %lu.\n", worksize_i[n]);

        // Assuming that both workspaces are the same size (seems to be generally true), then the two workspaces can share an allocation
        // Allocate workspace memory
        checkCudaErrors( cudaMalloc(&workspace[n], worksize_f[n]) );

        // Set cuFFT to use allocated workspace memory
        result = cufftSetWorkArea(plan[n], workspace[n]);
        if ( result != CUFFT_SUCCESS){
                printf("CUFFT error: ExecD2Z failed on line %d, Error code %d\n", __LINE__, result);
        return; }
        result = cufftSetWorkArea(invplan[n], workspace[n]);
        if ( result != CUFFT_SUCCESS){
                printf("CUFFT error: ExecD2Z failed on line %d, Error code %d\n", __LINE__, result);
        return; }    

        }

    return;
}

void plan1dFFT(int nGPUs, cufftHandle *plan){
// This function plans a 1-dimensional FFT to operate on the Z direction (assuming Z-direction is contiguous in memory)
    int result;

    int n;
    for(n = 0; n<nGPUs; ++n){
        cudaSetDevice(n);
        //Create plan for cuFFT, set cuFFT parameters
        int rank = 1;               // Dimensionality of the FFT - constant at rank 1
        int size[] = {NX};          // size of each rank
        int inembed[] = {0};            // inembed measures distance between dimensions of data
        int onembed[] = {0};       // For complex to complex transform, input and output data have same dimensions
        int istride = NZ2;                        // istride is distance between consecutive elements
        int ostride = NZ2;
        int idist = 1;                     // idist is the total length of one signal
        int odist = 1;
        int batch = NZ2;                      // # of 1D FFTs to perform (assuming data has been transformed previously in the Z-Y directions)

        // Plan Forward 1DFFT
        result = cufftPlanMany(&plan[n], rank, size, inembed, istride, idist, onembed, ostride, odist, CUFFT_Z2Z, batch);
        if ( result != CUFFT_SUCCESS){
            fprintf(stderr, "CUFFT error: cufftPlanforward failed");
        return; 
        }
    }
    
    return;
}

__global__
void scaleKernel_mgpu(int start_x, cufftDoubleReal *f)
{
	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if (( (i + start_x) >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten( i, j, k, NX, NY, 2*NZ2);

	f[idx] = f[idx] / ( (double)NX*NY*NZ );

	return;
}

__global__ 
void organizeData(cufftDoubleComplex *in, cufftDoubleComplex *out, int N, int j)
{// Function to grab non-contiguous chunks of data and make them contiguous

	const int k = blockIdx.x * blockDim.x + threadIdx.x;
	if(k >= NZ2) return;

	for(int i=0; i<N; ++i){

		// printf("For thread %d, indexing begins at local index of %d, which maps to temp at location %d\n", k, (k+ NZ*j), k);
		out[k + i*NZ2] = in[k + NZ2*j + i*NY*NZ2];

	}

	return;

}

void transpose_xy_mgpu(cufftDoubleComplex **src, cufftDoubleComplex **dst, cufftDoubleComplex **temp, int nGPUs)
{   // Transpose x and y directions (for a z-contiguous 1d array distributed across multiple GPUs)
	// This function loops through GPUs (instead of looping through all x,y) to do the transpose. Requires extra conversion to calculate the local index at the source location.
	// printf("Taking Transpose...\n");

	int n, j, local_idx_dst, dstNum;

   
	for(j=0; j<NY; ++j){
		for(n=0; n<nGPUs; ++n){
			cudaSetDevice(n); 

			dstNum = j*nGPUs/NY;

			// Open kernel that grabs all data 
			organizeData<<<divUp(NZ2,TX), TX>>>(src[n], temp[n], NX/nGPUs, j);

			local_idx_dst = n*NX/nGPUs*NZ2 + (j - dstNum*NY/nGPUs)*NZ2*NX;

			checkCudaErrors( cudaMemcpyAsync(&dst[dstNum][local_idx_dst], temp[n], sizeof(cufftDoubleComplex)*NZ2*NX/nGPUs, cudaMemcpyDeviceToDevice) );
		}
	}

	return;
}

void Execute1DFFT_Forward(cufftHandle plan, int NY_per_GPU, cufftDoubleComplex *f, cufftDoubleComplex *fhat)
{

	cufftResult result;
	// Loop through each slab in the Y-direction
	// Perform forward FFT
	for(int i=0; i<NY_per_GPU; ++i){
		result = cufftExecZ2Z(plan, &f[i*NZ2*NX], &fhat[i*NZ2*NX], CUFFT_FORWARD);
		if (  result != CUFFT_SUCCESS){
			fprintf(stderr, "CUFFT error: ExecZ2Z failed, error code %d\n",(int)result);
		return; 
		}       
	}

	return;
}

void Execute1DFFT_Inverse(cufftHandle plan, int NY_per_GPU, cufftDoubleComplex *fhat, cufftDoubleComplex *f)
{
	cufftResult result;

	// Loop through each slab in the Y-direction
	// Perform forward FFT
	for(int i=0; i<NY_per_GPU; ++i){
		result = cufftExecZ2Z(plan, &fhat[i*NZ2*NX], &f[i*NZ2*NX], CUFFT_INVERSE);
		if (  result != CUFFT_SUCCESS){
			fprintf(stderr, "CUFFT error: ExecZ2Z failed, error code %d\n",(int)result);
		return; 
		}       
	}

	return;
}

void forwardTransform(cufftHandle *p_1d, cufftHandle *p_2d, int nGPUs, int *NX_per_GPU, int *start_x, int *NY_per_GPU, int *start_y, cufftDoubleComplex **f_t, cufftDoubleComplex **temp, cufftDoubleReal **f )
{ // Transform from physical to wave domain

	int RESULT, n;

	// Take FFT in Z and Y directions
	for(n = 0; n<nGPUs; ++n){
		cudaSetDevice(n);

		RESULT = cufftExecD2Z(p_2d[n], f[n], (cufftDoubleComplex *)f[n]);
		if ( RESULT != CUFFT_SUCCESS){
			printf("CUFFT error: ExecD2Z failed on line %d, Error code %d\n", __LINE__, RESULT);
		return; }
		// printf("Taking 2D forward FFT on GPU #%2d\n",n);
	}

	// Transpose X and Y dimensions
	transpose_xy_mgpu((cufftDoubleComplex **)f, f_t, temp, nGPUs);

	// Take FFT in X direction (which has been transposed to what used to be the Y dimension)
	for(n = 0; n<nGPUs; ++n){
		cudaSetDevice(n);

		Execute1DFFT_Forward(p_1d[n], NY_per_GPU[n], f_t[n], (cufftDoubleComplex *)f[n]);
		// printf("Taking 1D forward FFT on GPU #%2d\n",n);
	}

	// Results remain in transposed coordinates

	// printf("Forward Transform Completed...\n");

	return;
}

void inverseTransform(cufftHandle *invp_1d, cufftHandle *invp_2d,  int nGPUs, int *NX_per_GPU, int *start_x, int *NY_per_GPU, int *start_y, cufftDoubleComplex **f_t, cufftDoubleComplex **temp, cufftDoubleComplex **f)
{ // Transform variables from wavespace to the physical domain 
	int RESULT, n;

	// Data starts in transposed coordinates, x,y flipped

	// Take FFT in X direction (which has been transposed to what used to be the Y dimension)
	for(n = 0; n<nGPUs; ++n){
		cudaSetDevice(n);
		Execute1DFFT_Inverse(invp_1d[n], NY_per_GPU[n], f[n], f_t[n]);
		// printf("Taking 1D inverse FFT on GPU #%2d\n",n);
	}

	// Transpose X and Y directions
	transpose_xy_mgpu(f_t, f, temp, nGPUs);

	for(n = 0; n<nGPUs; ++n){
		cudaSetDevice(n);
		// Take inverse FFT in Z and Y direction
		RESULT = cufftExecZ2D(invp_2d[n], f[n], (cufftDoubleReal *)f[n]);
		if ( RESULT != CUFFT_SUCCESS){
			printf("CUFFT error: ExecD2Z failed on line %d, Error code %d\n", __LINE__, RESULT);
		return; }
		// printf("Taking 2D inverse FFT on GPU #%2d\n",n);
	}

	for(n = 0; n<nGPUs; ++n){
		cudaSetDevice(n);
		const dim3 blockSize(TX, TY, TZ);
		const dim3 gridSize(divUp(NX_per_GPU[n], TX), divUp(NY, TY), divUp(NZ, TZ));

		scaleKernel_mgpu<<<gridSize, blockSize>>>(start_x[n], (cufftDoubleReal *)f[n]);
	}

	// printf("Scaled Inverse Transform Completed...\n");

	return;
}

/*
__global__
void surfaceIntegral_kernel(double *F, int w, int h, int d, double ref, double *Q, double *surfInt_Q) {
	extern __shared__ double s_F[];

	double dFdx, dFdy, dFdz, dChidx, dChidy, dChidz;

	// global indices
	const int i = blockIdx.x * blockDim.x + threadIdx.x; // column
	const int j = blockIdx.y * blockDim.y + threadIdx.y; // row
	const int k = blockIdx.z * blockDim.z + threadIdx.z; // stack
	if ((i >= w) || (j >= h) || (k >= d)) return;
	const int idx = flatten(i, j, k, w, h, d);
	// local width and height
	const int s_w = blockDim.x + 2 * RAD;
	const int s_h = blockDim.y + 2 * RAD;
	const int s_d = blockDim.z + 2 * RAD;
	// local indices
	const int s_i = threadIdx.x + RAD;
	const int s_j = threadIdx.y + RAD;
	const int s_k = threadIdx.z + RAD;
	const int s_idx = flatten(s_i, s_j, s_k, s_w, s_h, s_d);

	// Creating arrays in shared memory
	// Regular cells
	s_F[s_idx] = F[idx];

	//Halo Cells
	if (threadIdx.x < RAD) {
		s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] =
			F[flatten(i - RAD, j, k, w, h, d)];
		s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] =
			F[flatten(i + blockDim.x, j, k, w, h, d)];
	}
	if (threadIdx.y < RAD) {
		s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] =
			F[flatten(i, j - RAD, k, w, h, d)];
		s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] =
			F[flatten(i, j + blockDim.y, k, w, h, d)];
	}
	if (threadIdx.z < RAD) {
		s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] =
			F[flatten(i, j, k - RAD, w, h, d)];
		s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] =
			F[flatten(i, j, k + blockDim.z, w, h, d)];
	}

	__syncthreads();

	// Boundary Conditions
	// Making problem boundaries periodic
	if (i == 0){
		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] = 
			F[flatten(w, j, k, w, h, d)];
	}
	if (i == w - 1){
		s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] =
			F[flatten(0, j, k, w, h, d)];
	}

	if (j == 0){
		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] = 
			F[flatten(i, h, k, w, h, d)];
	}
	if (j == h - 1){
		s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] =
			F[flatten(i, 0, k, w, h, d)];
	}

	if (k == 0){
		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] = 
			F[flatten(i, j, d, w, h, d)];
	}
	if (k == d - 1){
		s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] =
			F[flatten(i, j, 0, w, h, d)];
	}

	// __syncthreads();

	// Calculating dFdx and dFdy
	// Take derivatives

	dFdx = ( s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] - 
		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

	dFdy = ( s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] - 
		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

	dFdz = ( s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] - 
		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] ) / (2.0*dx);

	__syncthreads();

	// Test to see if z is <= Zst, which sets the value of Chi
	s_F[s_idx] = (s_F[s_idx] <= ref); 

	// Test Halo Cells to form Chi
	if (threadIdx.x < RAD) {
		s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] <= ref);
		s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] <= ref);
	}
	if (threadIdx.y < RAD) {
		s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] <= ref);
		s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] <= ref);
	}
	if (threadIdx.z < RAD) {
		s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] <= ref);
		s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] <= ref);
	}

	__syncthreads();

	// Take derivatives
	dChidx = ( s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] - 
		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

	dChidy = ( s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] - 
		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] ) / (2.0*dx);
	
	dChidz = ( s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] - 
		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] ) / (2.0*dx);

	__syncthreads();

	// Compute Length contribution for each thread
	if (dFdx == 0 && dFdy == 0 && dFdz == 0){
		s_F[s_idx] = 0.0;
	}
	else if (dChidx == 0 && dChidy == 0 && dChidz == 0){
		s_F[s_idx] = 0.0;
	}
	else{
		s_F[s_idx] = -Q[idx]*(dFdx * dChidx + dFdy * dChidy + dFdz * dChidz) / sqrtf(dFdx * dFdx + dFdy * dFdy + dFdz * dFdz);
	}

	// __syncthreads();

	// Add length contribution from each thread into block memory
	if (threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0){
		double local_Q = 0.0;
		for (int q = 1; q <= blockDim.x; ++q) {
			for (int r = 1; r <= blockDim.y; ++r){
				for (int s = 1; s <= blockDim.z; ++s){
					int local_idx = flatten(q, r, s, s_w, s_h, s_d);
					local_Q += s_F[local_idx];
				}
			}
		}
		__syncthreads();
		atomicAdd(surfInt_Q, local_Q*dx*dx*dx);
	}

	return;
}

__global__
void multIk(cufftDoubleComplex *f, cufftDoubleComplex *fIk, double *waveNum, const int dir)
{	// Function to multiply the function fhat by i*k
	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ2)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ2);

	// i*k*(a + bi) = -k*b + i*k*a
	
// Create temporary variables to store real and complex parts
	double a = f[idx].x;
	double b = f[idx].y;

	if(dir == 1){ // Takes derivative in 1 direction (usually x)
		fIk[idx].x = -waveNum[i]*b/((double)NN);
		fIk[idx].y = waveNum[i]*a/((double)NN);
	}
	if(dir == 2){	// Takes derivative in 2 direction (usually y)
		fIk[idx].x = -waveNum[j]*b/((double)NN);
		fIk[idx].y = waveNum[j]*a/((double)NN);
	}
	if(dir == 3){
		fIk[idx].x = -waveNum[k]*b/((double)NN);
		fIk[idx].y = waveNum[k]*a/((double)NN);
	}

	return;
}


// __global__
// void multIk_inplace(cufftDoubleComplex *f, double *waveNum, const int dir)
// {	// Function to multiply the function fhat by i*k
// 	const int i = blockIdx.x * blockDim.x + threadIdx.x;
// 	const int j = blockIdx.y * blockDim.y + threadIdx.y;
// 	const int k = blockIdx.z * blockDim.z + threadIdx.z;
// 	if ((i >= NX) || (j >= NY) || (k >= NZ2)) return;
// 	const int idx = flatten(i, j, k, NX, NY, NZ2);

// 	// i*k*(a + bi) = -k*b + i*k*a
	
// // Create temporary variables to store real and complex parts
// 	double a = f[idx].x;
// 	double b = f[idx].y;

// 	if(dir == 1){ // Takes derivative in 1 direction (usually x)
// 		f[idx].x = -waveNum[i]*b/((double)NN);
// 		f[idx].y = waveNum[i]*a/((double)NN);
// 	}
// 	if(dir == 2){	// Takes derivative in 2 direction (usually y)
// 		f[idx].x = -waveNum[j]*b/((double)NN);
// 		f[idx].y = waveNum[j]*a/((double)NN);
// 	}
// 	if(dir == 3){
// 		f[idx].x = -waveNum[k]*b/((double)NN);
// 		f[idx].y = waveNum[k]*a/((double)NN);
// 	}

// 	return;
// }

__global__
void multIk2(cufftDoubleComplex *f, cufftDoubleComplex *fIk2, double *waveNum, const int dir)
{	// Function to multiply the function fhat by i*k
	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ2)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ2);

	// i*k*(a + bi) = -k*b + i*k*a

	if(dir == 1){ // Takes derivative in 1 direction (usually x)
		fIk2[idx].x = -waveNum[i]*waveNum[i]*f[idx].x/((double)NN);
		fIk2[idx].y = -waveNum[i]*waveNum[i]*f[idx].y/((double)NN);
	}
	if(dir == 2){	// Takes derivative in 2 direction (usually y)
		fIk2[idx].x = -waveNum[j]*waveNum[j]*f[idx].x/((double)NN);
		fIk2[idx].y = -waveNum[j]*waveNum[j]*f[idx].y/((double)NN);
	}
	if(dir == 3){
		fIk2[idx].x = -waveNum[k]*waveNum[k]*f[idx].x/((double)NN);
		fIk2[idx].y = -waveNum[k]*waveNum[k]*f[idx].y/((double)NN);
	}

	return;
}

// void fftDerivative(cufftHandle invp, double *waveNum, cufftDoubleComplex *fhat, cufftDoubleComplex *fphat, cufftDoubleReal *fp, int dir)
// {// Function to calculate derivatives of a function

// // Initialize result variable for error-checking
// 	cufftResult result;

// 	// Set kernel variables
// 	const dim3 blockSize(TX, TY, TZ);
// 	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ2, TZ));

// // Multiply complex function by i*k (derivative in Fourier Space)
// 	// This function also scales the field in preparation for the next transform
// 	multIk<<<gridSize, blockSize>>>(fhat, fphat, waveNum, dir);

// // Take inverse transform to get function back to physical space
// 	result = cufftExecZ2D(invp, fphat, fp );
// 	if (  result != CUFFT_SUCCESS){
// 		fprintf(stderr, "CUFFT error: ExecZ2D failed, error code %d\n",(int)result);
// 	return;	
// 	}

// 	return;
// }

void fftDer(cufftHandle p, cufftHandle invp, double *waveNum, cufftDoubleReal *f, cufftDoubleComplex *fhat, cufftDoubleReal *fp, int dir)
{// Function to calculate derivatives of a function

// Initialize result variable for error-checking
	cufftResult result;

	// Set kernel variables
	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ2, TZ));

// Take fourier transform to get function to wave space
	result = cufftExecD2Z(p, f, fhat );
	if (  result != CUFFT_SUCCESS){
		fprintf(stderr, "CUFFT error: ExecZ2D failed, error code %d\n",(int)result);
	return;	
	}

// Multiply complex function by i*k (derivative in Fourier Space)
	// This function also scales the field in preparation for the next transform
	multIk<<<gridSize, blockSize>>>(fhat, fhat, waveNum, dir);

// Take inverse transform to get function back to physical space
	result = cufftExecZ2D(invp, fhat, fp );
	if (  result != CUFFT_SUCCESS){
		fprintf(stderr, "CUFFT error: ExecZ2D failed, error code %d\n",(int)result);
	return;	
	}

	return;
}

void fft2ndDer(cufftHandle p, cufftHandle invp, double *waveNum, cufftDoubleReal *f, cufftDoubleComplex *fhat, cufftDoubleReal *fp, int dir)
{// Function to calculate derivatives of a function

// Initialize result variable for error-checking
	cufftResult result;

	// Set kernel variables
	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ2, TZ));

// Take fourier transform to get function to wave space
	result = cufftExecD2Z(p, f, fhat );
	if (  result != CUFFT_SUCCESS){
		fprintf(stderr, "CUFFT error: ExecZ2D failed, error code %d\n",(int)result);
	return;	
	}

// Multiply complex function by i*k (derivative in Fourier Space)
	// This function also scales the field in preparation for the next transform
	multIk2<<<gridSize, blockSize>>>(fhat, fhat, waveNum, dir);

// Take inverse transform to get function back to physical space
	result = cufftExecZ2D(invp, fhat, fp );
	if (  result != CUFFT_SUCCESS){
		fprintf(stderr, "CUFFT error: ExecZ2D failed, error code %d\n",(int)result);
	return;	
	}

	return;
}

void fft2ndDerivative(cufftHandle invp, double *waveNum, cufftDoubleComplex *fhat, cufftDoubleComplex *fphat, cufftDoubleReal *fp, int dir)
{// Function to calculate derivatives of a function

// Initialize result variable for error-checking
	cufftResult result;

	// Set kernel variables
	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ2, TZ));

// Multiply complex function by i*k (derivative in Fourier Space)
	// This function also scales the field in preparation for the next transform
	multIk2<<<gridSize, blockSize>>>(fhat, fphat, waveNum, dir);

// Take inverse transform to get function back to physical space
	result = cufftExecZ2D(invp, fphat, fp);
	if (  result != CUFFT_SUCCESS){
		fprintf(stderr, "CUFFT error: ExecZ2D failed, error code %d\n",(int)result);
	return;	
	}

	return;
}

__global__
void magnitude(cufftDoubleReal *f1, cufftDoubleReal *f2, cufftDoubleReal *f3, cufftDoubleReal *mag){
	// Function to calculate the magnitude of a 3D vector field

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	// Magnitude of a 3d vector field = sqrt(f1^2 + f2^2 + f3^2)

	mag[idx] = sqrt(f1[idx]*f1[idx] + f2[idx]*f2[idx] + f3[idx]*f3[idx]);

	return;

}

__global__
void mult3AndAdd(cufftDoubleReal *f1, cufftDoubleReal *f2, cufftDoubleReal *f3, cufftDoubleReal *f4, const int flag)
{	// Function to multiply 3 functions and add (or subtract) the result to a 4th function

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	if ( flag == 1 ){
		f4[idx] = f4[idx] + f1[idx]*f2[idx]*f3[idx];
	}
	else if ( flag == 0 ){
		f4[idx] = f4[idx] - f1[idx]*f2[idx]*f3[idx];
	}
	else{
		printf("Multipy and Add function failed: please designate 1 (plus) or 0 (minus).\n");
	}
		
		return;
}

__global__
void mult2AndAdd(cufftDoubleReal *f1, cufftDoubleReal *f2, cufftDoubleReal *f3, const int flag)
{	// Function to multiply 3 functions and add (or subtract) the result to a 4th function

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	if ( flag == 1 ){
		f3[idx] = f3[idx] + f1[idx]*f2[idx];
	}
	else if ( flag == 0 ){
		f3[idx] = f3[idx] - f1[idx]*f2[idx];
	}
	else{
		printf("Multipy and Add function failed: please designate 1 (plus) or 0 (minus).\n");
	}
		
		return;
}

__global__
void multiplyOrDivide(cufftDoubleReal *f1, cufftDoubleReal *f2, cufftDoubleReal *f3, const int flag){
	// This function either multiplies two functions or divides two functions, depending on which flag is passed. The output is stored in the first array passed to the function.

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	if ( flag == 1 ){
		f3[idx] = f1[idx]*f2[idx];
	}
	else if ( flag == 0 ){
		f3[idx] = f1[idx]/f2[idx];
	}
	else{
		printf("Multipy or Divide function failed: please designate 1 (multiply) or 0 (divide).\n");
	}

	return;
}

__global__
void calcTermIV_kernel(cufftDoubleReal *gradZ, cufftDoubleReal *IV){

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	IV[idx] = 1.0/(gradZ[idx]*gradZ[idx])*IV[idx];
		
	return;

}

void calcTermIV(cufftHandle p, cufftHandle invp, double *k, cufftDoubleReal *u, cufftDoubleReal *v, cufftDoubleReal *w, cufftDoubleReal *s, double *T4){
// Function to calculate the 4th term at each grid point in the dSigmadt equation
	//  The equation for Term IV is:
	// IV = -( nx*nx*dudx + nx*ny*dudy + nx*nz*dudz + ny*nx*dvdx + ny*ny*dvdy ...
	//  		+ ny*nz*dvdz  + nz*nx*dwdx + nz*ny*dwdy + nz*nz*dwdz), 
	// where nx = -dsdx/grads, ny = -dsdy/grads, nz = -dsdz/grads,
	//  and grads = sqrt(dsdx^2 + dsdy^2 + dsdz^2).
	

	// Allocate temporary variables
	cufftDoubleReal *dsdx, *dsdy, *dsdz, *grads;
	cufftDoubleComplex *temp_c;

	// cufftResult result;

	cudaMallocManaged(&dsdx, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&dsdy, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&dsdz, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&grads, sizeof(cufftDoubleReal)*NN);		// Variable to hold the magnitude of gradient of s as well as other temporary variables
	cudaMallocManaged(&temp_c, sizeof(cufftDoubleComplex)*NX*NY*NZ2);

	// Set kernel variables
	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ, TZ));

// Initialize T4 to zero
	cudaMemset(T4, 0.0, sizeof(double)*NX*NY*NZ);

// Calculate derivatives of scalar field
	// dsdx
	fftDer(p, invp, k, s, temp_c, dsdx, 1);
	// dsdy
	fftDer(p, invp, k, s, temp_c, dsdy, 2);
	// dsdz
	fftDer(p, invp, k, s, temp_c, dsdz, 3);

	// Approach: calculate each of the 9 required terms for Term IV separately and add them to the running total

// 1st term: nx*nx*dudx
	// Take derivative to get dudx
	fftDer(p, invp, k, u, temp_c, grads, 1);
	// Multiply by nx*nx and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdx, dsdx, grads, T4, 0);

// 2nd term: nx*ny*dudy
	// Take derivative to get dudy
	fftDer(p, invp, k, u, temp_c, grads, 2);
	// Multiply by nx*ny and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdx, dsdy, grads, T4, 0);

// 3rd term: nx*nz*dudz
	// Take derivative to get dudz
	fftDer(p, invp, k, u, temp_c, grads, 3);
	// Multiply by nx*nz and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdx, dsdz, grads, T4, 0);

// 4th term: ny*nx*dvdx
	// Take derivative to get dvdx
	fftDer(p, invp, k, v, temp_c, grads, 1);
	// Multiply by ny*nx and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdy, dsdx, grads, T4, 0);

// 5th term: ny*ny*dvdy
	// Take derivative to get dvdy
	fftDer(p, invp, k, v, temp_c, grads, 2);
	// Multiply by ny*ny and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdy, dsdy, grads, T4, 0);

// 6th term: ny*nz*dvdz
	// Take derivative to get dvdz
	fftDer(p, invp, k, v, temp_c, grads, 3);
	// Multiply by ny*nz and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdy, dsdz, grads, T4, 0);

// 7th term: nz*nx*dwdx
	// Take derivative to get dwdx
	fftDer(p, invp, k, w, temp_c, grads, 1);
	// Multiply by nz*nx and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdz, dsdx, grads, T4, 0);

// 8th term: nz*ny*dwdy
	// Take derivative to get dwdy
	fftDer(p, invp, k, w, temp_c, grads, 2);
	// Multiply by nz*ny and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdz, dsdy, grads, T4, 0);

// 9th term: nz*nz*dwdz
	// Take derivative to get dwdz
	fftDer(p, invp, k, w, temp_c, grads, 3);
	// Multiply by nz*nz and add to Term IV
	mult3AndAdd<<<gridSize, blockSize>>>(dsdz, dsdz, grads, T4, 0);

// Calculate grads
	magnitude<<<gridSize, blockSize>>>(dsdx, dsdy, dsdz, grads);

// Divide The sum of terms in T4 by grads^2
	calcTermIV_kernel<<<gridSize, blockSize>>>(grads, T4);

	cudaFree(dsdx);
	cudaFree(dsdy);
	cudaFree(dsdz);
	cudaFree(grads);
	cudaFree(temp_c);

	return;
}

__global__
void sum_kernel(cufftDoubleReal *f1, cufftDoubleReal *f2, cufftDoubleReal *f3, const int flag){
	// This kernel adds three functions, storing the result in the first array that was passed to it
	
	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	if ( flag == 1 ){
		f3[idx] = f1[idx] + f2[idx];
	}
	else if ( flag == 0 ){
		f3[idx] = f1[idx] - f2[idx];
	}
	else{
		printf("Sum kernel function failed: please designate 1 (add) or 0 (subtract).\n");
	}

	return;
}

__global__
void calcDiffusionVelocity_kernel(const double D, cufftDoubleReal *lapl_s, cufftDoubleReal *grads, cufftDoubleReal *diff_Vel){
// Function to calculate the diffusion velocity, given the diffusion coefficient, the laplacian of the scalar field, and the magnitude of the gradient of the scalar field
// The result of this is stored in the array holding |grads|
	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	diff_Vel[idx] = D*lapl_s[idx]/grads[idx];

	return;
}

void calcTermV(cufftHandle p, cufftHandle invp, double *waveNum, cufftDoubleReal *s, cufftDoubleReal *T5){
// Function to calculate the 5th term at each grid point in the dSigmadt equation
	//  The equation for Term V is:
	// V = -D*(dsdx2 + dsdy2 + dsdz2)/|grads| * ...
	//  		(d/dx(-nx) + d/dy(-nx) + d/dz(-nx), 
	// where nx = -dsdx/|grads|, ny = -dsdy/grads, nz = -dsdz/grads,
	//  and grads = sqrt(dsdx^2 + dsdy^2 + dsdz^2).
	

	// Allocate temporary variables
	cufftDoubleReal *dsdx, *dsdy, *dsdz;
	cufftDoubleComplex *temp_c;

	// cufftResult result;

	cudaMallocManaged(&dsdx, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&dsdy, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&dsdz, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&temp_c, sizeof(cufftDoubleComplex)*NX*NY*NZ2);

	// Set kernel variables
	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ, TZ));

// Calculate derivatives of scalar field
	// dsdx
	fftDer(p, invp, waveNum, s, temp_c, dsdx, 1);
	// dsdy
	fftDer(p, invp, waveNum, s, temp_c, dsdy, 2);
	// dsdz
	fftDer(p, invp, waveNum, s, temp_c, dsdz, 3);

// Calculate grads
	magnitude<<<gridSize, blockSize>>>(dsdx, dsdy, dsdz, T5);

// Calculate normal vectors
	// Divide dsdx by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdx, T5, dsdx, 0);
	// Divide dsdy by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdy, T5, dsdy, 0);
	// Divide dsdz by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdz, T5, dsdz, 0);

// Take derivative of normal vectors 
	fftDer(p, invp, waveNum, dsdx, temp_c, dsdx, 1);
	fftDer(p, invp, waveNum, dsdy, temp_c, dsdy, 2);
	fftDer(p, invp, waveNum, dsdz, temp_c, dsdz, 3);

// Sum the derivatives of normal vectors together to form divergence(n)
	sum_kernel<<<gridSize, blockSize>>>(dsdx, dsdy, dsdx, 1);
	sum_kernel<<<gridSize, blockSize>>>(dsdx, dsdz, dsdx, 1);			// dsdx is holding the divergence of the normal vector

// Form Laplacian(s)
	// Take second derivative of scalar field in the x direction - the Laplacian will be stored in dsdy
	fft2ndDer(p, invp, waveNum, s, temp_c, dsdy, 1);		// dsdy is a placeholder variable only - don't pay attention to the name!
	
	// Take second derivative in y direction
	fft2ndDer(p, invp, waveNum, s, temp_c, dsdz, 2);		// dsdz is also a temporary placeholder
	// Add the 2nd y derivative of s to the Laplacian term (stored in dsdy)
	sum_kernel<<<gridSize, blockSize>>>(dsdy, dsdz, dsdy, 1);
	
	// Take the second derivative in the z direction
	fft2ndDer(p, invp, waveNum, s, temp_c, dsdz, 3);
	// Add the 2nd z derivative of s to the Laplacian term (stored in dsdy)
	sum_kernel<<<gridSize, blockSize>>>(dsdy, dsdz, dsdy, 1);

// Calculate the diffusion velocity
	calcDiffusionVelocity_kernel<<<gridSize, blockSize>>>(-nu/((double)Sc), dsdy, T5, T5);

// Calculate Term V
	multiplyOrDivide<<<gridSize, blockSize>>>(T5, dsdx, T5, 1);

	cudaFree(dsdx);
	cudaFree(dsdy);
	cudaFree(dsdz);
	cudaFree(temp_c);

	return;
}

__global__
void calcTermVa_kernel(const double D, cufftDoubleReal *div_n, cufftDoubleReal *Va){
// Function to calculate the diffusion velocity, given the diffusion coefficient, the laplacian of the scalar field, and the magnitude of the gradient of the scalar field
// The result of this is stored in the array holding |grads|
	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	Va[idx] = -D*div_n[idx]*div_n[idx];

	return;
}

void calcTermVa(cufftHandle p, cufftHandle invp, double *waveNum, cufftDoubleReal *s, cufftDoubleReal *T5a){
// Function to calculate the decomposition of the 5th term at each grid point in the dSigmadt equation
	//  The equation for Term Va is:
	// Va = -D*(divergence(n))^2, 
	// where n = -dsdx/|grads|,
	

	// Allocate temporary variables
	cufftDoubleReal *dsdx, *dsdy, *dsdz;
	cufftDoubleComplex *temp_c;

	// cufftResult result;

	cudaMallocManaged(&dsdx, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&dsdy, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&dsdz, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&temp_c, sizeof(cufftDoubleComplex)*NX*NY*NZ2);

	// Set kernel variables
	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ, TZ));

// Calculate derivatives of scalar field
	// dsdx
	fftDer(p, invp, waveNum, s, temp_c, dsdx, 1);
	// dsdy
	fftDer(p, invp, waveNum, s, temp_c, dsdy, 2);
	// dsdz
	fftDer(p, invp, waveNum, s, temp_c, dsdz, 3);

// Calculate grads
	magnitude<<<gridSize, blockSize>>>(dsdx, dsdy, dsdz, T5a);

// Calculate normal vectors
	// Divide dsdx by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdx, T5a, dsdx, 0);
	// Divide dsdy by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdy, T5a, dsdy, 0);
	// Divide dsdz by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdz, T5a, dsdz, 0);

// Take derivative of normal vectors 
	fftDer(p, invp, waveNum, dsdx, temp_c, dsdx, 1);
	fftDer(p, invp, waveNum, dsdy, temp_c, dsdy, 2);
	fftDer(p, invp, waveNum, dsdz, temp_c, dsdz, 3);

// Zero out T5a
	cudaMemset(T5a, 0.0, sizeof(double)*NN);

// Sum the derivatives of normal vectors together to form divergence(n)
	sum_kernel<<<gridSize, blockSize>>>(T5a, dsdx, T5a, 1);
	sum_kernel<<<gridSize, blockSize>>>(T5a, dsdy, T5a, 1);
	sum_kernel<<<gridSize, blockSize>>>(T5a, dsdz, T5a, 1);			// T5a is now holding the divergence of the normal vector

// Calculate Term Va
	calcTermVa_kernel<<<gridSize, blockSize>>>(nu/((double)Sc), T5a, T5a);

	cudaFree(dsdx);
	cudaFree(dsdy);
	cudaFree(dsdz);
	cudaFree(temp_c);

	return;
}

__global__
void calcTermVb_kernel(const double D, cufftDoubleReal *Numerator, cufftDoubleReal *gradZ, cufftDoubleReal *div_n, cufftDoubleReal *Vb){

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || (j >= NY) || (k >= NZ)) return;
	const int idx = flatten(i, j, k, NX, NY, NZ);

	Vb[idx] = -D*Numerator[idx]/(gradZ[idx]*gradZ[idx])*div_n[idx];
		
	return;

}

void calcTermVb(cufftHandle p, cufftHandle invp, double *waveNum, cufftDoubleReal *s, cufftDoubleReal *T5b){
// Function to calculate the decomposition of the 5th term at each grid point in the dSigmadt equation
	//  The equation for Term Va is:
	// Va = -D*(divergence(n))^2, 
	// where n = -dsdx/|grads|,
	

	// Allocate temporary variables
	cufftDoubleReal *dsdx, *dsdy, *dsdz, *grads;
	cufftDoubleComplex *temp_c;

	// cufftResult result;

	cudaMallocManaged(&dsdx, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&dsdy, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&dsdz, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&grads, sizeof(cufftDoubleReal)*NN);
	cudaMallocManaged(&temp_c, sizeof(cufftDoubleComplex)*NX*NY*NZ2);		// Temporary variable that is passed to the fft derivative function for intermediate calculations

	// Set kernel variables
	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ, TZ));

///////////////////////////////////////////
	//Step 1: Calculate divergence of the normal vector
// Calculate derivatives of scalar field
	// dsdx
	fftDer(p, invp, waveNum, s, temp_c, dsdx, 1);
	// dsdy
	fftDer(p, invp, waveNum, s, temp_c, dsdy, 2);
	// dsdz
	fftDer(p, invp, waveNum, s, temp_c, dsdz, 3);

// Calculate grads
	magnitude<<<gridSize, blockSize>>>(dsdx, dsdy, dsdz, T5b);		// T5b now holds |grads|

// Calculate normal vectors
	// Divide dsdx by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdx, T5b, dsdx, 0);
	// Divide dsdy by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdy, T5b, dsdy, 0);
	// Divide dsdz by |grads|
	multiplyOrDivide<<<gridSize, blockSize>>>(dsdz, T5b, dsdz, 0);

// Take derivative of normal vectors 
	fftDer(p, invp, waveNum, dsdx, temp_c, dsdx, 1);
	fftDer(p, invp, waveNum, dsdy, temp_c, dsdy, 2);
	fftDer(p, invp, waveNum, dsdz, temp_c, dsdz, 3);

// Zero out T5a
	cudaMemset(T5b, 0.0, sizeof(double)*NN);

// Sum the derivatives of normal vectors together to form divergence(n)
	sum_kernel<<<gridSize, blockSize>>>(T5b, dsdx, T5b, 1);
	sum_kernel<<<gridSize, blockSize>>>(T5b, dsdy, T5b, 1);
	sum_kernel<<<gridSize, blockSize>>>(T5b, dsdz, T5b, 1);			// T5b is now holding the divergence of the normal vector

//////////////////////////////////////////////////////////////
	//Step 2: Calculate the numerator, grads*gradient(grads)
// Calculate |grads|
	// dsdx
	fftDer(p, invp, waveNum, s, temp_c, dsdx, 1);
	// dsdy
	fftDer(p, invp, waveNum, s, temp_c, dsdy, 2);
	// dsdz
	fftDer(p, invp, waveNum, s, temp_c, dsdz, 3);

// Calculate grads
	magnitude<<<gridSize, blockSize>>>(dsdx, dsdy, dsdz, grads);		// grads now holds |grads|

// Find the x derivative of |grads|
	fftDer(p, invp, waveNum, grads, temp_c, dsdz, 1);		// dsdz temporarily holds x derivative of |grads|
// Multiply dsdx and x derivative of |grads| and add to intermediate variable
	mult2AndAdd<<<gridSize, blockSize>>>(dsdx, dsdz, dsdx, 1);		// dsdx holds the current sum for this term

// Find the y derivative of |grads|
	fftDer(p, invp, waveNum, grads, temp_c, dsdz, 2);
// Multiply dsdy and y derivative of |grads| and add to intermediate variable
	mult2AndAdd<<<gridSize, blockSize>>>(dsdy, dsdz, dsdx, 1);

// Calculate dsdz
	fftDer(p, invp, waveNum, s, temp_c, dsdz, 3);			// Need to recalculate dsdz because the variable was used as a placeholder above
// Find the z derivative of |grads|
	fftDer(p, invp, waveNum, grads, temp_c, dsdy, 3);		// dsdy used as a placeholder for z derivative of |grads|
// Multiply dsdy and y derivative of |grads| and add to intermediate variable
	mult2AndAdd<<<gridSize, blockSize>>>(dsdy, dsdz, dsdx, 1);		// Multiplies dsdz and z derivative of |grads| and stores in dsdx variable

////////////////////////////////////////////////////////////////
	// Calculate Term Vb
	calcTermVb_kernel<<<gridSize, blockSize>>>(nu/((double)Sc), dsdx, grads, T5b, T5b);

	cudaFree(dsdx);
	cudaFree(dsdy);
	cudaFree(dsdz);
	cudaFree(grads);
	cudaFree(temp_c);

	return;
}

void calcSurfaceProps(cufftHandle p, cufftHandle invp, double *waveNum, cufftDoubleReal *u, cufftDoubleReal *v, cufftDoubleReal *w, cufftDoubleReal *z, double Zst, double *SA, double *T4, double *T5, double *T5a, double *T5b){
// Function to calculate surface quantities

	// Declare and allocate temporary variables
	double *temp;
	cudaMallocManaged(&temp, sizeof(double)*NN);

	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ, TZ));
	const size_t smemSize = (TX + 2*RAD)*(TY + 2*RAD)*(TZ + 2*RAD)*sizeof(double);

// Calculate surface area based on Zst
	surfaceArea_kernel<<<gridSize, blockSize, smemSize>>>(z, NX, NY, NZ, Zst, SA);
	cudaError_t err = cudaGetLastError();
	if (err != cudaSuccess) 
    printf("Error: %s\n", cudaGetErrorString(err));

// Calculate Term IV
	calcTermIV(p, invp, waveNum, u, v, w, z, temp);

	// Integrate TermIV over the flame surface (Refer to Mete's thesis for more info on the surface integration technique)
	surfaceIntegral_kernel<<<gridSize, blockSize, smemSize>>>(z, NX, NY, NZ, Zst, temp, T4);
	err = cudaGetLastError();
	if (err != cudaSuccess) 
    printf("Error: %s\n", cudaGetErrorString(err));

	cudaDeviceSynchronize();

// Calculate Term V
	calcTermV(p, invp, waveNum, z, temp);

	// Integrate TermV over the flame surface (Refer to Mete's thesis for more info on the surface integration technique)
	surfaceIntegral_kernel<<<gridSize, blockSize, smemSize>>>(z, NX, NY, NZ, Zst, temp, T5);
	err = cudaGetLastError();
	if (err != cudaSuccess) 
    printf("Error: %s\n", cudaGetErrorString(err));

	cudaDeviceSynchronize();

// Calculate Term Va
	calcTermVa(p, invp, waveNum, z, temp);

	// Integrate TermV over the flame surface (Refer to Mete's thesis for more info on the surface integration technique)
	surfaceIntegral_kernel<<<gridSize, blockSize, smemSize>>>(z, NX, NY, NZ, Zst, temp, T5a);
	err = cudaGetLastError();
	if (err != cudaSuccess) 
    printf("Error: %s\n", cudaGetErrorString(err));

	cudaDeviceSynchronize();

// Calculate Term Vb
	calcTermVb(p, invp, waveNum, z, temp);

	// Integrate TermV over the flame surface (Refer to Mete's thesis for more info on the surface integration technique)
	surfaceIntegral_kernel<<<gridSize, blockSize, smemSize>>>(z, NX, NY, NZ, Zst, temp, T5b);
	err = cudaGetLastError();
	if (err != cudaSuccess) 
    printf("Error: %s\n", cudaGetErrorString(err));

	cudaDeviceSynchronize();

	//Post-processing
	T4[0] = T4[0]/SA[0];
	T5[0] = T5[0]/SA[0];
	T5a[0] = T5a[0]/SA[0];
	T5b[0] = T5b[0]/SA[0];

	cudaFree(temp);

}
*/

// __global__
// void surfaceArea_kernel(double *F, int w, int h, int d, double ref, double *SA) {
// 	extern __shared__ double s_F[];

// 	double dFdx, dFdy, dFdz, dChidx, dChidy, dChidz;

// 	// global indices
// 	const int i = blockIdx.x * blockDim.x + threadIdx.x; // column
// 	const int j = blockIdx.y * blockDim.y + threadIdx.y; // row
// 	const int k = blockIdx.z * blockDim.z + threadIdx.z; // stack
// 	if ((i >= w) || (j >= h) || (k >= d)) return;
// 	const int idx = flatten(i, j, k, w, h, d);
// 	// local width and height
// 	const int s_w = blockDim.x + 2 * RAD;
// 	const int s_h = blockDim.y + 2 * RAD;
// 	const int s_d = blockDim.z + 2 * RAD;
// 	// local indices
// 	const int s_i = threadIdx.x + RAD;
// 	const int s_j = threadIdx.y + RAD;
// 	const int s_k = threadIdx.z + RAD;
// 	const int s_idx = flatten(s_i, s_j, s_k, s_w, s_h, s_d);

// 	// Creating arrays in shared memory
// 	// Regular cells
// 	s_F[s_idx] = F[idx];

// 	//Halo Cells
// 	if (threadIdx.x < RAD) {
// 		s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] =
// 			F[flatten(i - RAD, j, k, w, h, d)];
// 		s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] =
// 			F[flatten(i + blockDim.x, j, k, w, h, d)];
// 	}
// 	if (threadIdx.y < RAD) {
// 		s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] =
// 			F[flatten(i, j - RAD, k, w, h, d)];
// 		s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] =
// 			F[flatten(i, j + blockDim.y, k, w, h, d)];
// 	}
// 	if (threadIdx.z < RAD) {
// 		s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] =
// 			F[flatten(i, j, k - RAD, w, h, d)];
// 		s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] =
// 			F[flatten(i, j, k + blockDim.z, w, h, d)];
// 	}

// 	__syncthreads();

// 	// Boundary Conditions
// 	// Making problem boundaries periodic
// 	if (i == 0){
// 		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] = 
// 			F[flatten(w, j, k, w, h, d)];
// 	}
// 	if (i == w - 1){
// 		s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] =
// 			F[flatten(0, j, k, w, h, d)];
// 	}

// 	if (j == 0){
// 		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] = 
// 			F[flatten(i, h, k, w, h, d)];
// 	}
// 	if (j == h - 1){
// 		s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] =
// 			F[flatten(i, 0, k, w, h, d)];
// 	}

// 	if (k == 0){
// 		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] = 
// 			F[flatten(i, j, d, w, h, d)];
// 	}
// 	if (k == d - 1){
// 		s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] =
// 			F[flatten(i, j, 0, w, h, d)];
// 	}

// 	// __syncthreads();

// 	// Calculating dFdx and dFdy
// 	// Take derivatives

// 	dFdx = ( s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] - 
// 		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

// 	dFdy = ( s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] - 
// 		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

// 	dFdz = ( s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] - 
// 		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] ) / (2.0*dx);

// 	__syncthreads();

// 	// Test to see if z is <= Zst, which sets the value of Chi
// 	s_F[s_idx] = (s_F[s_idx] <= ref); 

// 	// Test Halo Cells to form Chi
// 	if (threadIdx.x < RAD) {
// 		s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] <= ref);
// 		s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] <= ref);
// 	}
// 	if (threadIdx.y < RAD) {
// 		s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] <= ref);
// 		s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] <= ref);
// 	}
// 	if (threadIdx.z < RAD) {
// 		s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] <= ref);
// 		s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] <= ref);
// 	}

// 	__syncthreads();

// 	// Take derivatives
// 	dChidx = ( s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] - 
// 		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

// 	dChidy = ( s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] - 
// 		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] ) / (2.0*dx);
	
// 	dChidz = ( s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] - 
// 		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] ) / (2.0*dx);

// 	__syncthreads();

// 	// Compute Length contribution for each thread
// 	if (dFdx == 0 && dFdy == 0 && dFdz == 0){
// 		s_F[s_idx] = 0;
// 	}
// 	else if (dChidx == 0 && dChidy == 0 && dChidz == 0){
// 		s_F[s_idx] = 0;
// 	}
// 	else{
// 		s_F[s_idx] = -(dFdx * dChidx + dFdy * dChidy + dFdz * dChidz) / sqrtf(dFdx * dFdx + dFdy * dFdy + dFdz * dFdz);
// 	}

// 	// __syncthreads();

// 	// Add length contribution from each thread into block memory
// 	if (threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0){
// 		double local_SA = 0.0;
// 		for (int q = 1; q <= blockDim.x; ++q) {
// 			for (int r = 1; r <= blockDim.y; ++r){
// 				for (int s = 1; s <= blockDim.z; ++s){
// 					int local_idx = flatten(q, r, s, s_w, s_h, s_d);
// 					local_SA += s_F[local_idx];
// 				}
// 			}
// 		}
// 		__syncthreads();
// 		atomicAdd(SA, local_SA*dx*dx*dx);
// 	}

// 	return;
// }


__global__
void surfaceArea_kernel(double *F, int w, int h, int d, double ref, double *SA) {
	extern __shared__ double s_F[];

	double dFdx, dFdy, dFdz, dChidx, dChidy, dChidz;

	// global indices
	const int i = blockIdx.x * blockDim.x + threadIdx.x; // column
	const int j = blockIdx.y * blockDim.y + threadIdx.y; // row
	const int k = blockIdx.z * blockDim.z + threadIdx.z; // stack
	if ((i >= w) || (j >= h) || (k >= d)) return;
	const int idx = flatten(i, j, k, w, h, d);
	// local width and height
	const int s_w = blockDim.x + 2 * RAD;
	const int s_h = blockDim.y + 2 * RAD;
	const int s_d = blockDim.z + 2 * RAD;
	// local indices
	const int s_i = threadIdx.x + RAD;
	const int s_j = threadIdx.y + RAD;
	const int s_k = threadIdx.z + RAD;
	const int s_idx = flatten(s_i, s_j, s_k, s_w, s_h, s_d);

	// Creating arrays in shared memory
	// Regular cells
	s_F[s_idx] = F[idx];

	//Halo Cells
	if (threadIdx.x < RAD) {
		s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] =
			F[flatten(i - RAD, j, k, w, h, d)];
		s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] =
			F[flatten(i + blockDim.x, j, k, w, h, d)];
	}
	if (threadIdx.y < RAD) {
		s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] =
			F[flatten(i, j - RAD, k, w, h, d)];
		s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] =
			F[flatten(i, j + blockDim.y, k, w, h, d)];
	}
	if (threadIdx.z < RAD) {
		s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] =
			F[flatten(i, j, k - RAD, w, h, d)];
		s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] =
			F[flatten(i, j, k + blockDim.z, w, h, d)];
	}

	__syncthreads();

	// Boundary Conditions
	// Making problem boundaries periodic
	if (i == 0){
		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] = 
			F[flatten(w, j, k, w, h, d)];
	}
	if (i == w - 1){
		s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] =
			F[flatten(0, j, k, w, h, d)];
	}

	if (j == 0){
		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] = 
			F[flatten(i, h, k, w, h, d)];
	}
	if (j == h - 1){
		s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] =
			F[flatten(i, 0, k, w, h, d)];
	}

	if (k == 0){
		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] = 
			F[flatten(i, j, d, w, h, d)];
	}
	if (k == d - 1){
		s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] =
			F[flatten(i, j, 0, w, h, d)];
	}

	// __syncthreads();

	// Calculating dFdx and dFdy
	// Take derivatives

	dFdx = ( s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] - 
		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

	dFdy = ( s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] - 
		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

	dFdz = ( s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] - 
		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] ) / (2.0*dx);

	__syncthreads();

	// Test to see if z is <= Zst, which sets the value of Chi
	s_F[s_idx] = (s_F[s_idx] <= ref); 

	// Test Halo Cells to form Chi
	if (threadIdx.x < RAD) {
		s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i - RAD, s_j, s_k, s_w, s_h, s_d)] <= ref);
		s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i + blockDim.x, s_j, s_k, s_w, s_h, s_d)] <= ref);
	}
	if (threadIdx.y < RAD) {
		s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j - RAD, s_k, s_w, s_h, s_d)] <= ref);
		s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j + blockDim.y, s_k, s_w, s_h, s_d)] <= ref);
	}
	if (threadIdx.z < RAD) {
		s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j, s_k - RAD, s_w, s_h, s_d)] <= ref);
		s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] = (s_F[flatten(s_i, s_j, s_k + blockDim.z, s_w, s_h, s_d)] <= ref);
	}

	__syncthreads();

	// Take derivatives
	dChidx = ( s_F[flatten(s_i + 1, s_j, s_k, s_w, s_h, s_d)] - 
		s_F[flatten(s_i - 1, s_j, s_k, s_w, s_h, s_d)] ) / (2.0*dx);

	dChidy = ( s_F[flatten(s_i, s_j + 1, s_k, s_w, s_h, s_d)] - 
		s_F[flatten(s_i, s_j - 1, s_k, s_w, s_h, s_d)] ) / (2.0*dx);
	
	dChidz = ( s_F[flatten(s_i, s_j, s_k + 1, s_w, s_h, s_d)] - 
		s_F[flatten(s_i, s_j, s_k - 1, s_w, s_h, s_d)] ) / (2.0*dx);

	__syncthreads();

	// Compute Length contribution for each thread
	if (dFdx == 0 && dFdy == 0 && dFdz == 0){
		s_F[s_idx] = 0;
	}
	else if (dChidx == 0 && dChidy == 0 && dChidz == 0){
		s_F[s_idx] = 0;
	}
	else{
		s_F[s_idx] = -(dFdx * dChidx + dFdy * dChidy + dFdz * dChidz) / sqrtf(dFdx * dFdx + dFdy * dFdy + dFdz * dFdz);
	}

	// __syncthreads();

	// Add length contribution from each thread into block memory
	if (threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0){
		double local_SA = 0.0;
		for (int q = 1; q <= blockDim.x; ++q) {
			for (int r = 1; r <= blockDim.y; ++r){
				for (int s = 1; s <= blockDim.z; ++s){
					int local_idx = flatten(q, r, s, s_w, s_h, s_d);
					local_SA += s_F[local_idx];
				}
			}
		}
		__syncthreads();
		atomicAdd(SA, local_SA*dx*dx*dx);
	}

	return;
}


void calcSurfaceArea(double *z, double Zst, double *SA){
// Function to calculate surface quantities

	// Declare and allocate temporary variables
	const dim3 blockSize(TX, TY, TZ);
	const dim3 gridSize(divUp(NX, TX), divUp(NY, TY), divUp(NZ, TZ));
	const size_t smemSize = (TX + 2*RAD)*(TY + 2*RAD)*(TZ + 2*RAD)*sizeof(double);

// Calculate surface area based on Zst
	surfaceArea_kernel<<<gridSize, blockSize, smemSize>>>(z, NX, NY, NZ, Zst, SA);
	cudaError_t err = cudaGetLastError();
	if (err != cudaSuccess) 
    printf("Error: %s\n", cudaGetErrorString(err));

	return;

}

__global__
void calcVrmsKernel_mgpu(int start_y, double *wave, cufftDoubleComplex *u1hat, cufftDoubleComplex *u2hat, cufftDoubleComplex *u3hat, double *RMS, double *KE){
// Function to calculate the RMS velocity of a flow field

	// Declare variables
	extern __shared__ double vel_mag[];

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || ( (j+start_y) >= NY) || (k >= NZ)) return;
	int kp = NZ-k;
	const int idx = flatten(j, i, k, NY, NX, NZ2);
	const int idx2 = flatten(j, i, kp, NY, NX, NZ2);
	// Create shared memory indices
	// local width and height
	const int s_w = blockDim.x;
	const int s_h = blockDim.y;
	const int s_d = blockDim.z;
	// local indices
	const int s_col = threadIdx.x;
	const int s_row = threadIdx.y;
	const int s_sta = threadIdx.z;
	const int s_idx = flatten(s_row, s_col, s_sta, s_h, s_w, s_d);

// Step 1: Calculate velocity magnitude at each point in the domain
	// Requires calculation of uu*, or multiplication of u with its complex conjugate
	// Mathematically, multiplying a number u = a + ib by its complex conjugate means
	// uu* = (a + ib) * (a - ib) = a^2 + b^2.
	// Some funky indexing is required because only half of the domain is represented in the complex form
	// (or is it? Can potentially just compute on the standard grid and multiply by 2....)
	if (k < NZ2){
		vel_mag[s_idx] = (u1hat[idx].x*u1hat[idx].x + u1hat[idx].y*u1hat[idx].y)/((double)NN*NN) + (u2hat[idx].x*u2hat[idx].x + u2hat[idx].y*u2hat[idx].y)/((double)NN*NN) + (u3hat[idx].x*u3hat[idx].x + u3hat[idx].y*u3hat[idx].y)/((double)NN*NN);
	}
	else{
		vel_mag[s_idx] = (u1hat[idx2].x*u1hat[idx2].x + u1hat[idx2].y*u1hat[idx2].y)/((double)NN*NN) + (u2hat[idx2].x*u2hat[idx2].x + u2hat[idx2].y*u2hat[idx2].y)/((double)NN*NN) + (u3hat[idx2].x*u3hat[idx2].x + u3hat[idx2].y*u3hat[idx2].y)/((double)NN*NN);
	}

	__syncthreads();

// Step 2: Add all of the contributions together ( need to use Atomic Add to make sure that all points are added correctly)
// Need to perform data reduction
	// Calculate sum of the velocity magnitude for each block
	if (threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0){

		double blockSum = 0.0;
		// for (int i = 0; i < blockDim.x; ++i) {
		// 	for (int j = 0; j < blockDim.y; ++j){
		// 		for (int k = 0; k < blockDim.z; ++k){
		// 			int local_idx = flatten(i, j, k, s_w, s_h, s_d);
		// 			blockSum += vel_mag[local_idx];
		// 		}
		// 	}
		// }
		for (int i = 0; i < blockDim.x*blockDim.y*blockDim.z; ++i) {
			blockSum += vel_mag[i];
		}

		__syncthreads();

		// Step 3: Add all blocks together into device memory using Atomic operations (requires -arch=sm_60 or higher)

		// Kinetic Energy
		atomicAdd(KE, blockSum/2.0);
		// RMS velocity
		atomicAdd(RMS, blockSum/3.0);

	}

	return;
}

__global__
void calcEpsilonKernel_mgpu(int start_y, double *wave, cufftDoubleComplex *u1hat, cufftDoubleComplex *u2hat, cufftDoubleComplex *u3hat, double *eps){
// Function to calculate the rate of dissipation of kinetic energy in a flow field

	// Declare variables
	extern __shared__ double vel_mag[];

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || ((j+start_y) >= NY) || (k >= NZ)) return;
	int kp = NZ-k;
	const int idx = flatten(j, i, k, NY, NX, NZ2);
	const int idx2 = flatten(j, i, kp, NY, NX, NZ2);
	// Create shared memory indices
	// local width and height
	const int s_w = blockDim.x;
	const int s_h = blockDim.y;
	const int s_d = blockDim.z;
	// local indices
	const int s_col = threadIdx.x;
	const int s_row = threadIdx.y;
	const int s_sta = threadIdx.z;
	const int s_idx = flatten(s_row, s_col, s_sta, s_h, s_w, s_d);

// Step 1: Calculate k_sq*velocity magnitude at each point in the domain
	// Requires calculation of uu*, or multiplication of u with its complex conjugate
	// Mathematically, multiplying a number u = a + ib by its complex conjugate means
	// uu* = (a + ib) * (a - ib) = a^2 + b^2.
	// Some funky indexing is required because only half of the domain is represented in the complex form
	if (k < NZ2){
		vel_mag[s_idx] = (wave[i]*wave[i] + wave[(j+start_y)]*wave[(j+start_y)] + wave[k]*wave[k] )*( (u1hat[idx].x*u1hat[idx].x + u1hat[idx].y*u1hat[idx].y)/((double)NN*NN) + (u2hat[idx].x*u2hat[idx].x + u2hat[idx].y*u2hat[idx].y)/((double)NN*NN) + (u3hat[idx].x*u3hat[idx].x + u3hat[idx].y*u3hat[idx].y)/((double)NN*NN) );
	}
	else{
		vel_mag[s_idx] = (wave[i]*wave[i] + wave[(j+start_y)]*wave[(j+start_y)] + wave[k]*wave[k] )*( (u1hat[idx2].x*u1hat[idx2].x + u1hat[idx2].y*u1hat[idx2].y)/((double)NN*NN) + (u2hat[idx2].x*u2hat[idx2].x + u2hat[idx2].y*u2hat[idx2].y)/((double)NN*NN) + (u3hat[idx2].x*u3hat[idx2].x + u3hat[idx2].y*u3hat[idx2].y)/((double)NN*NN) );
	}

	__syncthreads();

// Step 2: Add all of the contributions together ( need to use Atomic Add to make sure that all points are added correctly)
// Need to perform data reduction
// Calculate sum of the nu*k_sq*velocity magnitude for each block
	if (threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0){

		double blockSum = 0.0;
		// for (int i = 0; i < blockDim.x; ++i) {
		// 	for (int j = 0; j < blockDim.y; ++j){
		// 		for (int k = 0; k < blockDim.z; ++k){
		// 			int local_idx = flatten(i, j, k, s_w, s_h, s_d);
		// 			blockSum += nu*vel_mag[local_idx];
		// 		}
		// 	}
		// }
		for (int i = 0; i < blockDim.x*blockDim.y*blockDim.z; ++i) {
			blockSum += nu*vel_mag[i];
		}
		__syncthreads();

		// Dissipation Rate
		atomicAdd(eps, blockSum);
	}

	return;
}

__global__
void calcIntegralLengthKernel_mgpu(int start_y, double *wave, cufftDoubleComplex *u1hat, cufftDoubleComplex *u2hat, cufftDoubleComplex *u3hat, double *l){
// Function to calculate the integral length scale of a turbulent flow field

	// Declare variables
	extern __shared__ double vel_mag[];

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || ((j+start_y) >= NY) || (k >= NZ)) return;
	int kp = NZ-k;
	const int idx = flatten(j, i, k, NY, NX, NZ2);
	const int idx2 = flatten(j, i, kp, NY, NX, NZ2);
	// Create shared memory indices
	// local width and height
	const int s_w = blockDim.x;
	const int s_h = blockDim.y;
	const int s_d = blockDim.z;
	// local indices
	const int s_col = threadIdx.x;
	const int s_row = threadIdx.y;
	const int s_sta = threadIdx.z;
	const int s_idx = flatten(s_row, s_col, s_sta, s_h, s_w, s_d);

// Step 1: Calculate velocity magnitude at each point in the domain
	// Requires calculation of uu*, or multiplication of u with its complex conjugate
	// Mathematically, multiplying a number u = a + ib by its complex conjugate means
	// uu* = (a + ib) * (a - ib) = a^2 + b^2.
	// Some funky indexing is required because only half of the domain is represented in the complex form
	vel_mag[s_idx] = 0.0;
	if (wave[i]*wave[i] + wave[(j+start_y)]*wave[(j+start_y)] + wave[k]*wave[k] > 0){
		if (k < NZ2){
			vel_mag[s_idx] = ( (u1hat[idx].x*u1hat[idx].x + u1hat[idx].y*u1hat[idx].y)/((double)NN*NN) + (u2hat[idx].x*u2hat[idx].x + u2hat[idx].y*u2hat[idx].y)/((double)NN*NN) + (u3hat[idx].x*u3hat[idx].x + u3hat[idx].y*u3hat[idx].y)/((double)NN*NN) )/( 2.0*sqrt(wave[i]*wave[i] + wave[(j+start_y)]*wave[(j+start_y)] + wave[k]*wave[k]) );
		}
		else{
			vel_mag[s_idx] = ( (u1hat[idx2].x*u1hat[idx2].x + u1hat[idx2].y*u1hat[idx2].y)/((double)NN*NN) + (u2hat[idx2].x*u2hat[idx2].x + u2hat[idx2].y*u2hat[idx2].y)/((double)NN*NN) + (u3hat[idx2].x*u3hat[idx2].x + u3hat[idx2].y*u3hat[idx2].y)/((double)NN*NN) )/( 2.0*sqrt(wave[i]*wave[i] + wave[(j+start_y)]*wave[(j+start_y)] + wave[k]*wave[k]) );
		}
	}

	__syncthreads();

// Step 2: Add all of the contributions together ( need to use Atomic Add to make sure that all points are added correctly)
// Need to perform data reduction
// Calculate sum of the velocity magnitude for each block
	if (threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0){

		double blockSum = 0.0;
		// for (int i = 0; i < blockDim.x; ++i) {
		// 	for (int j = 0; j < blockDim.y; ++j){
		// 		for (int k = 0; k < blockDim.z; ++k){
		// 			int local_idx = flatten(i, j, k, s_w, s_h, s_d);
		// 			blockSum += vel_mag[local_idx];
		// 		}
		// 	}
		// }
		for (int i = 0; i < blockDim.x*blockDim.y*blockDim.z; ++i) {
			blockSum += vel_mag[i];
		}

		__syncthreads();

		// Dissipation Rate
		atomicAdd(l, blockSum);
	}

	return;
}

__global__
void calcScalarDissipationKernel_mgpu(int start_y, double *wave, cufftDoubleComplex *zhat, double *chi){
// Function to calculate the RMS velocity of a flow field

	// Declare variables
	extern __shared__ double sca_mag[];

	const int i = blockIdx.x * blockDim.x + threadIdx.x;
	const int j = blockIdx.y * blockDim.y + threadIdx.y;
	const int k = blockIdx.z * blockDim.z + threadIdx.z;
	if ((i >= NX) || ( (j+start_y) >= NY) || (k >= NZ)) return;
	int kp = NZ-k;
	const int idx = flatten(j, i, k, NY, NX, NZ2);
	const int idx2 = flatten(j, i, kp, NY, NX, NZ2);
	// Create shared memory indices
	// local width and height
	const int s_w = blockDim.x;
	const int s_h = blockDim.y;
	const int s_d = blockDim.z;
	// local indices
	const int s_col = threadIdx.x;
	const int s_row = threadIdx.y;
	const int s_sta = threadIdx.z;
	const int s_idx = flatten(s_row, s_col, s_sta, s_h, s_w, s_d);

// Step 1: Calculate velocity magnitude at each point in the domain
	// Requires calculation of uu*, or multiplication of u with its complex conjugate
	// Mathematically, multiplying a number u = a + ib by its complex conjugate means
	// uu* = (a + ib) * (a - ib) = a^2 + b^2.
	// Some funky indexing is required because only half of the domain is represented in the complex form
	// (or is it? Can potentially just compute on the standard grid and multiply by 2....)
	if (k < NZ2){
		sca_mag[s_idx] = (wave[i]*wave[i] + wave[(j+start_y)]*wave[(j+start_y)] + wave[k]*wave[k] )*(zhat[idx].x*zhat[idx].x + zhat[idx].y*zhat[idx].y)/((double)NN*NN);
	}
	else{
		sca_mag[s_idx] = (wave[i]*wave[i] + wave[(j+start_y)]*wave[(j+start_y)] + wave[k]*wave[k] )*(zhat[idx2].x*zhat[idx2].x + zhat[idx2].y*zhat[idx2].y)/((double)NN*NN);
	}

	__syncthreads();

// Step 2: Add all of the contributions together ( need to use Atomic Add to make sure that all points are added correctly)
// Need to perform data reduction
	// Calculate sum of the velocity magnitude for each block
	if (threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0){

		double blockSum = 0.0;

		for (int i = 0; i < blockDim.x*blockDim.y*blockDim.z; ++i) {
			blockSum += 2*(nu/Sc)*sca_mag[i];
		}

		__syncthreads();

		// Step 3: Add all blocks together into device memory using Atomic operations (requires -arch=sm_60 or higher)

		// Scalar Dissipation
		atomicAdd(chi, blockSum);

	}

	return;
}

void calcTurbStats_mgpu(const int iter, int nGPUs, int *NY_per_GPU, int *start_y, double **wave, cufftDoubleComplex **u1hat, cufftDoubleComplex **u2hat, cufftDoubleComplex **u3hat, cufftDoubleComplex **zhat, double **RMS, double **KE, double **eps, double **l, double **eta, double **lambda, double **Chi)
{// Function to call a cuda kernel that calculates the relevant turbulent statistics

	int n;
	for(n=0; n<nGPUs; ++n){
		cudaSetDevice(n);

		// Set thread and block dimensions for kernal calls
		const dim3 blockSize(TX, TY, TZ);
		const dim3 gridSize(divUp(NX, TX), divUp(NY_per_GPU[n], TY), divUp(NZ, TZ));
		const size_t smemSize = TX*TY*TZ*sizeof(double);
		cudaError_t err;


		// Call the kernel
		calcVrmsKernel_mgpu<<<gridSize, blockSize, smemSize>>>(start_y[n], wave[n], u1hat[n], u2hat[n], u3hat[n], &RMS[n][iter], &KE[n][iter]);
		err = cudaGetLastError();
		if (err != cudaSuccess) 
	    printf("Error: %s\n", cudaGetErrorString(err));

		calcEpsilonKernel_mgpu<<<gridSize, blockSize, smemSize>>>(start_y[n], wave[n], u1hat[n], u2hat[n], u3hat[n], &eps[n][iter]);
		err = cudaGetLastError();
		if (err != cudaSuccess) 
	    printf("Error: %s\n", cudaGetErrorString(err));

		calcIntegralLengthKernel_mgpu<<<gridSize, blockSize, smemSize>>>(start_y[n], wave[n], u1hat[n], u2hat[n], u3hat[n], &l[n][iter]);
		err = cudaGetLastError();
		if (err != cudaSuccess) 
	    printf("Error: %s\n", cudaGetErrorString(err));

		calcScalarDissipationKernel_mgpu<<<gridSize, blockSize, smemSize>>>(start_y[n], wave[n], zhat[n], &Chi[n][iter]);
		err = cudaGetLastError();
		if (err != cudaSuccess) 
	    printf("Error: %s\n", cudaGetErrorString(err));

	}

	// Syncrhonize GPUs
	for(n=0; n<nGPUs; ++n){
		cudaSetDevice(n);	
		cudaDeviceSynchronize();
	}

	// Adding together results from all GPUs
	for(n=1; n<nGPUs; ++n){
		cudaSetDevice(n);	
		cudaDeviceSynchronize();

		KE[0][iter] += KE[n][iter];
		RMS[0][iter] += RMS[n][iter];
		eps[0][iter] += eps[n][iter];
		l[0][iter] += l[n][iter];
		Chi[0][iter] += Chi[n][iter];
	}

	// "Post-processing" results from kernel calls - Calculating the remaining statistics
	//calcVrms kernel doesn't actually calculate the RMS velocity - 
	// Take square root to get Vrms
	RMS[0][iter] = sqrt(RMS[0][iter]);
	lambda[0][iter] = sqrt( 15.0*nu*RMS[0][iter]*RMS[0][iter]/eps[0][iter] );
	eta[0][iter] = sqrt(sqrt(nu*nu*nu/eps[0][iter]));
	l[0][iter] = 3*PI/4*l[0][iter]/KE[0][iter];

	return;
}

int main()
{
// Function to calculate the relevant turbulent statistics of the flow at each time step.

// Set GPU's to use and list device properties
	int n, nGPUs;
	// Query number of devices attached to host
	cudaGetDeviceCount(&nGPUs);
	// List properties of each device
	displayDeviceProps(nGPUs);

	printf("Running calcStats_mgpu using %d GPUs on a %dx%dx%d grid.\n",nGPUs,NX,NY,NZ);

	int i, c;

	// Split data according to number of GPUs
	int NX_per_GPU[nGPUs], NY_per_GPU[nGPUs], start_x[nGPUs], start_y[nGPUs];
	splitData(nGPUs, NX, NX_per_GPU, start_x);
	splitData(nGPUs, NY, NY_per_GPU, start_y);

	// Declare array of pointers to hold cuFFT plans
	cufftHandle *plan2d;
	cufftHandle *invplan2d;
	cufftHandle *plan1d;
    size_t *worksize_f, *worksize_i;
    cufftDoubleComplex **workspace;

	// Allocate memory for cuFFT plans
	// Allocate pinned memory on the host side that stores array of pointers
	cudaHostAlloc((void**)&plan2d, nGPUs*sizeof(cufftHandle), cudaHostAllocMapped);
	cudaHostAlloc((void**)&invplan2d, nGPUs*sizeof(cufftHandle), cudaHostAllocMapped);
	cudaHostAlloc((void**)&plan1d, nGPUs*sizeof(cufftHandle), cudaHostAllocMapped);
    cudaHostAlloc((void**)&worksize_f, nGPUs*sizeof(size_t *), cudaHostAllocMapped);
    cudaHostAlloc((void**)&worksize_i, nGPUs*sizeof(size_t *), cudaHostAllocMapped);
    cudaHostAlloc((void**)&workspace, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);

    // Create plans for cuFFT on each GPU
    plan1dFFT(nGPUs, plan1d);
    plan2dFFT(nGPUs, NX_per_GPU, worksize_f, worksize_i, workspace, plan2d, invplan2d);

	// Allocate memory on host
	double **h_u;
	double **h_v;
	double **h_w;
	double **h_z;

	h_u = (double **)malloc(sizeof(double *)*nGPUs);
	h_v = (double **)malloc(sizeof(double *)*nGPUs);
	h_w = (double **)malloc(sizeof(double *)*nGPUs);
	h_z = (double **)malloc(sizeof(double *)*nGPUs);

	for(n=0; n<nGPUs; ++n){
		h_u[n] = (double *)malloc(sizeof(complex double)*NX_per_GPU[n]*NY*NZ2);
		h_v[n] = (double *)malloc(sizeof(complex double)*NX_per_GPU[n]*NY*NZ2);
		h_w[n] = (double *)malloc(sizeof(complex double)*NX_per_GPU[n]*NY*NZ2);
		h_z[n] = (double *)malloc(sizeof(complex double)*NX_per_GPU[n]*NY*NZ2);
	}

	// Allocate host memory for the statistics
	double *h_Vrms;
	double *h_KE;
	double *h_epsilon;
	double *h_eta;
	double *h_l;
	double *h_lambda;
	double *h_Chi;

	h_Vrms = (double *)malloc(sizeof(double)*size_Stats);
	h_KE = (double *)malloc(sizeof(double)*size_Stats);
	h_epsilon = (double *)malloc(sizeof(double)*size_Stats);
	h_eta = (double *)malloc(sizeof(double)*size_Stats);
	h_l = (double *)malloc(sizeof(double)*size_Stats);
	h_lambda = (double *)malloc(sizeof(double)*size_Stats);
	h_Chi = (double *)malloc(sizeof(double)*size_Stats);
	
	// Declare variables
	double **k;
	double **Vrms;
	double **epsilon;
	double **KE;
	double **eta;
	double **l;
	double **lambda;
	double **Chi;
	// double **T4;
	// double **T5;
	// double **T5a;
	// double **T5b;

	cufftDoubleReal **u;
	cufftDoubleReal **v;
	cufftDoubleReal **w;
	cufftDoubleReal **z;

	cufftDoubleComplex **uhat;
	cufftDoubleComplex **vhat;
	cufftDoubleComplex **what;
	cufftDoubleComplex **zhat;

	cufftDoubleComplex **temp;
	cufftDoubleComplex **temp_reorder;
	cufftDoubleComplex **temp_advective;

	// Allocate pinned memory on the host side that stores array of pointers
	cudaHostAlloc((void**)&k, nGPUs*sizeof(double *), cudaHostAllocMapped);

	cudaHostAlloc((void**)&uhat, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&vhat, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&what, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&zhat, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);

	cudaHostAlloc((void**)&temp, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&temp_reorder, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&temp_advective, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
		
	cudaHostAlloc((void**)&Vrms, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&KE, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&epsilon, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&eta, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&l, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&lambda, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	cudaHostAlloc((void**)&Chi, nGPUs*sizeof(cufftDoubleComplex *), cudaHostAllocMapped);
	
	// Allocate memory for arrays
	for (n = 0; n<nGPUs; ++n){
		cudaSetDevice(n);

		checkCudaErrors( cudaMalloc((void **)&k[n], sizeof(double)*NX ) );

		checkCudaErrors( cudaMalloc((void **)&uhat[n], sizeof(cufftDoubleComplex)*NX_per_GPU[n]*NY*NZ2) ); 
		checkCudaErrors( cudaMalloc((void **)&vhat[n], sizeof(cufftDoubleComplex)*NX_per_GPU[n]*NY*NZ2) );
		checkCudaErrors( cudaMalloc((void **)&what[n], sizeof(cufftDoubleComplex)*NX_per_GPU[n]*NY*NZ2) );
		checkCudaErrors( cudaMalloc((void **)&zhat[n], sizeof(cufftDoubleComplex)*NX_per_GPU[n]*NY*NZ2) );

		checkCudaErrors( cudaMalloc((void **)&temp[n], sizeof(cufftDoubleComplex)*NX_per_GPU[n]*NY*NZ2) );
		checkCudaErrors( cudaMalloc((void **)&temp_reorder[n], sizeof(cufftDoubleComplex)*NX_per_GPU[n]*NZ2) );
		checkCudaErrors( cudaMalloc((void **)&temp_advective[n], sizeof(cufftDoubleComplex)*NX_per_GPU[n]*NY*NZ2) );
		
		checkCudaErrors( cudaMallocManaged((void **)&Vrms[n], sizeof(double)*size_Stats) );
		checkCudaErrors( cudaMallocManaged((void **)&KE[n], sizeof(double)*size_Stats) );
		checkCudaErrors( cudaMallocManaged((void **)&epsilon[n], sizeof(double)*size_Stats) );
		checkCudaErrors( cudaMallocManaged((void **)&eta[n], sizeof(double)*size_Stats) );
		checkCudaErrors( cudaMallocManaged((void **)&l[n], sizeof(double)*size_Stats) );
		checkCudaErrors( cudaMallocManaged((void **)&lambda[n], sizeof(double)*size_Stats) );
		checkCudaErrors( cudaMallocManaged((void **)&Chi[n], sizeof(double)*size_Stats) );
	
	// cudaMallocManaged(&T4, sizeof(double)*size_Stats);
	// cudaMallocManaged(&T5, sizeof(double)*size_Stats);
	// cudaMallocManaged(&T5a, sizeof(double)*size_Stats);
	// cudaMallocManaged(&T5b, sizeof(double)*size_Stats);
		printf("Memory allocated on Device #%d\n", n);
	}

	// Set pointers for real arrays
	u = (cufftDoubleReal **)uhat;
	v = (cufftDoubleReal **)vhat;
	w = (cufftDoubleReal **)what;
	z = (cufftDoubleReal **)zhat;

	// printf("Starting Timer...\n");
	// StartTimer();

	// Setup wavespace domain
	initializeWaveNumbers(nGPUs, k);

/////////////////////////////////////////////////////////////////////////////////////
// Calculate Turbulence statistics
/////////////////////////////////////////////////////////////////////////////////////

// Enter timestepping loop
	for (i = 0; i < size_Stats; ++i){

		// Calculate iteration number based on how often data is saved
		c = i*n_save;

		// Import data to GPU memory and distribute across GPUs for calculations
		importFields_mgpu(nGPUs, start_x, NX_per_GPU, c, h_u, h_v, h_w, h_z, u, v, w, z);
		printf("Data imported successfully!\n");

		for(n=0; n<nGPUs; ++n){
			cudaSetDevice(n);
			cudaDeviceSynchronize();
		}

		// Transform real data to Fourier space
		forwardTransform(plan1d, plan2d, nGPUs, NX_per_GPU, start_x, NY_per_GPU, start_y, temp, temp_reorder, u);
		forwardTransform(plan1d, plan2d, nGPUs, NX_per_GPU, start_x, NY_per_GPU, start_y, temp, temp_reorder, v);
		forwardTransform(plan1d, plan2d, nGPUs, NX_per_GPU, start_x, NY_per_GPU, start_y, temp, temp_reorder, w);
		forwardTransform(plan1d, plan2d, nGPUs, NX_per_GPU, start_x, NY_per_GPU, start_y, temp, temp_reorder, z);

		for(n=0; n<nGPUs; ++n){
			cudaSetDevice(n);
			cudaDeviceSynchronize();
		}

		// Calculate RMS velocity
		calcTurbStats_mgpu(i, nGPUs, NY_per_GPU, start_y, k, uhat, vhat, what, zhat, Vrms, KE, epsilon, l, eta, lambda, Chi);

		printf("The RMS velocity is %g \n", Vrms[0][i]);
		printf("The Kinetic Energy is %g \n", KE[0][i]);
		printf("The Dissipation Rate is %g \n", epsilon[0][i]);
		printf("The Integral Length Scale is %g \n", l[0][i]);
		printf("The Kolmogorov Length Scale is %g \n", eta[0][i]);
		printf("The Taylor Micro Scale is %g \n", lambda[0][i]);
		printf("The Scalar Dissipation is %g \n", Chi[0][i]);
	}
	// Exit timestepping loop

	// Copy turbulent results from GPU to CPU memory
	printf("Copy results to CPU memory...\n");

	cudaSetDevice(0);
	cudaDeviceSynchronize();

	checkCudaErrors( cudaMemcpyAsync(h_Vrms, Vrms[0], sizeof(double)*size_Stats, cudaMemcpyDefault) );
	checkCudaErrors( cudaMemcpyAsync(h_KE, KE[0], sizeof(double)*size_Stats, cudaMemcpyDefault) );
	checkCudaErrors( cudaMemcpyAsync(h_epsilon, epsilon[0], sizeof(double)*size_Stats, cudaMemcpyDefault) );
	checkCudaErrors( cudaMemcpyAsync(h_eta, eta[0], sizeof(double)*size_Stats, cudaMemcpyDefault) );
	checkCudaErrors( cudaMemcpyAsync(h_l, l[0], sizeof(double)*size_Stats, cudaMemcpyDefault) );
	checkCudaErrors( cudaMemcpyAsync(h_lambda, lambda[0], sizeof(double)*size_Stats, cudaMemcpyDefault) );
	checkCudaErrors( cudaMemcpyAsync(h_Chi, Chi[0], sizeof(double)*size_Stats, cudaMemcpyDefault) );

	// Save turbulence data
	writeStats("Vrms", h_Vrms, .0);
	writeStats("epsilon", h_epsilon, .0);
	writeStats("eta", h_eta, .0);
	writeStats("KE", h_KE, .0);
	writeStats("lambda", h_lambda, .0);
	writeStats("l", h_l, .0);
	writeStats("Chi", h_Chi, .0);

	// Deallocate resources
	for(n = 0; n<nGPUs; ++n){
		cufftDestroy(plan1d[n]);
		cufftDestroy(plan2d[n]);
		cufftDestroy(invplan2d[n]);
	}

	free(h_Vrms);
	free(h_KE);
	free(h_epsilon);
	free(h_eta);
	free(h_l);
	free(h_lambda);
	free(h_Chi);


	// Deallocate GPU memory
	for(n = 0; n<nGPUs; ++n){
		cudaSetDevice(n);

        cudaFree(plan1d);
        cudaFree(plan2d);
        cudaFree(invplan2d);
        cudaFree(worksize_f);
        cudaFree(worksize_i);
        cudaFree(workspace);

		cudaFree(k[n]);

		cudaFree(uhat[n]);
		cudaFree(vhat[n]);
		cudaFree(what[n]);
		cudaFree(zhat[n]);

		cudaFree(temp[n]);
		cudaFree(temp_reorder[n]);
		cudaFree(temp_advective[n]);
		
	}
	
	// Deallocate pointer arrays on host memory
	cudaFreeHost(k);

	cudaFreeHost(uhat);
	cudaFreeHost(vhat);
	cudaFreeHost(what);
	cudaFreeHost(zhat);

	cudaFreeHost(temp);
	cudaFreeHost(temp_reorder);
	cudaFreeHost(temp_advective);

	cudaFreeHost(Vrms);
	cudaFreeHost(KE);
	cudaFreeHost(epsilon);
	cudaFreeHost(eta);
	cudaFreeHost(l);
	cudaFreeHost(lambda);
	cudaFreeHost(Chi);

	cudaFreeHost(plan1d);
	cudaFreeHost(plan2d);
	cudaFreeHost(invplan2d);

/////////////////////////////////////////////////////////////////////////////////////
// Finished calculating turbulence statistics
/////////////////////////////////////////////////////////////////////////////////////


/////////////////////////////////////////////////////////////////////////////////////
// Calculate Flame Surface properties
/////////////////////////////////////////////////////////////////////////////////////
	n = 1;
	cudaSetDevice(n-1);		// Device is set to 0 as the flame surface properties is currently designed to run on a single GPU

	// Define the stoichiometric value of the mixture fraction:
 	int n_Z = 6;
	double Zst[n_Z] = {0.05, 0.1, 0.2, 0.3, 0.4, 0.5};
	// int n_Z = 1;
	// double Zst[n_Z] = {0.5};
	
	// Declare Variables
	int j;
	double *SurfArea;
	double *f;		// Mixture fraction data (Z data, but renamed it for the surface area calcs)
	
	// Allocate memory
	cudaMallocManaged(&SurfArea, sizeof(double)*size_Stats);
	cudaMallocManaged(&f, sizeof(double)*NN);

// Loop through values of Zst
/////////////////////////////////////////////////////////////////////////////////////
	for (j = 0; j < n_Z; ++j){

		// Initialize surface properties to 0
		cudaMemset(SurfArea, 0.0, sizeof(double)*size_Stats);
		// cudaMemset(T4, 0.0, sizeof(double)*size_Stats);
		// cudaMemset(T5, 0.0, sizeof(double)*size_Stats);
		// cudaMemset(T5a, 0.0, sizeof(double)*size_Stats);
		// cudaMemset(T5b, 0.0, sizeof(double)*size_Stats);

// Enter timestepping loop
/////////////////////////////////////////////////////////////////////////////////////
		for (i = 0; i < size_Stats; ++i){

			// Calculate iteration number based on how often data is saved
			c = i*n_save;

			// Import data to CPU memory for calculations
			importF(c, "z", f);

			// Calculate Integral Properties (uses only physical space variables)
			calcSurfaceArea(f, Zst[j], &SurfArea[i]);
			// calcSurfaceProps(plan, invplan, kx, u, v, w, z, Zst[j], &SurfArea[i], &T4[i], &T5[i], &T5a[i], &T5b[i]);

			cudaDeviceSynchronize();

			printf("The Surface Area of the flame is %g \n", SurfArea[i]);
			// printf("The value of Term IV is %g \n", T4[i]);
			// printf("The value of Term V is %g \n", T5[i]);
			// printf("The value of Term Va is %g \n", T5a[i]);
			// printf("The value of Term Vb is %g \n", T5b[i]);

		}
		// Exit timestepping loop

		// Save Zst-dependent data
		writeStats("Area", SurfArea, Zst[j]);
		// writeStats("IV", T4, Zst[j]);
		// writeStats("V", T5, Zst[j]);
		// writeStats("Va", T5a, Zst[j]);
		// writeStats("Vb", T5b, Zst[j]);

	}
	// Exit Zst loop

	// Deallocate Variables
	cudaFree(SurfArea);
	cudaFree(f);

//////////////////////////////////////////////////////////////////////////////////////
// Finished calculating surface properties
//////////////////////////////////////////////////////////////////////////////////////
	
	printf("Analysis complete, Data saved!\n");

	cudaDeviceReset();

	return 0;
}
