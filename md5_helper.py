import hashlib
import os
import sys

def md5_hash(s: str):
    return hashlib.md5(s.encode('utf-8')).hexdigest()

if __name__ == '__main__':
    input_filename = input('Enter input file name: ')
    if not os.path.exists(input_filename):
        print(f"Input file '{input_filename}' not found.")
        sys.exit(1)

    output_filename = 'hash.txt'

    with open(input_filename, 'r', encoding='utf-8') as infile, \
        open(output_filename, 'w', encoding='utf-8') as outfile:
        n = 0
        for line in infile:
            line = line.strip()
            if line != '':
                n += 1
                hash = md5_hash(line)
                outfile.write(hash + '\n')

    print(f"Total{n} passwords written to '{output_filename}'.")