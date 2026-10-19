# Morning reservation notifier.
use strict;
use lib "/scripts";
use Time::Local;
use LMTShared;

my ( $lmtcommon, $lmtemailer, $session ) = LMTShared::connect_cq(1);
my $base_url = $lmtcommon->get( 'common', 'cqbaseurl' );

$session->SetNameValue( "cronRunning", "yes" );

my @begin_today;
my @end_today;
my @begin_tomorrow;
my @end_tomorrow;
my @begin_next_week;
my @end_next_week;

my (
    $next_week_ahead_sec,  $next_week_ahead_min,  $next_week_ahead_hour,
    $next_week_ahead_mday, $next_week_ahead_mon,  $next_week_ahead_year,
    $next_week_ahead_wday, $next_week_ahead_yday, $next_week_ahead_isdst
) = localtime( time + 691200 );
my (
    $next_week_sec,  $next_week_min,  $next_week_hour,
    $next_week_mday, $next_week_mon,  $next_week_year,
    $next_week_wday, $next_week_yday, $next_week_isdst
) = localtime( time + 604800 );

my $next_week_today =
    int( $next_week_mon + 1 ) . "/"
  . $next_week_mday . "/"
  . int( 1900 + $next_week_year );
my $next_week_tomorrow =
    int( $next_week_ahead_mon + 1 ) . "/"
  . $next_week_ahead_mday . "/"
  . int( 1900 + $next_week_ahead_year );

my $next_week_query = $session->BuildQuery("Reservation");
$next_week_query->BuildField("ID");
$next_week_query->BuildField("BeginDate");
$next_week_query->BuildField("EndDate");

my @next_week_range    = ( $next_week_today, $next_week_tomorrow );
my @next_week_complete = ("Complete");
LMTShared::exclude_complete_between( $next_week_query, \@next_week_complete,
    \@next_week_range );

my $next_week_today_unix =
  mktime( '0', '0', '0', $next_week_mday, $next_week_mon, $next_week_year );
my $next_week_tomorrow_unix =
  mktime( '0', '0', '0', $next_week_ahead_mday, $next_week_ahead_mon,
    $next_week_ahead_year );

LMTShared::collect_reservations_by_bounds(
    $session,
    $next_week_query,
    [
        {
            field => 'begin',
            when  => $next_week_today_unix,
            into  => \@begin_next_week,
            say   => "BEGINS ON THIS DAY NEXT WEEK \n"
        },
        {
            field => 'end',
            when  => $next_week_tomorrow_unix,
            into  => \@end_next_week,
            say   => "ENDS ON THIS DAY NEXT WEEK \n"
        },
    ],
    1,
);

my (
    $tomorrow_sec,  $tomorrow_min,  $tomorrow_hour,
    $tomorrow_mday, $tomorrow_mon,  $tomorrow_year,
    $tomorrow_wday, $tomorrow_yday, $tomorrow_isdst
) = localtime( time + 86400 );
my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
  localtime time;

my $today = int( $mon + 1 ) . "/" . $mday . "/" . int( 1900 + $year );

# Historical date string uses the next-week month component.
my $tomorrow =
    int( $next_week_mon + 1 ) . "/"
  . $tomorrow_mday . "/"
  . int( 1900 + $tomorrow_year );

my $reservation_query = $session->BuildQuery("Reservation");
$reservation_query->BuildField("ID");
$reservation_query->BuildField("BeginDate");
$reservation_query->BuildField("EndDate");

my @date_range      = ( $today, $tomorrow );
my @complete_filter = ("Complete");
LMTShared::exclude_complete_between( $reservation_query, \@complete_filter,
    \@date_range );

my $today_unix = mktime( '0', '0', '0', $mday, $mon, $year );
my $tomorrow_unix =
  mktime( '0', '0', '0', $tomorrow_mday, $tomorrow_mon, $tomorrow_year );

LMTShared::collect_reservations_by_bounds(
    $session,
    $reservation_query,
    [
        { field => 'begin', when => $today_unix,    into => \@begin_today },
        { field => 'begin', when => $tomorrow_unix, into => \@begin_tomorrow },
        { field => 'end',   when => $today_unix,    into => \@end_today },
        { field => 'end',   when => $tomorrow_unix, into => \@end_tomorrow },
    ],
    0,
);

my $num_begin_today     = @begin_today;
my $num_end_today       = @end_today;
my $num_begin_tomorrow  = @begin_tomorrow;
my $num_end_tomorrow    = @end_tomorrow;
my $num_begin_next_week = @begin_next_week;
my $num_end_next_week   = @end_next_week;

print $num_begin_today . " items in the BeginToday Queue\n";
print $num_end_today . " Items in the EndToday Queue\n";
print $num_begin_tomorrow . " items in the BeginTomorrow Queue\n";
print $num_end_tomorrow . " items in the EndTomorrow Queue\n";
print $num_begin_next_week . " items in the BeginNextWeek Queue\n";
print $num_end_next_week . " items in the endNextWeek Queue\n";

if ( $num_begin_today > 0 ) {
    LMTShared::deliver_begin_today( $session, $base_url, $lmtemailer,
        $lmtcommon, \@begin_today );
}

my $stop_tonight =
"<br />It is essential that you  <strong>STOP</strong> using these IP addresses after 10pm tonight!";
my $none_now   = "<em>None currently associated with this reservation</em>";
my $future_ips = "<em>None as reservation is in future - Begins Tomorrow</em>";
my $none_ips   = "<em>No IP Addresses Associated with this Reservation</em>";

my @notices = (
    {
        count            => $num_end_today,
        items            => \@end_today,
        label            => "handleEndToday",
        template         => "/scripts/email/morningReservationEndToday.html",
        subject_tail     => " will end Tonight!",
        empty_ips        => $none_ips,
        suffix           => $stop_tonight,
        ips_before_asset => 1,
    },
    {
        count        => $num_begin_tomorrow,
        items        => \@begin_tomorrow,
        label        => "handleBeginTomorrow",
        template     => "/scripts/email/morningReservationBeginTomorrow.html",
        subject_tail => " will BEGIN Tomorrow morning!",
        fixed_ips    => $future_ips,
        crb_first    => 1,
    },
    {
        count        => $num_end_tomorrow,
        items        => \@end_tomorrow,
        label        => "handleEndTomorrow",
        template     => "/scripts/email/morningReservationEndTomorrow.html",
        subject_tail => " will END Tomorrow!",
        empty_ips    => $none_now,
    },
    {
        count        => $num_begin_next_week,
        items        => \@begin_next_week,
        label        => "handleBeginNextWeek",
        template     => "/scripts/email/morningReservationBeginNextWeek.html",
        subject_tail => " will BEGIN Tomorrow morning!",
        fixed_ips    => $future_ips,
        crb_first    => 1,
    },
    {
        count        => $num_end_next_week,
        items        => \@end_next_week,
        label        => "handleEndNextWeek",
        template     => "/scripts/email/morningReservationEndNextWeek.html",
        subject_tail => " en, first notification!",
        empty_ips    => $none_now,
    },
);

foreach my $notice (@notices) {
    if ( $notice->{count} > 0 ) {
        LMTShared::deliver_saved_reservation( $session, $base_url, $lmtemailer,
            $lmtcommon, $notice );
    }
}
