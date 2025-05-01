// File: md5.cu
// Compile with: nvcc md5.cu -o md5
// Usage:       ./md5 <target_md5_hex> <max_length>
// Example:     ./md5 098f6bcd4621d373cade4e832627b4f6 4
//
// WARNING: This is a simplified demonstration. Real brute force can be extremely
// time-consuming for large maximum lengths and wide character sets. Use responsibly
// and only for legitimate security testing or educational purposes.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <iostream>

#include <cuda_runtime.h>
#include "md5.cu"

// -----------------------------------------------------------------------------
// Constant device variables.

__constant__ char d_charset[26];
__constant__ uint32_t d_targetMD5[4];   // The MD5 we're trying to match.

__device__ bool d_foundFlag = false;    // Global flag to indicate password found.
__device__ char d_foundPassword[32];    // Store the found password (if any).

// -----------------------------------------------------------------------------
// Convert a thread index into a "combination" (string) of length L using the charset.
//
// Example of how to map "index" to a sequence of characters in base (charsetSize).
// For L=3 (XYZ), index in [0, charsetSize^3 - 1], each digit is index % charsetSize.
//
// This function writes the generated password into "outStr" (length <= 31).
// -----------------------------------------------------------------------------
__device__ void indexToString(unsigned long long index, int length, char* outStr, int charsetSize)
{
    for (int i = 0; i < length; i++) {
        outStr[i] = d_charset[index % charsetSize];
        index /= charsetSize;
    }
    outStr[length] = '\0';
}

// -----------------------------------------------------------------------------
// Kernel to brute-force all combinations of a fixed length L.
// Each thread handles exactly one combination based on its global index.
// -----------------------------------------------------------------------------
__global__ void md5BruteForceKernel(int length, uint64_t startIndex, uint64_t endIndex)
{
    // If we already found a match, no need to continue.
    if (d_foundFlag) return;

    uint64_t idx = blockDim.x * blockIdx.x + threadIdx.x;
    uint64_t globalIndex = startIndex + idx;
    if (globalIndex > endIndex) return;

    // Generate the candidate password.
    char candidate[32];
    indexToString(globalIndex, length, candidate, 26);

    // Compute MD5 of this candidate
    // (We'll copy into a temporary buffer for the md5Hash function)
    unsigned char buffer[32];
    int len = length < 31 ? length : 31;
    for (int i = 0; i < len; i++) {
        buffer[i] = (unsigned char)candidate[i];
    }

    uint32_t a, b, c, d;
    md5Hash(buffer, length, &a, &b, &c, &d);

    // Compare computed (a,b,c,d) with the target MD5.
    if (a == d_targetMD5[0] &&
        b == d_targetMD5[1] &&
        c == d_targetMD5[2] &&
        d == d_targetMD5[3])
    {
        // If match found, copy the password to the global array and set flag.
        if (!d_foundFlag) {
            d_foundFlag = true;
            for (int i = 0; i < length; i++) {
                d_foundPassword[i] = candidate[i];
            }
            d_foundPassword[length] = '\0';
        }
    }
}

// -----------------------------------------------------------------------------
// Helper: Convert 32-char hex MD5 string into 4 uint32_t's (little-endian).
// -----------------------------------------------------------------------------
void parseMD5(const std::string &hexStr, uint32_t out[4])
{
    // Each MD5 is 128 bits = 32 hex digits
    if (hexStr.size() != 32) {
        std::cerr << "Invalid MD5 hex string length (must be 32).\n";
        std::exit(1);
    }

    // Convert each pair of hex to a byte
    unsigned char md5Bytes[16];
    for (int i = 0; i < 16; i++) {
        unsigned int byteVal;
        sscanf(hexStr.substr(i * 2, 2).c_str(), "%x", &byteVal);
        md5Bytes[i] = static_cast<unsigned char>(byteVal);
    }

    // Interpret each 4 bytes as 32-bit little-endian
    for (int i = 0; i < 4; i++) {
        out[i] = (md5Bytes[i*4+0] << 0)  |
                 (md5Bytes[i*4+1] << 8)  |
                 (md5Bytes[i*4+2] << 16) |
                 (md5Bytes[i*4+3] << 24);
    }
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------
int main(int argc, char** argv)
{
    if (argc < 3) {
        std::cerr << "Usage: " << argv[0] << " <target_md5_hex> <max_length>\n";
        std::cerr << "Example: " << argv[0] << " 098f6bcd4621d373cade4e832627b4f6 4\n";
        return 1;
    }

    std::string targetMD5Hex = argv[1];
    int maxLen = std::atoi(argv[2]);
    if (maxLen < 1 || maxLen > 10) {
        std::cerr << "Please choose a reasonable maximum length (1..30).\n";
        return 1;
    }

    // 1) Parse target MD5
    uint32_t h_targetMD5[4];
    parseMD5(targetMD5Hex, h_targetMD5);

    // 2) Copy character set and target MD5 to device
    const char h_charset[] = "abcdefghijklmnopqrstuvwxyz";
    cudaMemcpyToSymbol(d_charset, h_charset, 26 * sizeof(char));
    cudaMemcpyToSymbol(d_targetMD5, h_targetMD5, 4 * sizeof(uint32_t));

    // Set foundFlag = false
    bool falseVal = false;
    cudaMemcpyToSymbol(d_foundFlag, &falseVal, sizeof(bool));

    // 3) Launch brute force for each length from 1 to maxLen
    //    We do a naive approach: for length L, total combos = 26^L.
    //    We chunk them into as many threads as possible but keep it simple.
    int threadsPerBlock = 256;
    for (int length = 1; length <= maxLen; length++) {
        // Quickly compute 26^length in 64-bit
        uint64_t totalCombos = 1;
        for (int i = 0; i < length; i++) {
            totalCombos *= 26ULL;
        }

        if (totalCombos == 0ULL) {
            // Overflow or no combos
            std::cerr << "Too large search space or overflow. Stopping.\n";
            break;
        }

        // We'll launch enough blocks to cover totalCombos
        // Each thread tries exactly 1 combination
        uint64_t blocksNeeded = (totalCombos + threadsPerBlock - 1) / threadsPerBlock;
        dim3 blockSize(threadsPerBlock);
        dim3 gridSize(static_cast<unsigned int>(
                        (blocksNeeded > 65535ULL) ? 65535 : blocksNeeded));
        // If gridSize is capped at 65535, we won't cover the entire search
        // in a single launch for extremely large spaces. A real implementation
        // would need chunking. For demonstration, we do a single shot.

        // Launch kernel
        md5BruteForceKernel<<< gridSize, blockSize >>>(length, 0ULL, totalCombos - 1ULL);
        cudaDeviceSynchronize();

        // Check if foundFlag is set
        bool hostFoundFlag = false;
        cudaMemcpyFromSymbol(&hostFoundFlag, d_foundFlag, sizeof(bool));
        if (hostFoundFlag) {
            // Copy the password back and print
            char hostFoundPass[32];
            cudaMemcpyFromSymbol(hostFoundPass, d_foundPassword, 32 * sizeof(char));
            std::cout << "Password found (length " << length << "): " 
                      << hostFoundPass << std::endl;
            break;
        }
    }

    return 0;
}
