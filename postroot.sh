#!/bin/bash

# To use important variables from command line use the following code:
COMMAND=$0    # Zero argument is shell command
PTEMPDIR=$1   # First argument is temp folder during install
PSHNAME=$2    # Second argument is Plugin-Name for scipts etc.
PDIR=$3       # Third argument is Plugin installation folder
PVERSION=$4   # Forth argument is Plugin version
#LBHOMEDIR=$5 # Comes from /etc/environment now. Fifth argument is
              # Base folder of LoxBerry
PTEMPPATH=$6  # Sixth argument is full temp path during install (see also $1)

# Combine them with /etc/environment
PCGI=$LBPCGI/$PDIR
PHTML=$LBPHTML/$PDIR
PTEMPL=$LBPTEMPL/$PDIR
PDATA=$LBPDATA/$PDIR
PLOG=$LBPLOG/$PDIR # Note! This is stored on a Ramdisk now!
PCONFIG=$LBPCONFIG/$PDIR
PSBIN=$LBPSBIN/$PDIR
PBIN=$LBPBIN/$PDIR

echo "<INFO> Installation as root user started."

echo "<INFO> Adding Testing branch to apt sources..."
echo 'deb http://ftp.de.debian.org/debian/ testing main non-free contrib' > /etc/apt/sources.list.d/testing.list
echo 'APT::Default-Release "stable";' > /etc/apt/apt.conf.d/99myDefaultRelease
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys  04EE7237B7D453EC 648ACFD622F3D138
apt-get update

echo "<INFO> Installing owserver from Testing branch (stable branch is broken in Debian Buster)..."
apt-get -t testing install owfs owserver owhttpd owftpd owfs-fuse owfs-common owserver libow-3.2-3 libftdi1-2

echo "<INFO> Stopping and disabling OWFS services..."
systemctl stop owserver
systemctl stop owfs
systemctl stop owftpd
systemctl stop owhttpd
systemctl disable owfs
systemctl disable owftpd

exit 0
