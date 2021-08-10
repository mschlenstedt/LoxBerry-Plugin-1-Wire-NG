#!/bin/sh

if [ ! $1 ]; then
	echo "usage: $0 SERIAL"
fi

echo "server: device = ftdi:s:0x0403:0x6001:$1" > /opt/loxberry/data/plugins/1-wire-ng/ftdidevices.dat
