CXX := g++
CXXFLAGS := -std=c++23 -O3 -ffast-math -pthread 
OPENSSL := -I/opt/homebrew/opt/openssl@3/include -L/opt/homebrew/opt/openssl@3/lib -lssl -lcrypto

md5_multithread: md5_multithread.cpp permutation.cpp
	$(CXX) $(CXXFLAGS) -o md5_multithread $(OPENSSL) md5_multithread.cpp permutation.cpp

CXX_GPU = nvcc
CXX_FLAGS_GPU = -O3

md5-gpu:
	$(CXX_GPU) $(CXX_FLAGS_GPU) md5_gpu.cu -o md5_gpu

all: md5_multithread

clean: rm -f md5_multithread md5_gpu

phony: all clean