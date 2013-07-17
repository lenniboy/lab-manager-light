package TestTools::VMdata;

#TODO: rename to CreatedVM (inkl. lokaler Variablen)

use strict;
use warnings;

use TestTools::QRdata;
use LWP::UserAgent;
use HTTP::Request;
use JSON;

sub new {
    my ( $class, $uuid, $vm_create_options ) = @_;

    my $self = {
        uuid    => $uuid,
        vm_create_options => $vm_create_options,
    };

    bless( $self, $class );

    return $self;
}

sub load_qrdata {
    my ($self) = @_;

    my $starttime = time();
    my $vm_spec;
    my $file;
    my $screenshot_count = 0;

    print 'DEBUG timeout: ' . $self->{vm_create_options}->{boot_timeout} . "\n";

    while ( not $vm_spec and ( time() <= $starttime + $self->{vm_create_options}->{boot_timeout} ) ) {
        $screenshot_count++;
        $file = $self->_download_vm_screenshot( $self->{uuid}, $screenshot_count );
        $vm_spec = $self->_decode_qr($file);
        sleep 3;    # be nice to vSphere and try again only after a few seconds
    }
    if ($vm_spec) {
        link( $file, "test/temp/" . $self->{vm_create_options}->{vm_host} . "_" . $self->{uuid} . ".png" );
        # do an minimal check for matching uuid
        $self->_fail_team_city_build( "expected uuid:" . $self->{uuid} . ", actual: " . $vm_spec->{UUID} ) if ( $vm_spec->{UUID} ne $self->{uuid} );
    } else {
        $self->_fail_team_city_build( "No QR code recognized after " . $self->{vm_create_options}->{boot_timeout} . " seconds" );
    }

    return new TestTools::QRdata($vm_spec, $self->{vm_create_options});
}

#####################################################################
#####################################################################
# PRIVATE FUNCTIONS
#####################################################################
#####################################################################


# downloads VM screenshot and saves it in a file and return file name
sub _download_vm_screenshot {
    my ( $self, $uuid, $screenshot_count ) = @_;
    my $file = "test/temp/" . $self->{vm_create_options}->{vm_host} . "_" . $self->{uuid} . "_" . $screenshot_count . ".png";
    my $url  = "http://" . $self->{vm_create_options}->{test_host} . "/lml/vmscreenshot.pl?image=1&uuid=" . $self->{uuid};

    print "##teamcity[progressMessage 'Downloading VM Screenshot from $url to $file']\n";
    my $png = $self->_do_http_get_request($url);

    open( FILE, ">$file" ) or $self->_fail_team_city_build("Could not open $file for writing");
    print FILE $png or $self->_fail_team_city_build("Could not write to $file");
    close(FILE);
    return $file;
}

# logs TeamCity build status message with FAILURE status
sub _fail_team_city_build {
    my ( $self, $reason ) = @_;
    print "##teamcity[buildStatus status='FAILURE' text='$reason']\n";
    exit 1;
}

sub _do_http_get_request {
    my ( $self, $url ) = @_;
    my $ua = LWP::UserAgent->new;
    $ua->agent("TeamCity/0.1 ");
    my $req = HTTP::Request->new( GET => "$url" );

    my $res = $ua->request($req);
    return $res->is_success ? $res->content : "ERROR: " . $res->status_line;
}

# decodes the QR code
# returns a hash with decoded vm specification, or undefined if no QR code
# identified in the picture
sub _decode_qr {
    my ( $self, $file ) = @_;

    print "##teamcity[progressMessage 'Decoding QR code from $file']\n";

    my $raw_data = `zbarimg -q --raw $file`;
    return $raw_data ? decode_json($raw_data) : undef;
}

1;
