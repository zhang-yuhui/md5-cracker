#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>
#include "md5.cu"
#define MAX_LENGTH 8
#define THREADS_PER_BLOCK 256
#define CHECK_CUDA(call) { \
    cudaError_t err = call; \
    if(err != cudaSuccess) { \
        fprintf(stderr, "CUDA Error at %s:%d - %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
        exit(1); \
    } \
}

// Convert hex string to 128-bit MD5 hash (four 32-bit integers)
void parse_md5(const char* hash_str, uint32_t hash[4]) {
    for(int i = 0; i < 4; i++) {
        char byte_str[9];
        strncpy(byte_str, hash_str + i*8, 8);
        byte_str[8] = '\0';
        hash[i] = strtoul(byte_str, NULL, 16);
    }
}

__global__ void crack_kernel(
    const char* wordlist,
    int wordlist_size,
    int length,
    uint64_t start_idx,
    uint32_t target_hash[4],
    volatile bool* found,
    char* result
) {
    uint64_t idx = blockIdx.x * blockDim.x + threadIdx.x + start_idx;
    uint64_t max_idx = 1;
    for(int i = 0; i < length; i++) max_idx *= wordlist_size;
    
    char candidate[MAX_LENGTH + 1];
    for(; idx < max_idx; idx += gridDim.x * blockDim.x) {
        if(*found) return;
        
        // Generate candidate password
        uint64_t tmp = idx;
        for(int pos = length-1; pos >= 0; pos--) {
            candidate[pos] = wordlist[tmp % wordlist_size];
            tmp /= wordlist_size;
        }
        
        // Compute MD5 hash
        uint32_t a, b, c, d;
        md5Hash((unsigned char*)candidate, length, &a, &b, &c, &d);
        
        // Check match
        if(a == target_hash[0] && b == target_hash[1] && 
           c == target_hash[2] && d == target_hash[3]) {
            memcpy(result, candidate, length);
            result[length] = '\0';
            *found = true;
            __threadfence_system();
            return;
        }
    }
}

int main(int argc, char** argv) {
    if(argc < 2) {
        printf("Usage: %s <hash> <charset> <max_length>\n", argv[0]);
        return 1;
    }

    // Parse input
    uint32_t target_hash[4];
    parse_md5(argv[1], target_hash);
    const char* charset = "abcdefghijklmnopqrstuvwxyz"; // argv[2];
    int max_length = 8; // atoi(argv[3]);
    int charset_size = strlen(charset);

    // Device allocations
    char *d_charset, *d_result;
    bool *d_found;
    uint32_t *d_target_hash;
    
    CHECK_CUDA(cudaMalloc(&d_charset, charset_size));
    CHECK_CUDA(cudaMalloc(&d_target_hash, sizeof(target_hash)));
    CHECK_CUDA(cudaMalloc(&d_found, sizeof(bool)));
    CHECK_CUDA(cudaMalloc(&d_result, MAX_LENGTH + 1));
    
    CHECK_CUDA(cudaMemcpy(d_charset, charset, charset_size, cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_target_hash, target_hash, sizeof(target_hash), cudaMemcpyHostToDevice));

    // Brute-force from length 1 to max_length
    for(int len = 1; len <= max_length; len++) {
        bool found = false;
        uint64_t combinations = 1;
        for(int i = 0; i < len; i++) combinations *= charset_size;

        // Configure kernel
        int threads = THREADS_PER_BLOCK;
        int blocks = min((combinations + threads - 1) / threads, 65535u);
        uint64_t start_idx = 0;

        CHECK_CUDA(cudaMemset(d_found, 0, sizeof(bool)));
        
        while(start_idx < combinations && !found) {
            crack_kernel<<<blocks, threads>>>(
                d_charset, charset_size, len, start_idx,
                d_target_hash, d_found, d_result
            );
            
            start_idx += blocks * threads;
            CHECK_CUDA(cudaMemcpy(&found, d_found, sizeof(bool), cudaMemcpyDeviceToHost));
        }

        if(found) {
            char password[MAX_LENGTH + 1];
            CHECK_CUDA(cudaMemcpy(password, d_result, len + 1, cudaMemcpyDeviceToHost));
            printf("Found password: %s\n", password);
            break;
        }
    }

    // Cleanup
    CHECK_CUDA(cudaFree(d_charset));
    CHECK_CUDA(cudaFree(d_target_hash));
    CHECK_CUDA(cudaFree(d_found));
    CHECK_CUDA(cudaFree(d_result));

    return 0;
}