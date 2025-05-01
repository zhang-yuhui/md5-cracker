import hashlib
import itertools
import os
import sys
from time import time

# Function to calculate MD5 hash
def md5_hash(s: str):
    return hashlib.md5(s.encode('utf-8')).hexdigest()

# Function to crack MD5 hash
def crack_md5(md5_target:str, dictionary:str, min_len:int = 1, max_len:int = 4) -> str:
    print(f"Cracking MD5 hash: {md5_target}")
    for length in range(min_len, max_len + 1):
        for guess in itertools.product(dictionary, repeat=length):
            guess = ''.join(guess)
            candidate_hash = md5_hash(guess)
            if candidate_hash == md5_target:
                print(guess, end="\t")
                return guess
    print("Not found!", end="\t")
    return None

def is_hash(hash: str):
    if len(hash) != 32:
        return False
    try:
        int(hash, 16)
        return True
    except ValueError:
        return False

def load_md5(filename: str = "hash.txt"):
    if not os.path.exists(filename):
        print(f"Dictionary file '{filename}' not found.")
        return None
    with open(filename, 'r') as f:
        md5_list = []
        for line in f:
            line = line.strip().lower()
            if is_hash(line):
                md5_list.append(line)
            else:
                print(f"Invalid hash: {line}, skipping...")
        if len(md5_list) == 0:
            print(f"No valid hashes found in {filename}.")
            return None
        else:
            print(f"Loaded {len(md5_list)} valid hashes from {filename}.")
            return md5_list

if __name__ == '__main__':
    # Default values
    WORD_LIST = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    MIN_PASSWORD_LENGTH = 1
    MAX_PASSWORD_LENGTH = 8
    hash_filename = "hash.txt"

    if len(sys.argv) > 1:
        hash_filename = sys.argv[1]
    else:
        print(f"Using default dictionary file: {hash_filename}")
    print(f"loading hash from {hash_filename}...")
    hash_list = load_md5(hash_filename)
    print()

    if hash_list is not None:
        result = []
        for hash in hash_list:
            start = time()
            if crack_md5(hash, WORD_LIST, MIN_PASSWORD_LENGTH, MAX_PASSWORD_LENGTH) is not None:
                result.append(hash)
            print(f"time taken: {time() - start:.4f} s")
        print(f"\nTotal {len(hash_list)} hashes and {len(result)} cracked.")
