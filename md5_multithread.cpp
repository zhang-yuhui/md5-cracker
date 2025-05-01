#include <iostream>
#include <string>
#include <atomic>
#include <vector>
#include <thread>
#include <chrono>
#include <random>
#include <iomanip>
#include <cstring>
#include <cmath>
#include <cstdio>
#include <fstream>
#include "permutation.h"
#include <openssl/md5.h>

// Default values
# define BATCH_SIZE 1000 // number of hashes to compute after before synchronization
size_t MIN_PASSWORD_LENGTH = 1;
size_t MAX_PASSWORD_LENGTH = 8;
std::string filename = "hash.txt";
std::string word_list = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

void compute_md5(const unsigned char* input, const size_t len, unsigned char digest[MD5_DIGEST_LENGTH]) {
    MD5(input, len, digest);
}

// Convert one hex character to its 0–15 value, or -1 if invalid
static inline int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    c = std::tolower(static_cast<unsigned char>(c));
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}



// Check if a string is a valid MD5 hex digest
bool inline is_valid_md5(const std::string& hex) {
    if (hex.size() != 32) {
        return false;
    }
    for (char c : hex) {
        if (!isxdigit(c)) {
            return false;
        }
    }
    return true;
}

// Parse a 32-character hex string into a 16-byte MD5 digest.
bool hex_to_md5(const std::string &hex, unsigned char digest[MD5_DIGEST_LENGTH]) {
    if (!is_valid_md5(hex)) {
        return false;
    }

    for (int i = 0; i < MD5_DIGEST_LENGTH; ++i) {
        int hi = hexval(hex[2*i]);
        int lo = hexval(hex[2*i + 1]);
        if (hi < 0 || lo < 0) {
            return false;  // invalid hex digit
        }
        digest[i] = static_cast<unsigned char>((hi << 4) | lo);
    }

    return true;
}

// Worker thread
void worker(__uint128_t start, __uint128_t end, const unsigned char* target_digest, 
           std::atomic<bool>& found, std::string& result, size_t word_length) {
    if(start >= end) return;
    //printf("worker start: %d\n", std::this_thread::get_id());
    unsigned char digest[MD5_DIGEST_LENGTH];
    __uint128_t current = start;
    Permutation perm(word_list, word_length);
    perm.set_counter(start);

    auto start_time = std::chrono::steady_clock::now();

    while (current < end and !found.load(std::memory_order_relaxed)) {
        __uint128_t batch_end = std::min(current + BATCH_SIZE, end);
        for (__uint128_t n = current; n < batch_end; ++n) {
            auto word = perm();
            compute_md5(word,word_length, digest);
            
            if (memcmp(digest, target_digest, MD5_DIGEST_LENGTH) == 0) {
                found.store(true, std::memory_order_relaxed);
                result.clear();
                for(size_t i = 0; i < word_length; ++i) {
                    result += (char) word[i];
                }
                return;
            }
        }
        current = batch_end + 1;
    }
    //printf("worker end: %d\n", std::this_thread::get_id());
}

// Multi-threaded search for one hash
bool md5_crack_multithreaded(const unsigned char* target_digest, std::string& result) {
    // set number of threads, default to 4
    unsigned int num_threads = std::thread::hardware_concurrency();
    num_threads = num_threads ? num_threads : 4;

    std::atomic<bool> found(false);
    for(size_t word_length = MIN_PASSWORD_LENGTH; word_length <= MAX_PASSWORD_LENGTH; ++word_length) {
        const __uint128_t max_num = pow(word_list.size(), word_length);
        const __uint128_t per_thread = max_num / num_threads + 1;
        std::vector<std::thread> threads;
        
        // multi-threaded search
        for (unsigned i = 0; i < num_threads; ++i) {
            // range: [start, end)
            __uint128_t start = i * per_thread;
            __uint128_t end = (i == num_threads - 1) ? max_num : start + per_thread;
            threads.emplace_back(worker, start, end, target_digest, std::ref(found), std::ref(result), word_length);
        }

        for (auto& t : threads) {
            t.join();
        }

        if (found.load(std::memory_order_relaxed)){
            return true;
        }
    }
    return false;
    
}


int main(int argc, char* argv[]) {
    
    // Parse command line arguments
    if(argc == 2) {
        filename = argv[1];
    } else if (argc == 3) {
        filename = argv[1];
        MAX_PASSWORD_LENGTH = atoi(argv[2]);
    } else {
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

    // multi-threaded search
    std::vector<std::string> results;
    auto start_multi = std::chrono::steady_clock::now();
    for(auto& hash : hashes) {
        unsigned char target_digest[MD5_DIGEST_LENGTH];
        std::string result;
        hex_to_md5(hash, target_digest);
        std::cout << "Cracking MD5 hash: " << hash << "\n";
        if (md5_crack_multithreaded(target_digest, result)) {
            std::cout << result << "\t";
            results.push_back(result);
        } else {
            std::cout << "Not found!" << '\t';
        }
        auto end_multi = std::chrono::steady_clock::now();
        std::chrono::duration<double> multi_duration = end_multi - start_multi;
        std::cout << "time taken: " << multi_duration.count() << "s\n";
        start_multi = std::chrono::steady_clock::now();
    }
    std::cout << std::endl;
    std::cout << "Total " <<hashes.size() << " hashes, " << results.size() << " cracked.\n";
    return 0;
}