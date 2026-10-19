# Build dhcpd.conf from ClearQuest reservations and lab board files.
use strict;
use lib "/scripts";
use CQPerlExt;
use English;
use File::stat;
use LMTShared;

my ( $lmtcommon, $lmtemailer, $session ) = LMTShared::connect_cq(1);

###
### Config Destinations
#########################################################################

# target destination
my $dhcpd_target = "/etc/dhcpd.conf";

# used as template
my $dhcpd_template = "/scripts/templates/dhcpd.conf";

# output of new config
my $dhcpd_temp = "/scripts/temp.conf";

#backup of known working config
my $dhcpd_last_good_config = "/scripts/backup/dhcpd.conf";

# customer pxe info
my $customer_pxe_info = "/var/www/html/pxe/pxe.txt";

###
### Other config
#########################################################################
my $pxeFileLastModified = 0;    # updated by sub load_pxeinfo();

###
### Backup
#########################################################################

system "crontab -l >/var/www/html/data/crontab";    # output crontab
system "chmod 777 /var/www/html/data/crontab";
system "cp /scripts/boards/* /var/www/html/data/";
system "chmod 777 /var/www/html/data/boards*";
system "chown apache:apache /var/www/html/data/boards*";
system "cp " . $dhcpd_target . " " . $dhcpd_last_good_config;
system "cp " . $dhcpd_template . " " . $dhcpd_temp;

###
### SIE-XXX is the entry in the lmt crb_location column
### boards.xxx is the output file
### A | B | C | D is where its going to be place in the dhcpd.conf
### Last entry is to doublecheck that ip assignment is
### assigned to the right vlan
### Otherwise the switch will ignore the lease on the wrong vlan
#########################################################################

my @room1 = ( 'SIE1-SW',         '/boards/boards.SW',         'A', 18 );
my @room2 = ( 'SIE1-SV',         '/boards/boards.SV',         'B', 18 );
my @room3 = ( 'Data Center',     '/boards/boards.DataCenter', 'C', 213 );
my @room4 = ( 'SIE1-ServerRack', '/boards/boards.ServerRack', 'D', 213 );
my @room5 = ( 'SIE1-RackRoom',   '/boards/boards.RackRoom',   'E', 212 );
my @room6 = ( 'SIE1-RackRoom2',  '/boards/boards.RackRoom2',  'F', 214 );

#my @room5 = ( 'SIE2-TME' , '/boards/boards.TME' , 'E' , 22 );
my @room7 = ( 'NTS', '/boards/boards.NTS', 'Z', 0 );
my @rooms = ( \@room1, \@room2, \@room3, \@room4, \@room5, \@room6 );

my $template = load_template($dhcpd_temp);
my $pxeinfo  = load_pxeinfo($customer_pxe_info);
my $diff     = 0;

# loop through each room, syncing db information into defined boards file
foreach my $room (@rooms) {

    # create boards files
    syncDB( $room->[0], $room->[1], $room->[2], $room->[3] );

    # create dhcpd hosts entries for temp.conf
    if ( $room->[0] ne 'NTS' ) {
        my $host_section =
          generate_host_section( "/scripts" . $room->[1], $room->[2],
            $pxeinfo );

        # add dhcpd hosts entries into temp.conf
        $template = addToConf( $host_section, $template, $room->[2] );
    }

    if ( $diff == 0 ) {
        $diff = diff( $room->[1], '/var/www/html' );
    }
}

$template = addDateToConf($template);

# output configured configuration into temp.conf
open my $output, '>', $dhcpd_temp
  or die "$PROGRAM_NAME: Failed to open output file $dhcpd_temp ($ERRNO)\n";
print {$output} $template;
close $output;

if ( $diff == 1 || $pxeFileLastModified < 360 ) {
    print "diff|change\n";

    # Move the temp.conf to /etc/dhcpd.conf
    system "cp " . $dhcpd_temp . " " . $dhcpd_target;

    # restart the server
    print "Attempting to restart dhcpd \n";
    system "/etc/init.d/dhcpd restart";
    dhcpChangedEmailer();
}
else {
    print "diff|nochange\n";
}

#########################################################################
#########################################################################
###
### Functions
###
#########################################################################

###
### Were there changes
### Diff the new boards files with the old ones files
###
### @param room, the board file eg. boards.Rackroom
### @param location of the old boards file ( they were copied into /var/www/html/data )
### @return true false ( update dhcp )
#########################################################################

sub diff {
    my $room        = shift;
    my $oldLocation = shift;
    my @path        = split( '/', $room );
    my $str =
        "diff /scripts"
      . $room
      . " /var/www/html/data/"
      . $path[2]
      . " | wc -l 2>&1";
    my $result = `$str`;

    if ( $result == "0" ) {
        print "nochange|$room\n";
        return 0;
    }
    else {
        print "change|$room\n";
        return 1;
    }
}

###
### Grabs all Ip reservations from LMT EE_DUT table
### puts them into boards.<LAB> files
###
### @param lab, SIE1-SW etc
### @param boardsfile, the file to save the db info into
### @param boardsSection
### @param vlan
#########################################################################

sub syncDB {
    my $Lab           = shift;
    my $boardsFile    = shift;
    my $boardsSection = shift;
    my $vlan          = shift;

    open my $boards_fh, '>', '/scripts/' . $boardsFile;

    print "begin|$Lab\n";

    print "updatecrbs|$Lab|$boardsFile|$boardsSection|$vlan\n";
    my ( $static_crbs, $static_crb_keepers ) = build_ip_query(
        $session,
        [
            "StaticCRB.id",                   "IPAddress",
            "StaticCRB.MACAddress1",          "StaticCRB.rootPath",
            "StaticCRB.CurrentUser.fullname", "StaticCRB.CurrentUser.email",
            "State",                          "StaticCRB.CRB_Location",
        ],
        [
            [ "StaticCRB.CRB_Location", $CQPerlExt::CQ_COMP_OP_EQ, [$Lab] ],
            [ "StaticCRB.MACAddress1", $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL, [] ],
        ],
    );
    import_lab_rows(
        query       => $static_crbs,
        keepers     => $static_crb_keepers,
        width       => 8,
        names       => [qw( id ipaddr mac root fullname email state location )],
        lab         => $Lab,
        vlan        => $vlan,
        fh          => $boards_fh,
        boards_file => $boardsFile,
        root_from_row => 1,
        ok            => [
            qw( id crbentry mac ipaddr vlan root file fullname email state location )
        ],
        ip_err => [
            qw( id crb iperror mac ipaddr vlan root file fullname state location )
        ],
        ip_vlan_err => [
            qw( id crb iperrorvlan mac ipaddr vlan root file fullname state location )
        ],
        mac_err =>
          [qw( id crb macerror mac ipaddr vlan root file fullname location )],
    );

    print "updateassets|$Lab|$boardsFile|$boardsSection|$vlan\n";
    my ( $assets, $asset_keepers ) = build_ip_query(
        $session,
        [
            "StaticAsset.id",          "IPAddress",
            "StaticAsset.MACAddress1", "StaticAsset.State",
            "State",                   "StaticAsset.Location",
        ],
        [
            [
                "StaticAsset.MACAddress1", $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL,
                []
            ],
            [ "StaticAsset.Location", $CQPerlExt::CQ_COMP_OP_EQ, [$Lab] ],
        ],
    );
    import_lab_rows(
        query       => $assets,
        keepers     => $asset_keepers,
        width       => 6,
        names       => [qw( id ipaddr mac assetstate state location )],
        lab         => $Lab,
        vlan        => $vlan,
        fh          => $boards_fh,
        boards_file => $boardsFile,
        require_ip  => 1,
        ok          => [
            qw( id assetentry mac ipaddr vlan root file assetstate state location )
        ],
        ip_err => [
            qw( id asset iperror mac ipaddr vlan root file assetstate state location )
        ],
        ip_vlan_err => [
            qw( id asset iperrorvlan mac ipaddr vlan root file assetstate state location )
        ],
        mac_err => [
            qw( id asset macerror mac ipaddr vlan root file assetstate state location )
        ],
    );

    print "updateassetreservations|$Lab|$boardsFile|$boardsSection|$vlan\n";
    my ( $asset_reservations, $asset_reservation_keepers ) = build_ip_query(
        $session,
        [
            "reservations.AssetRef.id",
            "IPAddress",
            "reservations.AssetRef.MACAddress1",
            "reservations.AssetRef.State",
            "State",
            "reservations.AssetRef.Location",
            "reservations.User.email",
        ],
        [
            [
                "reservations.AssetRef.MACAddress1",
                $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL,
                []
            ],
            [
                "reservations.AssetRef.Location", $CQPerlExt::CQ_COMP_OP_EQ,
                [$Lab]
            ],
        ],
    );
    import_lab_rows(
        query               => $asset_reservations,
        keepers             => $asset_reservation_keepers,
        width               => 6,
        names               => [qw( id ipaddr mac assetstate state location )],
        email_from_location => 1,
        lab                 => $Lab,
        vlan                => $vlan,
        fh                  => $boards_fh,
        boards_file         => $boardsFile,
        ok                  => [
            qw( id assetreservationentry mac ipaddr vlan root file assetstate state location email )
        ],
        ip_err => [
            qw( id assetreservation iperror mac ipaddr vlan root file assetstate state location \$email )
        ],
        ip_vlan_err => [
            qw( id assetreservation iperrorvlan mac ipaddr vlan root file assetstate state location email )
        ],
        mac_err => [
            qw( id assetreservation macerror mac ipaddr vlan root file assetstate state location email )
        ],
    );

    print "updatecrbreservations|$Lab|$boardsFile|$boardsSection|$vlan\n";
    print "updatecrbreservations|$Lab|$boardsFile|$boardsSection|$vlan\n";
    my ( $crb_reservations, $crb_reservation_keepers ) = build_ip_query(
        $session,
        [
            "reservations.CRBRef.id",
            "IPAddress",
            "reservations.CRBRef.MACAddress1",
            "reservations.CRBRef.rootPath",
            "reservations.CRBRef.Owner.fullname",
            "reservations.CRBRef.Owner.email",
            "State",
            "reservations.CRBRef.CRB_Location",
        ],
        [
            [
                "reservations.CRBRef.MACAddress1",
                $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL,
                []
            ],
            [
                "reservations.CRBRef.CRB_Location", $CQPerlExt::CQ_COMP_OP_EQ,
                [$Lab]
            ],
        ],
    );
    import_lab_rows(
        query       => $crb_reservations,
        keepers     => $crb_reservation_keepers,
        width       => 8,
        names       => [qw( id ipaddr mac root fullname email state location )],
        lab         => $Lab,
        vlan        => $vlan,
        fh          => $boards_fh,
        boards_file => $boardsFile,
        root_from_row => 1,
        ok            => [
            qw( id crbreservationentry mac ipaddr vlan root file fullname email state location )
        ],
        ip_err => [
            qw( id crbreservation iperror mac ipaddr vlan root file fullname email state location )
        ],
        ip_vlan_err => [
            qw( id crbreservation iperrorvlan mac ipaddr vlan root file fullname email state location )
        ],
        mac_err => [
            qw( id crbreservation macerror mac ipaddr vlan root file fullname email state location )
        ],
    );

    close $boards_fh;
}

###
### Static ip address preference, then reserved, else return 0
### If there is static and reserved ip address for a mac address
### We'll choose the static assignment, ignoring the reserved
### also check the validity of the address
###
### @param reserved, the reserved address in the database
### @param static, the static ip address in the database
### @param vlan, the vlan it should be in
### @return ip address, or 0 indicating dodgy data
#########################################################################

sub checkIpAddress {
    my $ip   = shift;
    my $vlan = shift;
    my $id   = shift;

    # Static gets priority
    if ( $ip =~
/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
      )
    {
        my @octets = split( /\./, $ip );

        # Check to see if the ip address is assigned to the right subnet
        if ( $octets[2] == $vlan ) {

            # All good
            return $ip;
        }
        else {
            # Ip Lease in the wrong vlan
            return 0;
        }
    }

    # Bad ip address
    else {
        # send alert
        return -1;
    }
}

###
### Mac address checker
### return 1 if good, 0 if not
###
### @param mac, the mac address to check
### @return 1 = true, 0 false
#########################################################################

sub checkMacAddress {
    my $mac = shift;

    if ( $mac =~ /^(([0-9a-fA-F]{2}[:-]{1}){5}([0-9a-fA-F]{2}))$/ ) {
        return 1;
    }
    else {
        # send alert
        return 0;
    }
}

###
### Load template file
### Return template data
###
### @param template, location of template file to load
### @return the data in the file
#########################################################################

sub load_template {
    my $template = shift;

    # Read in the template
    if ( open my $data_fh, '<', $template ) {
        print "opened|$template\n";
        my $data;
        $data .= $ARG while (<$data_fh>);
        close $data_fh;
        return $data;
    }

    # Failed Reading file
    else {
        # send alert
        print "openfail|$template\n";
    }
}

###
### Load customer pxe options
### Return pxe data
###
### @param pxefile, location of pxe file to load
### @return the data in the file
#########################################################################

sub load_pxeinfo {
    my $template = shift;

    # Read in the template
    if ( open my $data_fh, '<', $template ) {
        $pxeFileLastModified = time - stat($template)->mtime;
        print "opened|$template\n";
        my $data;
        $data .= $ARG while (<$data_fh>);
        close $data_fh;
        return $data;
    }

    # Failed Reading file
    else {
        # send alert
        print "openfail|$template\n";
    }
}

###
### Get customer info from loaded data
### Match mac / ip in pxe file
### Return data only if matched
### Return pxe array or 0 not found
###
### @param pxefile, the data loaded from the pxe file
### @param mac, the mac address to check for
### @ip the ip to check for
### @return the data in the file
#########################################################################

sub customer_pxe_match {
    my $pxeinfo = shift;
    my $mac     = shift;
    my $ip      = shift;

    my @lines = split( "\n", $pxeinfo );

    foreach my $line (@lines) {
        my ( $email, $macadd, $ipadd, $rootpath, $vend, $nextserver, $filename )
          = split( /\|/, $line );

        if ( $macadd eq $mac && $ipadd eq $ip ) {
            return ( $rootpath, $vend, $nextserver, $filename );
        }
    }

    return ();
}

###
### Generate config data from boards file
### Creates host section for static ip by mac address leases
###
### @param boardsfile
### @return hostS (plural) config for entry into dhcpd.conf
#########################################################################

sub generate_host_section {
    my $boardsfile  = shift;
    my $hostsection = shift;
    my $pxeinfo     = shift;
    my $config      = '';

    $hostsection =~ s/^\s+//;
    $hostsection =~ s/\s+$//;

    # open the boards file
    if ( open my $boards, '<', $boardsfile ) {
        print "createhostsentries|$boardsfile\n";

        my $count = 1;

        # read line by line
        while (<$boards>) {

            # split by space
            my @entry = split( / /, $_ );

            if ( @entry >= 4 ) {

                # doublecheck mac address
                if ( $entry[1] =~
                    /^(([0-9a-fA-F]{2}[:-]{1}){5}([0-9a-fA-F]{2}))$/ )
                {
                    # doublecheck ip address
                    if ( $entry[2] =~
/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
                      )
                    {
                        # check root path for addition
                        # at later date
                        $entry[3] =~ s/\015?\012?$//;

                        my @boardpxe =
                          customer_pxe_match( $pxeinfo, $entry[1], $entry[2] );

                        if ( @boardpxe != 0 ) {

                            # $rootpath , $vend , $nextserver , $filename

                            $config .= dhcp_host_prefix(
                                $entry[0], $hostsection, $count,
                                $entry[1], $entry[2]
                            );
                            $config .= ";\n\n";
                            $config .= "\t\t\t\t### Customer PXE info\n";

                            if ( $boardpxe[0] ne "" ) {
                                $config .= "\t\t\t\toption root-path \""
                                  . $boardpxe[0] . "\";\n";
                            }

                            if ( $boardpxe[1] ne "" ) {
                                $config .=
                                  "\t\t\t\toption vendor-encapsulated-options "
                                  . $boardpxe[1] . ";\n";
                            }

                            if ( $boardpxe[2] ne "" ) {
                                $config .=
                                  "\t\t\t\tnext-server " . $boardpxe[2] . ";\n";
                            }

                            if ( $boardpxe[3] ne "" ) {
                                $config .= "\t\t\t\tfilename \""
                                  . $boardpxe[3] . "\";\n";
                            }

                            $config .= "\t\t\t}";
                            $config .= "\n\n";

                        }
                        else {

                            ## keep appending new hosts into config
                            $config .= dhcp_host_prefix(
                                $entry[0], $hostsection, $count,
                                $entry[1], $entry[2]
                            );
                            $config .= ";\n\t\t\t\t";
                            $config .=
                              "option root-path \"" . $entry[3] . "\";\n";
                            $config .=
"\t\t\t\toption vendor-encapsulated-options 06:01:0B:08:07:AA:AA:01:0A:ED:D9:1C:00;\n";
                            $config .= "\t\t\t\tnext-server 10.237.217.28;\n";
                            $config .=
                              "\t\t\t\tfilename \"BStrap/X86pc/BStrap.0\";\n";
                            $config .= "";
                            $config .= "\t\t\t}";
                            $config .= "\n\n";

                        }

                        $count++;

                    }
                    else {
                        # send alert
                        print "iperror|" . $entry[2] . "\n";
                    }
                }
                else {
                    # send alert
                    print "macerror|" . $entry[1] . "\n";
                }
            }
            else {
                # send alert
                print "hosterror|" . $boardsfile . "\n";
            }
        }
        close $boards;

        # finally return the config for all the boards
        print "generated|" . $hostsection . "\n";
        return $config;
    }

    # Error opening boardsfile
    else {
        # send alert
        print "openfail|$boardsfile|$ERRNO\n";
        return 0;
    }
}

###
### Enters host informmation into dhcp config file
### At sections defined as A B C D E
### Refer to rooms array definition near top of document
###
### @param newdata, the data to be entered at that section
### @param dhcpconf, the template for the dhcp config file
### @param letter, the section where to enter the data
### @return the updated config file
#########################################################################

sub addToConf {
    my $newdata  = shift;
    my $dhcpconf = shift;
    my $letter   = shift;

    print "dhcpd|sectionadd|$letter\n";

    # Drop the new config into the template
    $dhcpconf =~
s/\n\t\t\t### HOST SECTION $letter START.*\n\t\t\t### HOST SECTION $letter END.*?\n/
\t\t\t### HOST SECTION $letter START
\t\t\t# This section of the file is autogenerated by
\t\t\t# \/scripts\/dhcp.pl
\t\t\t#
$newdata
\t\t\t### HOST SECTION $letter END
/s
      or die "Couldn't add $letter\n";

    return $dhcpconf;
}

###
### Enters last update into dhcp config file
###
### @param newdata, the data to be entered at that section
### @param dhcpconf, the template for the dhcp config file
### @return the updated config file
#########################################################################

sub addDateToConf {
    my $dhcpconf = shift;

    print "dhcpd|lastupdate\n";

    my @months   = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my @weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
    my (
        $second,     $minute,    $hour,
        $dayOfMonth, $month,     $yearOffset,
        $dayOfWeek,  $dayOfYear, $daylightSavings
    ) = gmtime();
    my $year = 1900 + $yearOffset;
    my $theGMTime =
"$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";

    # Drop the new config into the template
    $dhcpconf =~ s/### LAST UPDATE SECTION/### Last update : $theGMTime/s
      or die "Couldn't add last update section\n";

    return $dhcpconf;
}

###
### Used to send email if dhcp configuration changes
#########################################################################

sub dhcpChangedEmailer {
    $lmtemailer->loadTemplate("/scripts/email/default.html");
    $lmtemailer->setSubject(
        $lmtcommon->get( 'emailoptions', 'email_subject-prefix' )
          . " DHCP: updated!" );
    $lmtemailer->setSendTo( $lmtcommon->get( 'contacts', 'email_level1' ) );
    $lmtemailer->setSendFrom( $lmtcommon->get( 'contacts', 'email_level1' ) );

    my %replace = (
        "MESSAGE",
"The DHCP server configuration has been updated and the service has been restarted"
    );

    $lmtemailer->replaceThese(%replace);
    $lmtemailer->sendEmail();
}

sub build_ip_query {
    my ( $session, $fields, $filters ) = @_;
    my $query = $session->BuildQuery("ipaddress");
    foreach my $field ( @{$fields} ) {
        $query->BuildField($field);
    }
    my $keepers = apply_and_filters( $query, $filters );
    return ( $query, $keepers );
}

sub apply_and_filters {
    my ( $query, $filters ) = @_;
    my @keepers;
    foreach my $filter ( @{$filters} ) {
        my ( $field, $op, $values ) = @{$filter};
        my @copy = @{$values};
        push @keepers, \@copy;
        my $operator = $query->BuildFilterOperator($CQPerlExt::CQ_BOOL_OP_AND);
        $operator->BuildFilter( $field, $op, $keepers[-1] );
    }
    return \@keepers;
}

sub import_lab_rows {
    my (%opt) = @_;
    LMTShared::each_result_row(
        $session,
        $opt{query},
        sub {
            my ($result_set) = @_;
            my @columns = LMTShared::result_columns( $result_set, $opt{width} );
            my %row;
            @row{ @{ $opt{names} } } = @columns;
            if ( $opt{email_from_location} ) {
                $row{email} = $row{location};
            }
            return if $row{location} ne $opt{lab};
            if ( $opt{require_ip} && $row{ipaddr} eq "" ) {
                return;
            }
            my $root = $opt{root_from_row} ? $row{root} : "/BLANK/ROOT/PATH";
            if ( $opt{root_from_row} && $root eq "" ) {
                $root = "/BLANK/ROOT/PATH";
            }
            my %ctx = (
                id         => $row{id},
                mac        => $row{mac},
                ipaddr     => $row{ipaddr},
                vlan       => $opt{vlan},
                root       => $root,
                file       => $opt{boards_file},
                fullname   => $row{fullname},
                email      => $row{email},
                state      => $row{state},
                assetstate => $row{assetstate},
                location   => $row{location},
            );
            write_validated_board_line(
                $opt{fh},
                $opt{lab},
                $opt{vlan},
                $row{id},
                $row{mac},
                $row{ipaddr},
                $root,
                join_board_fields( $opt{ok},          \%ctx ),
                join_board_fields( $opt{ip_err},      \%ctx ),
                join_board_fields( $opt{ip_vlan_err}, \%ctx ),
                join_board_fields( $opt{mac_err},     \%ctx ),
            );
        },
    );
    return $opt{keepers};
}

sub join_board_fields {
    my ( $spec, $ctx ) = @_;
    my @parts = map {
        if ( $_ eq '\$email' ) {
            '$email';
        }
        elsif ( exists $ctx->{$_} ) {
            $ctx->{$_};
        }
        else {
            $_;
        }
    } @{$spec};
    return join( '|', @parts ) . "\n";
}

sub write_validated_board_line {
    my (
        $fh,     $lab,         $vlan, $id,
        $mac,    $ipaddr,      $root, $ok,
        $ip_err, $ip_vlan_err, $mac_err
    ) = @_;
    if ( checkMacAddress( $mac, $id ) != 0 || $lab eq "NTS" ) {
        my $ip = checkIpAddress( $ipaddr, $vlan, $id );
        if ( $ip eq $ipaddr || $lab eq "NTS" ) {
            print $ok;
            print {$fh} "$id $mac $ipaddr $root\n";
        }
        else {
            if ( $ip == -1 ) {
                print $ip_err;
            }
            else {
                print $ip_vlan_err;
            }
        }
    }
    else {
        print $mac_err;
    }
    return;
}

sub dhcp_host_prefix {
    my ( $entry_id, $hostsection, $count, $mac, $ip ) = @_;
    my $config = "";
    $config .= "\t\t\t";
    $config .= "host board-" . $entry_id . "-" . $hostsection . "-" . $count;
    $config .= "\n\t\t\t";
    $config .= "{";
    $config .= "\n\t\t\t\t";
    $config .= "hardware ethernet " . $mac;
    $config .= ";\n\t\t\t\t";
    $config .= "fixed-address " . $ip;
    return $config;
}

