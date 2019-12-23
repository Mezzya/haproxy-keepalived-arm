#!/bin/bash

apt -y update
apt -y upgrade
apt install -y apache2
systemctl start apache2
systemctl enable apache2
