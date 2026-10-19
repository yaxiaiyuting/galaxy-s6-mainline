#!/bin/bash
# SM-G9209: build, synchronize diagnostics, verify embedding, and package.
# Usage: ./build_mainline.sh [output-name-without-extension]
set -euo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KERNEL_DIR="$BASE_DIR/linux-6.6"
UNI_DIR="$BASE_DIR/uniLoader"
OUT_DIR="$BASE_DIR/out"
NAME="${1:-boot-auto}"
[[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo 'Invalid output name' >&2; exit 2; }
mkdir -p "$OUT_DIR"
# Avoid races while copying blobs and replacing the diagnostic constants.
exec 9>"$OUT_DIR/.build-mainline.lock"
flock -n 9 || { echo 'Another mainline build is running' >&2; exit 1; }
export KERNEL_DIR UNI_DIR OUT_DIR NAME
cd "$KERNEL_DIR"
echo '[1/6] Build kernel'
python3 - <<'PY'
import os, time
from pathlib import Path
p = Path(os.environ['KERNEL_DIR'])/'include/generated/dsh_build_id.h'
p.write_text(f'#define DSH_BUILD_ID 0x{time.time_ns():016x}UL\n')
PY
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j16 Image exynos/exynos7420-zeroflte.dtb > "$OUT_DIR/$NAME-kernel.log" 2>&1 || {
    tail -60 "$OUT_DIR/$NAME-kernel.log"; exit 1;
}
echo '[2/6] Synchronize symbols and embedded Image'
python3 - <<'PY'
import json, os, re, shutil, subprocess
from pathlib import Path
k, u, out = (Path(os.environ[x]) for x in ('KERNEL_DIR', 'UNI_DIR', 'OUT_DIR'))
syms = {}
for line in subprocess.check_output(['aarch64-linux-gnu-nm', '-n', str(k/'vmlinux')], text=True).splitlines():
    fields = line.split()
    if len(fields) == 3:
        syms[fields[2]] = int(fields[0], 16)
required = ('_text', '_end', 'dsh_marker', 'dsh_regs', 'dsh_diag', 'dsh_diag_test_mode', 'init_pg_dir', 'init_pg_end')
assert all(n in syms for n in required), 'Required kernel symbols missing'
assert syms['_stext'] <= syms['dsh_probe_exit'] < syms['_etext'], 'Probe exit must be executable in the permanent high mapping'
config = (k/'.config').read_text()
vb = int(re.search(r'^CONFIG_ARM64_VA_BITS=(\d+)$', config, re.M)[1])
phys = int(re.search(r'^CONFIG_PAYLOAD_ENTRY=(0x[0-9a-fA-F]+)$', (u/'.config').read_text(), re.M)[1], 16)
text = syms['_text']
expected = {39: 0xffffffc080000000, 48: 0xffff800080000000}
assert vb in expected and text == expected[vb], 'Unsupported VA layout or stale vmlinux'
# The debug data gets its own writable, execute-never block in the identity map.
assert (syms['dsh_regs']-text)//(2*1024*1024) != (syms['dsh_probe_exit']-text)//(2*1024*1024), 'Debug data overlaps executing exit block'
image = (k/'arch/arm64/boot/Image').read_bytes()
assert image[56:60] == b'ARM\x64', 'Invalid arm64 Image header'
assert int.from_bytes(image[16:24], 'little') == syms['_end']-text, 'Image/vmlinux size mismatch'
values = {n: phys+syms[n]-text for n in required}
for n in ('dsh_marker', 'dsh_regs', 'dsh_diag'):
    assert 0 <= syms[n]-text < len(image), f'{n} not in loaded Image'
p = u/'main/boot.c'
s = p.read_text()
for macro, sym in [('DSH_MARKER_PHYS', 'dsh_marker'), ('DSH_REGS_PHYS', 'dsh_regs'), ('DSH_DIAG_PHYS', 'dsh_diag'), ('DSH_DIAG_TEST_PHYS', 'dsh_diag_test_mode')]:
    s, count = re.subn(rf'#define {macro}\s+0x[0-9a-fA-F]+UL', f'#define {macro} {values[sym]:#x}UL', s)
    assert count == 1, f'Missing or repeated {macro}'
diag_offset = syms['dsh_diag'] - text
build_id = int.from_bytes(image[diag_offset+24:diag_offset+32], 'little')
assert build_id != 0, 'Missing diagnostic build ID'
s, count = re.subn(r'#define DSH_DIAG_BUILD_ID\s+0x[0-9a-fA-F]+UL', f'#define DSH_DIAG_BUILD_ID {build_id:#x}UL', s)
assert count == 1, 'Missing or repeated diagnostic build ID macro'
p.write_text(s)
shutil.copyfile(k/'arch/arm64/boot/Image', u/'blob/Image')
shutil.copyfile(k/'arch/arm64/boot/dts/exynos/exynos7420-zeroflte.dtb', u/'blob/dtb')
metadata = {'va_bits': vb, 'kernel_virtual': {n: hex(syms[n]) for n in required},
            'kernel_physical': {n: hex(values[n]) for n in required}, 'diagnostic_build_id': hex(build_id)}
(out/(os.environ['NAME']+'-symbols.json')).write_text(json.dumps(metadata, indent=2)+'\n')
print(json.dumps(metadata, indent=2))
PY
cd "$UNI_DIR"
echo '[3/6] Build uniLoader'
# The linker INPUT(blob/Image) dependency is not tracked by this build system.
rm -f uniLoader uniLoader.o .uniLoader.cmd
make ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- -j16 > "$OUT_DIR/$NAME-loader.log" 2>&1 || {
    tail -60 "$OUT_DIR/$NAME-loader.log"; exit 1;
}
echo '[4/6] Verify linked payload'
python3 - <<'PY'
import os, subprocess
from pathlib import Path
u = Path(os.environ['UNI_DIR'])
syms = {}
for line in subprocess.check_output(['aarch64-linux-gnu-nm', '-n', 'uniLoader.o'], text=True).splitlines():
    fields = line.split()
    if len(fields) == 3:
        syms[fields[2]] = int(fields[0], 16)
blob = (u/'uniLoader').read_bytes()
image = (u/'blob/Image').read_bytes()
off = syms['kernel'] - syms['_reloc_start']
assert syms['kernel_size'] == len(image), 'Linker kernel_size mismatch'
assert blob[off:off+len(image)] == image, 'Embedded kernel mismatch'
dtb = (u/'blob/dtb').read_bytes()
dt_off = syms['dtb'] - syms['_reloc_start']
assert blob[dt_off:dt_off+len(dtb)] == dtb, 'Embedded DTB mismatch'
ramdisk = (u/'blob/ramdisk').read_bytes()
rd_off = syms['ramdisk'] - syms['_reloc_start']
assert syms['ramdisk_size'] == len(ramdisk), 'Linker ramdisk_size mismatch'
assert blob[rd_off:rd_off+len(ramdisk)] == ramdisk, 'Embedded ramdisk mismatch'
assert syms['dsh_loader_vectors'] % 2048 == 0, 'Unaligned exception vectors'
print(f'Verified all {len(image):,} embedded kernel bytes at offset {off:#x}')
print(f'Verified all {len(dtb):,} embedded DTB bytes at offset {dt_off:#x}')
print(f'Verified all {len(ramdisk):,} embedded ramdisk bytes at offset {rd_off:#x}')
PY
cp uniLoader "$OUT_DIR/uniLoader-$NAME.bin"
cp uniLoader.o "$OUT_DIR/uniLoader-$NAME.elf"
cd "$OUT_DIR"
echo '[5/6] Package Samsung boot image'
python3 mkbootimg_7420.py "uniLoader-$NAME.bin" tiny-ramdisk.gz dt-noefi.img "$NAME.img" \
    'console=tty0 maxcpus=1 loglevel=8'
echo '[6/6] Validate checksum and partition size'
python3 - <<'PY'
import hashlib, json, os, struct
from pathlib import Path
name = os.environ['NAME']
p = Path(name+'.img')
d = p.read_bytes()
assert d[:8] == b'ANDROID!'
ks, _, rs, _, ss, _, _, page, ds = struct.unpack_from('<9I', d, 8)
assert page == 2048 and ss == 0
pos, digest = page, hashlib.sha1()
for size in (ks, rs, ss, ds):
    digest.update(d[pos:pos+size]); digest.update(struct.pack('<I', size))
    pos += (size+page-1)//page*page
assert digest.digest() == d[576:596], 'Samsung SHA-1 mismatch'
assert d[pos:].startswith(b'SEANDROIDENFORCE\x02'), 'Samsung trailer missing'
part = 29360128
assert len(d) <= part, 'BOOT partition overflow'
padded = d + bytes(part-len(d))
Path(name+'-padded.img').write_bytes(padded)
report = {'image': name+'-padded.img', 'bytes': part,
          'sha256': hashlib.sha256(padded).hexdigest(),
          'kernel_sha256': hashlib.sha256(Path(os.environ['KERNEL_DIR']+'/arch/arm64/boot/Image').read_bytes()).hexdigest(),
          'dtb_sha256': hashlib.sha256(Path(os.environ['UNI_DIR']+'/blob/dtb').read_bytes()).hexdigest(),
          'ramdisk_sha256': hashlib.sha256(Path(os.environ['UNI_DIR']+'/blob/ramdisk').read_bytes()).hexdigest(),
          'samsung_sha1': digest.hexdigest()}
Path(name+'-manifest.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
PY
echo "Ready: $OUT_DIR/$NAME-padded.img (not flashed)"
