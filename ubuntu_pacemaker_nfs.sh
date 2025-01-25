#!/bin/bash

set -e
if [[ $(id -u) -ne 0 ]] ; then echo "Please run as root" ; exit 1 ; fi

export LANGUAGE=en_US.UTF-8
export LANG=en_US.iso-8859-2
export LC_ALL=en_US.UTF-8

timedatectl set-timezone Europe/Warsaw
swapoff -a
systemctl disable swap.target
rm -rf /swap.img 
sed -i '/swap/s/^/#/' /etc/fstab

# Install Pacemaker ubuntu
apt install -y pacemaker corosync pcs resource-agents psmisc policycoreutils-python-utils drbd-utils samba nfs-kernel-server 

# Setup Cluster
systemctl enable --now pcsd.service
passwd hacluster
pcs host auth node1 node2
pcs cluster setup myCluster node1 node2 --force
pcs cluster start --all

pcs property set stonith-enabled=false
pcs property set no-quorum-policy=ignore

# Setup DRBD
modprobe drbd
echo drbd >/etc/modules-load.d/drbd.conf

# Config DRBD disk
touch /etc/drbd.d/shareddisk.res
cat << EOFdisk > /etc/drbd.d/shareddisk.res
resource shareddisk {
  net {
      protocol C;
      verify-alg sha256;
  }
  disk {
    on-io-error detach;
  }
  on node1 {
    device /dev/drbd0;
    disk /dev/newdata/drbd-1;
    meta-disk internal;
    address 192.168.92.201:7788;
  }
  on node2 {
    device /dev/drbd0;
    disk /dev/newdata/drbd-1;
    meta-disk internal;
    address 192.168.92.202:7788;
  }
}
EOFdisk

drbdadm create-md shareddisk
drbdadm up shareddisk
drbdadm primary shareddisk --force
mkfs.ext4 /dev/drbd1

# Setup Samba and NFS
systemctl disable --now smbd
systemctl disable --now nfs-kernel-server.service 
mkdir -p /exports
# /etc/samba/smb.conf 
# /etc/exports 

# Setup Pacemaker
pcs resource create ClusterIP ocf:heartbeat:IPaddr2 ip=192.168.92.100 cidr_netmask=24 op monitor interval=30s
pcs resource defaults update resource-stickiness=100
pcs resource op defaults update timeout=240s
pcs resource create ClusterSamba lsb:smbd op monitor interval=60s
pcs resource create ClusterNFS ocf:heartbeat:nfsserver op monitor interval=60s
pcs resource create DRBD ocf:linbit:drbd drbd_resource=shareddisk op monitor interval=60s
pcs resource promotable DRBD promoted-max=1 promoted-node-max=1 clone-max=2 clone-node-max=1 notify=true
pcs resource create DRBDFS ocf:heartbeat:Filesystem device="/dev/drbd1" directory="/exports" fstype="ext4"
pcs constraint order ClusterIP then ClusterNFS
pcs constraint order ClusterNFS then ClusterSamba
pcs constraint order promote DRBD-clone then start DRBDFS
pcs constraint order DRBDFS then ClusterNFS
pcs constraint order ClusterIP then DRBD-clone
pcs constraint colocation add ClusterSamba with ClusterIP
pcs constraint colocation add ClusterNFS with ClusterIP
pcs constraint colocation add DRBDFS with DRBD-clone INFINITY with-rsc-role=Master
pcs constraint colocation add DRBD-clone with ClusterIP
pcs cluster stop --all && sleep 2 && pcs cluster start --all