# Services:
# VMs
# VIP
# NFS
# Samba
# Apache
# Database
# Docker
# DNS

#Config files:
#membership and quorum configuration
/etc/corosync/corosync.conf
# cluster node and resource configuration.
/var/lib/pacemaker/crm/cib.xml
#Directory where resource scripts are located
/us/lib/of/resource.d/heartbeat/

# Log files:
/var/log/pacemaker.log
/var/log/cluster/corosync.log
/var/log/pcsd/pcsd.log
/var/log/messages (look for pengine, crmd,...)

# Check cluster status:
pcs status
pcs config
pcs cluster status
pcs quorum status
pcs resource show
pcs status -full
crm_verify -L -V
crm_mon

# Check cluster status:
corosync-cfgtool -s
corosync-capctl | grep members 
corosync-quorumtool -si 

# start/stop cluster
pcs cluster start --all
pcs cluster stop --all

# start/stop node
pcs cluster start SERVER1
pcs cluster stop SERVER1

# Maintenance of a node
#Cluster SERVER1 to SERVER2  # Place node in standby mode
pcs cluster standby SERVER1
#Remove node from standby mode
pcs cluster unstandby SERVER1 
#disable fencing
pcs property set stonith-enabled-false
# list of of subclasses (resource type):
pcs resource list heartbeat
#to reset failcount:
pcs resource cleanup ‹resource>

#Managing Running Resources
pcs resource move [resource_name] node name 
pcs resource restart [resource_name] 
pcs resource enable [resource_name] 
pcs resource disable (resource_name] 

#Add a resource in a group
pcs resource group add ‹group> ‹resource>
pcs resource group list
pcs resource list

#Cluster Admin Commands:
pcs status - View cluster status.
pcs config - View and manage cluster configuration. 
pcs cluster - Configure cluster options and nodes. 
pcs resource - Manage cluster resources. 
pcs stonith - Manage fence devices. 
pcs constraint - Manage resource constraints. 
pcs property - Manage pacemaker properties. 
pcs node - Manage cluster nodes. 
pcs quorum - Manage cluster quorum settings.
pcs alert - Manage pacemaker alerts. 
pcs pcsd - Manage pcs daemon.
pcs acl - Manage pacemaker access control lists

#Debug information commands:
pcs resource debug-start ‹resource> 
pcs resource debug-stop < resource> 
pcs resource debug-monitor ‹resource> 
pcs resource failcount show ‹resource>

#Configuration:
pcs cluster sync #Sync corosync.conf
pcs cluster destroy #Delete Configuration
pcs cluster cib output.cib #Output Configuration
pcs -f output.cib COMMAND #Change Configuration
pcs cluster cib-push output.cib #Input Configuration

#Display fencing devices
pcs stonith show
#Fence a node off
pcs stonith fence ‹node>
#Modify a fencing device
pcs stonith update stonithid (options]
#Deleting a fencing device
pcs stonith delete stonithid

#Creating and Modifying Resources pcs resource agents
pcs resource describe [resource] #List available resource agents 
pcs resource create [resource id][resource] options #Create resource
pcs resource show [resource id] #Display currently configured setting of resource
pcs resource update (resource id] options #Update resource configuration
pcs resource delete [resource id] #Delete resource
