# proxmox-pve-storage-netapp
proxmox netapp c-mode plugin


 proxmox storage config
----------------------
/etc/pve/storage.cfg

  
    netapppnfs: mynetappstorage
                path /mnt/pve/mypatch
                server x.x.x.x (ip of your controller nfs)
                aggregate myaggregatename
                adminserver x.x.x.x (cluster vip admin ip)
                options rw,noatime,nodiratime,noacl,vers=4,rsize=65536,wsize=65536,hard,proto=tcp,timeo=600
                content images
                maxfiles 1
                
