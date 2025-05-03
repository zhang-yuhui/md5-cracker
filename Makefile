SHELL      := /bin/bash
OS         := $(shell uname -s)

ifeq ($(OS),Linux) # Linux
  OPENSSL := -I/usr/include/openssl -L/usr/lib -lssl -lcrypto
else ifeq ($(OS),Darwin) # MacOS
  OPENSSL := -I/opt/homebrew/opt/openssl@3/include -L/opt/homebrew/opt/openssl@3/lib -lssl -lcrypto
else
  $(error Unsupported OS: $(OS))
endif

CXX := g++
CXXFLAGS := -std=c++23 -O3 -ffast-math -pthread 

md5_multithread: md5_multithread.cpp permutation.cpp
	$(CXX) md5_multithread.cpp permutation.cpp $(CXXFLAGS) -o md5_multithread $(OPENSSL) 

CXX_GPU = nvcc
CXX_FLAGS_GPU = -O3

md5-gpu:
	$(CXX_GPU) $(CXX_FLAGS_GPU) md5_gpu.cu -o md5_gpu

all: md5_multithread

clean: 
	rm -f md5_multithread md5_gpu

phony: all clean