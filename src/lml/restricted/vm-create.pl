#!/usr/bin/perl -w

use strict;
use warnings;

use FindBin;
use lib glob("{/opt/vmware/,/usr/lib/vmware-}vcli/?pps");    # the ? makes sure that only existing paths will match.
use lib "$FindBin::RealBin/../lib";

$Util::script_version = "1.0";

use CGI ':standard';
use VMware::VIRuntime;
use JSON;
use AppUtil::XMLInputUtil;
use AppUtil::HostUtil;
use AppUtil::VMUtil;
use Data::Dumper;
use LWP::Simple qw(get);
use Getopt::Long;
use LML::VMware;

use LML::Config;
my $C = new LML::Config();

# default paramter
my $linebreak             = '\n';
my $hostname_package_host = "vcs01.rz.is24.loc";

# default values will be used as default values
my $guestid = 'rhel6_64Guest';
my %custom_fields;

# initialize custom value variables
my $vm_name;
my $user_name;
my $expiration_date;

# are we called via webui?
if (    param('name')
     && param('username')
     && param('expiration') )
{
    $vm_name         = param('name');
    $user_name       = param('username');
    $expiration_date = param('expiration');

    # or are we called via commandline
} elsif ( @ARGV > 0 ) {

    # get the long commandline options
    GetOptions(
                "vm_name=s"         => \$vm_name,
                "user_name=s"       => \$user_name,
                "expiration_date=s" => \$expiration_date
    );

    # we have nothing, print help
} else {
    print_usage();
    exit 0;
}

# paramters must be set and valid!
my $check_param = check_parameter(
                                   vm_name         => $vm_name,
                                   user_name       => $user_name,
                                   expiration_date => $expiration_date
);
if ($check_param) {
    print $/. $check_param . $/;
    print_usage();
    exit 0;
}

#
my @vms = generate_vms_array(
                              vm_name         => $vm_name,
                              user_name       => $vm_name,
                              expiration_date => $expiration_date
);

#Util::connect();
create_vms(@vms);
#Util::disconnect();

# generate an array of hashes, where each hash
# represents a virtual machine to be created
# ============================================
sub generate_vms_array {
    my %args = @_;

    # assemble custom fields hash
    %custom_fields = (
                       'Contact User ID'   => $args{vm_name},
                       'Expires'           => $args{expiration_date},
                       'Force Boot'        => 'ON',
                       'Force Boot Target' => 'default'
    );

    # because it is possible that a machine don't exist in subversion we call
    # the generation now
    get( sprintf( $C->get( "vm_spec", "host_announcement" ), $args{vm_name} ) );

    # get now the json spec for this vm
    # TODO: get rid of hardcoded url (sprintf and configuration)
    my $answer = get( sprintf( $C->get( "vm_spec", "host_spec" ), $args{vm_name} ) );
    # check if we got something from web call
    error( "ERROR: Unable to get JSON description file for VM " . $args{vm_name} )
      unless defined $answer;

    # convert the HTML answer to pure json
    $answer =~ s/<[^>]*>//g;
    $answer =~ s/&quot;/"/g;
    $answer =~ s/esx\.json//g;
    # put the json structure to a perl data structure
    my $vm_spec = decode_json($answer);

    # get the best suited esx host
    my $esx_host_fqdn = get_best_esx_host();
    # strip down the real hostname from given fqdn
    $esx_host_fqdn =~ /(^[^\.]+).*$/;
    my $esx_host_name = $1;

    @vms = (
             {
               vmname        => $args{vm_name},
               vmhost        => $esx_host_fqdn,
               datacenter    => $vm_spec->{virtualMachine}->{dataCenter},
               guestid       => $guestid,
               datastore     => $esx_host_name . ':datastore1',
               disksize      => $vm_spec->{virtualMachine}->{diskSize},
               memory        => $vm_spec->{virtualMachine}->{memory},
               num_cpus      => $vm_spec->{virtualMachine}->{numberOfProcessors},
               custom_fields => \%custom_fields,
               target_folder => $vm_spec->{virtualMachine}->{targetFolder}
             }
    );

    return @vms;
}

# TODO: determine the best esx host for the new vm
# determine the esx host with the best disk/memory relation
# =========================================================
sub get_best_esx_host() {
    my $best_esx_host;

    $best_esx_host = "esx01.arc.int";

    return $best_esx_host;
}

# compose error output related to the execution context
# =====================================================
sub error {
    my $message = shift;

    # print html header before anything else if CGI is used
    if ( exists $ENV{GATEWAY_INTERFACE} ) {
        print header( -status => '500 Error while processing' );
        print $message;
    } else {
        print $message . "\n";
    }

    Util::disconnect();
    exit 1;
}

# compose a success output related to caller
# ==========================================
sub success {
    my $uuid    = shift;
    my $message = shift;

    # print html header before anything else if CGI is used
    if ( exists $ENV{GATEWAY_INTERFACE} ) {
        print header( -status => '200 vm created' );
    }
    print $uuid;
}

# This subroutine parses the input xml file to retrieve all the
# parameters specified in the file and passes these parameters
# to create_vm subroutine to create a single virtual machine
# =============================================================
sub create_vms {
    my @vms = @_;

    foreach (@vms) {
        create_vm($_);
    }
}

# create a virtual machine
# ========================
sub create_vm {
    my $args = shift;
    my @vm_devices;

    # connect to VMware
    connect_vi();

    my $host_view = Vim::find_entity_view( view_type => 'HostSystem',
                                           filter    => { 'name' => $$args{vmhost} } );

    if ( !$host_view ) {
        error( "ERROR: " . "Host '$$args{vmhost}' not found" );
    }

    my %ds_info = HostUtils::get_datastore(
                                            host_view => $host_view,
                                            datastore => $$args{datastore},
                                            disksize  => $$args{disksize}
    );

    if ( $ds_info{mor} eq 0 ) {
        if ( $ds_info{name} eq 'datastore_error' ) {
            error( "ERROR: " . "Datastore $$args{datastore} not available." );
        }
        if ( $ds_info{name} eq 'disksize_error' ) {
            error("ERROR: The free space available is less than the specified disksize.");
        }
    }

    my $ds_path                     = "[" . $ds_info{name} . "]";
    my $controller_vm_dev_conf_spec = create_conf_spec();
    my $disk_vm_dev_conf_spec       = create_virtual_disk( ds_path => $ds_path, disksize => $$args{disksize} );

    # get all networks, which are related to this vm
    my @vm_nics = find_networks(
                                 vm_name          => $$args{vmname},
                                 host_view        => $host_view,
                                 catchall_network => $C->get( "network_policy", "catchall" )
    );

    # check the success and add the found networks
    if (@vm_nics) {
        push( @vm_devices, @vm_nics );

    } else {
        error("ERROR: No networks for host '$$args{vmname}' found");
    }

    push( @vm_devices, $controller_vm_dev_conf_spec );
    push( @vm_devices, $disk_vm_dev_conf_spec );

    my $files = VirtualMachineFileInfo->new(
                                             logDirectory      => undef,
                                             snapshotDirectory => undef,
                                             suspendDirectory  => undef,
                                             vmPathName        => $ds_path
    );

    my $vm_config_spec = VirtualMachineConfigSpec->new(
                                                        name         => $$args{vmname},
                                                        memoryMB     => $$args{memory},
                                                        files        => $files,
                                                        numCPUs      => $$args{num_cpus},
                                                        guestId      => $$args{guestid},
                                                        deviceChange => \@vm_devices
    );

    my $datacenter_views = Vim::find_entity_views( view_type => 'Datacenter',
                                                   filter    => { name => $$args{datacenter} } );

    unless (@$datacenter_views) {
        error( "ERROR: " . "Datacenter '$$args{datacenter}' not found" );
    }

    if ( $#{$datacenter_views} != 0 ) {
        error( "ERROR: " . "Datacenter '$$args{datacenter}' not unique" );
    }

    my $datacenter           = shift @$datacenter_views;
    my $datacenter_vm_folder = Vim::get_view( mo_ref => $datacenter->vmFolder );
    my $comp_res_view        = Vim::get_view( mo_ref => $host_view->parent );

    # create the folder regardless its already there
    #create_folder( folder => $args{target_folder} );

    # get the wished folder
    my $target_folder_view;
    my @found = split( /\//, $$args{target_folder} );
    # remove any empty lines
    @found = grep( /\S/, @found );
    get_folder(
                folder      => $datacenter_vm_folder,
                found       => \@found,
                target_view => \$target_folder_view
    );

    # just for testing purposes
    #print "DEBUG: ".Data::Dumper->Dump([%{$vm_config_spec}])."\n";

    eval { $target_folder_view->CreateVM( config => $vm_config_spec, pool => $comp_res_view->resourcePool ); };

    if ($@) {
        if ( ref($@) eq 'SoapFault' ) {
            if ( ref( $@->detail ) eq 'PlatformConfigFault' ) {
                error( "ERROR: Invalid VM configuration: " . ${ $@->detail }{'text'} );
            } elsif ( ref( $@->detail ) eq 'InvalidDeviceSpec' ) {
                error( "ERROR: Invalid Device configuration: " . ${ $@->detail }{'property'} );
            } elsif ( ref( $@->detail ) eq 'DatacenterMismatch' ) {
                error("ERROR: DatacenterMismatch, the input arguments had entities that did not belong to the same datacenter");
            } elsif ( ref( $@->detail ) eq 'HostNotConnected' ) {
                error("ERROR: Unable to communicate with the remote host, since it is disconnected");
            } elsif ( ref( $@->detail ) eq 'InvalidState' ) {
                error("ERROR: The operation is not allowed in the current state");
            } elsif ( ref( $@->detail ) eq 'DuplicateName' ) {
                error("ERROR: Virtual machine already exists");
            } else {
                error( "ERROR: " . $@ );
            }
        } else {
            error( "ERROR: " . $@ );
        }
    }

    # set the custom fields with defined values
    set_custom_fields( vmname        => $$args{vmname},
                       custom_fields => $$args{custom_fields} );
    # get the view of the previously created vm
    my $vm_views = VMUtils::get_vms( 'VirtualMachine', $$args{vmname} );
    my $vm_view = shift @{$vm_views};
    # finally switch on the virtual machine
    eval { $vm_view->PowerOnVM(); };
    # handle errors
    if ($@) {
        error("ERROR: Switch on");
    }
    # if everything went find give an success status
    success( $vm_view->config->uuid );
}

#sub create_folder {
#    my %args = @_;
#
#    my $folder      = $args{folder};
#    #$datacenter_vm_folder->CreateFolder( name => $args{target_folder} );
#}

# iterate through folders of datacenter
sub get_folder {
    my %args = @_;

    my $folder      = $args{folder};
    my $found       = $args{found};
    my $target_view = $args{target_view};

    # quit if the target was already found
    not @{$found} and ${$target_view} and return;

    # are we in the target folder?
    if ( $folder->name eq ${$found}[0] ) {
        # cut the first found array element, if we are in that folder
        shift( @{$found} );
        # do we have a hit?
        if ( not @{$found} ) {
            ${$target_view} = $folder;
            return;
        }
    }

    # quit on no childs
    $folder->can("childEntity") or return;

    # quit if we get errors on requesting the child entry
    my $children = $folder->childEntity || return;

    # go through each found child
    for my $child ( @{$children} ) {
        # ignore virtual machines
        next if $child->type eq 'VirtualMachine';

        # call this function on child to start the game again
        get_folder(
                    folder      => Vim::get_view( mo_ref => $child ),
                    found       => $found,
                    target_view => $target_view
        );
    }
}

# set the custom fields used by lab manager light
# ===============================================
sub set_custom_fields {
    my %args = @_;

    # get view to service object
    my $customFieldsManager = Vim::get_view( mo_ref => Vim::get_service_content()->customFieldsManager );
    # only if there are fields defined
    if ( defined $customFieldsManager->{field} ) {
        my $fields = $customFieldsManager->{field};

        # get  view of the previous created vm
        my $vm = Vim::find_entity_view( view_type => 'VirtualMachine',
                                        filter    => { "config.name" => $args{vmname} } );

        # go through each custom field, which is defined globally
        my $key;
        foreach my $field (@$fields) {
            # go through each configured custom field (in input xml)
            foreach ( keys %{ $args{custom_fields} } ) {
                # if we are at the right field, use its key to modify the custom field in vm
                if ( $field->name eq $_ ) {
                    $customFieldsManager->SetField(
                                                    entity => $vm,
                                                    key    => $field->key,
                                                    value  => ${ $args{custom_fields} }{ $field->name }
                    );
                }
            }
        }
    }
}

# create virtual device config spec for controller
# ================================================
sub create_conf_spec {
    my $controller = ParaVirtualSCSIController->new(
                                                     key       => 0,
                                                     device    => [0],
                                                     busNumber => 0,
                                                     sharedBus => VirtualSCSISharing->new('noSharing')
    );

    my $controller_vm_dev_conf_spec = VirtualDeviceConfigSpec->new( device    => $controller,
                                                                    operation => VirtualDeviceConfigSpecOperation->new('add') );

    return $controller_vm_dev_conf_spec;
}

# create virtual device config spec for disk
# ==========================================
sub create_virtual_disk {
    my %args     = @_;
    my $ds_path  = $args{ds_path};
    my $disksize = $args{disksize};

    my $disk_backing_info = VirtualDiskFlatVer2BackingInfo->new( diskMode => 'persistent',
                                                                 fileName => $ds_path );

    my $disk = VirtualDisk->new(
                                 backing       => $disk_backing_info,
                                 controllerKey => 0,
                                 key           => 0,
                                 unitNumber    => 0,
                                 capacityInKB  => $disksize
    );

    my $disk_vm_dev_conf_spec = VirtualDeviceConfigSpec->new(
                                                              device        => $disk,
                                                              fileOperation => VirtualDeviceConfigSpecFileOperation->new('create'),
                                                              operation     => VirtualDeviceConfigSpecOperation->new('add')
    );
    return $disk_vm_dev_conf_spec;
}

# find all networks related to this vm
# ====================================
sub find_networks {
    my %args = @_;
    my @vm_networks;
    my $catchall_network = undef;
    # get the configured hostname pattern for later comparision
    my $hostname_pattern_extracted = undef;
    my $hostname_pattern = $C->get( "network_policy", "hostname_pattern" );
    if ( $args{vm_name} =~ /($hostname_pattern)/ ) {
        $hostname_pattern_extracted = $1;
    }

    # get all networks, which the selected esx host can see
    my $full_network_list = Vim::get_views( mo_ref_array => $args{host_view}->network );

    # go through each network the esx host can see
    foreach (@$full_network_list) {
        # get the configured network pattern
        my $network_pattern = $C->get( "network_policy", "network_pattern" );
        my $network_pattern_extracted = undef;
        if ( $_->name =~ /($network_pattern)/ ) {
            $network_pattern_extracted = $1;
        }
        # if the hostname pattern matches the network pattern, take it
        if (     defined $network_pattern_extracted
             and defined $hostname_pattern_extracted
             and $network_pattern_extracted eq $hostname_pattern_extracted )
        {
            # push the generated card spec to our array for network cards
            push( @vm_networks, create_nic( network => $_ ) );

            # else check if we have the catchall network, if yes rembember it
        } elsif ( $_->name eq $args{catchall_network} ) {
            $catchall_network = $_;
        }
    }

    # add a nic connected to the catchall network
    if ( not @vm_networks and defined $catchall_network ) {
        push( @vm_networks, create_nic( network => $catchall_network ) );
    }

    # now make sure, that the the networks are sorted in the correct order

    # when we finished, return the generated network cards as an array
    return @vm_networks;
}

# generate a spec of a networkcard
# ================================
sub create_nic {
    my %args = @_;

    # get the dv view of the actual network
    my $dvs_view = Vim::get_view( mo_ref => $args{network}->config->distributedVirtualSwitch );

    # create a new "connection" to that dv switch
    my $backing_port = DistributedVirtualSwitchPortConnection->new( portgroupKey => $args{network}->key,
                                                                    switchUuid   => $dvs_view->uuid );

    # new backing info for the network card to be generated
    my $nic_backing_info = VirtualEthernetCardDistributedVirtualPortBackingInfo->new( port => $backing_port );

    # generate basic conditions for the network card
    my $vd_connect_info = VirtualDeviceConnectInfo->new(
                                                         allowGuestControl => 1,
                                                         connected         => 0,
                                                         startConnected    => 1
    );

    # now generate the network card (just a view atm)
    my $nic = VirtualVmxnet3->new(
                                   backing     => $nic_backing_info,
                                   key         => 0,
                                   unitNumber  => 1,                   # 1 since 0 is used by disk
                                   addressType => 'generated',
                                   connectable => $vd_connect_info
    );

    # convert the generated networkcard view to a spec for adding to a virtual machine
    my $nic_vm_dev_conf_spec = VirtualDeviceConfigSpec->new( device    => $nic,
                                                             operation => VirtualDeviceConfigSpecOperation->new('add') );

    # return the generated spec
    return $nic_vm_dev_conf_spec;
}

# check the validity of the given paramter
# ========================================
sub check_parameter {
    # vm_name, user_name, expiration_date
    my $result;
    my %args                 = @_;
    my $hostname_pattern     = $C->get( "hostrules", "pattern" );
    my $european             = $C->get( "vsphere", "expires_european" );
    my $contactuserid_minuid = $C->get( "vsphere", "contactuserid_minuid" );
    my @pwnaminfo            = getpwnam( $args{user_name} );
    eval { my $expires = DateTime::Format::Flexible->parse_datetime( $args{expiration_date}, european => $european ) };
    $result = $result . "invalid expiration_date\n" if ($@);
    $result = $result . "invalid vm_name\n"         if ( $args{vm_name} !~ m/($hostname_pattern)/ );
    $result = $result . "invalid user_name\n"       if ( !scalar(@pwnaminfo) or $pwnaminfo[2] < $contactuserid_minuid );
    return $result;
}

sub print_usage {
    print "vm-create.pl <OPTIONS>\n\n";

    print "   --vm_name=value \t\t Name of the vm to be created (e.g. devxyz01)\n";
    print "   --user_name=value \t\t Name of the user, which is responsible for the vm (e.g. lmueller)\n";
    print "   --expiration_date=value \t Date where the vm will be expired (e.g. 01.01.2015) \n\n";
}