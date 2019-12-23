#!/bin/sh

if [ ! $1 ]; then
	echo "usage: $0 SERIAL"
fi

echo "server: device = ftdi:s:0x0403:0x6001:$1" > REPLACELBPDATADIR/ftdidevices.dat
