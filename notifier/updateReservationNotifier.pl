# Notify users when a reservation was just submitted or modified.
use strict;
use lib "/scripts";
use LMTShared;

my ( $lmtcommon, $lmtemailer, $session ) = LMTShared::connect_cq(1);

sub in_array {
    my ( $arr, $search_for ) = @_;
    my %items = map { $_ => 1 } @{$arr};
    return ( exists $items{$search_for} ) ? 1 : 0;
}

LMTShared::notify_recent_reservation_edits( $session, $lmtcommon, $lmtemailer,
    "AssetRef.id", "AssetRef.AssetTitle", "Asset", );
LMTShared::notify_recent_reservation_edits( $session, $lmtcommon, $lmtemailer,
    "CRBRef.id", "CRBRef.Headline", "CRB", );
