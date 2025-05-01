#pragma once
#include <vector>
#include <string>
#include <cmath>
#include <cstdio>
class Permutation {
public:
    Permutation(const std::string& words, size_t word_length = 1);
    ~Permutation();
    void set_counter(__uint128_t counter);
    constexpr __uint128_t get_counter() const { return counter_; }
    const unsigned char* operator() ();

private:
    std::vector<unsigned char> word_list_;
    __uint128_t counter_ = 0;
    size_t dict_length_ = 0;
    size_t word_length_ = 0;
    __uint128_t counter_max_ = 0;
    unsigned char* buffer = nullptr;
    const unsigned char* get_permut(__uint128_t index);
};