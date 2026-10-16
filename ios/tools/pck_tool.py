#!/usr/bin/env python3
"""Lists or extracts files from a Godot 4 .pck (formats 2 and 3).
Usage: pck_tool.py list PCK [PATTERN]
       pck_tool.py extract PCK OUTDIR PATTERN   (fnmatch on res:// paths)"""
import fnmatch, os, struct, sys

def read_directory(f):
    magic = f.read(4)
    if magic != b'GDPC':
        raise SystemExit('not a pck')
    version, major, minor, patch, flags = struct.unpack('<5I', f.read(20))
    file_base = struct.unpack('<Q', f.read(8))[0]
    dir_offset = None
    if version >= 3:
        dir_offset = struct.unpack('<Q', f.read(8))[0]
    f.read(16 * 4)
    if flags & 1:
        raise SystemExit('encrypted directory')
    if dir_offset is not None:
        f.seek(dir_offset)
    count = struct.unpack('<I', f.read(4))[0]
    entries = []
    for _ in range(count):
        length = struct.unpack('<I', f.read(4))[0]
        path = f.read(length).rstrip(b'\0').decode('utf-8')
        offset, size = struct.unpack('<QQ', f.read(16))
        f.read(16)  # md5
        entry_flags = struct.unpack('<I', f.read(4))[0]
        entries.append((path, offset + (file_base if flags & 2 else 0), size, entry_flags))
    return (version, major, minor, patch, flags), entries

def main():
    command, pck = sys.argv[1], sys.argv[2]
    with open(pck, 'rb') as f:
        header, entries = read_directory(f)
        if command == 'list':
            pattern = sys.argv[3] if len(sys.argv) > 3 else '*'
            print('header', header, 'files', len(entries))
            for path, offset, size, flags in entries:
                if fnmatch.fnmatch(path, pattern):
                    print(f'{size:12d} {flags:2d} {path}')
        elif command == 'extract':
            outdir, pattern = sys.argv[3], sys.argv[4]
            for path, offset, size, flags in entries:
                if not fnmatch.fnmatch(path, pattern):
                    continue
                if flags & 1:
                    raise SystemExit(f'{path} is encrypted')
                relative = path.split('://', 1)[-1]
                target = os.path.join(outdir, relative)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                f.seek(offset)
                remaining = size
                with open(target, 'wb') as out:
                    while remaining:
                        block = f.read(min(remaining, 8 << 20))
                        out.write(block)
                        remaining -= len(block)
                print(f'{size:12d} {relative}')

main()
