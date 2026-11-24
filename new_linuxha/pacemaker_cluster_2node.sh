#!/bin/bash
# HA Pacemaker + Corosync + DRBD 9 + KVM Cluster for Debian 13 (Trixie)
# 2-Node Cluster with Single Network Interface
# No Live-Migration
#
# Best-practice deployment script:
# - Run Phase 1 on BOTH nodes (nucone and nuctwo)
# - Run Phase 2 on FIRST node only (nucone)

set -e
[ "$(id -u)" -eq 0 ] || { echo "Please run as root"; exit 1; }

# ==============================================================================
# CLUSTER CONFIGURATION VARIABLES
# ==============================================================================
CLUSTER_NAME="hacluster"

# Node 1 details (Single network interface)
NODE1_NAME="sv-mmone"
NODE1_IP="192.168.90.90"

# Node 2 details (Single network interface)
NODE2_NAME="sv-mmtwo"
NODE2_IP="192.168.90.80"

# Cluster Virtual IP
VIP="192.168.90.85"
VIP_CIDR="24"

# DRBD Storage Configuration Using a dedicated partition — ensure this is NOT the OS partition
DRBD_DISK="/dev/sda3"
DRBD_VG="newdata"
DRBD_LV="drbd-1"
DRBD_RES="shareddisk"
DRBD_PORT="7788"
MOUNT_DIR="/vms"
HOSTNAME=$(hostname)

# Cluster auth password for 'hacluster' system user
HACLUSTER_PASS="dofhbq3uJdsaHNABAwq"

# ==============================================================================
# PHASE 1: EXECUTE ON BOTH NODES (sv-mmone & sv-mmtwo)
# ==============================================================================

# 1. System locales & Timezone
export DEBIAN_FRONTEND=noninteractive
timedatectl set-timezone Europe/Warsaw

# 2. Disable Swap (HA best practice)
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab

# 3. Configure /etc/hosts for two-node resolution
grep -qxF "$NODE1_IP $NODE1_NAME" /etc/hosts || echo "$NODE1_IP $NODE1_NAME" >> /etc/hosts
grep -qxF "$NODE2_IP $NODE2_NAME" /etc/hosts || echo "$NODE2_IP $NODE2_NAME" >> /etc/hosts

# 4. System & Network Kernel Optimization
cat << 'EOFsysctl' > /etc/sysctl.d/10-cluster.conf
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.ip_forward = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_unprivileged_port_start = 80
vm.swappiness = 10
EOFsysctl
sysctl --system

# 5. Enable Nested KVM (Intel & AMD, no if/case statements required)
cat << 'EOFkvm' > /etc/modprobe.d/kvm.conf
options kvm_intel nested=1
EOFkvm

# 6. Install Debian 13 HA, DRBD & Virtualization Packages
apt-get update
apt-get install -y \
  pacemaker \
  corosync \
  pcs \
  resource-agents \
  drbd-utils \
  lvm2 \
  qemu-system-x86 \
  libvirt-daemon-system \
  libvirt-clients \
  curl \
  wget \
  htop \
  nano

# 7. Configure services & hacluster password
systemctl enable --now libvirtd.service
systemctl enable --now pcsd.service
echo "hacluster:${HACLUSTER_PASS}" | chpasswd

# 8. Prepare LVM backing storage for DRBD (Run on new/blank disk)
wipefs -a "$DRBD_DISK"
pvcreate "$DRBD_DISK"
vgcreate "$DRBD_VG" "$DRBD_DISK"
lvcreate -l +100%FREE -n "$DRBD_LV" "$DRBD_VG"

# 9. Configure DRBD Resource (2 Nodes, Point-to-Point, Compatible with DRBD 8 & 9)
mkdir -p /etc/drbd.d
cat << EOFdrbd > /etc/drbd.d/${DRBD_RES}.res
resource ${DRBD_RES} {
  protocol C;
  disk {
    on-io-error detach;
  }
  net {
    verify-alg sha256;
  }
  on ${NODE1_NAME} {
  #  node-id 0;
    device /dev/drbd0;
    disk /dev/${DRBD_VG}/${DRBD_LV};
    meta-disk internal;
    address ${NODE1_IP}:${DRBD_PORT};
  }
  on ${NODE2_NAME} {
  #  node-id 1;
    device /dev/drbd0;
    disk /dev/${DRBD_VG}/${DRBD_LV};
    meta-disk internal;
    address ${NODE2_IP}:${DRBD_PORT};
  }
}
EOFdrbd

# 10. Initialize DRBD on both nodes
modprobe drbd
echo drbd > /etc/modules-load.d/drbd.conf
drbdadm create-md "$DRBD_RES"
drbdadm up "$DRBD_RES"
mkdir -p "$MOUNT_DIR"

# ==============================================================================
# PHASE 2: EXECUTE ON NODE 1 ONLY (sv-mmone)
# ==============================================================================

# 1. Initialize DRBD Primary & Filesystem (Node 1 only)
drbdadm primary --force "$DRBD_RES"
# The first sync will run in background and the disk is usable immediately
mkfs.ext4 /dev/drbd0

# 2. Authenticate Cluster Nodes via pcsd
mkdir -p /var/lib/pcsd
echo '{"format_version": 1, "data_version": 1, "known_hosts": {}}' > /var/lib/pcsd/known-hosts
chown -R hacluster:haclient /var/lib/pcsd
chmod 700 /var/lib/pcsd
chmod 600 /var/lib/pcsd/known-hosts
systemctl restart pcsd

pcs host auth "$NODE1_NAME" addr="$NODE1_IP" "$NODE2_NAME" addr="$NODE2_IP" -u hacluster -p "$HACLUSTER_PASS"

# 3. Setup Corosync Cluster (automatically configures two_node: 1 and syncs keys)
pcs cluster setup "$CLUSTER_NAME" "$NODE1_NAME" addr="$NODE1_IP" "$NODE2_NAME" addr="$NODE2_IP" --wait_for_all=1

# 4. Start and enable cluster across all nodes
pcs cluster start --all
pcs cluster enable --all

# 5. Configure Cluster Properties for 2-Node Operation
# Disable STONITH when no fencing hardware/SBD is attached (enable in production with fence agent)
pcs property set stonith-enabled=false
# In a 2-node cluster with two_node: 1, ignore loss of quorum on failure
pcs property set no-quorum-policy=ignore
# Resource stickiness prevents unnecessary service failback after node recovery
pcs resource defaults update resource-stickiness=100

# 6. Create DRBD Promotable Clone Resource
pcs resource create DRBD ocf:linbit:drbd \
  drbd_resource="$DRBD_RES" \
  op monitor interval=29s role=Promoted \
  op monitor interval=31s role=Unpromoted \
  --disabled

pcs resource promotable DRBD \
  meta \
  promoted-max=1 \
  promoted-node-max=1 \
  clone-max=2 \
  clone-node-max=1 \
  notify=true

pcs resource enable DRBD-clone

# 7. Create Resource Group for Dependent Services (VIP, Filesystem, VM)
pcs resource create VIP1 ocf:heartbeat:IPaddr2 \
  ip="$VIP" \
  cidr_netmask="$VIP_CIDR" \
  op monitor interval=30s \
  group HAGroup1

pcs resource create DRBDFS ocf:heartbeat:Filesystem \
  device=/dev/drbd0 \
  directory="$MOUNT_DIR" \
  fstype=ext4 \
  group HAGroup1

# 8. (Optional KVM VM) Define VM on both nodes, then add to HAGroup1
# virsh define /etc/libvirt/qemu/d12test.xml
# pcs resource create vmubuntu ocf:heartbeat:VirtualDomain \
#   config=/etc/libvirt/qemu/d12test.xml \
#   op monitor interval=30s timeout=30s \
#   op start interval=0s timeout=120s \
#   op stop interval=0s timeout=60s \
#   group HAGroup1

# 9. Configure Constraints between Promoted DRBD and HAGroup1
# Colocation: HAGroup1 runs exclusively on the node where DRBD is Promoted
pcs constraint colocation add HAGroup1 with DRBD-clone INFINITY with-rsc-role=Promoted
# Ordering: DRBD must be Promoted before HAGroup1 starts
pcs constraint order promote DRBD-clone then start HAGroup1

# ==============================================================================
# USEFUL CLUSTER STATUS & VERIFICATION COMMANDS
# ==============================================================================
# crm_mon -Arf1
# pcs status
# pcs cluster config
# pcs resource config
# pcs constraint list --full
# drbdadm status
# corosync-cfgtool -s

# Add VM to Pacemaker cluster
# Ensure libvirt default network is active on BOTH nodes
virsh net-start default || true
virsh net-autostart default || true

# Copy VM image to /vms
cp /path/to/your/image.qcow2 /vms/myvm.qcow2
cp ./vmdefinition.xml /vms/vmdefinition.xml
chmod 660 /vms/myvm.qcow2
chown root:kvm /vms/myvm.qcow2   # or libvirt-qemu:kvm on Debian

## (By storing `/vms/myvm.xml` on DRBD, Pacemaker will dynamically create and destroy the domain in libvirt on whichever node is active).*

## Run this on sv-mmone
pcs resource create debianvm1 ocf:heartbeat:VirtualDomain \
  config="/vms/vmdefinition.xml" \
  op monitor interval=30s timeout=30s \
  op start interval=0s timeout=120s \
  op stop interval=0s timeout=60s \
  --group HAGroup1

### Test how Failover Works
pcs node standby sv-mmone
pcs node unstandby sv-mmone
