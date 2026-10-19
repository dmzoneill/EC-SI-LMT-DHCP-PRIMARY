# Export every ClearQuest CRB and asset row.
use strict;
use lib "/scripts";
use LMTShared;

my ( $lmtcommon, $lmtemailer, $session ) = LMTShared::connect_cq(0);

open my $out, '>', '/scripts/log/LMTall.txt';

LMTShared::each_query_row(
    $session, "EE_DUT",
    [
        "id",                 "CRB_Location",
        "MACAddress1",        "State",
        "staticip.IPAddress", "CurrentUser.email"
    ],
    sub {
        my ( $id, $location, $mac1, $state, $ip, $email ) = @_;
        print {$out} "crb|$id|$ip|$mac1|$location|$state|$email\n";
    },
);

LMTShared::each_query_row(
    $session, "ASSET",
    [ "id", "Location", "State", "MACAddress1", "ipAddress.IPAddress" ],
    sub {
        my ( $id, $location, $state, $mac, $ip ) = @_;
        print {$out} "asset|$id|$ip|$mac|$location|$state\n";
    },
);

close $out;
