#!/bin/sh
# Read-only verification for the Cypress MBR touchkey bring-up.
echo "== dmesg =="
dmesg | grep -i -E "mbr-touchkey|vtouch" || echo "(no touchkey dmesg yet)"
echo
echo "== LDO21 regulator =="
for r in /sys/class/regulator/regulator.*; do
	[ "$(cat "$r/name" 2>/dev/null)" = "vtouch_3.3v" ] && \
		echo "$r: name=$(cat "$r/name") state=$(cat "$r/state")"
done
echo
echo "== input devices =="
for n in /sys/class/input/event*/device/name; do
	printf "%s: " "$n"; cat "$n"
done
echo
echo "== interrupts =="
grep -i mbr /proc/interrupts || echo "(no mbr-touchkey IRQ)"
echo
echo "== uinput / remapper =="
ls -l /dev/uinput 2>/dev/null || echo "(no /dev/uinput)"
systemctl is-active touchkey-remap.service 2>/dev/null || true
echo
echo "Run 'python3 /tmp/evread.py mbr-touchkey 30' (or evtest) and press BACK/RECENT."
