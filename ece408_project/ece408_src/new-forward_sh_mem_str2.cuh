
#ifndef MXNET_OPERATOR_NEW_FORWARD_CUH_
#define MXNET_OPERATOR_NEW_FORWARD_CUH_

#include <mxnet/base.h>

namespace mxnet
{
namespace op
{

#define TILE_WIDTH 17
#define MASK_WIDTH 7
#define BLOCK_WIDTH (TILE_WIDTH + MASK_WIDTH - 1)
#define BM_GRID_SIZE 1
#define MASK_RADIUS 3

//__constant__ float kernel_const[(3 * 12 * 7 * 7) + (12 * 24 * 7 * 7)];

__global__ void forward_kernel(float *y, const float *x, const float *k, const int B, const int M, const int C, const int H, const int W, const int K, int W_grid)
{

#define y4d(b , m, h, w) y[(b) * (M * H_out * W_out) + (m) * (H_out * W_out) + (h) * (W_out) + w]
#define x4d(b, c, h_plus_p, w_plus_q) x[(b) * (C * H * W) + (c) * (H * W) + (h_plus_p) * (W) + w_plus_q]
#define k4d(m, c, p, q) k[(m) * (C * K * K) + (c) * (K * K) + (p) * (K) + q]
#define kernel_shared(i, h, w) kernel[i * (K * K) + h * K + w]
#define input_shared(i, j, k) input[i * (BLOCK_WIDTH * BLOCK_WIDTH) + j * BLOCK_WIDTH + k]
//#define input_shared(i, j, k) input[i * (TILE_WIDTH * TILE_WIDTH) + j * TILE_WIDTH + k]

/*    if ((blockIdx.x * blockDim.x + threadIdx.x == 0) && (blockIdx.y * blockDim.y + threadIdx.y == 0) && (blockIdx.z * blockDim.z + threadIdx.z == 0))
    for (int m = 0; m < M; m++){
	    printf("m = %d\n", m);
	    for (int c = 0; c < C; c++){
		    printf("c = %d\n", c);
		    for (int i = 0; i < K; i++){
			   for (int j = 0; j < K; j++){
				   printf("%f\t", k4d(m, c, i, j));
			   }
			   printf("\n");
		    }
	    }
    }
*/
//    if (C == 3)	
//        cudaMemcpyToSymbol(kernel_const, k, 3 * 12 * 7 * 7 * sizeof(float), 0, cudaMemcpyDeviceToDevice);

    const int H_out = H - K + 1;
    const int W_out = W - K + 1;

    int b = blockIdx.z;
    int m = blockIdx.x;
    int h = (blockIdx.y / W_grid) * TILE_WIDTH + threadIdx.y;
    int w = (blockIdx.y % W_grid) * TILE_WIDTH + threadIdx.x;

/*
    int b = (blockIdx.z % B_grid) * BM_GRID_SIZE + (threadIdx.z / BM_GRID_SIZE);
    int m = (blockIdx.z / B_grid) * BM_GRID_SIZE + (threadIdx.z % BM_GRID_SIZE);
    int h = blockDim.y * blockIdx.y + threadIdx.y;
    int w = blockDim.x * blockIdx.x + threadIdx.x;
*/
/*
    if ((blockIdx.x * blockDim.x + threadIdx.x == 0) && (blockIdx.y * blockDim.y + threadIdx.y == 0) && (blockIdx.z == 1)){
        for (int i = 0; i < H; i++){
	    for (int j = 0; j < W; j++){
		printf("%f\t", x4d(3, 0, i, j));
	    }
    	    printf("\n");
	}
    }
*/

    extern __shared__ float input[]; // size = C * (BLOCK_WIDTH) * (BLOCK_WIDTH) * sizeof(float)

    if(h >= 0 && h < H && w >= 0 && w < W) 
	for (int c = 0; c < C; c++)
            input_shared(c, threadIdx.y, threadIdx.x) = x4d(b, c, h, w);
    else
        for (int c = 0; c < C; c++)
            input_shared(c, threadIdx.y, threadIdx.x) = 0.0;
    __syncthreads();
/*
    if (w == 56 && h == 56 && b == 25 && m == 0){
	for (int i = 0; i < BLOCK_WIDTH; i++){
	    for (int j =0; j < BLOCK_WIDTH; j++){
                printf("%f\t", input_shared(0, i, j));
	    }
	    printf("\n");
	}
	printf("Actual\n");
	for (int i = 0; i < BLOCK_WIDTH; i++){
	    for (int j =0; j < BLOCK_WIDTH; j++){
                printf("%f\t", x4d(b, 0, h+i, w+j));
	    }
	    printf("\n");
	}
    }
*/

    float out = 0.0f;

    if (threadIdx.x < TILE_WIDTH && threadIdx.y < TILE_WIDTH){
//    if (m < M && h < H_out && w < W_out){
        for (int c = 0; c < C; c++){
            for (int p = 0; p < K; p++){
                for (int q = 0; q < K; q++){
//		    if (((threadIdx.y + p) < TILE_WIDTH) && ((threadIdx.x + q) < TILE_WIDTH))
                        out += k4d(m, c, p, q) * input_shared(c, (threadIdx.y + p), (threadIdx.x + q));
//		    else
//                        out += k4d(m, c, p, q) * x4d(b, c, h+p, w+q);
                }
            }
        }
	if (h < H_out && w < W_out)
            y4d(b, m, h, w) = out;
    }

#undef y4d
#undef x4d
#undef k4d
#undef kernel_shared
#undef input_shared

}

template <>
void forward<gpu, float>(mshadow::Tensor<gpu, 4, float> &y, const mshadow::Tensor<gpu, 4, float> &x, const mshadow::Tensor<gpu, 4, float> &k)
{

    // Extract the tensor dimensions into B,M,C,H,W,K
    const int B = x.shape_[0];
    const int M = y.shape_[1];
    const int C = x.shape_[1];
    const int H = x.shape_[2];
    const int W = x.shape_[3];
    const int K = k.shape_[3];
    int W_grid = ceil((W - K + 1) / (TILE_WIDTH * 1.0));
    int H_grid = ceil((H - K + 1) / (TILE_WIDTH *1.0));
    const int Y = H_grid * W_grid;

    int B_grid = ceil(B / (1.0 * BM_GRID_SIZE));
    int M_grid = ceil(M / (1.0 * BM_GRID_SIZE));
    const int BM = B_grid * M_grid;

/*  printf("LOG : B = %d\n", B);
    printf("LOG : M = %d\n", M);
    printf("LOG : C = %d\n", C);
    printf("LOG : H = %d\n", H);
    printf("LOG : W = %d\n", W);
    printf("LOG : K = %d\n", K);
    printf("LOG : W_grid = %d\n", W_grid);
    printf("LOG : H_grid = %d\n", H_grid);
    printf("LOG : Y = %d\n", Y); // 17*17
*/

    // Set the kernel dimensions
    dim3 gridDim(M, Y, B);
//    dim3 gridDim(H_grid, W_grid, BM);
//    int bm_threads = BM_GRID_SIZE * BM_GRID_SIZE;
//    dim3 blockDim(TILE_WIDTH, TILE_WIDTH, 1);
//    dim3 blockDim(TILE_WIDTH, TILE_WIDTH, bm_threads);
    dim3 blockDim(BLOCK_WIDTH, BLOCK_WIDTH, 1);

    // Call the kernel
//    forward_kernel<<<gridDim, blockDim>>>(y.dptr_, x.dptr_, k.dptr_, B, M, C, H, W, K, B_grid, M_grid);
//    long size = (C * (TILE_WIDTH) * (TILE_WIDTH) * sizeof(float));
    long size = (C * (BLOCK_WIDTH) * (BLOCK_WIDTH) * sizeof(float));
//    forward_kernel<<<gridDim, blockDim, size>>>(y.dptr_, x.dptr_, k.dptr_, B, M, C, H, W, K, W_grid);
    forward_kernel<<<gridDim, blockDim, size>>>(y.dptr_, x.dptr_, k.dptr_, B, M, C, H, W, K, W_grid);

    // Use MSHADOW_CUDA_CALL to check for CUDA runtime errors.
    MSHADOW_CUDA_CALL(cudaDeviceSynchronize());

}

template <typename gpu, typename DType>
void forward(mshadow::Tensor<gpu, 4, DType> &y, const mshadow::Tensor<gpu, 4, DType> &x, const mshadow::Tensor<gpu, 4, DType> &w)
{
    CHECK_EQ(0,1) << "Remove this line and replace it with your implementation.";
}
}
}

#endif
