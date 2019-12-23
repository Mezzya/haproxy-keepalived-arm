#!/bin/bash

apt-get -y update
apt-get install -y apache2
systemctl start apache2
systemctl enable apache2
