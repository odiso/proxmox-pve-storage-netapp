# proxmox-pve-storage-netapp
proxmox netapp c-mode plugin

installation
------------
download libpve-storage-perl_XXX_all.deb in releases,
and install it on your proxmox host with

dpkg -i libpve-storage-perl_XXX_all.deb



proxmox storage config
----------------------
/etc/pve/storage.cfg

  
    netapp: mynetappstorage
            path /mnt/pve/mymountpoint
            server x.x.x.x (ip of your controller nfs)
            options rw,noatime,nodiratime,noacl,vers=4,rsize=65536,wsize=65536,hard,proto=tcp,timeo=600
            vserver myvservername
            aggregate myaggregatename
            adminserver x.x.x.x (cluster vip admin ip)
            login youradminlogin
            password yourpassword
            content images
            maxfiles 1


you need to create the mountpoint directory on proxmox host

mkdir /mnt/pve/mymountpoint
                




  NETAPP CLUSTER MODE, PHYSICAL VIEW
  ------------------------------------

                    (Cluster admin VIP)
               ----------------------------
      |------ |INTERCLUSTER NETWORK (10GB)|------
      |        ----------------------------     |
      |              |           |              |
      |              |           |              |
    [NODE1]       [NODE2]     [NODE3]         [NODE4]
      |              |           |              |
    ----------   ----------   -----------    -----------
    AGGREGATE1    AGGREGATE3   AGGREGATE4    AGGREGATE5
    [vm1][vm2]    [vm3][vm4]   [vm5][vm6]    [vm7][vm8]
    ----------   ----------   -----------    ----------
      |
    ----------
    AGGREGATE2
    [vm9][vm10]
    ----------

    An aggregate is a raid-dp of x disk.
    Each aggregate have differents volumes, 1 by vm.

    NETAPP CLUSTER MODE, LOGICAL VIEW
    ---------------------------------
    A virtual server is defined on top of the physical cluster

    -----------------------------------
    |           VSERVER               |
    |        (NFS ips, 1 by node)     |
    | [vm1][vm2][vm3][vm4][vm5]...    |
    -----------------------------------

    Each node is a nfs metadatas server.
    You only need to mount nfs on 1 metadataserver to access the whole vserver

    NFS VIEW
    ---------
    We only mount the root

    mymetadataserver:/ /mnt/pve/netapp-vservername

    /
    /images/vm1/vm-1-disk-1.raw
    /images/vm1/vm-1-disk-2.raw
    /images/vm2/
    /images/vm3/
    /images/vm4/
    /images/vm5/
    /images/vm6/
    /images/vm7/
    /images/vm8/
    /images/vm9/
    /images/vm10/

    Eech vm have a volume in the storage.(volume name can't be only numeric, so I prefix them with "vm".vmid.
    Each node is limited to 500volumes, that why I don't have 1 volume by disk.
    We can move volume in realtime in the cluster, from 1 aggreate to another aggregate. (in netapp interface for now)
