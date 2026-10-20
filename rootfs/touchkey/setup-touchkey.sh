#!/bin/sh
# Install the touchkey BACK/RECENT remapper on the phone (run as root).
set -e
cd "$(dirname "$0")"

if [ ! -x touchkey-remap ]; then
	make
fi

install -m755 touchkey-remap /usr/local/bin/touchkey-remap
install -m644 touchkey-remap.service /etc/systemd/system/touchkey-remap.service
systemctl daemon-reload
systemctl enable --now touchkey-remap.service

echo "installed. status:"
systemctl --no-pager status touchkey-remap.service || true
