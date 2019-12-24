#!/bin/bash

help() {
    echo "This script installs/configures haproxy and keepalived on a Ubuntu VM"
    echo "Options:"
    echo "        -a Backend application VM hostname (multiple allowed)"
    echo "        -p Backend application VM port (single, common for all application VMs)"
    echo "        -l Load balancer DNS name"
    echo "        -t Load balancer port"
    echo "        -m HAproxy VM being configured as MASTER"
    echo "        -b HAproxy VM being configured as BACKUP"
}

while getopts ":a:p:l:t:m:b:" opt; do
    case $opt in
        a) 
          APPVMS+=("$OPTARG")
          ;;

        p) 
          APPVM_PORT="$OPTARG"
          ;;

        l) 
          LBDNSNAME="$OPTARG"
          ;;

        t) 
          LB_PORT="$OPTARG"
          ;;

        m) 
          MASTERVM="$OPTARG"
          ;;

        b) 
          BACKUPVM="$OPTARG"
          ;;

        \?) echo "Invalid option: -$OPTARG" >&2
          help
          ;;
    esac
done

setup_haproxy() {
    # Install haproxy
    yum -y update
    yum install gcc pcre-devel tar make -y
    wget http://www.haproxy.org/download/2.1/src/haproxy-2.1.2.tar.gz -O ~/haproxy.tar.gz
    tar xzvf ~/haproxy.tar.gz -C ~/
    cd ~/haproxy-2.1.2
    make TARGET=linux-glibc
    make install

    mkdir -p /etc/haproxy
    mkdir -p /var/lib/haproxy
    touch /var/lib/haproxy/stats

    sudo ln -s /usr/local/sbin/haproxy /usr/sbin/haproxy
    cp ~/haproxy-2.1.2/examples/haproxy.init /etc/init.d/haproxy
    chmod 755 /etc/init.d/haproxy
    systemctl daemon-reload
    chkconfig haproxy on
    useradd -r haproxy
    # Enable haproxy (to be started during boot)
    # tmpf=`mktemp` && mv /etc/default/haproxy $tmpf && sed -e "s/ENABLED=0/ENABLED=1/" $tmpf > /etc/default/haproxy && chmod --reference $tmpf /etc/default/haproxy

    # Setup haproxy configuration file
    HAPROXY_CFG=/etc/haproxy/haproxy.cfg
    cp -p $HAPROXY_CFG ${HAPROXY_CFG}.default

    echo "
global
    log 127.0.0.1   local1 notice
    log 127.0.0.1   local0 info
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    

# Listen on all IP addresses. This is required for load balancer probe to work
listen http 
    bind 0.0.0.0:$LB_PORT
    mode tcp
    option tcplog
    balance roundrobin
    maxconn 10000" > $HAPROXY_CFG

    # Add application VMs to haproxy listener configuration 
    for APPVM in "${APPVMS[@]}"; do
        APPVM_IP=`host $APPVM | awk '/has address/ { print $4 }'`
        if [[ -z $APPVM_IP ]]; then
            echo "Unknown hostname $APPVM. Cannot be added to $HAPROXY_CFG." >&2
        else
            echo "    server $APPVM $APPVM_IP:$APPVM_PORT maxconn 5000 check" >> $HAPROXY_CFG
        fi 
    done

    chmod --reference ${HAPROXY_CFG}.default

    # Start haproxy service
    service haproxy start
}

setup_keepalived() {

    MASTERVM_IP=`host $MASTERVM | awk '/has address/ { print $4 }'`
    BACKUPVM_IP=`host $BACKUPVM | awk '/has address/ { print $4 }'`

    LB_IP=`host $LBDNSNAME | awk '/has address/ { print $4 }'`

    IS_MASTER=$( [[ `hostname -s` == $MASTERVM ]]; echo $? )

    # keepalived uses VRRP over multicast by default, but Azure doesn't support multicast 
    # (http://feedback.azure.com/forums/217313-azure-networking/suggestions/547215-multicast-support) 
    # keepalived needs to be configured with unicast. Support for unicast was introduced only in version 1.2.8. 
    # Default version available in Ubuntu 14.04 is 1.2.7-1ubuntu1. 

    # Install a newer version of keepalived from a ppa.
   # sudo snap install keepalived --classic
   # sudo apt-get install -y linux-headers-$(uname -r)
    yum -y install keepalived

    # Setup keepalived.conf
    KEEPALIVED_CFG=/etc/keepalived/keepalived.conf
    cp -p $KEEPALIVED_CFG ${KEEPALIVED_CFG}.default

    echo "
vrrp_script chk_appsvc {
    script /usr/local/sbin/keepalived-check-appsvc.sh
    interval 1
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    interface eth0 

    authentication {
        auth_type PASS
        auth_pass secr3t
    }

    virtual_router_id 51

    virtual_ipaddress {
        $LB_IP
    }

    track_script {
        chk_appsvc
    }

    notify /usr/local/sbin/keepalived-action.sh
    notify_stop \"/usr/local/sbin/keepalived-action.sh INSTANCE VI_1 STOP\"

" > $KEEPALIVED_CFG

    if [[ $IS_MASTER -eq 0 ]]; then
        echo "    state MASTER" >> $KEEPALIVED_CFG
        echo "    priority 101" >> $KEEPALIVED_CFG

        UNICAST_SRC_IP=$MASTERVM_IP
        UNICAST_PEER_IP=$BACKUPVM_IP

    else
        echo "    state BACKUP" >> $KEEPALIVED_CFG
        echo "    priority 100" >> $KEEPALIVED_CFG

        UNICAST_SRC_IP=$BACKUPVM_IP
        UNICAST_PEER_IP=$MASTERVM_IP

    fi

echo "
    unicast_src_ip $UNICAST_SRC_IP
    unicast_peer {
        $UNICAST_PEER_IP
    }

}
" >> $KEEPALIVED_CFG

    chmod --reference ${KEEPALIVED_CFG}.default $KEEPALIVED_CFG
        
    # Script to perform application level status check 
    cp keepalived-check-appsvc.sh /usr/local/sbin/keepalived-check-appsvc.sh
    chmod +x /usr/local/sbin/keepalived-check-appsvc.sh

    # Script to update probe status based on keepalived status
    cp keepalived-action.sh /usr/local/sbin/keepalived-action.sh
    chmod +x /usr/local/sbin/keepalived-action.sh

    # Enable binding non local VIP 
    echo "net.ipv4.ip_nonlocal_bind=1" >> /etc/sysctl.conf
    sysctl -p

    # Restart keepalived
    service keepalived stop && service keepalived start
}


# Setup haproxy
setup_haproxy

# Setup keepalived
setup_keepalived

