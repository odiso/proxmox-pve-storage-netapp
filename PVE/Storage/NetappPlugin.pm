package PVE::Storage::NetappPlugin;

use strict;
use warnings;
use IO::File;
use File::Path;
use LWP::UserAgent;
use HTTP::Request;
use XML::Simple;
use PVE::Tools qw(run_command);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);
use Data::Dumper;
# Netapp helper functions

sub netapp_request {
    my ($scfg, $vserver, $params) = @_;

	my $vfiler = $vserver ? "vfiler='$vserver'" : "";

	my $content = "<?xml version='1.0' encoding='UTF-8' ?>\n";
	$content .= "<!DOCTYPE netapp SYSTEM 'file:/etc/netapp_filer.dtd'>\n";
	$content .= "<netapp $vfiler version='1.20' xmlns='http://www.netapp.com/filer/admin'>\n";
	$content .= $params;
	$content .= "</netapp>\n";
	my $url = "http://".$scfg->{adminserver}."/servlets/netapp.servlets.admin.XMLrequest_filer";
	my $request = HTTP::Request->new('POST',"$url");
	$request->authorization_basic($scfg->{login},$scfg->{password});

	$request->content($content);
	$request->content_length(length($content));
	my $ua = LWP::UserAgent->new;
	my $response = $ua->request($request);
	my $xmlparser = XML::Simple->new( KeepRoot => 1 );
	my $xmlresponse = $xmlparser->XMLin($response->{_content});

	if(is_array($xmlresponse->{netapp}->{results})){
	    foreach my $result (@{$xmlresponse->{netapp}->{results}}) {
		if($result->{status} ne 'passed'){
		    die "netapp api error : ".$result->{reason};
		}
	    }
	}
	elsif ($xmlresponse->{netapp}->{results}->{status} ne 'passed') {
	    die "netapp api error : ".$content.$xmlresponse->{netapp}->{results}->{reason};
	}

	return $xmlresponse;
}

sub netapp_build_params {
    my ($execute, %params) = @_;

    my $xml = "<$execute>\n";
    while (my ($property, $value) = each(%params)){
	$xml.="<$property>$value</$property>\n";
    }
    $xml.="</$execute>\n";

    return $xml;

}


sub netapp_create_volume {
    my ($scfg, $volume, $size) = @_;

    print "netapp create volume $volume\n";
    my $aggregate = $scfg->{aggregate};
    my $xmlparams = netapp_build_params("volume-create", "containing-aggr-name" => $aggregate, "volume" => $volume, "size" => "$size", "junction-path" => "/images/$volume", "space-reserve" => "none");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);

}

sub netapp_sisenable_volume {
    my ($scfg, $volume) = @_;

    print "netapp enable sis on volume $volume\n";
    my $aggregate = $scfg->{aggregate};
    my $xmlparams = netapp_build_params("sis-enable", "path" => "/vol/$volume");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);

}

sub netapp_sissetconfig_volume {
    my ($scfg, $volume) = @_;

    print "netapp enable compression on volume $volume\n";
    my $aggregate = $scfg->{aggregate};
    my $xmlparams = netapp_build_params("sis-set-config", "enable-compression" => "true", "enable-inline-compression" => "true", "schedule" => "-", "path" => "/vol/$volume");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);

}

sub netapp_snapshotsetreserve_volume {
    my ($scfg, $volume) = @_;

    print "netapp set snapshotreserver 0% on volume $volume\n";
    my $aggregate = $scfg->{aggregate};
    my $xmlparams = netapp_build_params("snapshot-set-reserve", "volume" => $volume, "percentage" => "0");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);

}

sub netapp_file_rename {
    my($scfg, $src, $dst) = @_;
    print "netapp rename file $src $dst\n";
    my $xmlparams ="<file-rename-file><from-path>$src</from-path><to-path>$dst</to-path></file-rename-file>";
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);

}

sub netapp_list_files {
    my ($scfg, $vmid) = @_;

    my $xmlparams = '';
    my $vols = {};

    if($vmid){
	$vols->{"vm$vmid"} = "vm$vmid";
    }else{
	$vols = netapp_list_vols($scfg);
    }

    while( my ($volume) = each %$vols) {
	$xmlparams .= '<file-list-directory-iter><desired-attributes><file-info><name></name><file-size></file-size></file-info></desired-attributes><max-records>1000</max-records><path>/vol/'.$volume.'</path></file-list-directory-iter>';
    }

    my $xmlresponse = netapp_request($scfg, $scfg->{vserver}, $xmlparams);

    my $list = {};

    if(is_array($xmlresponse->{netapp}->{results})){
	foreach my $result (@{$xmlresponse->{netapp}->{results}}) {

	    while( my ($filename, $properties) = each @{$result->{"attributes-list"}->{"file-info"}} ) {

		if ($filename =~  m/^((vm|base)-(\d+)-disk-(\d+).(\S+))/) {
		    my ($image, $owner, $format) = ($1, $3, $5);

		    $list->{$image} = {
			name => $image,
			vmid => $owner,
			format => $format,
			parent => undef,
			size => $properties->{'file-size'}
		    };

		}
	    }
	}
    }else{
	while( my ($filename, $properties) = each @{$xmlresponse->{netapp}->{results}->{"attributes-list"}->{"file-info"}}) {
               if ($filename =~  m/^((vm|base)-(\d+)-disk-(\d+).(\S+))/) {
                    my ($image, $owner, $format) = ($1, $3, $5);

                    $list->{$image} = {
                        name => $image,
                        vmid => $owner,
                        format => $format,
                        parent => undef,
                        size => $properties->{'file-size'}
                    };
                }
	}
    }
	return $list;
}

sub netapp_list_vols {
    my ($scfg, $vmid) = @_;

    my $xmlparams = '<volume-get-iter><desired-attributes><volume-attributes><volume-id-attributes><name></name></volume-id-attributes></volume-attributes></desired-attributes><max-records>5000</max-records></volume-get-iter>';
    my $xmlresponse = netapp_request($scfg, $scfg->{vserver}, $xmlparams);

    my $list = {};
    foreach my $result (@{$xmlresponse->{netapp}->{results}->{"attributes-list"}->{"volume-attributes"}}) {
	if ($result->{'volume-id-attributes'}->{name} =~  m/^(vm(\d+))/) {
	    my ($volume) = ($1);
	    $list->{$volume} = $volume;
	}
    }
    return $list;
}

sub netapp_resize_volume {
    my ($scfg, $volume, $action, $size) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("volume-size", "volume" => $volume, "new-size" => "$action$size" ));

}

sub netapp_snapshot_create {
    my ($scfg, $volume, $snapname) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("snapshot-create", "volume" => $volume, "snapshot" => "$snapname" ));

}

sub netapp_snapshot_exist {
    my ($scfg, $volume, $snap) = @_;

    my $snapshotslist = netapp_request($scfg, $scfg->{vserver}, netapp_build_params("snapshot-list-info", "volume" => "$volume"));
    my $snapshotexist = undef;
    $snapshotexist = 1 if (defined($snapshotslist->{"netapp"}->{"results"}->{"snapshots"}->{"snapshot-info"}->{"$snap"}));
    $snapshotexist = 1 if (defined($snapshotslist->{netapp}->{results}->{"snapshots"}->{"snapshot-info"}->{name}) && $snapshotslist->{netapp}->{results}->{"snapshots"}->{"snapshot-info"}->{name} eq $snap);
    return $snapshotexist;

}


sub netapp_snapshot_rollback {
    my ($scfg, $volume, $snapname) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("snapshot-restore-volume", "volume" => $volume, "snapshot" => "$snapname" ));

}

sub netapp_snapshot_delete {
    my ($scfg, $volume, $snapname) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("snapshot-delete", "volume" => $volume, "snapshot" => "$snapname" ));

}


sub netapp_unmount_volume {
    my ($scfg, $volume) = @_;

	print "netapp umount volume $volume\n";
	my $xmlparams = netapp_build_params("volume-unmount", "volume-name" => "$volume", "force" => "true");
        netapp_request($scfg, $scfg->{vserver}, $xmlparams);


}

sub netapp_offline_volume {
    my ($scfg, $volume) = @_;

	print "netapp offline volume $volume\n";
	my $xmlparams = netapp_build_params("volume-offline", "name" => "$volume");
        netapp_request($scfg, $scfg->{vserver}, $xmlparams);


}

sub netapp_destroy_volume {
    my ($scfg, $volume) = @_;

	print "netapp destroy volume $volume\n";
	my $xmlparams = netapp_build_params("volume-destroy", "name" => "$volume");
        netapp_request($scfg, $scfg->{vserver}, $xmlparams);


}

sub netapp_clone_volume {
    my ($scfg, $volumesrc, $snap, $volumedst) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("volume-clone-create",
								"parent-volume" => "$volumesrc",
								"parent-snapshot" => "$snap",
								"volume" => "$volumedst",
								"junction-path" => "/images/$volumedst",
								"junction-active" => "true",
								"space-reserve" => "none",
								));
}

sub netapp_aggregate_size {
    my ($scfg) = @_;

	my $list = netapp_request($scfg, undef, netapp_build_params("aggr-get-iter", "desired-attributes" => "" ));

        foreach my $aggregate (@{$list->{netapp}->{results}->{"attributes-list"}->{"aggr-attributes"}}) {
	  if($aggregate->{"aggregate-name"} eq $scfg->{aggregate}){
	     my $used = $aggregate->{"aggr-space-attributes"}->{"size-used"};
	     my $total = $aggregate->{"aggr-space-attributes"}->{"size-total"};
	     my $free = $aggregate->{"aggr-space-attributes"}->{"size-available"};
	     return ($total, $free, $used, 1);
	  }
	}

}


sub is_array {
  my ($ref) = @_;
  # Firstly arrays need to be references, throw
  #  out non-references early.
  return 0 unless ref $ref;

  if (ref $ref eq 'ARRAY'){
  return 1;
  }
  return 0;


  # Now try and eval a bit of code to treat the
  #  reference as an array.  If it complains
  #  in the 'Not an ARRAY reference' then we're
  #  sure it's not an array, otherwise it was.
  eval {
    my $a = @$ref;
  };
  if ($@=~/^Not an ARRAY reference/) {
    return 0;
  } elsif ($@) {
    die "Unexpected error in eval: $@\n";
  } else {
    return 1;
  }

}

# Configuration

sub type {
    return 'netapp';
}

sub plugindata {
    return {
	content => [ { images => 1, rootdir => 1, vztmpl => 1, iso => 1, backup => 1},
		     { images => 1 }],
	format => [ { raw => 1, qcow2 => 1, vmdk => 1 } , 'raw' ],
    };
}

sub properties {
    return {
        vserver => {
            description => "Vserver name",
            type => 'string',
        },
        aggregate => {
            description => "Aggregate name",
            type => 'string',
        },
	adminserver => {
	    description => "Cluster Management IP or DNS name.",
	    type => 'string', format => 'pve-storage-server',
	},
	login => {
	    description => "login",
	    type => 'string',
	},
	password => {
	    description => "password",
	    type => 'string',
	}
    };
}

sub options {
    return {
	path => { fixed => 1 },
	server => { fixed => 1 },
	adminserver => { fixed => 1 },
	login => { fixed => 1 },
	password => { fixed => 1 },
	vserver => { fixed => 1 },
	aggregate => { fixed => 1 },
        nodes => { optional => 1 },
	disable => { optional => 1 },
        maxfiles => { optional => 1 },
	options => { optional => 1 },
	content => { optional => 1 },
	format => { optional => 1 },
	login => { fixed => 1 },
	password => { fixed => 1 },
    };
}


sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    my $vserver = $config->{vserver};
    $config->{path} = "/mnt/pve/netapp-$vserver" if $create && !$config->{path};

    return $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);
}

# Storage implementation

sub path {
    my ($class, $scfg, $volname, $storeid) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $dir = $class->get_subdir($scfg, $vtype);

    $dir .= "/vm$vmid" if $vtype eq 'images';

    my $path = "$dir/$name";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m!^vm(\d+)/(\S+)/vm(\d+)/(\S+)$!) {
        my ($basedvmid, $basename) = ($1, $2);
        PVE::Storage::Plugin::parse_name_dir($basename);
        my ($vmid, $name) = ($3, $4);
        my (undef, undef, $isBase) = PVE::Storage::Plugin::parse_name_dir($name);
        return ('images', $name, $vmid, $basename, $basedvmid, $isBase);
    } elsif ($volname =~ m!^vm(\d+)/(\S+)$!) {
        my ($vmid, $name) = ($1, $2);
        my (undef, undef, $isBase) = PVE::Storage::Plugin::parse_name_dir($name);
        return ('images', $name, $vmid, undef, undef, $isBase);
    }
    die "unable to parse directory volume name ".$volname."\n";
}

my $find_free_diskname = sub {
    my ($imgdir, $vmid, $fmt) = @_;

    my $disk_ids = {};
    PVE::Tools::dir_glob_foreach($imgdir,
                                 qr!(vm|base)-$vmid-disk-(\d+)\..*!,
                                 sub {
                                     my ($fn, $type, $disk) = @_;
                                     $disk_ids->{$disk} = 1;
                                 });

    for (my $i = 1; $i < 100; $i++) {
        if (!$disk_ids->{$i}) {
            return "vm-$vmid-disk-$i.$fmt";
        }
    }

    die "unable to allocate a new image name for VM $vmid in '$imgdir'\n";
};

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my $snap = '__base__';

    # this only works for file based storage types
    die "storage definition has no path\n" if !$scfg->{path};

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
        $class->parse_volname($volname);

    die "create_base on wrong vtype '$vtype'\n" if $vtype ne 'images';

    die "create_base not possible with base image\n" if $isBase;

    my $path = $class->path($scfg, $volname);

    my $newname = $name;
    $newname =~ s/^vm-/base-/;

    my $newvolname = $basename ? "vm$basevmid/$basename/vm$vmid/$newname" :
        "vm$vmid/$newname";

    my $newpath = $class->path($scfg, $newvolname);

    die "file '$newpath' already exists\n" if -f $newpath;

    rename($path, $newpath) ||
        die "rename '$path' to '$newpath' failed - $!\n";

    #create the base snapshot, only if all disks are convert to base

    my $running  = undef; #fixme : is create_base always offline ?

    my $imagedir = $class->get_subdir($scfg, 'images');
    $imagedir.= "/vm$vmid";
    my @gr = <$imagedir/vm-$vmid-disk-*>;
    my $nbdisks = @gr;

    $class->volume_snapshot($scfg, $storeid, $newvolname, $snap, $running) if $nbdisks == 0;

    return $newvolname;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    $cache->{netapp} = netapp_list_files($scfg, $vmid) if !$cache->{netapp};

    my $res = [];
    if (my $dat = $cache->{netapp}) {
        foreach my $image (keys %$dat) {

            my $volname = $dat->{$image}->{name};
            my $owner = $dat->{$volname}->{vmid};

            my $volid = "$storeid:vm$owner/$volname";

            my $info = $dat->{$volname};
            $info->{volid} = $volid;
	
            push @$res, $info;
        }
    }
    return $res;
}


sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid) = @_;

    my $snap = '__base__';

    # this only works for file based storage types
    die "storage definintion has no path\n" if !$scfg->{path};

    my ($vtype, $basename, $basevmid, undef, undef, $isBase) =
        $class->parse_volname($volname);

    die "clone_image on wrong vtype '$vtype'\n" if $vtype ne 'images';

    die "clone_image only works on base images\n" if !$isBase;

    my $imagedir = $class->get_subdir($scfg, 'images');
    my (undef, $fmt) = PVE::Storage::Plugin::parse_name_dir($basename);

    my $name = $basename;
    $name =~ s/base-$basevmid/vm-$vmid/g;

    warn "clone $volname: $vtype, $name, $vmid to $name (base=../$basevmid/$basename)\n";

    my $newvol = "vm$basevmid/$basename/vm$vmid/$name";

    my $volumedst = "vm$vmid";
    my $volumesrc = "vm$basevmid";
    #clone netapp volume

    my $volumeexist = undef;
    my $vols = netapp_list_vols($scfg);
    while( my ($volume) = each %$vols) {
        if ($volume eq $volumedst){
	    $volumeexist = 1;
	    last;
	}
    }

    if (!$volumeexist){

	netapp_clone_volume($scfg, $volumesrc, $snap, $volumedst);
	#delete snapshot embed to clone

	netapp_snapshot_delete($scfg, $volumedst, $snap);

        my $dat = netapp_list_files($scfg, $vmid);

	#resize volume to minimal size

	my $totalsize = 0;
        foreach my $image (keys %$dat) {
           my $filesize = $dat->{$image}->{size};
	   $totalsize += $filesize;
        }

	#add 20m
	$totalsize += 20971520;

	while(1){
	    eval{
		netapp_resize_volume($scfg, $volumedst, "", $totalsize);
	    };
	    if ($@) {
		print "shrink failed.Wait 1sec.\n";
		sleep 1;
	    }else{
		last;
	    }

	}
   }

    #rename files after netapp volume cloning
    netapp_file_rename($scfg, "/vol/$volumedst/$basename","/vol/vm$vmid/$name");

    return $newvol;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $imagedir = $class->get_subdir($scfg, 'images');
    mkpath $imagedir if (-d $imagedir);

    my $volumedir = $imagedir;
    $volumedir .= "/vm$vmid";

    if (!(-d $volumedir)){
	eval {
	    netapp_create_volume($scfg,"vm$vmid","20 m");
	    netapp_sisenable_volume($scfg,"vm$vmid");
	    netapp_sissetconfig_volume($scfg,"vm$vmid");
	    netapp_snapshotsetreserve_volume($scfg,"vm$vmid");
	};
    }

    my $server = $scfg->{server};
    my $export = "/images/vm$vmid";
    my $options = $scfg->{options} ? $scfg->{options} : "minorversion=1,rw,noatime,nodiratime,noacl,vers=4,rsize=65536,wsize=65536,hard,proto=tcp,timeo=600,bg,intr";

    print "waiting trying to mount the new volume\n";
    while (!PVE::Storage::NFSPlugin::nfs_is_mounted($server, $export, $volumedir)) {
	eval { PVE::Storage::NFSPlugin::nfs_mount($server, $export, $volumedir, $options) };
	eval { my @files = glob("$imagedir/*");  };
	sleep 1;
    }

    $name = &$find_free_diskname($volumedir, $vmid, $fmt) if !$name;

    my (undef, $tmpfmt) = PVE::Storage::Plugin::parse_name_dir($name);

    die "illegal name '$name' - wrong extension for format ('$tmpfmt != '$fmt')\n"
        if $tmpfmt ne $fmt;

    my $path = "$volumedir/$name";

    die "disk image '$path' already exists\n" if -e $path;

    my $cmd = ['/usr/bin/qemu-img', 'create'];

    push @$cmd, '-o', 'preallocation=metadata' if $fmt eq 'qcow2';

    push @$cmd, '-f', $fmt, $path, "${size}K";

    run_command($cmd, errmsg => "unable to create image");
    #add space to volume

    netapp_resize_volume($scfg,"vm$vmid","+",$size*1024);

    return "vm$vmid/$name";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname) = @_;
    my $path = $class->path($scfg, $volname);

    if (! -f $path) {
        warn "disk image '$path' does not exists\n";
    } else {

	my ($size, $format, $used, undef) = PVE::Storage::Plugin::file_size_info($path);
	my ($vtype, $name, $vmid) = $class->parse_volname($volname);

	unlink $path;

	my $imagedir = $class->get_subdir($scfg, 'images');
	$imagedir.= "/vm$vmid";
	my @gr = <$imagedir/vm-$vmid-disk-*>;
	my $nbdisks = @gr;

	if($nbdisks == 0) {

	    print "umount nfs $imagedir\n";
	    eval{
		my $cmd = ['/bin/umount', $imagedir];
		run_command($cmd, errmsg => 'umount error');
	    };

	    #delete netapp volume if they are no more image
	    eval{ netapp_unmount_volume($scfg, "vm$vmid");};
	    eval{ netapp_offline_volume($scfg, "vm$vmid");};
	    eval{ netapp_destroy_volume($scfg, "vm$vmid");};
	    if ($@) {
		die "error delete netapp volume";
	    }

	}else{
	    #else shrink the volume
	    #the space reclaim is async on file removal, we loop until it's work
	    while(1){
		eval{
		    netapp_resize_volume($scfg,"vm$vmid","-",$size);
		};
		if ($@) {
		    print "shrink failed.Wait 1sec.\n";
		    sleep 1;
		}else{
		     last;
		}
	    }
	}

    }

    return undef;
}


sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} = PVE::Storage::NFSPlugin::read_proc_mounts() if !$cache->{mountdata};
    my $vserver = $scfg->{vserver};

    my $path = $scfg->{path} ? $scfg->{path} : "/mnt/pve/netapp-$vserver";

    my $server = $scfg->{server};
    my $export = "/";

    if (!PVE::Storage::NFSPlugin::nfs_is_mounted($server, $export, $path, $cache->{mountdata})) {
	# NOTE: only call mkpath when not mounted (avoid hang
	# when NFS server is offline
	mkpath $path;

	die "unable to activate storage '$storeid' - " .
	    "directory '$path' does not exist\n" if ! -d $path;

	my $options = $scfg->{options} ? $scfg->{options} : "minorversion=1,rw,noatime,nodiratime,noacl,vers=4,rsize=65536,wsize=65536,hard,proto=tcp,timeo=600,bg,intr";
	PVE::Storage::NFSPlugin::nfs_mount($server, $export, $path, $options);
    }

    $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} = PVE::Storage::NFSPlugin::read_proc_mounts() if !$cache->{mountdata};

    my $path = $scfg->{path};
    my $server = $scfg->{server};
    my $export = "/";

    if (PVE::Storage::NFSPlugin::nfs_is_mounted($server, $export, $path, $cache->{mountdata})) {
	my $cmd = ['/bin/umount', $path];
	run_command($cmd, errmsg => 'umount error');
    }
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $exclusive, $cache) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $imagedir = $class->get_subdir($scfg, 'images');
    my $volumedir = $imagedir;
    $volumedir .= "/vm$vmid";

    my $server = $scfg->{server};
    my $export = "/images/vm$vmid";

    my $options = $scfg->{options} ? $scfg->{options} : "minorversion=1,rw,noatime,nodiratime,noacl,vers=4,rsize=65536,wsize=65536,hard,proto=tcp,timeo=600,bg,intr";

    if (!PVE::Storage::NFSPlugin::nfs_is_mounted($server, $export, $volumedir)) {
        PVE::Storage::NFSPlugin::nfs_mount($server, $export, $volumedir, $options);
    }

}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $cache) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $imagedir = $class->get_subdir($scfg, 'images');
    my $volumedir = $imagedir;
    $volumedir .= "/vm$vmid";

    my $server = $scfg->{server};
    my $export = "/images/vm$vmid";

    if (PVE::Storage::NFSPlugin::nfs_is_mounted($server, $export, $volumedir)) {
        my $cmd = ['/bin/umount', $volumedir];
        run_command($cmd, errmsg => 'umount error');
    }

}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my ($total, $free, $used, $active) = netapp_aggregate_size($scfg);

    return ($total, $free, $used, $active);
}


sub check_connection {
    my ($class, $storeid, $scfg) = @_;

    my $server = $scfg->{server};
    my $vserver = $scfg->{vserver};
    my $path = $scfg->{path} ? $scfg->{path} : "/mnt/pve/netapp-$vserver";
    # test connection to portmapper
    my $cmd = ['ls', $path];

    eval {
	run_command($cmd, timeout => 2, outfunc => sub {}, errfunc => sub {});
    };
    if (my $err = $@) {
	return 0;
    }

    return 1;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    die "can't resize this image format" if $volname !~ m/\.(raw)$/;

    my $path = $class->path($scfg, $volname);
    my ($oldsize, $format, $used, undef) = PVE::Storage::Plugin::file_size_info($path);
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $incsize = $size - $oldsize;
    netapp_resize_volume($scfg,"vm$vmid", "+", $incsize);

    return 1 if $running;

    my $cmd = ['/usr/bin/qemu-img', 'resize', $path , $size];

    run_command($cmd, timeout => 10);

    return undef;

}


sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $path = $class->path($scfg, $volname);

    my ($size, $format, $used, undef) = PVE::Storage::Plugin::file_size_info($path);
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    #don't snasphot twice if multiple disk in one volume
    netapp_snapshot_create($scfg, "vm$vmid", $snap) if !netapp_snapshot_exist($scfg, "vm$vmid", $snap);

    #reserve space (thinprovisionned) equal to disk size
    netapp_resize_volume($scfg,"vm$vmid", "+", $size);

    return undef;

}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $dat = netapp_list_files($scfg, $vmid);

   foreach my $image (keys %$dat) {
	return $dat->{$image}->{size} if $image eq $name;
   }
}


sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    netapp_snapshot_rollback($scfg, "vm$vmid", $snap);

}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $path = $class->path($scfg, $volname);
    my ($size, $format, $used, undef) = PVE::Storage::Plugin::file_size_info($path);
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    netapp_snapshot_delete($scfg, "vm$vmid", $snap) if netapp_snapshot_exist($scfg, "vm$vmid", $snap);

    #remove reserved space equal to disk size
    netapp_resize_volume($scfg,"vm$vmid", "-", $size);

    return undef;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

   my $features = {
        snapshot => { current => 1, snap => 1},
        clone => { base => 1, snap => 1},
        template => { current => 1},
        copy => { base => 1, current => 1, snap => 1},
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
        $class->parse_volname($volname);

    my $key = undef;
    if($snapname) {
        $key = 'snap';
    } else {
        $key =  $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;
