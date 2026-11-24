### Why Live Migration Fails with the Current Script

In your current setup, there are **3 architectural blockers**:

1. **DRBD is Single-Primary (`promoted-max=1`)**: During live migration, QEMU runs on Node 1 while simultaneously starting on Node 2 to receive memory state. Both nodes must have access to the underlying storage device simultaneously.
2. **`ext4` is not a Clustered Filesystem**: Your script mounts an `ext4` filesystem on `/vms`. If DRBD is made dual-primary with `ext4` mounted on both nodes, **catastrophic filesystem corruption will occur immediately**. Concurrent mounting requires a cluster-aware filesystem (**OCFS2**) or **direct raw block devices**.
3. **The `HAGroup1` Resource Group**: Placing the VM in a Pacemaker `group` forces all resources (`VIP`, `DRBDFS`, `VM`) to reside on a single node and move via **cold failover** (stop on Node 1, demote, promote on Node 2, start on Node 2). Live migration requires the VM to be an independent resource outside the group.

---

### Key Requirements for Live Migration

| Component | Current Script | Required for Live Migration |
| :--- | :--- | :--- |
| **DRBD Mode** | Single-Primary (`allow-two-primaries` absent) | **Dual-Primary** (`allow-two-primaries yes;`) |
| **Pacemaker DRBD** | `promoted-max=1` | `promoted-max=2` |
| **Filesystem on `/vms`** | `ext4` (Single node only) | **`ocfs2`** (Mounted on both nodes via Clone) |
| **Pacemaker Topology** | `HAGroup1` (tightly coupled group) | `DRBDFS-clone` + standalone `VirtualDomain` with constraints |
| **VirtualDomain Meta** | None | `meta allow-migrate=true` |
| **Libvirt Transport** | Local | Passwordless SSH (`migration_transport=ssh`) |
| **VM Disk Caching** | Default | **`cache='none'`** (Mandatory in VM XML) |
| **Fencing (STONITH)** | Disabled (`stonith-enabled=false`) | **Mandatory** (Split-brain in dual-primary corrupts data) |

---

### Concrete Enhancements to [pacemaker_cluster_2node.sh](file:///Users/marek/aicode/linuxha/pacemaker_cluster_2node.sh)

Here are the specific changes to apply to your script:

#### 1. Phase 1: Packages & DRBD Configuration (Both Nodes)

Add `ocfs2-tools` to the package list (around line 79) and enable dual-primary in the DRBD configuration (line 107):

```bash
# In Package Installation (Line 79):
apt-get install -y \
  pacemaker corosync pcs resource-agents drbd-utils lvm2 \
  qemu-system-x86 libvirt-daemon-system libvirt-clients \
  ocfs2-tools \
  curl wget htop nano
```

Update `/etc/drbd.d/${DRBD_RES}.res` (around line 108) to allow dual-primary and fencing:

```bash
cat << EOFdrbd > /etc/drbd.d/${DRBD_RES}.res
resource ${DRBD_RES} {
  protocol C;
  disk {
    on-io-error detach;
    fencing resource-and-stonith;
  }
  net {
    verify-alg sha256;
    allow-two-primaries yes;
  }
  on ${NODE1_NAME} {
    device /dev/drbd0;
    disk /dev/${DRBD_VG}/${DRBD_LV};
    meta-disk internal;
    address ${NODE1_IP}:${DRBD_PORT};
  }
  on ${NODE2_NAME} {
    device /dev/drbd0;
    disk /dev/${DRBD_VG}/${DRBD_LV};
    meta-disk internal;
    address ${NODE2_IP}:${DRBD_PORT};
  }
}
EOFdrbd
```

#### 2. Phase 1: Passwordless SSH for Libvirt (Both Nodes)

Libvirt live migration defaults to SSH (`qemu+ssh://<other-node>/system`). Add key exchange between the nodes:

```bash
# Ensure root SSH keys exist and are authorized across both nodes
if [ ! -f /root/.ssh/id_rsa ]; then
  ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
fi
# Disable host key prompts for cluster peers
cat << 'EOFssh' > /root/.ssh/config
Host sv-mmone sv-mmtwo 192.168.90.*
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOFssh
chmod 600 /root/.ssh/config
```
*(Ensure `id_rsa.pub` of Node 1 is in `authorized_keys` of Node 2 and vice versa).*

---

#### 3. Phase 2: Formatting with OCFS2 (Node 1 Only)

Replace `mkfs.ext4 /dev/drbd0` (line 147) with `mkfs.ocfs2`:

```bash
# Format as cluster filesystem supporting up to 2 simultaneous cluster nodes
mkfs.ocfs2 -N 2 -L drbd_vms /dev/drbd0 --fs-features=backup-super
```

---

#### 4. Phase 2: Update DRBD & Filesystem Clone in Pacemaker (Node 1 Only)

Modify lines 181–217 in [pacemaker_cluster_2node.sh](file:///Users/marek/aicode/linuxha/pacemaker_cluster_2node.sh):

```bash
# 6. Create DRBD Promotable Clone with promoted-max=2 (Dual-Primary)
pcs resource create DRBD ocf:linbit:drbd \
  drbd_resource="$DRBD_RES" \
  op monitor interval=29s role=Promoted \
  op monitor interval=31s role=Unpromoted \
  --disabled

pcs resource promotable DRBD \
  meta \
  promoted-max=2 \
  promoted-node-max=1 \
  clone-max=2 \
  clone-node-max=1 \
  notify=true

pcs resource enable DRBD-clone

# 7. Create Clustered Filesystem Resource (Mounted on BOTH nodes)
pcs resource create DRBDFS ocf:heartbeat:Filesystem \
  device=/dev/drbd0 \
  directory="$MOUNT_DIR" \
  fstype=ocfs2 \
  --clone

# 8. Create VirtualDomain Resource with Live Migration enabled
pcs resource create vmubuntu ocf:heartbeat:VirtualDomain \
  config="/vms/d12test.xml" \
  migration_transport="ssh" \
  migrate_options="--unsafe" \
  meta allow-migrate=true \
  op monitor interval=30s timeout=30s \
  op start interval=0s timeout=120s \
  op stop interval=0s timeout=60s

# VIP can remain standalone or in a separate management group
pcs resource create VIP1 ocf:heartbeat:IPaddr2 \
  ip="$VIP" \
  cidr_netmask="$VIP_CIDR" \
  op monitor interval=30s

# 9. Configure Constraints for Storage -> Filesystem -> VM
# DRBDFS-clone must run on nodes where DRBD is Promoted
pcs constraint colocation add DRBDFS-clone with DRBD-clone INFINITY with-rsc-role=Promoted
pcs constraint order promote DRBD-clone then start DRBDFS-clone

# vmubuntu requires DRBDFS-clone active on the host
pcs constraint colocation add vmubuntu with DRBDFS-clone INFINITY
pcs constraint order start DRBDFS-clone then start vmubuntu
```

---

### VM Configuration Requirement: Cache Mode

In the VM XML definition (`/vms/d12test.xml`), disk caching **must** be set to `none`:

```xml
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2' cache='none'/>
  <source file='/vms/d12test.qcow2'/>
  <target dev='vda' bus='virtio'/>
</disk>
```
> [!IMPORTANT]
> If `cache='none'` is not set, Libvirt will block migration because uncommitted host cache data on Node 1 cannot be seen by Node 2.

---

### Fencing (STONITH) Requirement

In a single-primary cluster, split-brain causes a disconnected secondary. In **dual-primary DRBD**, a split-brain causes both nodes to write simultaneously without synchronization, destroying the filesystem.

You should implement the QNet witness + softdog SBD configuration outlined in your [Addwitness.md](file:///Users/marek/aicode/linuxha/Addwitness.md) before enabling dual-primary live migration in production:
```bash
pcs property set stonith-enabled=true
pcs property set no-quorum-policy=stop
```

---

### How to Trigger and Verify Live Migration

Once deployed, you can migrate the VM with zero downtime:

1. **Trigger live migration**:
   ```bash
   pcs resource move vmubuntu sv-mmtwo
   ```
2. **Observe live migration in real-time**:
   ```bash
   crm_mon -Arf1
   ```
   Pacemaker will show:
   `vmubuntu (ocf:heartbeat:VirtualDomain): Migrating sv-mmone -> sv-mmtwo`
   followed by:
   `vmubuntu (ocf:heartbeat:VirtualDomain): Started sv-mmtwo`
3. **Clear migration constraint** (to allow future moves):
   ```bash
   pcs resource clear vmubuntu
   ```