#!/bin/bash
set -euo pipefail

### How It Works Under the Hood

#     ┌──────────────────────┐
#     │  3rd Host Container  │
#     │  (corosync-qnetd)    │
#     └──────────┬───────────┘
#          vote  │  vote
#          ┌─────┴─────┐
#          ▼           ▼
#    ┌───────────┐   ┌───────────┐
#    │   Node1   │◄──┤   Node2   │
#    │ (softdog) │   │ (softdog) │
#    └───────────┘   └───────────┘
# 

# 1. **Total cluster votes = 3** (Node 1, Node 2, and the QNet container).
# 2. If the link between Node 1 and Node 2 cuts:
#    * Both nodes race to talk to the QNet container.
#    * Whichever node successfully connects to QNet keeps **2 out of 3 votes** (maintains quorum).
#    * The isolated node has only **1 out of 3 votes** (loses quorum).
# 3. **The SBD Watchdog steps in:**
#    * When a node loses quorum, the kernel watchdog (`softdog`) trips and **immediately reboots the isolated node** (suicide fencing).
#    * The surviving node safely promotes DRBD and mounts the filesystem without data corruption.
# 4. No need for SAN, PDU, or IPMI.

# Node 1 details (Single network interface)
NODE1_NAME="sv-mmone"
NODE1_IP="192.168.90.90"

# Node 2 details (Single network interface)
NODE2_NAME="sv-mmtwo"
NODE2_IP="192.168.90.80"

# QNetd container IP
QNETD_IP="192.168.90.10"

# ============================================================
# RUN ON THE 3RD MACHINE (192.168.90.10) — qnetd host
# ============================================================
# You can run `corosync-qnetd` using any minimal container (e.g. Debian/Ubuntu/Alpine). (QNetd listens on TCP port `5403`)
# Docker is strictly required, the container must include openssh-server, 
# have an authorized root key matching the cluster nodes, and expose port 22.
docker run -d \
  --name corosync-qnetd \
  --restart always \
  --net host \
  debian:bookworm-slim \
  bash -c "apt-get update && apt-get install -y corosync-qnetd && exec corosync-qnetd -f"

# ============================================================
# RUN ON BOTH CLUSTER NODES (sv-mmone AND sv-mmtwo)
# ============================================================
#### Step 1: On both cluster nodes - Enable Diskless SBD (Kernel Watchdog Fencing) 
modprobe softdog
echo "softdog" >> /etc/modules-load.d/watchdog.conf
ls /dev/watchdog || { echo "ERROR: /dev/watchdog missing"; exit 1; }

#### Step 2: On both cluster nodes - Configure SBD for diskless operation in `/etc/default/sbd`: (The `-W` flag enables watchdog-only/diskless mode)
apt-get install -y sbd corosync-qdevice
cat > /etc/default/sbd << EOF
SBD_DEVICE=""
SBD_WATCHDOG_DEV=/dev/watchdog
SBD_WATCHDOG_TIMEOUT=10
SBD_TIMEOUT_ACTION=flush
SBD_OPTS="-W"
SBD_PACEMAKER=yes
EOF

systemctl enable --now sbd

# ============================================================
# RUN ON ONE NODE ONLY (e.g. sv-mmone)
# ============================================================
#### Step 3: On one node - Add qdevice (run once from any node)
pcs quorum device add model net host="$QNETD_IP" algorithm=ffsplit
# When you run pcs quorum device add model net host=$QNETD_IP algorithm=ffsplit, 
# pcs attempts to establish an SSH connection as root to $QNETD_IP (port 22). 
# It uses this connection to run corosync-qnetd-tool -i 
# to initialize the CA and copy NSS certificates between the cluster nodes and the qnetd server.

# On one node - Update cluster properties only on
pcs cluster stop --all
pcs cluster start --all

# Step 4. Register SBD stonith agent (required only with disk-based SBD)
# pcs stonith create sbd-fence fence_sbd \
#   pcmk_host_list="$NODE1_NAME $NODE2_NAME" \
#   op monitor interval=5s timeout=25s

# Step 5. On one node - In your cluster setup script (e.g. [pacemaker_cluster_2node.sh](file:///Users/marek/aicode/linuxha/pacemaker_cluster_2node.sh#L167-L173)), change:
# a. Enable STONITH (SBD serves as the fencing provider)
pcs property set stonith-enabled=true
pcs property set stonith-watchdog-timeout=10
# b. Do NOT ignore quorum anymore (let QNetd handle it cleanly)
pcs property set no-quorum-policy=stop

# Step 6. Verify
pcs quorum status
pcs stonith status
pcs status