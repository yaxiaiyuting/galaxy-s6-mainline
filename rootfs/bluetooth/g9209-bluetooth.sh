#!/bin/bash
# G9209 BCM4358 UART 蓝牙初始化（bash 版，与实测流程一致）
# 用 dmesg 判断固件就绪，比 btmgmt 轮询可靠。
set -u
ADDR=$(python3 -c "import json;print(json.load(open('/etc/g9209-bluetooth.conf'))['factory_address'].upper())")
log() { echo "G9209-BT: $*"; }

# 1) 清理残留
pkill -f btattach 2>/dev/null; pkill -f 'gpioset --mode' 2>/dev/null
sleep 2
rmmod g9209_bt_transport 2>/dev/null
sleep 1
# 等 hci0 消失
for i in $(seq 1 20); do [ -e /sys/class/bluetooth/hci0 ] || break; sleep 0.25; done
log "clean state: hci=$(ls /sys/class/bluetooth/ 2>/dev/null | tr '\n' ' ')"

# 2) BT_EN 拉低 3 秒硬复位
gpioset --mode=time --sec=3 gpiochip32 1=0 || log "BT_EN low failed"

# 3) 加载时钟/LPASS 模块
modprobe g9209_bt_transport || { log "modprobe failed"; exit 1; }
sleep 0.5

# 4) BT_WAKE=1, BT_EN=1（常驻持有）
gpioset --mode=signal gpiochip27 4=1 &
WAKE_PID=$!
sleep 0.5
gpioset --mode=signal gpiochip32 1=1 &
EN_PID=$!
sleep 0.5
log "BT_EN=$(cat /sys/kernel/debug/gpio | grep gpio-178 | tr -s ' ')"

# 5) 挂接 HCI
btattach -B /dev/ttySAC0 -P bcm -S 115200 &
BT_PID=$!

# 6) 等固件下载完成
# 注意：dmesg 里可能残留上一次尝试的 "Samsung Zero EU" 行，
# 直接 grep 会假阳性。先记录基线计数，等它增加。
BASE=$(dmesg | grep -c "BCM4358A3 Samsung Zero EU")
ready=0
for i in $(seq 1 120); do
  NOW=$(dmesg | grep -c "BCM4358A3 Samsung Zero EU")
  if [ "$NOW" -gt "$BASE" ]; then ready=1; break; fi
  sleep 0.5
done
if [ "$ready" != 1 ]; then
  log "firmware init timeout"
  kill $BT_PID $EN_PID $WAKE_PID 2>/dev/null
  exit 1
fi
log "firmware loaded"

# 6b) 固件就绪后控制器还在收尾（HCI_SETUP/POWERON），此时 power off 会
#     报 0x0a (Busy)，public-addr 会报 0x0b (Rejected)。等它彻底稳定。
sleep 4

# 7) 改地址：power off → 确认断电 → public-addr，整体重试 5 轮
set_addr_ok=0
for attempt in $(seq 1 5); do
  # power off（Busy 就重试）
  off_ok=0
  for i in $(seq 1 40); do
    btmgmt -i 0 power off >/dev/null 2>&1
    S=$(btmgmt -i 0 info 2>/dev/null | grep "current settings")
    case "$S" in
      *powered*) sleep 0.5 ;;
      *) off_ok=1; break ;;
    esac
  done
  if [ "$off_ok" != 1 ]; then
    log "attempt $attempt: controller still powered"
    sleep 2; continue
  fi
  OUT=$(btmgmt -i 0 public-addr "$ADDR" 2>&1)
  RC=$?
  # 目标地址与当前相同时 btmgmt 静默返回 0（无输出），也算成功
  if [ "$RC" = 0 ] && ! echo "$OUT" | grep -q "failed"; then
    log "attempt $attempt: address set OK"
    set_addr_ok=1; break
  fi
  log "attempt $attempt: public-addr rc=$RC out=$(echo "$OUT" | tr -d '\r\n' | sed 's/\x1b\[[0-9;]*m//g' | head -c 100)"
  sleep 2
done
if [ "$set_addr_ok" != 1 ]; then log "WARNING: factory address not restored"; fi
sleep 1
btmgmt -i 0 power on >/dev/null 2>&1
sleep 1
log "done: $(btmgmt -i 0 info 2>/dev/null | grep -E 'addr ' | tr -s ' ')"
log "hci0 ready"
# 保持前台（守护子进程）
wait $BT_PID
