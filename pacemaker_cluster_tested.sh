#!/bin/bash
# HA Pacemaker Corosync DRBD for Centos 8 Stream

set -e
if [[ $(id -u) -ne 0 ]] ; then echo "Please run as root" ; exit 1 ; fi

# DO ON ALL NODES
#################
# Prepare system
export LANGUAGE=en_US.UTF-8
export LANG=en_US.iso-8859-2
export LC_ALL=en_US.UTF-8

# Enable repository on Centos 8 
# mkdir -p /etc/yum.repos.d/rpmsave
# mv /etc/yum.repos.d/*.rpmsave /etc/yum.repos.d/rpmsave/

sed -i 's|^enabled=.*|enabled=1|g' /etc/yum.repos.d/*-HighAvailability.repo
sed -i 's|^enabled=.*|enabled=1|g' /etc/yum.repos.d/*-PowerTools.repo 

# Add Elpro and epel repository for kmod-drbd and other 
rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
dnf install -y elrepo-release epel-release
dnf update -y

# Install Basic tools
dnf install -y htop nano curl wget autoconf automake make gcc git
dnf clean all

timedatectl set-timezone Europe/Warsaw
swapoff -a
systemctl disable swap.target
rm -rf /swap.img 
sed -i '/swap/s/^/#/' /etc/fstab

# Add all hosts to /etc/hosts
echo "192.168.92.201 nucone.maas" >> /etc/hosts
echo "192.168.92.202 nuctwo.maas" >> /etc/hosts
echo "192.168.92.203 nucthree.maas" >> /etc/hosts

# Configure sysctl
touch /etc/sysctl.d/10-ip.conf
cat << EOFsysctl > /etc/sysctl.d/10-ip.conf
net.core.rmem_max = 262144
net.core.wmem_max = 262144
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.ip_forward = 1
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_unprivileged_port_start=80
vm.swappiness=10
EOFsysctl
sysctl --system

# Install components
dnf install -y pacemaker corosync pcs drbd kmod-drbd90 drbd-pacemaker
systemctl disable drbd
systemctl enable pacemaker
systemctl enable corosync

dnf module install -y virt
systemctl enable --now libvirtd.service
firewall-cmd --add-port=7780-7800/tcp --permanent
firewall-cmd --add-service=high-availability --permanent
firewall-cmd --reload

# For web access
# dnf install -y cockpit-machines cockpit-packagekit cockpit-composer 
# systemctl enable --now cockpit.socket

# Enable KVM nesting in /etc/modprobe.d/kvm.conf
if lscpu | grep -iq "Intel" 
then
  echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm.conf
elif lscpu | grep -iq "AMD" 
then
  echo "options kvm_amd nested=1" > /etc/modprobe.d/kvm.conf
fi
# Corosync config
# Can also do it using: pcs cluster setup --name cluster nucone.maas nuctwo.maas nucthree.maas --start
touch /etc/corosync/corosync.conf
cat << EOFcorosync > /etc/corosync/corosync.conf
totem {
  version: 2
  secauth: off
  cluster_name: cluster
  transport: knet
  rrp_mode: passive
}
nodelist {
  node {
    ring0_addr: 192.168.92.201
    ring1_addr: 192.168.122.201
    nodeid: 1
    name: nucone.maas
}
  node {
    ring0_addr: 192.168.92.202
    ring1_addr: 192.168.122.202
    nodeid: 2
    name: nuctwo.maas
} 
  node {
    ring0_addr: 192.168.92.203
    ring1_addr: 192.168.122.203
    nodeid: 3
    name: nucthree.maas
}
}  
quorum {
  provider: corosync_votequorum
  two_node: 1
}
logging {
  to_syslog: yes
}
EOFcorosync

# Configure Corosync Pacemaker Pcsd
# configure password for hacluster user to enable cluster authorization
# if you do not want to automate: passwd hacluster
echo Secr3tPassw0rd123 | passwd --stdin hacluster

# Turn off stonith
pcs property set stonith-enabled=false
pcs property set no-quorum-policy=ignore

# Enable service
systemctl enable --now corosync pacemaker pcsd 
# systemctl enable --now drbd

# Create volume for disk you want to use as DRBD
pvcreate /dev/sda
vgcreate newdata /dev/sda
lvcreate -l +100%FREE -n drbd-1 newdata

# Config DRBD disk
touch /etc/drbd.d/shareddisk.res
cat << EOFdisk > /etc/drbd.d/shareddisk.res
resource shareddisk {
  connection-mesh {
    hosts nucone.maas nuctwo.maas nucthree.maas;
    net {
      protocol C;
      verify-alg sha256;
    }
  }
  disk {
    on-io-error detach;
  }
  on nucone.maas {
    node-id   1;
    device /dev/drbd0;
    disk /dev/newdata/drbd-1;
    meta-disk internal;
    address 192.168.92.201:7788;
  }
  on nuctwo.maas {
    node-id   2;
    device /dev/drbd0;
    disk /dev/newdata/drbd-1;
    meta-disk internal;
    address 192.168.92.202:7788;
  }
  on nucthree.maas {
    node-id   3;
    device /dev/drbd0;
    disk /dev/newdata/drbd-1;
    meta-disk internal;
    address 192.168.92.203:7788;
  }
}
EOFdisk

# Create DRBD disk 
modprobe drbd
sed -i 's/usage-count yes;/usage-count no;/g' /etc/drbd.d/global_common.conf
drbdadm create-md shareddisk
drbdadm up shareddisk

# on first node
drbdadm --clear-bitmap new-current-uuid shareddisk
drbdadm primary shareddisk
mkfs.ext4 /dev/drbd0
mkdir -p /vms

# Test DRBD on all nodes:
drbdadm primary shareddisk
drbdadm status
mkdir -p /mnt/drbd
mount -o rw /dev/drbd0 /mnt/drbd
touch /mnt/drbd/test
umount /mnt/drbd
drbdadm secondary shareddisk
# repeat on next hosts

# ONLY ON FIRST - MAIN NODE
####################
corosync-keygen
pcs host auth nucone.maas nuctwo.maas nucthree.maas
pcs cluster start --all
pcs cluster enable --all

# Create Group and Resource using https://192.168.92.202:2224/ or with cli
# Add Virtual IP
# pcs resource group add HAGroup1
pcs resource create VIP1 ocf:heartbeat:IPaddr2 ip=192.168.92.200 cidr_netmask=23 op monitor interval=30s --group HAGroup1
# pcs resource defaults resource-stickiness=100

# Create DRBD cluster resource
pcs resource create DRBD ocf:linbit:drbd drbd_resource=shareddisk op monitor interval="29s" role="Master" op monitor interval="31s" role="Slave" --group HAGroup1
pcs resource promotable DRBD notify=true
pcs resource create DRBDFS ocf:heartbeat:Filesystem device=/dev/drbd0 directory=/vms fstype=ext4  --group HAGroup1
# pcs resource create my_fs Filesystem device="/dev/newdata/drbd-1" directory="/vms" fstype="ext4" --group HAGroup1

# Check this
pcs constraint order promote DRBD-clone then start DRBDFS
# pcs constraint order VIP1 then DRBD-clone
# pcs constraint order DRBDFS then VIP1
pcs constraint colocation add DRBD-clone with VIP1
# pcs constraint colocation add DRBDFS with DRBD-clone INFINITY with-rsc-role=Master

pcs cluster stop --all && sleep 2 && pcs cluster start --all

# Create VM Cluster resource - mine is d12test
# copy to other nodes
scp /etc/libvirt/qemu/d12test.xml madmin@nucone.maas:/home/madmin
scp /etc/libvirt/qemu/d12test.xml madmin@nucthree.maas:/home/madmin
cp /home/madmin/d12test.xml /etc/libvirt/qemu/d12test.xml
# Define vm on all hosts
virsh define /etc/libvirt/qemu/d12test.xml
# Configure on one host
pcs resource create vmubuntu ocf:heartbeat:VirtualDomain config=/etc/libvirt/qemu/d12test.xml op monitor interval="30" timeout="30s" op start interval="0" timeout="120s" op stop interval="0" timeout="60s" --group HAGroup1

# If resources do not start automatically run pcs resource debug-start DRBD on all nodes
# allow-migrate=true migration_transport=ssh meta 

# Useful commands
#################
cat /proc/drbd
drbdadm status
corosync-cfgtool -s
crm_mon
pcs status 
pcs status nodes
pcs cluster config
pcs resource config
pcs resource providers
pcs resource disable VIP1
pcs resource enable VIP1
# pcs resource update VIP1 clusterip_hash=sourceip
pcs constraint list --full
pcs cluster cib

pcs cluster config show --output-format=cmd 
	# pcs cluster setup cluster \
	#   nucone.maas addr=192.168.92.201 addr=192.168.122.201 \
	#   nuctwo.maas addr=192.168.92.202 addr=192.168.122.202 \
	#   nucthree.maas addr=192.168.92.203 addr=192.168.122.203 \
	#   transport \
	#   knet \
	#   --no-cluster-uuid
