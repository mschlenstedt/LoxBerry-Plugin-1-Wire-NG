#!/bin/bash

pluginname=REPLACELBPPLUGINDIR

# Clean config
sed -i '/dtoverlay=w1-gpio,gpiopin=4.*$/d' /boot/config.txt

gpio=$(jq -r '.gpio' $LBPCONFIG/$pluginname/owfs.json)

if [ $gpio = "true" ]; then
	sed -i '${/^$/d;}' /boot/config.txt # Remove last blank line
	echo "" >> /boot/config.txt
	pullup=$(jq -r '.pullup' $LBPCONFIG/$pluginname/owfs.json)
	echo "$pullup"
	if [ $pullup = "true" ]; then 
		echo "dtoverlay=w1-gpio,gpiopin=4,pullup=on" >> /boot/config.txt
	else
		echo "dtoverlay=w1-gpio,gpiopin=4,pullup=off" >> /boot/config.txt
	fi
fi
exit 0
