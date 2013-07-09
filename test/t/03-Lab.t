use strict;
use warnings;

use Test::More;
use Test::Exception;
use File::Slurp;
use Data::Dumper;

BEGIN {
    use_ok "LML::Config";
    use_ok "LML::Lab";
}

# load test config
my $C = new_ok( "LML::Config" => [ "src/lml/default.conf", "test/data/test.conf" ] );

my %LAB_TESTDATA = (
    "HOSTS" => {
                 "4213059e-70c2-6f34-1986-50463d0222f8" => {
                                                             "HOSTNAME"         => "tstgag002",
                                                             "LASTSEEN"         => "1354790575",
                                                             "LASTSEEN_DISPLAY" => "Thu Dec  6 11:42:55 2012",
                                                             "MACS"             => ["01:02:03:04:69:b0"],
                                                             "EXTRAOPTS"        => "option foo2 \"bar2\"",
                 },
                 "4213038e-9203-3a2b-ce9d-c6dac1f2dbbf" => {
                                                             "HOSTNAME"         => "tsthst001",
                                                             "LASTSEEN"         => "1351688243",
                                                             "LASTSEEN_DISPLAY" => "Wed Oct 31 13:57:23 2012",
                                                             "MACS"             => ["01:02:03:04:6e:4e"],
                                                             "IP"               => "1.2.3.4",
                                                             "VM_ID"            => "vm-1000",
                                                             "EXTRAOPTS"        => "option foo \"bar\";option bar baz;",
                 } }

);

#write test data to lab file

write_file( $C->labfile, Data::Dumper->Dump( [ \%LAB_TESTDATA ], [qw(LAB)] ) );

# test if we can load config from config files
my $LAB = new_ok( "LML::Lab" => [ $C->labfile ], "should create new Lab object" );

is( $LAB->{HOSTS}{"4213038e-9203-3a2b-ce9d-c6dac1f2dbbf"}{HOSTNAME},
    "tsthst001", "LAB should contain hostname from test data" );
my $VM = new LML::VM( {
                        "CUSTOMFIELDS" => {
                                            "Contact User ID" => "User2",
                                            "Expires"         => "31.01.2013",
                                            "Force Boot"      => ""
                        },
                        "EXTRAOPTIONS" => { "bios.bootDeviceClasses" => "allow:net" },
                        "MAC"          => {
                                   "99:02:03:04:6e:4e" => "arc.int",
                                   "99:02:03:04:9e:9e" => "foo"
                        },
                        "NAME"       => "tsthst001",
                        "NETWORKING" => [ {
                                            "MAC"     => "99:02:03:04:6e:4e",
                                            "NETWORK" => "arc.int"
                                          },
                                          {
                                            "MAC"     => "99:02:03:04:9e:9e",
                                            "NETWORK" => "foo"
                                          }
                        ],
                        "PATH"  => "development/vm/otherpath/tsthst001",
                        "VM_ID" => "vm-1000",
                        "UUID"  => "4213038e-9203-3a2b-ce9d-c6dac1f2dbbf",
                      } );
$VM->set_networks_filter( $C->vsphere_networks );    # set network filter
is(
    $LAB->update_vm($VM),
    1,
    "should return 1 to indicate that the VM changed some data that is DHCP relevant"
);
is_deeply( [ $LAB->vms_to_update ],
           ["4213038e-9203-3a2b-ce9d-c6dac1f2dbbf"],
           "should return the uuid of the changed VM" );
is_deeply( $LAB->{HOSTS}{"4213038e-9203-3a2b-ce9d-c6dac1f2dbbf"}{MACS},
           ["99:02:03:04:6e:4e"], "should copy only MACS of managed networks" );

$LAB->set_filename("test/temp/new_lab.conf");
is(
    $LAB->write_file( "by " . __FILE__, "test" ),
    2986,
"Writing to 'test/temp/new_lab.conf' should write 2986 bytes and it would be better to analyse the content but at least we notice change"
);

is_deeply( [ $LAB->list_hosts ],
           [ '4213038e-9203-3a2b-ce9d-c6dac1f2dbbf', '4213059e-70c2-6f34-1986-50463d0222f8' ],
           "should list uuids of hosts" );

dies_ok { $LAB->remove } "should be not ok to not specify uuid on host removal";
ok( $LAB->remove("haha"),                                 "should be ok to remove non-existant host" );
ok( $LAB->remove('4213059e-70c2-6f34-1986-50463d0222f8'), "should be ok to remove existing host" );

dies_ok { new LML::Lab("/dev/null") } "should die on reading invalid LAB file";

$LAB = new_ok(
               "LML::Lab" => [ {
                                 "HOSTS" => {
                                              "12345-1234-123" => {
                                                                    "HOSTNAME" => "foo",
                                                                    "MACS"     => [ "1:2:3", "4:5:6" ] } } } ] );

is_deeply(
           $LAB->get_vm("12345-1234-123"),
           {
              "HOSTNAME" => "foo",
              "NAME" => "foo",
              "MACS"     => [ "1:2:3", "4:5:6" ],
              "filter_networks" => []
           },
           "should return test data from previous test"
);

is( $LAB->get_vm("foobar"), undef, "should return undef if VM not found" );
done_testing();
