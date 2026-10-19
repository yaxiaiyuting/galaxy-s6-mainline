#!/usr/bin/env python3
import os, time, select, termios, fcntl, array, glob, socket, sys, random
PORT = random.randint(20000,45000)
SCRIPT = sys.argv[1]
TIMEOUT = int(sys.argv[2]) if len(sys.argv)>2 else 60
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('192.168.42.1', PORT)); srv.listen(1); srv.settimeout(TIMEOUT)
acm = sorted(glob.glob('/dev/ttyACM*'))[0]
fd = os.open(acm, os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0]=a[1]=a[3]=0; a[2]=termios.CS8|termios.CREAD|termios.CLOCAL
a[4]=a[5]=termios.B115200; a[6][termios.VMIN]=a[6][termios.VTIME]=0
termios.tcsetattr(fd, termios.TCSANOW, a)
try: fcntl.ioctl(fd, termios.TIOCEXCL)
except OSError: pass
try: fcntl.ioctl(fd, termios.TIOCMBIS, array.array('i',[termios.TIOCM_DTR|termios.TIOCM_RTS]))
except OSError: pass
def rd(sec):
    out=bytearray(); end=time.time()+sec
    while time.time()<end:
        try: r,_,_=select.select([fd],[],[],0.2)
        except Exception: break
        if r:
            try: d=os.read(fd,65536)
            except OSError: continue
            if d: out.extend(d)
    return bytes(out)
rd(1)
cmd = "nohup bash -c '{ " + SCRIPT + f" ; }} > /dev/tcp/192.168.42.1/{PORT} 2>&1' >/dev/null 2>&1 &"
os.write(fd, (cmd+"\r\n").encode())
time.sleep(2); rd(0.5)
try:
    conn, addr = srv.accept(); conn.settimeout(20)
    data = b""
    while True:
        try: c = conn.recv(65536)
        except socket.timeout: break
        if not c: break
        data += c
    print(data.decode('utf-8','replace'))
    conn.close()
except socket.timeout:
    print("TIMEOUT")
srv.close(); os.close(fd)
