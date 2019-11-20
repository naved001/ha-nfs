# Stack test nodes only
sudo -i
echo  "BOOTPROTO=dhcp
DEVICE=eth1
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
" > /etc/sysconfig/network-scripts/ifcfg-eth1

## BOTH nodes need to be up with drbd interface responding

# Packages
yum install -y deltarpm epel-release
#yum -y install http://www.elrepo.org/elrepo-release-7.0-3.el7.elrepo.noarch.rpm
yum -y install elrepo-release

yum install -y  drbd90-utils kmod-drbd90 nfs-utils lvm2 mc corosync pcs pacemaker pwgen policycoreutils-python
systemctl disable  drbd --now
yum -y update
modprobe drbd
systemctl enable rpcbind --now
systemctl disable nfs-lock --now
systemctl disable nfs --now
systemctl enable --now pcsd
modprobe drbd
echo drbd > /etc/modules-load.d/drbd.conf
lsmod |grep drbd &>/dev/null || reboot


#After Reboot


#Config variables
#Must change
HAVIP=192.168.188.254
NODE1=drbd-1
NODE2=drbd-2
IP1=192.168.188.7
IP2=192.168.188.12
REPIP1=192.168.2.19
REPIP2=192.168.2.9
BACKDEV=/dev/vdb
PASSWORD=changeme
PASSWORD='!iz-{^1Ivk=04sBoPU6\r3@'

#Change optional
DRBDRES=r0
DRBDDEV=drbd0
DRBDVG=vg_drbd
DRBDLV=lv_$DRBDRES
NFSEXPORTDIR=/mnt/$DRBDDEV
NFSCLIENTIP=*

echo $PASSWORD | grep changeme && exit

drbdadm status | grep $DRBDRES &>/dev/null && exit

#Configuration files
echo  "resource $DRBDRES {
protocol C;
device /dev/$DRBDDEV;
disk /dev/$DRBDVG/$DRBDLV;
meta-disk internal;
on $NODE1 {
address $REPIP1:7788;
}
on $NODE2 {
address $REPIP2:7788;
}
}
"> /etc/drbd.d/$DRBDRES.res

echo "$IP1  $NODE1
" >> /etc/hosts

echo "$IP2  $NODE2
" >> /etc/hosts

ping -qnc1 -w1 $REPIP1 || exit
ping -qnc1 -w1 $REPIP2 || exit

semanage permissive -a drbd_t
mkdir -p $NFSEXPORTDIR
pvcreate $BACKDEV
vgcreate $DRBDVG $BACKDEV
lvcreate -y -l 100%FREE -n $DRBDLV $DRBDVG
drbdadm --force create-md $DRBDRES
drbdadm up $DRBDRES || exit
echo "$PASSWORD" | passwd --stdin hacluster







##ONE of the nodes (1)

drbdadm -- --clear-bitmap new-current-uuid $DRBDRES/0
drbdadm primary $DRBDRES
mkfs.ext4 /dev/$DRBDDEV
drbdadm secondary $DRBDRES

pcs cluster auth $NODE1 -u hacluster -p "$PASSWORD"
pcs cluster auth $NODE2 -u hacluster -p "$PASSWORD"

pcs cluster setup --name cluster_nfs $NODE1 $NODE2
pcs cluster start --all
pcs property set stonith-enabled=false
pcs property set no-quorum-policy=ignore

pcs cluster cib add_drbd
pcs -f add_drbd resource create nfsserver_data ocf:linbit:drbd drbd_resource=$DRBDRES op monitor interval=60s
pcs -f add_drbd resource master nfsserver_data_sync nfsserver_data master-max=1 master-node-max=1 clone-max=2 clone-node-max=1 notify=true
pcs cluster cib-push add_drbd
rm -rf add_drbd

sleep 30
pcs resource create nfsfs Filesystem device=/dev/$DRBDDEV  directory=$NFSEXPORTDIR fstype=ext4 --group nfsgrp

pcs constraint colocation add nfsserver_data_sync nfsgrp INFINITY with-rsc-role=Master
pcs constraint order promote nfsserver_data_sync then start nfsgrp

pcs resource create nfsd nfsserver nfs_shared_infodir=$NFSEXPORTDIR/nfsinfo --group nfsgrp
pcs resource create nfsroot exportfs clientspec="$NFSCLIENTIP" options=rw,sync,no_root_squash directory=$NFSEXPORTDIR fsid=0 --group nfsgrp
pcs resource create nfsip IPaddr2 ip=$HAVIP cidr_netmask=32 --group nfsgrp




##BOTH nodes after successful cluster configuration
systemctl enable --now corosync
systemctl enable --now pacemaker
pcs cluster cib pcs-config
