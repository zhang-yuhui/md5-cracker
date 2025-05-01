#include <stdio.h>
#include <string.h>
#include <cuda_runtime.h>
#include <cooperative_groups.h>

#include "md5.h"

#define CHARSET "abc"
#define MAX_LEN 8
#define MIN_LEN 7
#define BLOCKS 512
#define THREADS 256

__constant__ char charset[] = CHARSET;
__device__ char found_password[MAX_LEN + 1];
__device__ volatile bool found = false;

template <int LEN>
__global__ void md5CrackerKernel(uint64_t start_idx, uint64_t end_idx, 
                                const uint32_t *target, int charset_len) {
    uint64_t idx = start_idx + blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t stride = (uint64_t)blockDim.x * gridDim.x;
    char candidate[LEN + 1];
    candidate[LEN] = '\0';

    for (; idx < end_idx; idx += stride) {
        if (found) return;

        uint64_t current = idx;
        for (int i = LEN-1; i >= 0; --i) {
            int digit = current % charset_len;
            candidate[i] = charset[digit];
            current /= charset_len;
        }

        uint32_t a, b, c, d;
        md5Hash((unsigned char*)candidate, LEN, &a, &b, &c, &d);

        if (a == target[0] && b == target[1] && c == target[2] && d == target[3]) {
            bool expected = false;
            if (atomicCAS((bool*)&found, expected, true)) {
                memcpy(found_password, candidate, LEN);
                found_password[LEN] = '\0';
            }
            return;
        }
    }
}

void crackHash(const char *hash_str) {
    uint32_t target[4];
    char buf[9];
    
    // Parse hash string into 4 uint32_t values
    for (int i = 0; i < 4; ++i) {
        strncpy(buf, hash_str + i*8, 8);
        buf[8] = '\0';
        target[i] = strtoul(buf, NULL, 16);
    }

    int num_devices;
    cudaGetDeviceCount(&num_devices);
    const int charset_len = strlen(CHARSET);

    // Search for both lengths
    for (int len = MIN_LEN; len <= MAX_LEN; ++len) {
        const uint64_t total_perms = (uint64_t)pow(charset_len, len);
        cudaLaunchParams *launchParams = new cudaLaunchParams[num_devices];
        bool success = false;

        // Prepare multi-GPU launch
        for (int dev = 0; dev < num_devices; ++dev) {
            cudaSetDevice(dev);
            cudaStream_t stream;
            cudaStreamCreate(&stream);

            uint32_t *d_target;
            cudaMalloc(&d_target, 4*sizeof(uint32_t));
            cudaMemcpyAsync(d_target, target, 4*sizeof(uint32_t), 
                          cudaMemcpyHostToDevice, stream);

            uint64_t start = (total_perms * dev) / num_devices;
            uint64_t end = (total_perms * (dev + 1)) / num_devices;

            launchParams[dev].func = (void*)(len == 7 ? 
                md5CrackerKernel<7> : md5CrackerKernel<8>);
            launchParams[dev].gridDim = BLOCKS;
            launchParams[dev].blockDim = THREADS;
            launchParams[dev].sharedMem = 0;
            launchParams[dev].stream = stream;
            launchParams[dev].args = {&start, &end, &d_target, &charset_len};
        }

        cudaLaunchCooperativeKernelMultiDevice(launchParams, num_devices);

        // Check results
        for (int dev = 0; dev < num_devices; ++dev) {
            cudaSetDevice(dev);
            cudaDeviceSynchronize();

            char result[MAX_LEN + 1];
            cudaMemcpyFromSymbol(result, found_password, MAX_LEN + 1);
            if (strlen(result) > 0) {
                printf("Found password: %s\n", result);
                success = true;
                break;
            }
        }

        delete[] launchParams;
        if (success) return;
    }

    printf("Password not found\n");
}

int main(int argc, char **argv) {
    if (argc != 2) {
        printf("Usage: %s <md5_hash>\n", argv[0]);
        return 1;
    }
    crackHash(argv[1]);
    return 0;
}
