# proxmox-pve-storage-netapp
proxmox netapp c-mode plugin


proxmox storage config
----------------------
/etc/pve/storage.cfg

  
    netapp: mynetappstorage
            path /mnt/pve/mymountpoint
            server x.x.x.x (ip of your controller nfs)
            vserver myvservername
            aggregate myaggregatename
            adminserver x.x.x.x (cluster vip admin ip)
            login youradminlogin
            password yourpassword
            options rw,noatime,nodiratime,noacl,vers=4,rsize=65536,wsize=65536,hard,proto=tcp,timeo=600
            content images
            maxfiles 1


you need to create the mountpoint directory on proxmox host

mkdir /mnt/pve/mymountpoint
                
