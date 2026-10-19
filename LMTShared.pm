package LMTShared;

use strict;
use lib "/scripts";
use CQPerlExt;
use Time::Local;
use Date::Parse;
use Class::Struct;
use LMTCommon;
use LMTEmailer;

struct Reservation => {
    reservationID       => '$',
    reservationHeadline => '$',
    User_name           => '$',
    User_email          => '$',
    BeginDate           => '$',
    EndDate             => '$',
    AssetName           => '$',
    AssetID             => '$',
};

sub open_cq_session {
    my ($lmtcommon) = @_;
    my $login       = $lmtcommon->get( 'database', 'cq_login' );
    my $pass        = $lmtcommon->get( 'database', 'cq_pass' );
    my $db          = $lmtcommon->get( 'database', 'cq_db' );
    my $dbset       = $lmtcommon->get( 'database', 'cq_dbset' );

    my $cq      = CQClearQuest::Build();
    my $runmode = $cq->GetPerlReturnStringMode();
    $cq->SetPerlReturnStringMode($CQPerlExt::CQ_RETURN_STRING_UNICODE);

    my $session = CQSession::Build();
    CQSession::UserLogon( $session, "$login", "$pass", "$db", "$dbset" );
    return $session;
}

sub connect_cq {
    my ($with_emailer) = @_;
    my $lmtcommon = LMTCommon->new();
    my $lmtemailer;
    if ($with_emailer) {
        $lmtemailer = LMTEmailer->new();
    }
    my $session = open_cq_session($lmtcommon);
    return ( $lmtcommon, $lmtemailer, $session );
}

sub format_cq_date {
    my ($db_format) = @_;
    my @split1      = split ' ', $db_format;
    my @split2      = split '-', $split1[0];
    my $day         = $split2[2];
    my $month       = $split2[1];
    my $year        = $split2[0];
    return " " . $day . "-" . $month . "-" . $year . " ";
}

sub each_result_row {
    my ( $session, $query, $code ) = @_;
    my $result_set = $session->BuildResultSet($query);
    $result_set->Execute();
    my $status = $result_set->MoveNext();
    while ( $status == 1 ) {
        $code->($result_set);
        $status = $result_set->MoveNext();
    }
    return;
}

sub result_columns {
    my ( $result_set, $count ) = @_;
    my @values;
    for my $index ( 1 .. $count ) {
        push @values, $result_set->GetColumnValue($index);
    }
    return @values;
}

sub each_query_row {
    my ( $session, $entity, $fields, $code ) = @_;
    my $query = $session->BuildQuery($entity);
    foreach my $field ( @{$fields} ) {
        $query->BuildField($field);
    }
    each_result_row(
        $session, $query,
        sub {
            my ($result_set) = @_;
            $code->( result_columns( $result_set, scalar @{$fields} ) );
        }
    );
    return;
}

sub reservation_unix_bounds {
    my ($result_set) = @_;
    my @begin_parts  = split ' ', $result_set->GetColumnValue(2);
    @begin_parts = split '-', $begin_parts[0];
    my @end_parts = split ' ', $result_set->GetColumnValue(3);
    @end_parts = split '-', $end_parts[0];
    my $begin_unix = mktime(
        '0', '0', '0', $begin_parts[2],
        $begin_parts[1] - 1,
        $begin_parts[0] - 1900
    );
    my $end_unix = mktime(
        '0', '0', '0', $end_parts[2],
        $end_parts[1] - 1,
        $end_parts[0] - 1900
    );
    return ( $begin_unix, $end_unix );
}

sub exclude_complete_between {
    my ( $query, $states, $range ) = @_;
    my $complete = $query->BuildFilterOperator($CQPerlExt::CQ_BOOL_OP_AND);
    my $either   = $complete->BuildFilterOperator($CQPerlExt::CQ_BOOL_OP_OR);
    $complete->BuildFilter( "state", $CQPerlExt::CQ_COMP_OP_NOT_IN, $states );
    $either->BuildFilter( "BeginDate", $CQPerlExt::CQ_COMP_OP_BETWEEN, $range );
    $either->BuildFilter( "EndDate",   $CQPerlExt::CQ_COMP_OP_BETWEEN, $range );
    return;
}

sub collect_reservations_by_bounds {
    my ( $session, $query, $rules, $announce ) = @_;
    my $result_set = $session->BuildResultSet($query);
    $result_set->Execute();
    my $status = $result_set->MoveNext();
    while ( $status == 1 ) {
        my ( $begin_unix, $end_unix ) = reservation_unix_bounds($result_set);
        if ($announce) {
            print "NEXT WEEK \n";
        }
        foreach my $rule ( @{$rules} ) {
            my $value = $rule->{field} eq 'begin' ? $begin_unix : $end_unix;
            if ( $value == $rule->{when} ) {
                if ( $rule->{say} ) {
                    print $rule->{say};
                }
                push @{ $rule->{into} }, $result_set->GetColumnValue(1);
            }
        }
        $status = $result_set->MoveNext();
    }
    return;
}

sub read_asset_or_crb {
    my ( $session, $asset, $crb ) = @_;
    my ( $title, $id );
    if ( $asset ne "" ) {
        my $asset_entity = $session->GetEntity( "Asset", $asset );
        $title = $asset_entity->GetFieldValue("assetTitle")->GetValue();
        $id    = $asset_entity->GetFieldValue("id")->GetValue();
    }
    elsif ( $crb ne "" ) {
        my $crb_entity = $session->GetEntity( "EE_DUT", $crb );
        $title = $crb_entity->GetFieldValue("Headline")->GetValue();
        $id    = $crb_entity->GetFieldValue("id")->GetValue();
    }
    return ( $title, $id );
}

sub reservation_user {
    my ( $session, $entity ) = @_;
    my $login = $entity->GetFieldValue("User")->GetValue();
    my $user  = $session->GetEntity( "users", $login );
    return (
        $user->GetFieldValue("fullname")->GetValue(),
        $user->GetFieldValue("email")->GetValue(),
    );
}

sub reservation_ip_addresses {
    my ( $session, $entity ) = @_;
    my $linked = $entity->GetFieldValue("IPRef")->GetValueAsList();
    my @addresses;
    foreach my $ip ( @{$linked} ) {
        my $ip_entity = $session->GetEntity( "IPAddress", $ip );
        push @addresses, $ip_entity->GetFieldValue("IPAddress")->GetValue();
    }
    return @addresses;
}

sub reservation_record {
    my (%fields) = @_;
    return Reservation->new(
        reservationID       => $fields{id},
        reservationHeadline => $fields{headline},
        User_name           => $fields{name},
        User_email          => $fields{email},
        BeginDate           => format_cq_date( $fields{begin} ),
        EndDate             => format_cq_date( $fields{end} ),
        AssetName           => $fields{asset_name},
        AssetID             => $fields{asset_id},
    );
}

sub log_reservation_debug {
    my (
        $label, $id,  $headline,   $name, $email,
        $begin, $end, $asset_name, $asset_id
    ) = @_;
    print "$label\n";
    print "$id\n";
    print "$headline\n";
    print "$name\n";
    print "$email\n";
    print format_cq_date($begin) . "\n";
    print format_cq_date($end) . "\n";
    print "Asset CRB Name: " . $asset_name . "\n";
    print "Asset CRB IXA: " . $asset_id . "\n";
    return;
}

sub html_ip_list {
    my ( $addresses, $empty_html, $suffix ) = @_;
    my $ip_list = "";
    foreach my $ip_address ( @{$addresses} ) {
        $ip_list .= "<strong>" . $ip_address . "</strong>, ";
    }
    if ( $ip_list eq "" ) {
        return $empty_html;
    }
    $ip_list = substr $ip_list, 0, length($ip_list) - 2;
    if ( defined $suffix && $suffix ne "" ) {
        $ip_list .= $suffix;
    }
    return $ip_list;
}

sub send_reservation_notice {
    my (
        $session,     $base_url, $lmtemailer,   $lmtcommon,
        $reservation, $template, $subject_tail, $ip_list
    ) = @_;
    my $entity =
      $session->GetEntity( "Reservation", $reservation->reservationID );
    my $res_id       = $reservation->reservationID;
    my $res_headline = $reservation->reservationHeadline;
    my $res_begin    = $reservation->BeginDate;
    my $res_end      = $reservation->EndDate;
    my $user_name    = $reservation->User_name;
    my $user_email   = $reservation->User_email;
    my $asset_name   = $reservation->AssetName;
    my $asset_id     = $reservation->AssetID;

    my $database_set  = $session->GetSessionDatabase()->GetDatabaseSetName();
    my $database_name = $session->GetSessionDatabase()->GetDatabaseName();
    my $entity_def    = $entity->GetEntityDefName();
    my $res_url       = $base_url;
    $res_url .= '?command=GenerateMainFrame&service=CQ';
    $res_url .= "&schema=$database_set&contextid=$database_name";
    $res_url .= "&entityDefName=$entity_def&entityID=$res_id";

    my $subject = " Reservation: " . $res_headline . $subject_tail;
    $lmtemailer->loadTemplate($template);
    $lmtemailer->setSubject(
        $lmtcommon->get( 'emailoptions', 'email_subject-prefix' ) . $subject );
    $lmtemailer->setSendTo(
        $user_email . "," . $lmtcommon->get( 'contacts', 'email_level1' ) );
    $lmtemailer->setSendFrom( $lmtcommon->get( 'contacts', 'email_level1' ) );

    my %replace = (
        "res_Headline",  $res_headline, "res_ID",      $res_id,
        "asset_Name",    $asset_name,   "asset_ID",    $asset_id,
        "res_BeginDate", $res_begin,    "res_EndDate", $res_end,
        "user_Name",     $user_name,    "ip_List",     $ip_list,
        "res_URL",       $res_url,
    );
    $lmtemailer->replaceThese(%replace);
    $lmtemailer->sendEmail();
    return;
}

sub deliver_begin_today {
    my ( $session, $base_url, $lmtemailer, $lmtcommon, $reservations ) = @_;
    foreach my $reservation ( @{$reservations} ) {
        my $entity   = $session->GetEntity( "Reservation", $reservation );
        my $begin    = $entity->GetFieldValue("BeginDate")->GetValue();
        my $end      = $entity->GetFieldValue("EndDate")->GetValue();
        my $headline = $entity->GetFieldValue("Headline")->GetValue();
        my $asset    = $entity->GetFieldValue("AssetRef")->GetValue();
        my $crb      = $entity->GetFieldValue("CRBRef")->GetValue();
        my ( $name, $email ) = reservation_user( $session, $entity );
        my $linked = $entity->GetFieldValue("IPRef")->GetValueAsList();
        my ( $title, $asset_id );

        if ( $asset ne "" ) {
            my $asset_entity = $session->GetEntity( "Asset", $asset );
            if ( $asset_entity->GetFieldValue("state")->GetValue() ne
                "Reserved" )
            {
                $session->EditEntity( $asset_entity, "Reserved" );
                if ( $asset_entity->Validate() eq "" ) {
                    $asset_entity->Commit();
                }
                else {
                    $asset_entity->Revert();
                }
            }
            $title    = $asset_entity->GetFieldValue("assetTitle")->GetValue();
            $asset_id = $asset_entity->GetFieldValue("id")->GetValue();
        }
        elsif ( $crb ne "" ) {
            my $crb_entity = $session->GetEntity( "EE_DUT", $crb );
            $title    = $crb_entity->GetFieldValue("Headline")->GetValue();
            $asset_id = $crb_entity->GetFieldValue("id")->GetValue();
        }

        my @addresses;
        foreach my $ip ( @{$linked} ) {
            my $ip_entity = $session->GetEntity( "IPAddress", $ip );
            push @addresses, $ip_entity->GetFieldValue("IPAddress")->GetValue();
        }

        if ( $entity->GetFieldValue("state")->GetValue() eq "Submitted" ) {
            $session->EditEntity( $entity, "Active" );
            if ( $entity->Validate() eq "" ) {
                $entity->Commit();
            }
            else {
                $entity->Revert();
            }
        }

        my $record = reservation_record(
            id         => $reservation,
            headline   => $headline,
            name       => $name,
            email      => $email,
            begin      => $begin,
            end        => $end,
            asset_name => $title,
            asset_id   => $asset_id,
        );
        log_reservation_debug(
            "handleBeginToday", $reservation, $headline,
            $name,              $email,       $begin,
            $end,               $title,       $asset_id,
        );
        send_reservation_notice(
            $session,
            $base_url,
            $lmtemailer,
            $lmtcommon,
            $record,
            "/scripts/email/morningReservationBeginToday.html",
            " Begins Today!",
            html_ip_list(
                \@addresses,
                "<em>None currently associated with this reservation</em>", ""
            ),
        );
    }
    return;
}

sub deliver_saved_reservation {
    my ( $session, $base_url, $lmtemailer, $lmtcommon, $notice ) = @_;
    foreach my $reservation ( @{ $notice->{items} } ) {
        my $entity   = $session->GetEntity( "Reservation", $reservation );
        my $begin    = $entity->GetFieldValue("BeginDate")->GetValue();
        my $end      = $entity->GetFieldValue("EndDate")->GetValue();
        my $headline = $entity->GetFieldValue("Headline")->GetValue();
        my ( $asset, $crb );
        if ( $notice->{crb_first} ) {
            $crb   = $entity->GetFieldValue("CRBRef")->GetValue();
            $asset = $entity->GetFieldValue("AssetRef")->GetValue();
        }
        else {
            $asset = $entity->GetFieldValue("AssetRef")->GetValue();
            $crb   = $entity->GetFieldValue("CRBRef")->GetValue();
        }

        my @addresses;
        my ( $title, $asset_id );
        if ( $notice->{fixed_ips} ) {
            ( $title, $asset_id ) = read_asset_or_crb( $session, $asset, $crb );
        }
        elsif ( $notice->{ips_before_asset} ) {
            @addresses = reservation_ip_addresses( $session, $entity );
            ( $title, $asset_id ) = read_asset_or_crb( $session, $asset, $crb );
        }
        else {
            ( $title, $asset_id ) = read_asset_or_crb( $session, $asset, $crb );
            @addresses = reservation_ip_addresses( $session, $entity );
        }
        my ( $name, $email ) = reservation_user( $session, $entity );
        my $record = reservation_record(
            id         => $reservation,
            headline   => $headline,
            name       => $name,
            email      => $email,
            begin      => $begin,
            end        => $end,
            asset_name => $title,
            asset_id   => $asset_id,
        );
        log_reservation_debug(
            $notice->{label}, $reservation, $headline,
            $name,            $email,       $begin,
            $end,             $title,       $asset_id,
        );
        my $ip_list;
        if ( $notice->{fixed_ips} ) {
            $ip_list = $notice->{fixed_ips};
        }
        else {
            $ip_list = html_ip_list( \@addresses, $notice->{empty_ips},
                $notice->{suffix} );
        }
        send_reservation_notice( $session, $base_url, $lmtemailer, $lmtcommon,
            $record, $notice->{template}, $notice->{subject_tail}, $ip_list, );
    }
    return;
}

sub send_reservation_update_email {
    my (
        $lmtemailer,   $lmtcommon, $res_id,  $res_headline,
        $res_state,    $res_begin, $res_end, $res_project,
        $id,           $headline,  $ip,      $res_timestamp,
        $res_fullname, $res_email, $type
    ) = @_;
    my $res_headline_legacy;
    my $asset_headline;
    my $ip_list;
    if ( $ip ne "" ) {
        $ip_list = "<strong>" . $ip . "</strong>";
    }
    else {
        $ip_list = "<em>No IP Addresses Associated with this Reservation</em>";
    }

    my $subject =
        " Reservation "
      . $res_headline_legacy
      . " Has Been Submitted / Modified!";
    $lmtemailer->loadTemplate("/scripts/email/updateReservationNotifier.html");
    $lmtemailer->setSubject(
        $lmtcommon->get( 'emailoptions', 'email_subject-prefix' ) . $subject );
    $lmtemailer->setSendTo(
        $res_email . "," . $lmtcommon->get( 'contacts', 'email_level1' ) );
    $lmtemailer->setSendFrom( $lmtcommon->get( 'contacts', 'email_level1' ) );

    my %replace = (
        "RESFULLNAME",   $res_fullname,   "TYPE",   $type,
        "ASSETHEADLINE", $asset_headline, "IDNO",   $id,
        "HEADLINE",      $headline,       "IPLIST", $ip_list,
        "RESHEADLINE",   $res_headline,   "RESID",  $res_id,
        "RESBEGIN",      $res_begin,      "RESEND", $res_end,
    );
    $lmtemailer->replaceThese(%replace);
    $lmtemailer->sendEmail();
    return;
}

sub notify_recent_reservation_edits {
    my ( $session, $lmtcommon, $lmtemailer, $id_field, $title_field, $kind ) =
      @_;
    my $submitted_query = $session->BuildQuery("Reservation");
    foreach my $field (
        "ID",                       "Headline",
        "State",                    "BeginDate",
        "EndDate",                  "Project",
        $id_field,                  $title_field,
        "history.action_timestamp", "User.fullname",
        "User.email",               "history.action_timestamp",
        "IPRef.IPAddress",
      )
    {
        $submitted_query->BuildField($field);
    }

    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
      localtime time;
    my $result_set = $session->BuildResultSet($submitted_query);
    $result_set->Execute();
    my $status = $result_set->MoveNext();
    my @notified;

    while ( $status == 1 ) {
        my $res_id         = $result_set->GetColumnValue(1);
        my $res_headline   = $result_set->GetColumnValue(2);
        my $res_state      = $result_set->GetColumnValue(3);
        my $res_begin      = $result_set->GetColumnValue(4);
        my $res_end        = $result_set->GetColumnValue(5);
        my $res_project    = $result_set->GetColumnValue(6);
        my $asset_id       = $result_set->GetColumnValue(7);
        my $asset_headline = $result_set->GetColumnValue(8);
        my $res_timestamp  = $result_set->GetColumnValue(9);
        my $res_fullname   = $result_set->GetColumnValue(10);
        my $res_email      = $result_set->GetColumnValue(11);
        my $last_modified  = $result_set->GetColumnValue(12);
        my $res_ip         = $result_set->GetColumnValue(13);

        my $start =
            ( int($year) + 1900 ) . "-"
          . ( int($mon) + 1 ) . "-"
          . $mday
          . " $hour:$min:$sec";
        my ( $years, $months, $days, $hours, $mins, $secs ) = split /\W+/,
          $last_modified;
        my $stop =
            $years . "-"
          . $months . "-"
          . $days . " "
          . $hours . ":"
          . $mins . ":"
          . $secs;
        my $diff = str2time($start) - str2time($stop);

        if ( $diff < 360 && $diff > -60 ) {
            print "Asset reservation\n";
            printf "It was modified %d seconds ago\n", $diff;
            print "Reservation id : $res_id\n";
            print "Reservation Headline : $res_headline\n";
            print "Reservation State : $res_state\n";
            print "Reservation Begin : $res_begin\n";
            print "Reservation End : $res_end\n";
            print "Reservation Project : $res_project\n";
            print "Asset id : $asset_id\n";
            print "Asset Headline : $asset_headline\n";
            print "Asset IP : $res_ip\n";
            print "Reservation timestamp : $res_timestamp\n";
            print "Reservation Fullname : $res_fullname\n";
            print "Reservation Email : $res_email\n";

            if ( $asset_id ne "" ) {
                send_reservation_update_email(
                    $lmtemailer,     $lmtcommon,   $res_id,
                    $res_headline,   $res_state,   $res_begin,
                    $res_end,        $res_project, $asset_id,
                    $asset_headline, $res_ip,      $res_timestamp,
                    $res_fullname,   $res_email,   $kind,
                );
            }
            push @notified, '$assetID';
        }
        $status = $result_set->MoveNext();
    }
    return;
}

1;
