#!/usr/bin/env python3
"""Build report init, repair known archive defects, and validate unpack order."""
import argparse
import gzip
import hashlib
import json
import posixpath
import stat
import subprocess
import tempfile
from collections import Counter
from pathlib import Path
from cpio_newc import members

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
assert args.source.resolve() != args.output.resolve()
source = args.source.read_bytes()
old, tail = members(gzip.decompress(source))
def normalized(item):
    return posixpath.normpath(item['name'])

def data(item):
    start = item['data_offset']
    return item['entry'][start:start + item['fields'][6]]

# p106 includes the busybox applet named "busybox" as a second archive entry.
# Linux unpacks that symlink after the binary, replacing it with a self-loop.
duplicates = {name: count for name, count in Counter(map(normalized, old)).items() if count > 1}
dropped = []
retained = list(old)
if duplicates:
    assert duplicates == {'bin/busybox': 2}, f'Unexpected duplicate paths: {duplicates}'
    matches = [item for item in old if normalized(item) == 'bin/busybox']
    assert stat.S_ISREG(matches[0]['fields'][1]) and data(matches[0]).startswith(b'\x7fELF')
    assert stat.S_ISLNK(matches[1]['fields'][1]) and data(matches[1]).rstrip(b'\0') == b'busybox'
    retained = [item for item in old if item is not matches[1]]
    dropped = ['bin/busybox self-referencing duplicate symlink']
root = Path(__file__).resolve().parent
init = args.output.with_suffix('.init')
subprocess.run(['aarch64-linux-gnu-gcc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                '-static', '-s', '-o', str(init), str(root/'pmsg-init.c')], check=True)
elf_info = subprocess.check_output(['aarch64-linux-gnu-readelf', '-h', '-l', str(init)], text=True)
assert 'INTERP' not in elf_info and 'AArch64' in elf_info
test = subprocess.check_output(['qemu-aarch64', str(init), '--self-test'], text=True)
replacements = {'init': init.read_bytes(), 'etc/rc': (root/'rc').read_bytes()}
entries, seen = [], []
for item in retained:
    name = item['name']
    while name.startswith('./'):
        name = name[2:]
    if name not in replacements:
        entries.append(item['entry'])
        continue
    assert item['fields'][4] == 1, 'Refuse to replace a hard-linked member'
    payload = replacements[name]
    header = bytearray(item['entry'][:item['data_offset']])
    header[54:62] = f'{len(payload):08x}'.encode()
    if header[:6] == b'070702':
        header[102:110] = f'{sum(payload)&0xffffffff:08x}'.encode()
    entries.append(bytes(header) + payload + bytes(-len(payload) % 4))
    seen.append(name)
assert sorted(seen) == sorted(replacements)
raw = b''.join(entries) + tail
raw += bytes(-len(raw) % 512)
new, _ = members(raw)
assert len(new) == len(retained)
for before, after in zip(retained, new):
    assert before['name'] == after['name']
    name = before['name'].removeprefix('./')
    if name not in replacements:
        assert before['entry'] == after['entry']
    else:
        assert all(before['fields'][i] == after['fields'][i] for i in range(13) if i not in (6, 12))

# Linux initramfs extraction does not create missing parent directories.
# Put all directories first and add absent ancestors of existing entries.
tree = {normalized(item): item for item in new}
assert len(tree) == len(new), 'Duplicate final archive paths'
added_directories = []
next_inode = max(item['fields'][0] for item in new) + 1
for name in list(tree):
    parent = posixpath.dirname(name)
    while parent and parent != '.':
        if parent in tree:
            assert stat.S_ISDIR(tree[parent]['fields'][1]), f'Non-directory parent: {parent}'
        else:
            encoded_name = parent.encode() + b'\0'
            fields = [next_inode, stat.S_IFDIR | 0o755, 0, 0, 2, 0, 0, 0, 0, 0, 0,
                      len(encoded_name), 0]
            next_inode += 1
            entry = b'070701' + ''.join(f'{field:08x}' for field in fields).encode() + encoded_name
            entry += bytes(-len(entry) % 4)
            item = members(entry + next(x['entry'] for x in new if x['name'] == 'TRAILER!!!'))[0][0]
            tree[parent] = item
            added_directories.append(parent)
        parent = posixpath.dirname(parent)
directories = sorted((item for item in tree.values() if stat.S_ISDIR(item['fields'][1])),
                     key=lambda item: (normalized(item).count('/'), normalized(item)))
others = [item for item in new if not stat.S_ISDIR(item['fields'][1])]
raw = b''.join(item['entry'] for item in directories + others) + tail
raw += bytes(-len(raw) % 512)
new, _ = members(raw)
unpacked_directories = {'.'}
for item in new:
    name = normalized(item)
    parent = posixpath.dirname(name)
    assert not name.startswith('/') and name != '..' and not name.startswith('../')
    assert not parent or parent in unpacked_directories, f'Parent not yet unpacked: {name}'
    if stat.S_ISDIR(item['fields'][1]):
        unpacked_directories.add(name)

# Check the final filesystem, rather than only the bytes of individual entries.
names = [normalized(item) for item in new]
assert len(names) == len(set(names)), 'Duplicate final archive paths'
tree = dict(zip(names, new))
def resolve(name):
    visited = set()
    while True:
        assert name not in visited, f'Symlink loop at {name}'
        visited.add(name)
        assert name in tree, f'Dangling symlink target: {name}'
        item = tree[name]
        if not stat.S_ISLNK(item['fields'][1]):
            return item
        target = data(item).rstrip(b'\0').decode()
        assert '\0' not in target
        name = posixpath.normpath(target.lstrip('/') if target.startswith('/') else
                                 posixpath.join(posixpath.dirname(name), target))
        assert name != '..' and not name.startswith('../'), 'Symlink escapes root'
for name, item in tree.items():
    if stat.S_ISLNK(item['fields'][1]):
        resolve(name)
shell = resolve('bin/sh')
assert stat.S_ISREG(shell['fields'][1]) and shell['fields'][1] & 0o111
assert data(shell).startswith(b'\x7fELF')
with tempfile.TemporaryDirectory(prefix='g9209-shell-') as directory:
    extracted = Path(directory)
    # Do not use mkdir(parents=True): this must fail on invalid archive order.
    for item in new:
        name = normalized(item)
        if name == 'TRAILER!!!':
            continue
        target = extracted/name
        mode = item['fields'][1]
        if stat.S_ISDIR(mode):
            target.mkdir(exist_ok=name == '.')
        elif stat.S_ISREG(mode):
            target.write_bytes(data(item))
            target.chmod(mode & 0o777)
        elif stat.S_ISLNK(mode):
            target.symlink_to(data(item).rstrip(b'\0').decode())
        # Device nodes are supplied by devtmpfs at runtime; no host mknod.
    executable = extracted/'bin/sh'
    rc = extracted/'etc/rc'
    assert rc.read_bytes() == replacements['etc/rc']
    shell_test = subprocess.check_output([
        'qemu-aarch64', '-0', 'sh', str(executable), '-c',
        "test -r \"$1\" && read -r line <\"$1\" && test \"$line\" = '#!/bin/sh' && "
        "test \"$(printf '%s' 'a b;c')\" = 'a b;c' && printf '%s\\n' G9209_SHELL_PASS",
        'archive-test', str(rc)
    ], text=True, timeout=10)
    assert shell_test == 'G9209_SHELL_PASS\n'
compressed = gzip.compress(raw, mtime=0)
args.output.write_bytes(compressed)
assert args.source.read_bytes() == source
report = {'source_sha256': hashlib.sha256(source).hexdigest(),
          'output_sha256': hashlib.sha256(compressed).hexdigest(),
          'source_members': len(old), 'members': len(new), 'replaced': seen,
          'dropped': dropped, 'final_paths_unique': True, 'symlinks_resolved': True,
          'added_directories': added_directories, 'parent_directories_first': True,
          'bytes': len(compressed),
          'self_test': test.strip(), 'shell_test': shell_test.strip()}
args.output.with_suffix(args.output.suffix+'.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
