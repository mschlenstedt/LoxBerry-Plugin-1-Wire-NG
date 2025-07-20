#!/bin/bash

pluginname=REPLACELBPPLUGINDIR

if [ -e /boot/firmware/config.txt ]; then
	configfile="/boot/firmware/config.txt"
elif [ -e /boot/config.txt ]; then
	configfile="/boot/config.txt"
else
	echo "Error: No config.txt found. Is this a Raspberry?"
	exit 1
fi

# Clean config
sed -i '/dtoverlay=w1-gpio,gpiopin=4.*$/d' $configfile

gpio=$(jq -r '.gpio' $LBPCONFIG/$pluginname/owfs.json)

if [ $gpio = "true" ]; then
	sed -i '${/^$/d;}' $configfile # Remove last blank line
	echo "" >> $configfile
	pullup=$(jq -r '.pullup' $LBPCONFIG/$pluginname/owfs.json)
	if [ $pullup = "true" ]; then 
		echo "dtoverlay=w1-gpio,gpiopin=4,pullup=on" >> $configfile
	else
		echo "dtoverlay=w1-gpio,gpiopin=4,pullup=off" >> $configfile
	fi
fi

echo "Done…"
exit 0
