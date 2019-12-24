#!/bin/bash

yum -y update
yum -y install apache2
systemctl start apache2
systemctl enable apache2
