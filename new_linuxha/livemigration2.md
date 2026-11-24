Live migration of a KVM virtual machine across a 2-node Pacemaker cluster using DRBD requires a dual-primary DRBD setup (or a cluster setup that promotes DRBD to dual-primary temporarily during migration). Because live migration briefly runs the VM on both nodes simultaneously, both hypervisors must have write access to the underlying block device during the handoff.

Key Requirements Before Migrating
1. DRBD in Dual-Primary Mode: In your DRBD resource configuration (/etc/drbd.d/r0.res), net { allow-two-primaries yes; } must be configured, and the DRBD clone resource in Pacemaker must allow both nodes to be promoted to Promoted (formerly Master):

pcs resource clone drbd_res-clone meta promotable=true promoted-max=2

3. Cluster-Aware Locking / Fencing: To prevent split-brain risk on a dual-primary DRBD setup, working STONITH/fencing and DRBD fencing policies (e.g., fencing resource-and-stonith;) are required.
4. Hypervisor & Network Access:
    * Both nodes must have passwordless SSH (or mutual TLS) configured for libvirt between nodes.
    * The VM's domain XML configuration must be identical and present in the same path on both nodes (e.g., /etc/pacemaker/vms/vm-test.xml).
5. VirtualDomain Resource Configuration: The VM resource in Pacemaker must explicitly enable migration:

pcs resource update vm_res migration_transport="ssh" hypervisor="qemu:///system" meta allow-migrate=true

Step-by-Step Procedure
1. Verify DRBD and Cluster HealthPre-checkEnsure DRBD is in sync and both nodes are healthy before attempting migration.Check DRBD status:drbdadm status
2. Ensure the disk state is UpToDate/UpToDate.Check cluster health:pcs status
3. Verification: Confirm that all nodes report online, no failcounts exist, and the DRBD resource is Promoted on the active host.
4. Ensure Target Node is Promoted for DRBDDual-Primary requirementBecause a live migration requires concurrent read/write during memory transfer, the DRBD resource must be in the Promoted (Primary) state on both nodes.If your Pacemaker DRBD clone configuration sets promoted-max=2, Pacemaker can promote the DRBD volume automatically, or you can verify it is already primary on both nodes:drbdadm status
5. Verification: The output should show the role as Primary/Primary (or Promoted in pcs status).
6. Initiate Live Migration via PacemakerCluster commandAlways trigger the migration via Pacemaker, not direct virsh migrate. Moving the VM directly in virsh will cause Pacemaker to detect an unexpected resource stop on the source and initiate fencing or a failed recovery.Move the resource to the target node:pcs resource move vm_res <target-node-name>
7. Verification: Pacemaker will invoke the migrate_to and migrate_from operations. Check the status in real time with pcs status or crm_mon -1. The VM will transition smoothly to the target node without downtime.
8. Clear the Migration ConstraintPost-migration cleanupRunning pcs resource move places an explicit location constraint in the Pacemaker CIB (cluster information base). To allow Pacemaker to freely manage failover in the future, remove this constraint once migration is complete.Clear the constraint:pcs resource clear vm_res
9. Verification: Run pcs constraint to verify that no static location ban or preference remains on vm_res.
Common Pitfalls & Considerations
* Split-Brain Risk: Avoid running dual-primary DRBD indefinitely if you are not using a cluster-aware filesystem (e.g., GFS2/OCFS2) or a hypervisor that guarantees mutual exclusion like libvirt. With VirtualDomain, dual-primary should ideally only occur during the migration window.
* libvirt User & Polkit: Ensure the user running libvirtd can communicate across nodes over SSH without interactive prompts (e.g., ssh root@<target-node> virsh uri).
* Cache Settings: In the VM's disk XML definition, 
set <driver name='qemu' type='raw' cache='none'/> (or cache='directsync'). 
Buffered caching can lead to data loss or migration aborts on raw block devices like DRBD.

An end-to-end configuration for a 2-node DRBD dual-primary setup supporting live migration of a Pacemaker-managed KVM virtual machine requires configuring DRBD resource definitions, fencing integration, and Pacemaker CIB constraints.
Assume the two cluster nodes are named node1 (192.168.10.11) and node2 (192.168.10.12).

1. DRBD Configuration (/etc/drbd.d/r0.res)
Install this file identically on both node1 and node2.
resource r0 {
    protocol C;

    ### Allow both nodes to hold the primary role concurrently during migration
    net {
        allow-two-primaries yes;
        after-sb-0pri discard-zero-changes;
        after-sb-1pri discard-secondary;
        after-sb-2pri disconnect;
        csums-alg md5;
        verify-alg md5;
    }

    ### Integrate DRBD with cluster-level fencing to guard against split-brain
    disk {
        fencing resource-and-stonith;
        resync-rate 100M;
    }

    handlers {
        fence-peer "/usr/lib/drbd/crm-fence-peer.9.sh";
        unfence-peer "/usr/lib/drbd/crm-unfence-peer.9.sh";
        split-brain "/usr/lib/drbd/notify-split-brain.sh root";
    }

    startup {
        wfc-timeout 60;
        degr-wfc-timeout 120;
    }

    on node1 {
        device    /dev/drbd0;
        disk      /dev/vg_data/lv_vm_storage;
        address   192.168.10.11:7788;
        meta-disk internal;
    }

    on node2 {
        device    /dev/drbd0;
        disk      /dev/vg_data/lv_vm_storage;
        address   192.168.10.12:7788;
        meta-disk internal;
    }
}

Note: Check the exact path to the fence handler scripts (e.g., crm-fence-peer.9.sh or crm-fence-peer.sh) on your Linux distribution under /usr/lib/drbd/.

### 2. Disk Caching Requirement (VM Domain XML)
In your VM XML definition (/etc/pacemaker/vms/vm01.xml), DRBD requires disabling the host cache so that data is written directly to the synchronized block device:

<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none' io='native'/>
  <source dev='/dev/drbd0'/>
  <target dev='vda' bus='virtio'/>
</disk>

### 3. Pacemaker CIB Commands (pcs)
Run these commands on one node only (e.g., node1).
Step A: Create the DRBD Resource and Clone as Promotable
Create the base DRBD OCF primitive and wrap it into a clone that permits two nodes to be promoted (promoted-max=2):
### 1. Create the DRBD primitive
pcs resource create drbd_r0 ocf:linbit:drbd \
    drbd_resource=r0 \
    op monitor interval=15s role=Master \
    op monitor interval=30s role=Slave

### 2. Clone the resource and allow two primaries
pcs resource clone drbd_r0 \
    promotable=true \
    promoted-max=2 \
    promoted-node-max=1 \
    clone-max=2 \
    clone-node-max=1 \
    notify=true

### Step B: Create the VirtualDomain Resource with Migration Flags
Create the VM resource using ocf:heartbeat:VirtualDomain with live migration enabled:

pcs resource create vm01 ocf:heartbeat:VirtualDomain \
    config=/etc/pacemaker/vms/vm01.xml \
    hypervisor="qemu:///system" \
    migration_transport="ssh" \
    op start timeout=120s \
    op stop timeout=120s \
    op monitor interval=30s timeout=30s \
    op migrate_from timeout=120s \
    op migrate_to timeout=120s \
    meta allow-migrate=true

### Step C: Configure Colocation and Ordering Constraints
Ensure the VM only runs on a node where DRBD is active and promoted to Primary:
### Order: Promote DRBD to Primary before starting the VM
*pcs constraint order promote drbd_r0-clone then start vm01*

### Colocation: The VM can only run where DRBD is Promoted
*pcs constraint colocation add vm01 with drbd_r0-clone role=Promoted*

### Verification
1. Check the DRBD roles directly via the kernel module:drbdadm status r0
2. Verification: Output should report role:Primary on both nodes, with disk state UpToDate/UpToDate.
3. Inspect the Pacemaker cluster state:pcs status
4. Verification: drbd_r0-clone should show Promoted: [ node1 node2 ] and vm01 will show Started node1.
5. Test live migration across the nodes:pcs resource move vm01 node2
6. Verification: Run pcs status to watch vm01 migrate from node1 to node2 with zero guest downtime, then run pcs resource clear vm01 to remove the temporary location constraint.

