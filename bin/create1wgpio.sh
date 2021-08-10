#!/bin/bash
grep -i "dtoverlay=w1-gpio,gpiopin=" /boot/config.txt #überprüfen ob die enträge schon vorhanden sind
if [ $? -eq 0 ]; then echo"" #wenn sie schon vorhanden sind nichts tun
else echo "dtoverlay=w1-gpio,gpiopin=4,pullup=on" >> /boot/config.txt #ansonsten die Einträge einfügen
fi
