#!/bin/bash

pluginname=REPLACELBPPLUGINDIR

gpio=$(jq '.gpio' $LBPCONFIG/$pluginname/owfs.json)

if [ $gpio = "true" ]; then
	grep -i "dtoverlay=w1-gpio,gpiopin=4" /boot/config.txt #überprüfen ob die enträge schon vorhanden sind
	if [ $? -eq 0 ]; then 
		echo"" #wenn sie schon vorhanden sind nichts tun
	else 
		echo "" >> /boot/config.txt # Leerzeile
		pullup=$(jq '.usb' $LBPCONFIG/$pluginname/owfs.json)
		if [ $pullup = "true" ]; then 
			echo "dtoverlay=w1-gpio,gpiopin=4,pullup=on" >> /boot/config.txt
		else
			echo "dtoverlay=w1-gpio,gpiopin=4,pullup=off" >> /boot/config.txt
		fi
	fi
else
	sed -i 's/dtoverlay=w1-gpio,gpiopin=4.*$//g' /boot/config.txt
fi
