/**
 * CUDA MD5 cracker
 * Copyright (C) 2015  Konrad Kusnierz <iryont@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#include <stdio.h>
#include <iostream>
#include <time.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <sstream>
#include <fstream>
#include <vector>
#include <cstring>

#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include <curand_kernel.h>

#define CONST_WORD_LIMIT 10
#define CONST_CHARSET_LIMIT 100

#define CONST_CHARSET "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" // for special character: !\"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~" 
#define CONST_CHARSET_LENGTH (sizeof(CONST_CHARSET) - 1)

#define CONST_WORD_LENGTH_MIN 1
#define CONST_WORD_LENGTH_MAX 8

#define TOTAL_BLOCKS 14848UL // 7427*2 for RTX 4080lp
#define TOTAL_THREADS 256UL
#define HASHES_PER_KERNEL 1024UL

#define word_t __uint128_t

#include "assert.cu"
#include "md5.cu"

/* Global variables */
uint8_t g_wordLength;
int devices;

char g_word[CONST_WORD_LIMIT];
char g_charset[CONST_CHARSET_LIMIT];
char g_cracked[CONST_WORD_LIMIT];

__device__ char g_deviceCharset[CONST_CHARSET_LIMIT];
__device__ char g_deviceCracked[CONST_WORD_LIMIT];

__device__ __host__ bool next(uint8_t* length, char* word, word_t increment){
  uint32_t idx = 0;
  word_t add = 0;
  
  while(increment > 0 && idx < CONST_WORD_LIMIT){
    if(idx >= *length && increment > 0){
      increment--;
    }
    
    add = increment + word[idx];
    word[idx] = add % CONST_CHARSET_LENGTH;
    increment = add / CONST_CHARSET_LENGTH;
    idx++;
  }
  
  if(idx > *length){
    *length = idx;
  }
  
  if(idx > CONST_WORD_LENGTH_MAX){
    return false;
  }

  return true;
}

__global__ void md5Crack(uint8_t wordLength, char* charsetWord, uint32_t hash01, uint32_t hash02, uint32_t hash03, uint32_t hash04){
  uint32_t idx = (blockIdx.x * blockDim.x + threadIdx.x) * HASHES_PER_KERNEL;
  
  /* Shared variables */
  __shared__ char sharedCharset[CONST_CHARSET_LIMIT];
  
  /* Thread variables */
  char threadCharsetWord[CONST_WORD_LIMIT];
  char threadTextWord[CONST_WORD_LIMIT];
  uint8_t threadWordLength;
  uint32_t threadHash01, threadHash02, threadHash03, threadHash04;
  
  /* Copy everything to local memory */
  memcpy(threadCharsetWord, charsetWord, CONST_WORD_LIMIT);
  memcpy(&threadWordLength, &wordLength, sizeof(uint8_t));
  memcpy(sharedCharset, g_deviceCharset, sizeof(uint8_t) * CONST_CHARSET_LIMIT);
  
  /* Increment current word by thread index */
  next(&threadWordLength, threadCharsetWord, idx);
  
  for(uint32_t hash = 0; hash < HASHES_PER_KERNEL; hash++){
    for(uint32_t i = 0; i < threadWordLength; i++){
      threadTextWord[i] = sharedCharset[threadCharsetWord[i]];
    }
    
    md5Hash((unsigned char*)threadTextWord, threadWordLength, &threadHash01, &threadHash02, &threadHash03, &threadHash04);   

    if(threadHash01 == hash01 && threadHash02 == hash02 && threadHash03 == hash03 && threadHash04 == hash04){
      memcpy(g_deviceCracked, threadTextWord, threadWordLength);
    }
    
    if(!next(&threadWordLength, threadCharsetWord, 1)){
      break;
    }
  }
}

std::string md5_CUDA (const char hash[32]){
  
  /* Hash stored as u32 integers */
  uint32_t md5Hash[4];
  std::string result_pwd = "";
  /* Parse argument */
  for(uint8_t i = 0; i < 4; i++){
    char tmp[16];
    
    strncpy(tmp, hash + i * 8, 8);
    sscanf(tmp, "%x", &md5Hash[i]);   
    md5Hash[i] = (md5Hash[i] & 0xFF000000) >> 24 | (md5Hash[i] & 0x00FF0000) >> 8 | (md5Hash[i] & 0x0000FF00) << 8 | (md5Hash[i] & 0x000000FF) << 24;
  }
  
  /* Fill memory */
  memset(g_word, 0, CONST_WORD_LIMIT);
  memset(g_cracked, 0, CONST_WORD_LIMIT);
  memcpy(g_charset, CONST_CHARSET, CONST_CHARSET_LENGTH);
  
  /* Current word length = minimum word length */
  g_wordLength = CONST_WORD_LENGTH_MIN;
  
  /* Main device */
  cudaSetDevice(0);
  
  /* Time */
  cudaEvent_t clockBegin;
  cudaEvent_t clockLast;
  
  cudaEventCreate(&clockBegin);
  cudaEventCreate(&clockLast);
  cudaEventRecord(clockBegin, 0);
  
  /* Current word is different on each device */
  char** words = new char*[devices];
  
  for(int device = 0; device < devices; device++){
    cudaSetDevice(device);
    
    /* Copy to each device */
    ERROR_CHECK(cudaMemcpyToSymbol(g_deviceCharset, g_charset, sizeof(uint8_t) * CONST_CHARSET_LIMIT, 0, cudaMemcpyHostToDevice));
    ERROR_CHECK(cudaMemcpyToSymbol(g_deviceCracked, g_cracked, sizeof(uint8_t) * CONST_WORD_LIMIT, 0, cudaMemcpyHostToDevice));
    
    /* Allocate on each device */
    ERROR_CHECK(cudaMalloc((void**)&words[device], sizeof(uint8_t) * CONST_WORD_LIMIT));
  }
  
  while(true){
    bool result = false;
    bool found = false;
    
    for(int device = 0; device < devices; device++){
      cudaSetDevice(device);
      
      /* Copy current data */
      ERROR_CHECK(cudaMemcpy(words[device], g_word, sizeof(uint8_t) * CONST_WORD_LIMIT, cudaMemcpyHostToDevice)); 
    
      /* Start kernel */
      md5Crack<<<TOTAL_BLOCKS, TOTAL_THREADS>>>(g_wordLength, words[device], md5Hash[0], md5Hash[1], md5Hash[2], md5Hash[3]);
      
      /* Global increment */
      word_t dummy = 1;
      result = next(&g_wordLength, g_word, dummy* TOTAL_THREADS * HASHES_PER_KERNEL * TOTAL_BLOCKS);
    }
    
    /* Display progress */
#ifdef DEBUG
    char word[CONST_WORD_LIMIT];
    
    for(int i = 0; i < g_wordLength; i++){
      word[i] = g_charset[g_word[i]];
    }
    
    std::cout << "Notice: currently at " << std::string(word, g_wordLength) << " (" << (uint32_t)g_wordLength << ")" << std::endl;
#endif
    for(int device = 0; device < devices; device++){
      cudaSetDevice(device);
      
      /* Synchronize now */
      cudaDeviceSynchronize();
      
      /* Copy result */
      ERROR_CHECK(cudaMemcpyFromSymbol(g_cracked, g_deviceCracked, sizeof(uint8_t) * CONST_WORD_LIMIT, 0, cudaMemcpyDeviceToHost)); 
      
      /* Check result */
      if(found = *g_cracked != 0){     
        std::cout << "Notice: cracked " << g_cracked << std::endl; 
        result_pwd = std::string(g_cracked);
        break;
      }
    }
    
    if(!result || found){
      if(!result && !found){
        std::cout << "Notice: found nothing (host)" << std::endl;
      }
      
      break;
    }
  }
  
  for(int device = 0; device < devices; device++){
    cudaSetDevice(device);
    
    /* Free on each device */
    cudaFree((void**)words[device]);
  }
  
  /* Free array */
  delete[] words;
  
  /* Main device */
  cudaSetDevice(0);
  
  float milliseconds = 0;
  
  cudaEventRecord(clockLast, 0);
  cudaEventSynchronize(clockLast);
  cudaEventElapsedTime(&milliseconds, clockBegin, clockLast);
  
  std::cout << "Notice: computation time " << milliseconds << " ms" << std::endl;
  
  cudaEventDestroy(clockBegin);
  cudaEventDestroy(clockLast);
  return result_pwd;
}

static inline int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  c = std::tolower(static_cast<unsigned char>(c));
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

// to avoid leading and ending space
std::string trim(const std::string& s) {
  size_t start = 0;
  while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) {
      ++start;
  }

  if (start == s.size())
      return "";

  size_t end = s.size() - 1;
  while (end > start && std::isspace(static_cast<unsigned char>(s[end]))) {
      --end;
  }

  return s.substr(start, end - start + 1);
}

// Check if a string is a valid MD5 hex digest
bool inline is_valid_md5(const std::string& hex) {
  if (hex.size() != 32) {
      std::cout<<hex.size();
      return false;
  }
  for (char c : hex) {
      if (!isxdigit(c)) {
          return false;
          std::cout<<c<<' ';
      }
  }
  return true;
}

int main(int argc, char* argv[]){
  /* Check arguments */
  std::string filename = "hash.txt";
  if(argc == 2) {
        filename = argv[1];
    }else {
        std::cout << "No filename provided. Using default filename: " << filename << "\n";
    }

    // Load hashes from file
    std::ifstream file(filename);
    if(!file.is_open()) {
        std::cout << "Failed to open file " << filename << "\n";
        return 1;
    }
    std::vector<std::string> hashes;
    std::string line;
    while (std::getline(file, line)) {
        line = trim(line);
        if(!is_valid_md5(line)) {
            std::cout << "Invalid hash: " << line << "\n";
            std::cout << "skipping...\n";
            continue;
        }
        hashes.push_back(line);
    }

    std::cout << "Loaded " << hashes.size() << " hashes from " << filename << "\n";
    if(hashes.size() == 0) {
        std::cout << "No valid hashes found in " << filename << "\n";
        return 1;
    }
    std::cout<<std::endl;
  
  /* Amount of available devices */
  ERROR_CHECK(cudaGetDeviceCount(&devices));
  
  /* Sync type */
  ERROR_CHECK(cudaSetDeviceFlags(cudaDeviceScheduleSpin));
  
  /* Display amount of devices */
  std::cout << "Notice: " << devices << " device(s) found" << std::endl;
  
  std::vector<std::string> results;
  for(auto hash: hashes){
    std::string result = md5_CUDA(hash.c_str());
    if(!result.empty())
      results.push_back(hash);
  }
  std::cout << std::endl;
  std::cout << "Total " <<hashes.size() << " hashes, " << results.size() << " cracked.\n";
  return 0;
}
