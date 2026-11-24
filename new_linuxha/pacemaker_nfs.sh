#!/bin/bash
# ==============================================================================
# HA Pacemaker + Corosync + DRBD + NFS + Samba Cluster Script
# 2-Node Active/Passive Cluster
#
# Usage:
#   Run Phase 1 on BOTH nodes:  ./pacemaker_nfs.sh phase1
#   Run Phase 2 on NODE 1 ONLY: ./pacemaker_nfs.sh phase2
# ==============================================================================

set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "[-] Error: Please run as root."
  exit 1
fi

export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

# --- CONFIGURATION VARIABLES ---
CLUSTER_NAME="myCluster"
NODE1_NAME="sv-mmone"
NODE1_IP="192.168.90.90"
NODE2_NAME="sv-mmtwo"
NODE2_IP="192.168.90.80"

VIP="192.168.90.85"
VIP_CIDR="24"

DRBD_RES="shareddisk"
DRBD_DEV="/dev/drbd0"
DRBD_PORT="7788"
DRBD_BACKING_DEV="/dev/newdata/drbd-1"
MOUNT_DIR="/vms"
SHARED_SHARE_DIR="${MOUNT_DIR}/shares"
NFS_STATE_DIR="${MOUNT_DIR}/.nfs_state"

HACLUSTER_PASS="YourSecurePasswordHere"

# ==============================================================================
# PHASE 1: PREREQUISITES (Run on BOTH nodes)
# ==============================================================================
timedatectl set-timezone Europe/Warsaw
swapoff -a
sed -i '/swap/ { /^#/! s/^/#/ }' /etc/fstab
systemctl disable swap.target

# Static host resolution
grep -qxF "$NODE1_IP $NODE1_NAME" /etc/hosts || echo "$NODE1_IP $NODE1_NAME" >> /etc/hosts
grep -qxF "$NODE2_IP $NODE2_NAME" /etc/hosts || echo "$NODE2_IP $NODE2_NAME" >> /etc/hosts

# Install packages
apt-get update
apt-get install -y \
    pacemaker \
    corosync \
    pcs \
    resource-agents \
    psmisc \
    drbd-utils \
    samba \
    nfs-kernel-server \
    nfs-common \
    rpcbind

# Setup cluster daemon & hacluster password
systemctl enable --now pcsd.service
echo "hacluster:${HACLUSTER_PASS}" | chpasswd

# Disable services managed by Pacemaker; ensure rpcbind is up
systemctl disable --now smbd nmbd nfs-kernel-server
systemctl enable --now rpcbind

# DRBD kernel module
modprobe drbd
echo drbd > /etc/modules-load.d/drbd.conf

# Write DRBD resource config (idempotent overwrite)
mkdir -p /etc/drbd.d
cat > /etc/drbd.d/${DRBD_RES}.res << EOF
resource ${DRBD_RES} {
  protocol C;
  net {
    verify-alg sha256;
  }
  disk {
    on-io-error detach;
  }
  on ${NODE1_NAME} {
    device    ${DRBD_DEV};
    disk      ${DRBD_BACKING_DEV};
    meta-disk internal;
    address   ${NODE1_IP}:${DRBD_PORT};
  }
  on ${NODE2_NAME} {
    device    ${DRBD_DEV};
    disk      ${DRBD_BACKING_DEV};
    meta-disk internal;
    address   ${NODE2_IP}:${DRBD_PORT};
  }
}
EOF

# Initialise DRBD metadata & bring resource up
drbdadm create-md --force ${DRBD_RES}
drbdadm up ${DRBD_RES}

mkdir -p "${MOUNT_DIR}"

# Configure Samba share template (idempotent)
if ! grep -q "\[cluster_share\]" /etc/samba/smb.conf 2>/dev/null; then
    cat >> /etc/samba/smb.conf << EOF

[cluster_share]
   comment = HA Shared Storage
   path = ${SHARED_SHARE_DIR}
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0775
   directory mask = 0775
EOF
fi

# ==============================================================================
# PHASE 2: CLUSTER & RESOURCES (Run on NODE1 ONLY)
# ==============================================================================
# 1. Initialize DRBD Primary & Filesystem
drbdadm primary ${DRBD_RES} --force
mkfs.ext4 -F ${DRBD_DEV}

# Authenticate both nodes and set up the cluster
pcs host auth "${NODE1_NAME}" addr="${NODE1_IP}" "${NODE2_NAME}" addr="${NODE2_IP}" \
    -u hacluster -p "${HACLUSTER_PASS}"
pcs cluster setup "${CLUSTER_NAME}" "${NODE1_NAME}" addr="${NODE1_IP}" "${NODE2_NAME}" addr="${NODE2_IP}" --force
pcs cluster start --all --wait=60
pcs cluster enable --all

# 3. Cluster Properties
# pcs property set stonith-enabled=false
# pcs property set no-quorum-policy=ignore
pcs resource defaults update resource-stickiness=100
# pcs resource op defaults update timeout=240s

# DRBD promotable clone
pcs resource create DRBD ocf:linbit:drbd drbd_resource=${DRBD_RES} \
    op monitor interval=60s role=Promoted \
    op monitor interval=65s role=Unpromoted
pcs resource promotable DRBD promoted-max=1 promoted-node-max=1 clone-max=2 clone-node-max=1 notify=true

# Add VIP
pcs resource create ClusterIP ocf:heartbeat:IPaddr2 ip=${VIP} cidr_netmask=${VIP_CIDR} op monitor interval=30s --group HAGroup1
pcs resource op defaults update timeout=240s

# 4. Filesystem
pcs resource create DRBDFS ocf:heartbeat:Filesystem device="${DRBD_DEV}" directory="${MOUNT_DIR}" fstype="ext4" op monitor interval=30s --group HAGroup1

# Add Samba and NFS
pcs resource create ClusterNFS ocf:heartbeat:nfsserver nfs_shared_infodir="${MOUNT_DIR}/.nfs_state" nfs_ip="${VIP}" op monitor interval=30s --group HAGroup1
pcs resource create ClusterSamba systemd:smbd op monitor interval=60s --group HAGroup1

# Constraints: HAGroup1 must run on the DRBD Promoted node
pcs constraint colocation add HAGroup1 with DRBD-clone INFINITY with-rsc-role=Promoted
pcs constraint order promote DRBD-clone then start HAGroup1

# pcs constraint order ClusterIP then ClusterNFS
# pcs constraint order ClusterNFS then ClusterSamba
# pcs constraint order promote DRBD-clone then start DRBDFS
# pcs constraint order DRBDFS then ClusterNFS
# pcs constraint order ClusterIP then DRBD-clone

# pcs constraint colocation add ClusterSamba with ClusterIP
# pcs constraint colocation add ClusterNFS with ClusterIP
# pcs constraint colocation add DRBDFS with DRBD-clone INFINITY with-rsc-role=Master
# pcs constraint colocation add DRBD-clone with ClusterIP
pcs cluster start --all