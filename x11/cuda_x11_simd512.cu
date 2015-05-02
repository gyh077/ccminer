// Parallelization:
//
// FFT_8  wird 2 times 8-fach parallel ausgeführt (in FFT_64)
//        and  1 time 16-fach parallel (in FFT_128_full)
//
// STEP8_IF and STEP8_MAJ beinhalten je 2x 8-fach parallel Operations

#if __CUDA_ARCH__ <= 500
#define TPB 256
#else
#define TPB 224
#endif

#include "cuda_helper.h"
#include <stdio.h>



static uint32_t *d_state[MAX_GPUS];
static uint4 *d_temp4[MAX_GPUS];

// texture bound to d_temp4[thr_id], for read access in Compaction kernel
texture<uint4, 1, cudaReadModeElementType> texRef1D_128;

__constant__ uint8_t c_perm0[8] = { 2, 3, 6, 7, 0, 1, 4, 5 };
__constant__ uint8_t c_perm1[8] = { 6, 7, 2, 3, 4, 5, 0, 1 };
__constant__ uint8_t c_perm2[8] = { 7, 6, 5, 4, 3, 2, 1, 0 };
__constant__ uint8_t c_perm3[8] = { 1, 0, 3, 2, 5, 4, 7, 6 };
__constant__ uint8_t c_perm4[8] = { 0, 1, 4, 5, 6, 7, 2, 3 };
__constant__ uint8_t c_perm5[8] = { 6, 7, 2, 3, 0, 1, 4, 5 };
__constant__ uint8_t c_perm6[8] = { 6, 7, 0, 1, 4, 5, 2, 3 };
__constant__ uint8_t c_perm7[8] = { 4, 5, 2, 3, 6, 7, 0, 1 };

__constant__ short c_FFT128_8_16_Twiddle[128] = {
	1,   1,   1,   1,   1,    1,   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,
	1,  60,   2, 120,   4,  -17,   8, -34,  16, -68,  32, 121,  64, -15, 128, -30,
	1,  46,  60, -67,   2,   92, 120, 123,   4, -73, -17, -11,   8, 111, -34, -22,
	1, -67, 120, -73,   8,  -22, -68, -70,  64,  81, -30, -46,  -2,-123,  17,-111,
	1,-118,  46, -31,  60,  116, -67, -61,   2,  21,  92, -62, 120, -25, 123,-122,
	1, 116,  92,-122, -17,   84, -22,  18,  32, 114, 117, -49, -30, 118,  67,  62,
	1, -31, -67,  21, 120, -122, -73, -50,   8,   9, -22, -89, -68,  52, -70, 114,
	1, -61, 123, -50, -34,   18, -70, -99, 128, -98,  67,  25,  17,  -9,  35, -79
};

__constant__ short c_FFT256_2_128_Twiddle[128] = {
	  1,  41,-118,  45,  46,  87, -31,  14,
	 60,-110, 116,-127, -67,  80, -61,  69,
	  2,  82,  21,  90,  92, -83, -62,  28,
	120,  37, -25,   3, 123, -97,-122,-119,
	  4, -93,  42, -77, -73,  91,-124,  56,
	-17,  74, -50,   6, -11,  63,  13,  19,
	  8,  71,  84, 103, 111, -75,   9, 112,
	-34,-109,-100,  12, -22, 126,  26,  38,
	 16,-115, -89, -51, -35, 107,  18, -33,
	-68,  39,  57,  24, -44,  -5,  52,  76,
	 32,  27,  79,-102, -70, -43,  36, -66,
	121,  78, 114,  48, -88, -10, 104,-105,
	 64,  54, -99,  53, 117, -86,  72, 125,
	-15,-101, -29,  96,  81, -20, -49,  47,
	128, 108,  59, 106, -23,  85,-113,  -7,
	-30,  55, -58, -65, -95, -40, -98,  94
};


/************* the round function ****************/


#define IF(x, y, z) (((y ^ z) & x) ^ z)
#define MAJ(x, y, z) ((z &y) | ((z|y) & x))


#include "x11/simd_functions.cu"

/********************* Message expansion ************************/

/*
 * Reduce modulo 257; result is in [-127; 383]
 * REDUCE(x) := (x&255) - (x>>8)
 */
#define REDUCE(x) \
	(((x)&255) - ((x)>>8))

/*
 * Reduce from [-127; 383] to [-128; 128]
 * EXTRA_REDUCE_S(x) := x<=128 ? x : x-257
 */
#define EXTRA_REDUCE_S(x) \
	((x)<=128 ? (x) : (x)-257)

/*
 * Reduce modulo 257; result is in [-128; 128]
 */
#define REDUCE_FULL_S(x) \
	EXTRA_REDUCE_S(REDUCE(x))

__device__ __forceinline__
void FFT_8(int *y, int stripe) {

/*
 * FFT_8 using w=4 as 8th root of unity
 * Unrolled decimation in frequency (DIF) radix-2 NTT.
 * Output data is in revbin_permuted order.
 */

#define X(i) y[stripe*i]

#define DO_REDUCE(i) \
	X(i) = REDUCE(X(i))

#define DO_REDUCE_FULL_S(i) \
do { \
	X(i) = REDUCE(X(i)); \
	X(i) = EXTRA_REDUCE_S(X(i)); \
} while(0)

#define BUTTERFLY(i,j,n) \
do { \
	int u= X(i); \
	int v= X(j); \
	X(i) = u+v; \
	X(j) = (u-v) << (2*n); \
} while(0)

	BUTTERFLY(0, 4, 0);
	BUTTERFLY(1, 5, 1);
	BUTTERFLY(2, 6, 2);
	BUTTERFLY(3, 7, 3);

	DO_REDUCE(6);
	DO_REDUCE(7);

	BUTTERFLY(0, 2, 0);
	BUTTERFLY(4, 6, 0);
	BUTTERFLY(1, 3, 2);
	BUTTERFLY(5, 7, 2);

	DO_REDUCE(7);

	BUTTERFLY(0, 1, 0);
	BUTTERFLY(2, 3, 0);
	BUTTERFLY(4, 5, 0);
	BUTTERFLY(6, 7, 0);

	DO_REDUCE_FULL_S(0);
	DO_REDUCE_FULL_S(1);
	DO_REDUCE_FULL_S(2);
	DO_REDUCE_FULL_S(3);
	DO_REDUCE_FULL_S(4);
	DO_REDUCE_FULL_S(5);
	DO_REDUCE_FULL_S(6);
	DO_REDUCE_FULL_S(7);

#undef X
#undef DO_REDUCE
#undef DO_REDUCE_FULL_S
#undef BUTTERFLY
}

__device__ __forceinline__ void FFT_16(int *y) {

/**
 * FFT_16 using w=2 as 16th root of unity
 * Unrolled decimation in frequency (DIF) radix-2 NTT.
 * Output data is in revbin_permuted order.
 */
#define DO_REDUCE_FULL_S(i) \
	do { \
		y[i] = REDUCE(y[i]); \
		y[i] = EXTRA_REDUCE_S(y[i]); \
	} while(0)

	int u,v;

	// BUTTERFLY(0, 8, 0);
	// BUTTERFLY(1, 9, 1);
	// BUTTERFLY(2, 10, 2);
	// BUTTERFLY(3, 11, 3);
	// BUTTERFLY(4, 12, 4);
	// BUTTERFLY(5, 13, 5);
	// BUTTERFLY(6, 14, 6);
	// BUTTERFLY(7, 15, 7);
	{
		u = y[0]; // 0..7
		v = y[1]; // 8..15
		y[0] = u+v;
		y[1] = (u-v) << (threadIdx.x&7);
	}

	// DO_REDUCE(11);
	// DO_REDUCE(12);
	// DO_REDUCE(13);
	// DO_REDUCE(14);
	// DO_REDUCE(15);
	if ((threadIdx.x&7) >=3) y[1] = REDUCE(y[1]);  // 11...15

	// BUTTERFLY( 0, 4, 0);
	// BUTTERFLY( 1, 5, 2);
	// BUTTERFLY( 2, 6, 4);
	// BUTTERFLY( 3, 7, 6);
	{
		u = __shfl((int)y[0],  (threadIdx.x&3),8); // 0,1,2,3  0,1,2,3
		v = __shfl((int)y[0],4+(threadIdx.x&3),8); // 4,5,6,7  4,5,6,7
		y[0] = ((threadIdx.x&7) < 4) ? (u+v) : ((u-v) << (2*(threadIdx.x&3)));
	}

	// BUTTERFLY( 8, 12, 0);
	// BUTTERFLY( 9, 13, 2);
	// BUTTERFLY(10, 14, 4);
	// BUTTERFLY(11, 15, 6);
	{
		u = __shfl((int)y[1],  (threadIdx.x&3),8); // 8,9,10,11    8,9,10,11
		v = __shfl((int)y[1],4+(threadIdx.x&3),8); // 12,13,14,15  12,13,14,15
		y[1] = ((threadIdx.x&7) < 4) ? (u+v) : ((u-v) << (2*(threadIdx.x&3)));
	}

	// DO_REDUCE(5);
	// DO_REDUCE(7);
	// DO_REDUCE(13);
	// DO_REDUCE(15);
	if ((threadIdx.x&1) && (threadIdx.x&7) >= 4) {
		y[0] = REDUCE(y[0]);  // 5, 7
		y[1] = REDUCE(y[1]);  // 13, 15
	}

	// BUTTERFLY( 0, 2, 0);
	// BUTTERFLY( 1, 3, 4);
	// BUTTERFLY( 4, 6, 0);
	// BUTTERFLY( 5, 7, 4);
	{
		u = __shfl((int)y[0],  (threadIdx.x&5),8); // 0,1,0,1  4,5,4,5
		v = __shfl((int)y[0],2+(threadIdx.x&5),8); // 2,3,2,3  6,7,6,7
		y[0] = ((threadIdx.x&3) < 2) ? (u+v) : ((u-v) << (4*(threadIdx.x&1)));
	}

	// BUTTERFLY( 8, 10, 0);
	// BUTTERFLY( 9, 11, 4);
	// BUTTERFLY(12, 14, 0);
	// BUTTERFLY(13, 15, 4);
	{
		u = __shfl((int)y[1],  (threadIdx.x&5),8); // 8,9,8,9      12,13,12,13
		v = __shfl((int)y[1],2+(threadIdx.x&5),8); // 10,11,10,11  14,15,14,15
		y[1] = ((threadIdx.x&3) < 2) ? (u+v) : ((u-v) << (4*(threadIdx.x&1)));
	}

	// BUTTERFLY( 0, 1, 0);
	// BUTTERFLY( 2, 3, 0);
	// BUTTERFLY( 4, 5, 0);
	// BUTTERFLY( 6, 7, 0);
	{
		u = __shfl((int)y[0],  (threadIdx.x&6),8); // 0,0,2,2      4,4,6,6
		v = __shfl((int)y[0],1+(threadIdx.x&6),8); // 1,1,3,3      5,5,7,7
		y[0] = ((threadIdx.x&1) < 1) ? (u+v) : (u-v);
	}

	// BUTTERFLY( 8, 9, 0);
	// BUTTERFLY(10, 11, 0);
	// BUTTERFLY(12, 13, 0);
	// BUTTERFLY(14, 15, 0);
	{
		u = __shfl((int)y[1],  (threadIdx.x&6),8); // 8,8,10,10    12,12,14,14
		v = __shfl((int)y[1],1+(threadIdx.x&6),8); // 9,9,11,11    13,13,15,15
		y[1] = ((threadIdx.x&1) < 1) ? (u+v) : (u-v);
	}

	DO_REDUCE_FULL_S( 0); // 0...7
	DO_REDUCE_FULL_S( 1); // 8...15

#undef DO_REDUCE_FULL_S
}

__device__ __forceinline__
void FFT_128_full(int *y)
{
	int i;

	FFT_8(y+0,2); // eight parallel FFT8's
	FFT_8(y+1,2); // eight parallel FFT8's

#pragma unroll 16
	for (i=0; i<16; i++)
	/*if (i & 7)*/ y[i] = REDUCE(y[i]*c_FFT128_8_16_Twiddle[i*8+(threadIdx.x&7)]);

//#pragma unroll 8
	for (i=0; i<16; i+=2)
		FFT_16(y+i);  // eight sequential FFT16's, each one executed in parallel by 8 threads
}

__device__ __forceinline__
void FFT_256_halfzero(int *y)
{
	/*
	 * FFT_256 using w=41 as 256th root of unity.
	 * Decimation in frequency (DIF) NTT.
	 * Output data is in revbin_permuted order.
	 * In place.
	 */
	const int tmp = y[15];

#pragma unroll 8
	for (int i=0; i<8; i++)
		y[16+i] = REDUCE(y[i] * c_FFT256_2_128_Twiddle[8*i+(threadIdx.x&7)]);
#pragma unroll 8
	for (int i=24; i<32; i++)
		y[i] = 0;

	/* handle X^255 with an additional butterfly */
	if ((threadIdx.x&7) == 7)
	{
		y[15] = REDUCE(tmp + 1);
		y[31] = REDUCE((tmp - 1) * c_FFT256_2_128_Twiddle[127]);
	}

	FFT_128_full(y);
	FFT_128_full(y+16);
}


/***************************************************/

__device__ __forceinline__
void Expansion(const uint32_t *const __restrict__ data, uint4 *const __restrict__ g_temp4)
{
	/* Message Expansion using Number Theoretical Transform similar to FFT */
	int expanded[32];
#pragma unroll 4
	for (int i=0; i < 4; i++) {
		expanded[  i] = __byte_perm(__shfl((int)data[0], 2*i, 8), __shfl((int)data[0], (2*i)+1, 8), threadIdx.x&7)&0xff;
		expanded[4+i] = __byte_perm(__shfl((int)data[1], 2*i, 8), __shfl((int)data[1], (2*i)+1, 8), threadIdx.x&7)&0xff;
	}
#pragma unroll 8
	for (int i=8; i < 16; i++)
		expanded[i] = 0;

	FFT_256_halfzero(expanded);

	// store w matrices in global memory

	uint4 vec0;
	int P, Q, P1, Q1, P2, Q2;
	bool even = (threadIdx.x & 1) == 0;

//  0   8   4  12   2  10   6  14      16  24  20  28  18  26  22  30         2 2 2 2 2 2 2 2     2 2 2 2 2 2 2 2
//  0   8   4  12   2  10   6  14      16  24  20  28  18  26  22  30         6 6 6 6 6 6 6 6     6 6 6 6 6 6 6 6
//  0   8   4  12   2  10   6  14      16  24  20  28  18  26  22  30         0 0 0 0 0 0 0 0     0 0 0 0 0 0 0 0
//  0   8   4  12   2  10   6  14      16  24  20  28  18  26  22  30         4 4 4 4 4 4 4 4     4 4 4 4 4 4 4 4

	// 2 6 0 4

	P1 = expanded[ 0]; P2 = __shfl(expanded[ 2], (threadIdx.x-1)&7, 8); P = even ? P1 : P2;
	Q1 = expanded[16]; Q2 = __shfl(expanded[18], (threadIdx.x-1)&7, 8); Q = even ? Q1 : Q2;
	vec0.x = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm0[threadIdx.x&7], 8);
	P1 = expanded[ 8]; P2 = __shfl(expanded[10], (threadIdx.x-1)&7, 8); P = even ? P1 : P2;
	Q1 = expanded[24]; Q2 = __shfl(expanded[26], (threadIdx.x-1)&7, 8); Q = even ? Q1 : Q2;
	vec0.y = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm0[threadIdx.x&7], 8);
	P1 = expanded[ 4]; P2 = __shfl(expanded[ 6], (threadIdx.x-1)&7, 8); P = even ? P1 : P2;
	Q1 = expanded[20]; Q2 = __shfl(expanded[22], (threadIdx.x-1)&7, 8); Q = even ? Q1 : Q2;
	vec0.z = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm0[threadIdx.x&7], 8);
	P1 = expanded[12]; P2 = __shfl(expanded[14], (threadIdx.x-1)&7, 8); P = even ? P1 : P2;
	Q1 = expanded[28]; Q2 = __shfl(expanded[30], (threadIdx.x-1)&7, 8); Q = even ? Q1 : Q2;
	vec0.w = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm0[threadIdx.x&7], 8);
	g_temp4[threadIdx.x&7] = vec0;

//  1   9   5  13   3  11   7  15      17  25  21  29  19  27  23  31         6 6 6 6 6 6 6 6     6 6 6 6 6 6 6 6
//  1   9   5  13   3  11   7  15      17  25  21  29  19  27  23  31         2 2 2 2 2 2 2 2     2 2 2 2 2 2 2 2
//  1   9   5  13   3  11   7  15      17  25  21  29  19  27  23  31         4 4 4 4 4 4 4 4     4 4 4 4 4 4 4 4
//  1   9   5  13   3  11   7  15      17  25  21  29  19  27  23  31         0 0 0 0 0 0 0 0     0 0 0 0 0 0 0 0

	// 6 2 4 0

	P1 = expanded[ 1]; P2 = __shfl(expanded[ 3], (threadIdx.x-1)&7, 8); P = even ? P1 : P2;
	Q1 = expanded[17]; Q2 = __shfl(expanded[19], (threadIdx.x-1)&7, 8); Q = even ? Q1 : Q2;
	vec0.x = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm1[threadIdx.x&7], 8);
	P1 = expanded[ 9]; P2 = __shfl(expanded[11], (threadIdx.x-1)&7, 8); P = even ? P1 : P2;
	Q1 = expanded[25]; Q2 = __shfl(expanded[27], (threadIdx.x-1)&7, 8); Q = even ? Q1 : Q2;
	vec0.y = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm1[threadIdx.x&7], 8);
	P1 = expanded[ 5]; P2 = __shfl(expanded[ 7], (threadIdx.x-1)&7, 8); P = even ? P1 : P2;
	Q1 = expanded[21]; Q2 = __shfl(expanded[23], (threadIdx.x-1)&7, 8); Q = even ? Q1 : Q2;
	vec0.z = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm1[threadIdx.x&7], 8);
	P1 = expanded[13]; P2 = __shfl(expanded[15], (threadIdx.x-1)&7, 8); P = even ? P1 : P2;
	Q1 = expanded[29]; Q2 = __shfl(expanded[31], (threadIdx.x-1)&7, 8); Q = even ? Q1 : Q2;
	vec0.w = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm1[threadIdx.x&7], 8);
	g_temp4[8+(threadIdx.x&7)] = vec0;

//  1   9   5  13   3  11   7  15      17  25  21  29  19  27  23  31         7 7 7 7 7 7 7 7     7 7 7 7 7 7 7 7
//  1   9   5  13   3  11   7  15      17  25  21  29  19  27  23  31         5 5 5 5 5 5 5 5     5 5 5 5 5 5 5 5
//  0   8   4  12   2  10   6  14      16  24  20  28  18  26  22  30         3 3 3 3 3 3 3 3     3 3 3 3 3 3 3 3
//  0   8   4  12   2  10   6  14      16  24  20  28  18  26  22  30         1 1 1 1 1 1 1 1     1 1 1 1 1 1 1 1

	// 7 5 3 1

	bool hi = (threadIdx.x&7)>=4;

	P1 = hi?expanded[ 1]:expanded[ 0]; P2 = __shfl(hi?expanded[ 3]:expanded[ 2], (threadIdx.x+1)&7, 8); P = !even ? P1 : P2;
	Q1 = hi?expanded[17]:expanded[16]; Q2 = __shfl(hi?expanded[19]:expanded[18], (threadIdx.x+1)&7, 8); Q = !even ? Q1 : Q2;
	vec0.x = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm2[threadIdx.x&7], 8);
	P1 = hi?expanded[ 9]:expanded[ 8]; P2 = __shfl(hi?expanded[11]:expanded[10], (threadIdx.x+1)&7, 8); P = !even ? P1 : P2;
	Q1 = hi?expanded[25]:expanded[24]; Q2 = __shfl(hi?expanded[27]:expanded[26], (threadIdx.x+1)&7, 8); Q = !even ? Q1 : Q2;
	vec0.y = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm2[threadIdx.x&7], 8);
	P1 = hi?expanded[ 5]:expanded[ 4]; P2 = __shfl(hi?expanded[ 7]:expanded[ 6], (threadIdx.x+1)&7, 8); P = !even ? P1 : P2;
	Q1 = hi?expanded[21]:expanded[20]; Q2 = __shfl(hi?expanded[23]:expanded[22], (threadIdx.x+1)&7, 8); Q = !even ? Q1 : Q2;
	vec0.z = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm2[threadIdx.x&7], 8);
	P1 = hi?expanded[13]:expanded[12]; P2 = __shfl(hi?expanded[15]:expanded[14], (threadIdx.x+1)&7, 8); P = !even ? P1 : P2;
	Q1 = hi?expanded[29]:expanded[28]; Q2 = __shfl(hi?expanded[31]:expanded[30], (threadIdx.x+1)&7, 8); Q = !even ? Q1 : Q2;
	vec0.w = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm2[threadIdx.x&7], 8);
	g_temp4[16+(threadIdx.x&7)] = vec0;

//  1   9   5  13   3  11   7  15      17  25  21  29  19  27  23  31         1 1 1 1 1 1 1 1     1 1 1 1 1 1 1 1
//  1   9   5  13   3  11   7  15      17  25  21  29  19  27  23  31         3 3 3 3 3 3 3 3     3 3 3 3 3 3 3 3
//  0   8   4  12   2  10   6  14      16  24  20  28  18  26  22  30         5 5 5 5 5 5 5 5     5 5 5 5 5 5 5 5
//  0   8   4  12   2  10   6  14      16  24  20  28  18  26  22  30         7 7 7 7 7 7 7 7     7 7 7 7 7 7 7 7

  // 1 3 5 7

	bool lo = (threadIdx.x&7)<4;

	P1 = lo?expanded[ 1]:expanded[ 0]; P2 = __shfl(lo?expanded[ 3]:expanded[ 2], (threadIdx.x+1)&7, 8); P = !even ? P1 : P2;
	Q1 = lo?expanded[17]:expanded[16]; Q2 = __shfl(lo?expanded[19]:expanded[18], (threadIdx.x+1)&7, 8); Q = !even ? Q1 : Q2;
	vec0.x = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm3[threadIdx.x&7], 8);
	P1 = lo?expanded[ 9]:expanded[ 8]; P2 = __shfl(lo?expanded[11]:expanded[10], (threadIdx.x+1)&7, 8); P = !even ? P1 : P2;
	Q1 = lo?expanded[25]:expanded[24]; Q2 = __shfl(lo?expanded[27]:expanded[26], (threadIdx.x+1)&7, 8); Q = !even ? Q1 : Q2;
	vec0.y = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm3[threadIdx.x&7], 8);
	P1 = lo?expanded[ 5]:expanded[ 4]; P2 = __shfl(lo?expanded[ 7]:expanded[ 6], (threadIdx.x+1)&7, 8); P = !even ? P1 : P2;
	Q1 = lo?expanded[21]:expanded[20]; Q2 = __shfl(lo?expanded[23]:expanded[22], (threadIdx.x+1)&7, 8); Q = !even ? Q1 : Q2;
	vec0.z = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm3[threadIdx.x&7], 8);
	P1 = lo?expanded[13]:expanded[12]; P2 = __shfl(lo?expanded[15]:expanded[14], (threadIdx.x+1)&7, 8); P = !even ? P1 : P2;
	Q1 = lo?expanded[29]:expanded[28]; Q2 = __shfl(lo?expanded[31]:expanded[30], (threadIdx.x+1)&7, 8); Q = !even ? Q1 : Q2;
	vec0.w = __shfl((int)__byte_perm(185*P,  185*Q , 0x5410), c_perm3[threadIdx.x&7], 8);
	g_temp4[24+(threadIdx.x&7)] = vec0;

//  1   9   5  13   3  11   7  15       1   9   5  13   3  11   7  15         0 0 0 0 0 0 0 0     1 1 1 1 1 1 1 1
//  0   8   4  12   2  10   6  14       0   8   4  12   2  10   6  14         4 4 4 4 4 4 4 4     5 5 5 5 5 5 5 5
//  1   9   5  13   3  11   7  15       1   9   5  13   3  11   7  15         6 6 6 6 6 6 6 6     7 7 7 7 7 7 7 7
//  0   8   4  12   2  10   6  14       0   8   4  12   2  10   6  14         2 2 2 2 2 2 2 2     3 3 3 3 3 3 3 3

//{ 8, 72, 40, 104, 24, 88, 56, 120 },   { 9, 73, 41, 105, 25, 89, 57, 121 },
//{ 4, 68, 36, 100, 20, 84, 52, 116 },   { 5, 69, 37, 101, 21, 85, 53, 117 },
//{ 14, 78, 46, 110, 30, 94, 62, 126 },  { 15, 79, 47, 111, 31, 95, 63, 127 },
//{ 2, 66, 34, 98, 18, 82, 50, 114 },    { 3, 67, 35, 99, 19, 83, 51, 115 },

	bool sel = ((threadIdx.x+2)&7) >= 4;  // 2,3,4,5

	P1 = sel?expanded[0]:expanded[1]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	Q2 = sel?expanded[2]:expanded[3]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.x = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm4[threadIdx.x&7], 8);
	P1 = sel?expanded[8]:expanded[9]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	Q2 = sel?expanded[10]:expanded[11]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.y = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm4[threadIdx.x&7], 8);
	P1 = sel?expanded[4]:expanded[5]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	Q2 = sel?expanded[6]:expanded[7]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.z = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm4[threadIdx.x&7], 8);
	P1 = sel?expanded[12]:expanded[13]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	Q2 = sel?expanded[14]:expanded[15]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.w = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm4[threadIdx.x&7], 8);

	g_temp4[32+(threadIdx.x&7)] = vec0;

//  0   8   4  12   2  10   6  14       0   8   4  12   2  10   6  14         6 6 6 6 6 6 6 6     7 7 7 7 7 7 7 7
//  1   9   5  13   3  11   7  15       1   9   5  13   3  11   7  15         2 2 2 2 2 2 2 2     3 3 3 3 3 3 3 3
//  0   8   4  12   2  10   6  14       0   8   4  12   2  10   6  14         0 0 0 0 0 0 0 0     1 1 1 1 1 1 1 1
//  1   9   5  13   3  11   7  15       1   9   5  13   3  11   7  15         4 4 4 4 4 4 4 4     5 5 5 5 5 5 5 5

	P1 = sel?expanded[1]:expanded[0]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	Q2 = sel?expanded[3]:expanded[2]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.x = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm5[threadIdx.x&7], 8);
	P1 = sel?expanded[9]:expanded[8]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	Q2 = sel?expanded[11]:expanded[10]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.y = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm5[threadIdx.x&7], 8);
	P1 = sel?expanded[5]:expanded[4]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	Q2 = sel?expanded[7]:expanded[6]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.z = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm5[threadIdx.x&7], 8);
	P1 = sel?expanded[13]:expanded[12]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	Q2 = sel?expanded[15]:expanded[14]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.w = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm5[threadIdx.x&7], 8);

	g_temp4[40+(threadIdx.x&7)] = vec0;

// 16  24  20  28  18  26  22  30      16  24  20  28  18  26  22  30         6 6 6 6 6 6 6 6     7 7 7 7 7 7 7 7
// 16  24  20  28  18  26  22  30      16  24  20  28  18  26  22  30         0 0 0 0 0 0 0 0     1 1 1 1 1 1 1 1
// 17  25  21  29  19  27  23  31      17  25  21  29  19  27  23  31         0 0 0 0 0 0 0 0     1 1 1 1 1 1 1 1
// 17  25  21  29  19  27  23  31      17  25  21  29  19  27  23  31         6 6 6 6 6 6 6 6     7 7 7 7 7 7 7 7

	// sel markiert threads 2,3,4,5

	int t;
	t = __shfl(expanded[17],(threadIdx.x+4)&7,8); P1 = sel?t:expanded[16]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	t = __shfl(expanded[19],(threadIdx.x+4)&7,8); Q2 = sel?t:expanded[18]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.x = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm6[threadIdx.x&7], 8);
	t = __shfl(expanded[25],(threadIdx.x+4)&7,8); P1 = sel?t:expanded[24]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	t = __shfl(expanded[27],(threadIdx.x+4)&7,8); Q2 = sel?t:expanded[26]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.y = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm6[threadIdx.x&7], 8);
	t = __shfl(expanded[21],(threadIdx.x+4)&7,8); P1 = sel?t:expanded[20]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	t = __shfl(expanded[23],(threadIdx.x+4)&7,8); Q2 = sel?t:expanded[22]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.z = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm6[threadIdx.x&7], 8);
	t = __shfl(expanded[29],(threadIdx.x+4)&7,8); P1 = sel?t:expanded[28]; Q1 = __shfl(P1, threadIdx.x^1, 8);
	t = __shfl(expanded[31],(threadIdx.x+4)&7,8); Q2 = sel?t:expanded[30]; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.w = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm6[threadIdx.x&7], 8);

	g_temp4[48+(threadIdx.x&7)] = vec0;

// 17  25  21  29  19  27  23  31      17  25  21  29  19  27  23  31         4 4 4 4 4 4 4 4     5 5 5 5 5 5 5 5
// 17  25  21  29  19  27  23  31      17  25  21  29  19  27  23  31         2 2 2 2 2 2 2 2     3 3 3 3 3 3 3 3
// 16  24  20  28  18  26  22  30      16  24  20  28  18  26  22  30         2 2 2 2 2 2 2 2     3 3 3 3 3 3 3 3
// 16  24  20  28  18  26  22  30      16  24  20  28  18  26  22  30         4 4 4 4 4 4 4 4     5 5 5 5 5 5 5 5

	// sel markiert threads 2,3,4,5

	t = __shfl(expanded[16],(threadIdx.x+4)&7,8); P1 = sel?expanded[17]:t; Q1 = __shfl(P1, threadIdx.x^1, 8);
	t = __shfl(expanded[18],(threadIdx.x+4)&7,8); Q2 = sel?expanded[19]:t; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.x = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm7[threadIdx.x&7], 8);
	t = __shfl(expanded[24],(threadIdx.x+4)&7,8); P1 = sel?expanded[25]:t; Q1 = __shfl(P1, threadIdx.x^1, 8);
	t = __shfl(expanded[26],(threadIdx.x+4)&7,8); Q2 = sel?expanded[27]:t; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.y = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm7[threadIdx.x&7], 8);
	t = __shfl(expanded[20],(threadIdx.x+4)&7,8); P1 = sel?expanded[21]:t; Q1 = __shfl(P1, threadIdx.x^1, 8);
	t = __shfl(expanded[22],(threadIdx.x+4)&7,8); Q2 = sel?expanded[23]:t; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.z = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm7[threadIdx.x&7], 8);
	t = __shfl(expanded[28],(threadIdx.x+4)&7,8); P1 = sel?expanded[29]:t; Q1 = __shfl(P1, threadIdx.x^1, 8);
	t = __shfl(expanded[30],(threadIdx.x+4)&7,8); Q2 = sel?expanded[31]:t; P2 = __shfl(Q2, threadIdx.x^1, 8);
	P = even? P1 : P2; Q = even? Q1 : Q2;
	vec0.w = __shfl((int)__byte_perm(233*P,  233*Q , 0x5410), c_perm7[threadIdx.x&7], 8);

	g_temp4[56+(threadIdx.x&7)] = vec0;
}

/***************************************************/
__global__ void __launch_bounds__(TPB, 4)
x11_simd512_gpu_expand_64(uint32_t threads, uint32_t startNounce, const uint64_t *const __restrict__ g_hash, uint4 *const __restrict__ g_temp4)
{
	uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x)/8;
	if (thread < threads)
	{
		const uint32_t nounce = (startNounce + thread);

		const int hashPosition = nounce - startNounce;

		uint32_t *inpHash = (uint32_t*)&g_hash[8 * hashPosition];

		// Hash einlesen und auf 8 Threads und 2 Register verteilen
		uint32_t Hash[2];

		#pragma unroll 2
		for (int i=0; i<2; i++)
			Hash[i] = inpHash[8*i + (threadIdx.x & 7)];

		// Puffer für expandierte Nachricht
		uint4 *temp4 = &g_temp4[64 * hashPosition];

		Expansion(Hash, temp4);
	}
}

__global__ void __launch_bounds__(TPB, 1)
x11_simd512_gpu_compress1_64(uint32_t threads, uint32_t startNounce, uint64_t *g_hash,  uint4 *g_fft4, uint32_t *g_state)
{
	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	if (thread < threads)
	{
		const uint32_t nounce = (startNounce + thread);

		const int hashPosition = nounce - startNounce;
		uint32_t *const Hash = (uint32_t*)&g_hash[8 * hashPosition];

		Compression1(Hash, hashPosition, g_fft4, g_state);
	}
}
__global__ void __launch_bounds__(TPB, 1)
x11_simd512_gpu_compress2_64(uint32_t threads, uint32_t startNounce, uint64_t *g_hash, uint4 *g_fft4, uint32_t *g_state)
{
	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	if (thread < threads)
	{
		const uint32_t nounce =  (startNounce + thread);

		const int hashPosition = nounce - startNounce;

		Compression2(hashPosition, g_fft4, g_state);
	}
}


__global__ void __launch_bounds__(TPB, 1)
x11_simd512_gpu_compress_64_maxwell(uint32_t threads, uint32_t startNounce, uint64_t *const __restrict__ g_hash, const uint4 *const __restrict__ g_fft4, uint32_t *const __restrict__ g_state)
{
	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	if (thread < threads)
	{
		const uint32_t nounce = (startNounce + thread);

		const int hashPosition = nounce - startNounce;
		uint32_t *const Hash = (uint32_t*)&g_hash[8 * hashPosition];

		Compression1(Hash, hashPosition, g_fft4, g_state);
		Compression2(hashPosition, g_fft4, g_state);
	}
}


__global__ void  __launch_bounds__(TPB, 4)
x11_simd512_gpu_final_64(uint32_t threads, uint32_t startNounce, uint64_t *g_hash, uint4 *g_fft4, uint32_t *g_state)
{
	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	if (thread < threads)
	{
		const uint32_t nounce = (startNounce + thread);

		const int hashPosition = nounce - startNounce;
		uint32_t *const Hash = (uint32_t*)&g_hash[8 * hashPosition];

		Final(Hash, hashPosition, g_fft4, g_state);
	}
}

__host__ 
int x11_simd512_cpu_init(int thr_id, uint32_t threads)
{
	CUDA_SAFE_CALL(cudaMalloc(&d_state[thr_id], 32*sizeof(int)*threads));
	CUDA_SAFE_CALL(cudaMalloc(&d_temp4[thr_id], 64*sizeof(uint4)*threads));

	// Texture for 128-Bit Zugriffe
	cudaChannelFormatDesc channelDesc128 = cudaCreateChannelDesc<uint4>();
	texRef1D_128.normalized = 0;
	texRef1D_128.filterMode = cudaFilterModePoint;
	texRef1D_128.addressMode[0] = cudaAddressModeClamp;
	CUDA_SAFE_CALL(cudaBindTexture(NULL, &texRef1D_128, d_temp4[thr_id], &channelDesc128, 64*sizeof(uint4)*threads));
	return 0;
}
void x11_simd512_cpu_free(int thr_id)
{
	cudaFree(&d_state[thr_id]);
	cudaFree(&d_temp4[thr_id]);
}
__host__
void x11_simd512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_hash)
{
	int tpb;
	if (device_sm[device_map[thr_id]] == 520)
		tpb = 224;
	else
		tpb = 256;

	dim3 block(tpb);
	dim3 grid8(((threads + tpb-1)/tpb)*8);

	x11_simd512_gpu_expand_64 <<<grid8, block, 0, gpustream[thr_id]>>> (threads, startNounce, (uint64_t*)d_hash, d_temp4[thr_id]);
	//MyStreamSynchronize(NULL, order, thr_id);

	dim3 grid((threads + tpb-1)/tpb);

	if (device_sm[device_map[thr_id]] >= 500) 
	{
		x11_simd512_gpu_compress_64_maxwell << < grid, block, 0, gpustream[thr_id]>>> (threads, startNounce, (uint64_t*)d_hash, d_temp4[thr_id], d_state[thr_id]);
		//MyStreamSynchronize(NULL, order, thr_id);
	}
	else 
	{
		x11_simd512_gpu_compress1_64 << < grid, block, 0, gpustream[thr_id]>>> (threads, startNounce, (uint64_t*)d_hash, d_temp4[thr_id], d_state[thr_id]);
		x11_simd512_gpu_compress2_64 << < grid, block, 0, gpustream[thr_id]>>> (threads, startNounce, (uint64_t*)d_hash, d_temp4[thr_id], d_state[thr_id]);
		//	MyStreamSynchronize(NULL, order, thr_id);
	}

	x11_simd512_gpu_final_64 << <grid, block, 0, gpustream[thr_id]>>> (threads, startNounce, (uint64_t*)d_hash,d_temp4[thr_id], d_state[thr_id]);
//	MyStreamSynchronize(NULL, order, thr_id);
}
