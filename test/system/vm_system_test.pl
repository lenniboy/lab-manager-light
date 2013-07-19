#!/usr/bin/perl -w

# required RPM dependencies on RHEL/compatible:
# zbar
# perl-libwww-perl
# perl-JSON
# perl-DateTime

# Defaults
use strict;
use warnings;

use FindBin;
use lib "$FindBin::RealBin/lib";

# Our test modules
use TestTools::VMmanager;
use TestTools::VmCreateOptions;
use TestTools::TestDataProvider;

# For debugging
use Data::Dumper;

sub assert_qr {
    my ( $qrdata, $test_definition ) = @_;
    foreach my $pattern ( @{ $test_definition->{expect} } ) {
        $qrdata->assert_regex($pattern);
    }
}

sub assert_qrdata {
    my ($qrdata) = @_;

    $qrdata->assert_qr_code_age();
    $qrdata->assert_vm_path();
    $qrdata->assert_lml_host();
    $qrdata->assert_uuid();
    $qrdata->assert_host();
    $qrdata->assert_hostname();
    $qrdata->assert_contact_user_id();
    $qrdata->assert_expiration_date();
}

sub excute_test_case {
    my ($test_definition) = @_;
    my $test_result=0;
    print $test_definition->{label} . "\n";
    my $vm_create_options = new TestTools::VmCreateOptions($test_definition);

    my $vm_manager = new TestTools::VMmanager($vm_create_options);
    my $vm_created = $vm_manager->create_vm();
    eval {
        my $qrdata = $vm_created->load_qrdata();
        if ( "qrdata" eq $test_definition->{result} ) {
            assert_qrdata($qrdata);
        } elsif ( "qr" eq $test_definition->{result} ) {
            assert_qr( $qrdata, $test_definition );
        }
    };
    if ($@) {
        print "##teamcity[buildStatus text='Integration Test \"$test_definition->{label}\" FAILED']\n";
    } else {
        print "##teamcity[buildStatus text='Integration Test \"$test_definition->{label}\" OK']\n";
        $test_result = 1;
    }
    $vm_manager->delete_vm();
    return $test_result;
}

my @test_spec       = TestTools::TestDataProvider->parseTestData();
my $counter         = 1;
my $good_tests  = 0;
my $number_of_tests = scalar(@test_spec);

foreach my $test_case (@test_spec) {
    print "##teamcity[buildStatus status='Running test ($counter/$number_of_tests) \"$test_case->{label}\"']\n";
    $good_tests++ if (excute_test_case($test_case));
    print "##teamcity[buildStatus text='Integration Test \"$test_case->{label}\" OK']\n";
    $counter++;
}

my $failed_tests = $number_of_tests - $good_tests;
printf "##teamcity[buildStatus status='%s' text='%d System Tests failed']\n",($failed_tests == 0 ? "SUCCESS" : "FAILURE"),$failed_tests;