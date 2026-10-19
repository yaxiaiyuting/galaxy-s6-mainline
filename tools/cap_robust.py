import os, time, select, termios, fcntl, array, glob, sys
out_path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/boot_cap.log'
dur = int(sys.argv[2]) if len(sys.argv) > 2 else 130
raw = open(out_path, 'wb')
def open_acm():
    for c in sorted(glob.glob('/dev/ttyACM*')):
        try:
            fd = os.open(c, os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
            a = termios.tcgetattr(fd)
            a[0]=a[1]=a[3]=0; a[2]=termios.CS8|termios.CREAD|termios.CLOCAL
            a[4]=a[5]=termios.B115200; a[6][termios.VMIN]=a[6][termios.VTIME]=0
            termios.tcsetattr(fd, termios.TCSANOW, a)
            try: fcntl.ioctl(fd, termios.TIOCEXCL)
            except OSError: pass
            try: fcntl.ioctl(fd, termios.TIOCMBIS, array.array('i',[termios.TIOCM_DTR|termios.TIOCM_RTS]))
            except OSError: pass
            return fd, c
        except OSError:
            continue
    return None, None
# 1) 发 boot
fd, path = open_acm()
if fd is None:
    print("no acm"); sys.exit(1)
print(f"using {path}", flush=True)
for cmd in ['setcmd', 'watchdog arm', 'boot']:
    try: os.write(fd, (cmd+'\n').encode()); time.sleep(1.2)
    except OSError: pass
# drain a bit
end=time.time()+2
while time.time()<end:
    try: select.select([fd],[],[],0.2); os.read(fd,65536)
    except Exception: pass
try: os.close(fd)
except OSError: pass
# 2) 持续读（自动重连）
end = time.time() + dur
total = 0
fd = None
while time.time() < end:
    if fd is None:
        fd, path = open_acm()
        if fd is None:
            time.sleep(0.3); continue
        # 打开后立即 drain
    try:
        r,_,_ = select.select([fd],[],[],0.3)
    except Exception:
        r = []
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            d = b''
        if d:
            raw.write(d); raw.flush(); total += len(d)
    # 检测设备是否消失（重新枚举）
    if not glob.glob('/dev/ttyACM*'):
        try: os.close(fd)
        except OSError: pass
        fd = None
raw.close()
print(f"captured {total} bytes -> {out_path}", flush=True)
