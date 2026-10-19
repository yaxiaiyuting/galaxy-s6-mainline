import os, time, select, termios, fcntl, array, glob
out_path = '/tmp/loader_prevlog.txt'
cands = sorted(glob.glob('/dev/ttyACM*'))
print("ACM:", cands, flush=True)
fd = None
for c in cands:
    try: fd = os.open(c, os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK); break
    except OSError: continue
if fd is None:
    print("no acm", flush=True); raise SystemExit
a = termios.tcgetattr(fd)
a[0]=a[1]=a[3]=0; a[2]=termios.CS8|termios.CREAD|termios.CLOCAL
a[4]=a[5]=termios.B115200; a[6][termios.VMIN]=a[6][termios.VTIME]=0
termios.tcsetattr(fd, termios.TCSANOW, a)
try: fcntl.ioctl(fd, termios.TIOCEXCL)
except OSError: pass
try: fcntl.ioctl(fd, termios.TIOCMBIS, array.array('i',[termios.TIOCM_DTR|termios.TIOCM_RTS]))
except OSError: pass
def rd(sec):
    out = bytearray(); end = time.time()+sec
    while time.time() < end:
        try: r,_,_ = select.select([fd],[],[],0.2)
        except Exception: break
        if r:
            try: d = os.read(fd, 65536)
            except OSError: continue
            if d: out.extend(d)
    return bytes(out)
rd(2)
os.write(fd, b'log\r\n')
buf = bytearray()
end = time.time() + 70
while time.time() < end:
    buf.extend(rd(1.0))
    if b'=== end ===' in bytes(buf) or b'[prevlog] === end ===' in bytes(buf):
        break
open(out_path, 'wb').write(bytes(buf))
print(f"captured {len(buf)} bytes -> {out_path}", flush=True)
try: os.close(fd)
except OSError: pass
