#include "permutation.h"

Permutation::Permutation(const std::string& words, size_t word_length) {
    dict_length_ = words.size();
    counter_ = 0;
    word_length_ = word_length;
    counter_max_ = std::pow(dict_length_, word_length_);
    buffer = new unsigned char[word_length_];
    for(const auto& word : words) {
        word_list_.push_back(static_cast<unsigned char>(word));
    }
}

void Permutation::set_counter(__uint128_t counter) {
    counter_ = counter;
}

const unsigned char* Permutation::operator()() {
    auto result = get_permut(counter_);
    counter_++;
    return result;
}

const unsigned char* Permutation::get_permut(__uint128_t index) {
    if(index >= counter_max_){
        //printf("Index out of range: %lld \n", index);
        return nullptr;
    }
    size_t tmp = index;
    for(size_t i = 0; i < word_length_; ++i) {
        buffer[i] = word_list_[tmp % dict_length_];
        tmp /= dict_length_;
    }
    return buffer;
}

Permutation::~Permutation() {
    delete[] buffer;
}
