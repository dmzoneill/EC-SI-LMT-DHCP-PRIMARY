###
### Includes
#########################################################################

use lib "/scripts";

use CQPerlExt;
use Time::Local;
use Switch;
use POSIX;
use Class::Struct;
use Net::SMTP;
use Date::Parse;
use Socket;
use Sys::Hostname;
use strict;
use LMTCommon;
use LMTEmailer;




###
### Ini Reader
#########################################################################
my $lmtcommon = new LMTCommon;
my $lmtemailer = new LMTEmailer;
my $baseUrl = $lmtcommon->get( 'common' , 'cqbaseurl' );




###
### Database Setup
#########################################################################

my $CQ_LOGIN = $lmtcommon->get( 'database' , 'cq_login' );
my $CQ_PASS = $lmtcommon->get( 'database' , 'cq_pass' );
my $CQ_DB = $lmtcommon->get( 'database' , 'cq_db' );
my $CQ_DBSET = $lmtcommon->get( 'database' , 'cq_dbset' ); # CQ Database Set example for Shannon

### Unicode for crap data in db
my $cq = CQClearQuest::Build();
my $runmode = $cq->GetPerlReturnStringMode();
$cq->SetPerlReturnStringMode( $CQPerlExt::CQ_RETURN_STRING_UNICODE );

my $session = CQSession::Build();
CQSession::UserLogon( $session , "$CQ_LOGIN" , "$CQ_PASS" , "$CQ_DB" , "$CQ_DBSET" );


#
# Define a reservation struct that will be used for passing reservation details between sub routines
########################################################################################################

struct Reservation =>
{
    reservationID  => '$',
    reservationHeadline => '$',
	User_name => '$',
	User_email => '$',
	BeginDate => '$',
	EndDate => '$',
	AssetName => '$',
	AssetID => '$',
};



#
# Set session so clearquest knows if it is a cron job
########################################################################################################

$session->SetNameValue( "cronRunning" , "yes" );


#
# Create Arrays that will be used to hold reservations later
########################################################################################################

my @beginToday;
my @endToday;
my @beginTomorrow;
my @endTomorrow;
my @beginNextWeek;
my @endNextWeek;




#
# Reservations for Next Week
########################################################################################################

# Create A Query that Gets all Reservations that Start/End Next week
my $reservationQuery = $session->BuildQuery( "Reservation" );
$reservationQuery->BuildField( "ID" );
$reservationQuery->BuildField( "BeginDate" );
$reservationQuery->BuildField( "EndDate" );

# Now we must build a filter to get next week and nextweek + 1 day
my ( $nextWeekTSec , $nextWeekTMin , $nextWeekTHour , $nextWeekTMday , $nextWeekTMon , $nextWeekTYear , $nextWeekTWday , $nextWeekTYDay , $nextWeekTIsDst ) = localtime ( time + 691200 );
my ( $nextWeekSec , $nextWeekMin , $nextWeekHour , $nextWeekMday , $nextWeekMon , $nextWeekYear , $nextWeekWday , $nextWeekYDay , $nextWeekIsDst ) = localtime ( time + 604800 );

my $nextWeektoday = int( $nextWeekMon + 1 ) . "/" . $nextWeekMday . "/" . int( 1900 + $nextWeekYear );
my $nextWeektomorrow = int( $nextWeekTMon + 1 ) . "/" . $nextWeekTMday . "/" . int( 1900 + $nextWeekTYear );

my @dateRangeNextWeek = ( $nextWeektoday , $nextWeektomorrow );
my @completeFilterNextWeek = ( "Complete" );

my $query_CompleteFilter = $reservationQuery->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
my $query_Filter = $query_CompleteFilter->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_OR );

$query_CompleteFilter->BuildFilter( "state" , $CQPerlExt::CQ_COMP_OP_NOT_IN , \@completeFilterNextWeek );
$query_Filter->BuildFilter( "BeginDate" , $CQPerlExt::CQ_COMP_OP_BETWEEN , \@dateRangeNextWeek );
$query_Filter->BuildFilter( "EndDate" , $CQPerlExt::CQ_COMP_OP_BETWEEN , \@dateRangeNextWeek );

# Get today and tomorrow in Unix Time as we will need them for comparison reasons below
my $NWtodayUnixTime = mktime( '0' , '0' , '0' , $nextWeekMday , $nextWeekMon , $nextWeekYear );
my $NWtomorrowUnixTime = mktime( '0' , '0' , '0' , $nextWeekTMday , $nextWeekTMon , $nextWeekTYear );
my $resultSet = $session->BuildResultSet( $reservationQuery );
$resultSet->Execute();

my $status = $resultSet->MoveNext();

while ( $status == 1 )
{
	# Now we have a list of all Reservations that Start/End (Today or tomorrow)		
	# Next we must load all Reservation IDs into their respective Arrays
	# To do comparisons we are going to have to convert today and tomorrow to Unix Times - then convert the reservation end/start dates to unix time

	my @thisBeginDateParts = split( ' ' , $resultSet->GetColumnValue( 2 ) );
	my @thisBeginDateParts = split( '-' , $thisBeginDateParts[ 0 ] );
	my @thisEndDateParts = split( ' ' , $resultSet->GetColumnValue( 3 ) );
	my @thisEndDateParts = split( '-' , $thisEndDateParts[ 0 ] );
		
	my $thisBeginUnixTime = mktime( '0' , '0' , '0' , $thisBeginDateParts[ 2 ] , $thisBeginDateParts[ 1 ] - 1 , $thisBeginDateParts[ 0 ] - 1900 );	
	my $thisEndUnixTime = mktime( '0' , '0' , '0' , $thisEndDateParts[ 2 ] , $thisEndDateParts[ 1 ] - 1 , $thisEndDateParts[ 0 ] - 1900 );		
	
	# Note we cannot use elsif in the following if statements as an Asset May start today and finish tomorrow (if elsif used, fail to send finish tomorrow alert!)

	print "NEXT WEEK \n";
	
	if ( $thisBeginUnixTime == $NWtodayUnixTime )
	{
		print "BEGINS ON THIS DAY NEXT WEEK \n";
		# The Current Reservation begins next week 
		push( @beginNextWeek , $resultSet->GetColumnValue( 1 ) );
	}	
	if ( $thisEndUnixTime == $NWtomorrowUnixTime )
	{
		print "ENDS ON THIS DAY NEXT WEEK \n";
		# The Current Reservation ends next week 		
		push( @endNextWeek , $resultSet->GetColumnValue( 1 ) );
	}
	
	$status = $resultSet->MoveNext();
}






#
# Create A Query that Gets all Reservations that Start/End Today and Tomorrow
########################################################################################################

my $reservationQuery = $session->BuildQuery( "Reservation" );
$reservationQuery->BuildField( "ID" );
$reservationQuery->BuildField( "BeginDate" );
$reservationQuery->BuildField( "EndDate" );

# Now we must build a filter to get Today and Tomorrows Date
my ( $tomorrowSec , $tomorrowMin , $tomorrowHour , $tomorrowMday , $tomorrowMon , $tomorrowYear , $tomorrowWday , $tomorrowYDay , $tomorrowIsDst ) = localtime ( time + 86400 );
my ( $sec , $min , $hour , $mday , $mon , $year , $wday , $yday , $isdst ) = localtime time;

my $today = int( $mon + 1 ) . "/" . $mday . "/" . int( 1900 + $year );
my $tomorrow = int( $nextWeekMon + 1 ) . "/" . $tomorrowMday . "/" . int( 1900 + $tomorrowYear );

my @dateRange = ( $today , $tomorrow );
my @completeFilter = ( "Complete" );


my $query_CompleteFilter = $reservationQuery->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
my $query_Filter = $query_CompleteFilter->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_OR );

$query_CompleteFilter->BuildFilter( "state" , $CQPerlExt::CQ_COMP_OP_NOT_IN , \@completeFilter );
$query_Filter->BuildFilter( "BeginDate" , $CQPerlExt::CQ_COMP_OP_BETWEEN , \@dateRange );
$query_Filter->BuildFilter( "EndDate" , $CQPerlExt::CQ_COMP_OP_BETWEEN , \@dateRange );

# Get today and tomorrow in Unix Time as we will need them for comparison reasons below
my $todayUnixTime = mktime( '0' , '0' , '0' , $mday , $mon , $year );
my $tomorrowUnixTime = mktime( '0' , '0' , '0' , $tomorrowMday , $tomorrowMon , $tomorrowYear );
my $resultSet = $session->BuildResultSet( $reservationQuery );
$resultSet->Execute();


my $status = $resultSet->MoveNext();

while ( $status == 1 )
{
	# Now we have a list of all Reservations that Start/End (Today or tomorrow)		
	# Next we must load all Reservation IDs into their respective Arrays
	# To do comparisons we are going to have to convert today and tomorrow to Unix Times - then convert the reservation end/start dates to unix time

	my @thisBeginDateParts = split( ' ' , $resultSet->GetColumnValue( 2 ) );
	my @thisBeginDateParts = split( '-' , $thisBeginDateParts[ 0 ] );
	my @thisEndDateParts = split( ' ' , $resultSet->GetColumnValue( 3 ) );
	my @thisEndDateParts = split( '-' , $thisEndDateParts[ 0 ] );
		
	my $thisBeginUnixTime = mktime( '0' , '0' , '0' , $thisBeginDateParts[ 2 ] , $thisBeginDateParts[ 1 ] - 1 , $thisBeginDateParts[ 0 ] - 1900 );	
	my $thisEndUnixTime = mktime( '0' , '0' , '0' , $thisEndDateParts[ 2 ] , $thisEndDateParts[ 1 ] - 1 , $thisEndDateParts[ 0 ] - 1900 );		
	
	# Note we cannot use elsif in the following if statements as an Asset May start today and finish tomorrow (if elsif used, fail to send finish tomorrow alert!)

	if ( $thisBeginUnixTime == $todayUnixTime )
	{
		# The Current Reservation begins tomorrow so place it in the beginToday Queue
		push( @beginToday , $resultSet->GetColumnValue( 1 ) );
	}
	if ( $thisBeginUnixTime == $tomorrowUnixTime )
	{
		# The Current Reservation begins tomorrow so place it in the beginTomorrow Queue
		push( @beginTomorrow , $resultSet->GetColumnValue( 1 ) );
	}
	if ( $thisEndUnixTime == $todayUnixTime )
	{
		# The Current Reservation ends today so place it in the endToday Queue
		push( @endToday , $resultSet->GetColumnValue( 1 ) );
	}
	if ( $thisEndUnixTime == $tomorrowUnixTime )
	{
		# The Current Reservation ends tomorrow so place it in the endTomorrow Queue		
		push( @endTomorrow , $resultSet->GetColumnValue( 1 ) );
	}
	
	$status = $resultSet->MoveNext();
}


#
# Count the amount for each alert time
# And call prefefind function if these are greate than one
########################################################################################################

my $numBeginToday = @beginToday;
my $numEndToday = @endToday;
my $numBeginTomorrow = @beginTomorrow;
my $numEndTomorrow = @endTomorrow;
my $numBeginNextWeek = @beginNextWeek;
my $numEndNextWeek = @endNextWeek;

print $numBeginToday . " items in the BeginToday Queue\n";
print $numEndToday . " Items in the EndToday Queue\n";
print $numBeginTomorrow . " items in the BeginTomorrow Queue\n";
print $numEndTomorrow . " items in the EndTomorrow Queue\n";
print $numBeginNextWeek . " items in the BeginNextWeek Queue\n";
print $numEndNextWeek . " items in the endNextWeek Queue\n";

#Now we have all reservations that we are going to work on in their respected arrays. Now simply work on each

if ( $numBeginToday > 0 )
{
	handleBeginToday( \@beginToday );
}

if ( $numEndToday > 0 )
{
	handleEndToday( \@endToday );
}

if ( $numBeginTomorrow > 0 )
{
	handleBeginTomorrow( \@beginTomorrow );
}

if ( $numEndTomorrow > 0 )
{
	handleEndTomorrow( \@endTomorrow );
}

if ( $numBeginNextWeek > 0 )
{
	handleBeginNextWeek( \@beginNextWeek );
}

if ( $numEndNextWeek > 0 )
{
	handleEndNextWeek( \@endNextWeek );
}





#
# Begin Today 
########################################################################################################

sub handleBeginToday(@)
{
	use vars qw( $session $baseUrl );
	my $reservations = shift @_;

	# Now we must loop through each of these reservations. 
	# For each reservation - Email the user that their reservation has begun. 
	# No need to handle IP stuff as this is done by user during period

	foreach my $reservation ( @$reservations )
	{	
		my $res_Entity = $session->GetEntity( "Reservation" , $reservation );		
		my $reservationBeginDate = $res_Entity->GetFieldValue( "BeginDate" )->GetValue();
		my $reservationEndDate = $res_Entity->GetFieldValue( "EndDate" )->GetValue();
		my $reservationHeadline = $res_Entity->GetFieldValue( "Headline" )->GetValue();
		my $reservationAsset = $res_Entity->GetFieldValue( "AssetRef" )->GetValue();
		my $reservationCRB = $res_Entity->GetFieldValue( "CRBRef" )->GetValue();
		my $res_User = $res_Entity->GetFieldValue( "User" )->GetValue();
		my $user_Entity = $session->GetEntity( "users" , $res_User );
		my $users_name = $user_Entity->GetFieldValue( "fullname" )->GetValue();
		my $users_email = $user_Entity->GetFieldValue( "email" )->GetValue();
		my $reservationIPs = $res_Entity->GetFieldValue( "IPRef" )->GetValueAsList();		
		my $assetCRBTitle;
	    my $assetCRBID;
	
		if ( $reservationAsset ne "" )
		{
			my $asset_Entity = $session->GetEntity( "Asset" , $reservationAsset );
		
			if ( $asset_Entity->GetFieldValue( "state" )->GetValue ne "Reserved" )
			{				
				$session->EditEntity( $asset_Entity , "Reserved" );

				if ( $asset_Entity->Validate() eq "" )
				{
					$asset_Entity->Commit();
				}
				else
				{
					$asset_Entity->Revert();
				}		
			}
			$assetCRBTitle = $asset_Entity->GetFieldValue( "assetTitle" )->GetValue();
			$assetCRBID = $asset_Entity->GetFieldValue( "id" )->GetValue();
		}
		elsif( $reservationCRB ne "" )
		{
			my $crb_Entity = $session->GetEntity( "EE_DUT" , $reservationCRB );
			$assetCRBTitle = $crb_Entity->GetFieldValue( "Headline" )->GetValue();
			$assetCRBID = $crb_Entity->GetFieldValue( "id" )->GetValue();
		}		

		my @reservationIPAddresses;
		
		foreach my $ip ( @$reservationIPs )
		{			
			# Now for each of these IPs that are currently (well should be!) in the Used State - we must free them
			my $ip_Entity = $session->GetEntity( "IPAddress" , $ip );
			my $ipAddr = $ip_Entity->GetFieldValue( "IPAddress" )->GetValue();			
			push( @reservationIPAddresses , $ipAddr );
		}
		
		# Now call upon the mailer sub routine passing the reservation's Name and User's name and email address.
		if( $res_Entity->GetFieldValue( "state" )->GetValue() eq "Submitted" )
		{
			$session->EditEntity( $res_Entity , "Active" );
			if( $res_Entity->Validate() eq "" )
			{
				$res_Entity->Commit();
			}
			else
			{
				$res_Entity->Revert();
			}
		}
				
		my $tempRes = Reservation->new(	reservationID => $reservation,	
										reservationHeadline => $reservationHeadline, 
										User_name => $users_name, 
										User_email => $users_email, 
										BeginDate => formatDate( $reservationBeginDate ), 
										EndDate => formatDate( $reservationEndDate ),
										AssetName => $assetCRBTitle,
										AssetID => $assetCRBID,
										);
			
		print "handleBeginToday\n";
		print  $reservation . "\n";
		print  $reservationHeadline . "\n";
		print  $users_name . "\n";
		print  $users_email . "\n";
		print  formatDate( $reservationBeginDate ) . "\n";
		print  formatDate( $reservationEndDate ) . "\n";
		print  "Asset CRB Name: ".$assetCRBTitle . "\n";
		print  "Asset CRB IXA: ". $assetCRBID . "\n";
	
		sendBeginTodayEmail( $tempRes , \@reservationIPAddresses );
	}
}





#
# Send Begin Today Email
########################################################################################################

sub sendBeginTodayEmail($@)
{
	use vars qw( $session $baseUrl );
	my $reservation = shift @_;
	my $ipAddresses = shift @_;

	# First we must get all variables needed. Get the entity of current reservation
	my $res_Entity = $session->GetEntity( "Reservation" , $reservation->reservationID );
	my $res_ID = $reservation->reservationID;
	my $res_Headline = $reservation->reservationHeadline;
	my $res_BeginDate = $reservation->BeginDate;
	my $res_EndDate = $reservation->EndDate;
	my $user_Name = $reservation->User_name;
	my $user_Email = $reservation->User_email;
	my $asset_Name = $reservation->AssetName;
	my $asset_ID = $reservation->AssetID;
	my $ip_List = "";
		
	foreach my $ipAddress ( @$ipAddresses )
	{	
		$ip_List .= "<strong>" . $ipAddress . "</strong>, ";		
	}

	if ( $ip_List eq "" )
	{
		$ip_List = "<em>None currently associated with this reservation</em>";
	}
	else
	{
		$ip_List = substr $ip_List , 0 , length( $ip_List ) - 2; # Get rid of final comma
	}

	# Get reservation URL	
	my $res_URL = "";
	my $databaseSetName = $session->GetSessionDatabase()->GetDatabaseSetName();
	my $databaseName = $session->GetSessionDatabase()->GetDatabaseName();
	my $entityDefName = $res_Entity->GetEntityDefName();

	$res_URL = $baseUrl;
	$res_URL .= '?command=GenerateMainFrame&service=CQ';
	$res_URL .= "&schema=$databaseSetName&contextid=$databaseName";
	$res_URL .= "&entityDefName=$entityDefName&entityID=$res_ID";
	# $res_URL .= "&test=1";

	my $subject = " Reservation: " . $res_Headline . " Begins Today!";
	
	$lmtemailer->loadTemplate( "/scripts/email/morningReservationBeginToday.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . $subject );
	$lmtemailer->setSendTo( $user_Email . "," . $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"res_Headline" , $res_Headline,
		"res_ID" , $res_ID,
		"asset_Name" , $asset_Name,
		"asset_ID" , $asset_ID,
		"res_BeginDate" , $res_BeginDate,
		"res_EndDate" , $res_EndDate,
		"user_Name" , $user_Name,
		"ip_List" , $ip_List,
		"res_URL" , $res_URL,
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
}





#
# Begin End Today
########################################################################################################

sub handleEndToday(@)
{
	use vars qw( $session $baseUrl );
	my $reservations = shift @_;

	# Now we must loop through each of these reservations. 
	# For each reservation we must send a notification email to users stateing they should return equipment
	# We must also set all IPs to the Used State and include details of this in email
	# We must then delete the reservation

	foreach my $reservation ( @$reservations )
	{
	
		my $res_Entity = $session->GetEntity( "Reservation" , $reservation );
		
		my $reservationBeginDate = $res_Entity->GetFieldValue( "BeginDate" )->GetValue();
		my $reservationEndDate = $res_Entity->GetFieldValue( "EndDate" )->GetValue();
		my $reservationHeadline = $res_Entity->GetFieldValue( "Headline" )->GetValue();
		my $reservationAsset = $res_Entity->GetFieldValue( "AssetRef" )->GetValue();
		my $reservationCRB = $res_Entity->GetFieldValue( "CRBRef" )->GetValue();
		my $reservationIPs = $res_Entity->GetFieldValue( "IPRef" )->GetValueAsList();

		my @reservationIPAddresses;		
		my $assetCRBTitle;
	        my $assetCRBID;
	
		if( $reservationAsset ne "" )
		{

			my $asset_Entity = $session->GetEntity( "Asset" , $reservationAsset );
			$assetCRBTitle = $asset_Entity->GetFieldValue( "assetTitle" )->GetValue();
			$assetCRBID = $asset_Entity->GetFieldValue( "id" )->GetValue();
		}
		elsif( $reservationCRB ne "" )
		{			
			my $crb_Entity = $session->GetEntity( "EE_DUT" , $reservationCRB );
			$assetCRBTitle = $crb_Entity->GetFieldValue( "Headline" )->GetValue();
			$assetCRBID = $crb_Entity->GetFieldValue( "id" )->GetValue();
		}

		foreach my $ip ( @$reservationIPs )
		{			
			# Catch IP addresses and change state/remove link
			my $ip_Entity = $session->GetEntity( "IPAddress" , $ip );
			my $ipAddr = $ip_Entity->GetFieldValue( "IPAddress" )->GetValue();	
			push( @reservationIPAddresses , $ipAddr );						
		}
			
		# Next get user details so that we can send an email		

		my $res_User = $res_Entity->GetFieldValue( "User" )->GetValue();
		my $user_Entity = $session->GetEntity( "users" , $res_User );
		my $users_name = $user_Entity->GetFieldValue( "fullname" )->GetValue();
		my $users_email = $user_Entity->GetFieldValue( "email" )->GetValue();

		# Note that there is a Complete Action hook that frees any IPs that are associated with the reservation.		
		# Now call upon the mailer sub routine passing the reservation's Name and User's name and email address.

		my $tempRes = Reservation->new( reservationID => $reservation,
			reservationHeadline => $reservationHeadline,
			User_name => $users_name,
			User_email => $users_email,
			BeginDate => formatDate( $reservationBeginDate ),
			EndDate => formatDate( $reservationEndDate ),
			AssetName => $assetCRBTitle,
			AssetID => $assetCRBID,
        );
		
		print "handleEndToday\n";
		print  $reservation . "\n";
		print  $reservationHeadline . "\n";
		print  $users_name . "\n";
		print  $users_email . "\n";
		print  formatDate( $reservationBeginDate ) . "\n";
		print  formatDate( $reservationEndDate ) . "\n";
		print  "Asset CRB Name: ".$assetCRBTitle . "\n";
		print  "Asset CRB IXA: ". $assetCRBID . "\n";

		sendEndTodayEmail( $tempRes , \@reservationIPAddresses );
	}
}





#
# Send End Today Email
########################################################################################################

sub sendEndTodayEmail($@)
{
	use vars qw( $session $baseUrl );
	my $reservation = shift @_;
	my $ipAddresses = shift @_;

	# First we must get all variables needed. Get the entity of current reservation
	my $res_Entity = $session->GetEntity( "Reservation" , $reservation->reservationID );
	my $res_ID = $reservation->reservationID;
	my $res_Headline = $reservation->reservationHeadline;
	my $res_BeginDate = $reservation->BeginDate;
	my $res_EndDate = $reservation->EndDate;	
	my $user_Name = $reservation->User_name;
	my $user_Email = $reservation->User_email;	
	my $asset_Name = $reservation->AssetName;
	my $asset_ID = $reservation->AssetID;
	my $ip_List = "";
	
	foreach my $ipAddress ( @$ipAddresses )
	{	
		$ip_List .= "<strong>" . $ipAddress . "</strong>, ";		
	}
	if ( $ip_List eq "" )
	{
		$ip_List = "<em>No IP Addresses Associated with this Reservation</em>";
	}
	else
	{
		$ip_List = substr $ip_List , 0 , length( $ip_List ) - 2; 		# Get rid of final comma
		$ip_List .= "<br />It is essential that you  <strong>STOP</strong> using these IP addresses after 10pm tonight!";
	}

	# Get reservation URL	
	my $res_URL = "";
	my $databaseSetName = $session->GetSessionDatabase()->GetDatabaseSetName();
	my $databaseName = $session->GetSessionDatabase()->GetDatabaseName();
	my $entityDefName = $res_Entity->GetEntityDefName();

	$res_URL = $baseUrl;
	$res_URL .= '?command=GenerateMainFrame&service=CQ';
	$res_URL .= "&schema=$databaseSetName&contextid=$databaseName";
	$res_URL .= "&entityDefName=$entityDefName&entityID=$res_ID";


	my $subject = " Reservation: " . $res_Headline . " will end Tonight!";
	
	$lmtemailer->loadTemplate( "/scripts/email/morningReservationEndToday.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . $subject );
	$lmtemailer->setSendTo( $user_Email . "," . $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"res_Headline" , $res_Headline,
		"res_ID" , $res_ID,
		"asset_Name" , $asset_Name,
		"asset_ID" , $asset_ID,
		"res_BeginDate" , $res_BeginDate,
		"res_EndDate" , $res_EndDate,
		"user_Name" , $user_Name,
		"ip_List" , $ip_List,
		"res_URL" , $res_URL,
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
}





#
# Begin Tomorrow
########################################################################################################

sub handleBeginTomorrow(@)
{
	use vars qw( $session $baseUrl );
	my $reservations = shift @_;

	# Foreach reservation here we simply need to send an alert to the user. Nothing is done in the database

	foreach my $reservation ( @$reservations )
	{	
		my $res_Entity = $session->GetEntity( "Reservation" , $reservation );		
		my $reservationBeginDate = $res_Entity->GetFieldValue( "BeginDate" )->GetValue();
		my $reservationEndDate = $res_Entity->GetFieldValue( "EndDate" )->GetValue();
		my $reservationHeadline = $res_Entity->GetFieldValue( "Headline" )->GetValue();
		my $reservationCRB = $res_Entity->GetFieldValue( "CRBRef" )->GetValue();
		my $reservationAsset = $res_Entity->GetFieldValue( "AssetRef" )->GetValue();

		my $assetCRBTitle;
                my $assetCRBID;

		if( $reservationAsset ne "" )
		{
			my $asset_Entity = $session->GetEntity( "Asset" , $reservationAsset );
			$assetCRBTitle = $asset_Entity->GetFieldValue( "assetTitle" )->GetValue();
			$assetCRBID = $asset_Entity->GetFieldValue( "id" )->GetValue();
		}
		elsif( $reservationCRB ne "" )
		{
			my $crb_Entity = $session->GetEntity( "EE_DUT" , $reservationCRB );
			$assetCRBTitle = $crb_Entity->GetFieldValue( "Headline" )->GetValue();
			$assetCRBID = $crb_Entity->GetFieldValue( "id" )->GetValue();
		}

		my $res_User = $res_Entity->GetFieldValue( "User" )->GetValue();
		my $user_Entity = $session->GetEntity( "users" , $res_User );
		my $users_name = $user_Entity->GetFieldValue( "fullname" )->GetValue();
		my $users_email = $user_Entity->GetFieldValue( "email" )->GetValue();
		
		my $tempRes = Reservation->new( reservationID => $reservation,
			reservationHeadline => $reservationHeadline,
			User_name => $users_name,
			User_email => $users_email,
			BeginDate => formatDate( $reservationBeginDate ),
			EndDate => formatDate( $reservationEndDate ),
			AssetName => $assetCRBTitle,
			AssetID => $assetCRBID,
        );
		
		print "handleBeginTomorrow\n";
		print  $reservation . "\n";
		print  $reservationHeadline . "\n";
		print  $users_name . "\n";
		print  $users_email . "\n";
		print  formatDate( $reservationBeginDate ) . "\n";
		print  formatDate( $reservationEndDate ) . "\n";
		print  "Asset CRB Name: ".$assetCRBTitle . "\n";
		print  "Asset CRB IXA: ". $assetCRBID . "\n";	

		# Now call upon the mailer sub routine passing the reservation's Name and User's name and email address.
		sendBeginTomorrowEmail( $tempRes );
	}
}





#
# Send Begin Tomorrow Email
########################################################################################################

sub sendBeginTomorrowEmail($)
{
	use vars qw( $session $baseUrl );
	my $reservation = shift @_;
	my $res_Entity = $session->GetEntity( "Reservation" , $reservation->reservationID );
	my $res_ID = $reservation->reservationID;
	my $res_Headline = $reservation->reservationHeadline;
	my $res_BeginDate = $reservation->BeginDate;
	my $res_EndDate = $reservation->EndDate;	
	my $user_Name = $reservation->User_name;
	my $user_Email = $reservation->User_email;	
	my $asset_Name = $reservation->AssetName;
	my $asset_ID = $reservation->AssetID;
	my $ip_List = "";
	
	$ip_List = "<em>None as reservation is in future - Begins Tomorrow</em>";	

	# Get reservation URL	
	my $res_URL = "";
	my $databaseSetName = $session->GetSessionDatabase()->GetDatabaseSetName();
	my $databaseName = $session->GetSessionDatabase()->GetDatabaseName();
	my $entityDefName = $res_Entity->GetEntityDefName();

	$res_URL = $baseUrl;
	$res_URL .= '?command=GenerateMainFrame&service=CQ';
	$res_URL .= "&schema=$databaseSetName&contextid=$databaseName";
	$res_URL .= "&entityDefName=$entityDefName&entityID=$res_ID";

	my $subject = " Reservation: " . $res_Headline . " will BEGIN Tomorrow morning!";
	
	$lmtemailer->loadTemplate( "/scripts/email/morningReservationBeginTomorrow.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . $subject );
	$lmtemailer->setSendTo( $user_Email . "," . $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"res_Headline" , $res_Headline,
		"res_ID" , $res_ID,
		"asset_Name" , $asset_Name,
		"asset_ID" , $asset_ID,
		"res_BeginDate" , $res_BeginDate,
		"res_EndDate" , $res_EndDate,
		"user_Name" , $user_Name,
		"ip_List" , $ip_List,
		"res_URL" , $res_URL,
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
}





#
# End Tomorrow
########################################################################################################

sub handleEndTomorrow(@)
{
	use vars qw( $session $baseUrl );
	my $reservations = shift @_;

	# Foreach reservation here we simply need to send an alert to the user that the current reservation they have is about to end tomorrow. 
	# Nothing is done in the database until tomorrow (End Date)
	
	foreach my $reservation( @$reservations )
	{
	
		my $res_Entity = $session->GetEntity( "Reservation" , $reservation );
		
		my $reservationBeginDate = $res_Entity->GetFieldValue( "BeginDate" )->GetValue();
		my $reservationEndDate = $res_Entity->GetFieldValue( "EndDate" )->GetValue();
		my $reservationHeadline = $res_Entity->GetFieldValue( "Headline" )->GetValue();
		my $reservationAsset = $res_Entity->GetFieldValue( "AssetRef" )->GetValue();
		my $reservationCRB = $res_Entity->GetFieldValue( "CRBRef" )->GetValue();
		my $assetCRBTitle;
        my $assetCRBID;

		if( $reservationAsset ne "" )
		{
			my $asset_Entity = $session->GetEntity( "Asset" , $reservationAsset );
			$assetCRBTitle = $asset_Entity->GetFieldValue( "assetTitle" )->GetValue();
			$assetCRBID = $asset_Entity->GetFieldValue( "id" )->GetValue();
		}
		elsif( $reservationCRB ne "" )
		{
			my $crb_Entity = $session->GetEntity( "EE_DUT" , $reservationCRB );
			$assetCRBTitle = $crb_Entity->GetFieldValue( "Headline" )->GetValue();
			$assetCRBID = $crb_Entity->GetFieldValue( "id" )->GetValue();
		}

		my $reservationIPs = $res_Entity->GetFieldValue( "IPRef" )->GetValueAsList();
		my @reservationIPAddresses;

		foreach my $ip ( @$reservationIPs )
		{			
			# Now for each of these IPs that are currently (well should be!) in the Used State - we must free them
			my $ip_Entity = $session->GetEntity( "IPAddress" , $ip );
			my $ipAddr = $ip_Entity->GetFieldValue( "IPAddress" )->GetValue();			
			push( @reservationIPAddresses , $ipAddr );		
		}
			
		my $res_User = $res_Entity->GetFieldValue( "User" )->GetValue();
		my $user_Entity = $session->GetEntity( "users" , $res_User );
		my $users_name = $user_Entity->GetFieldValue( "fullname" )->GetValue();
		my $users_email = $user_Entity->GetFieldValue( "email" )->GetValue();
		
		my $tempRes = Reservation->new( reservationID => $reservation,
			reservationHeadline => $reservationHeadline,
			User_name => $users_name,
			User_email => $users_email,
			BeginDate => formatDate( $reservationBeginDate ),
			EndDate => formatDate( $reservationEndDate ),
			AssetName => $assetCRBTitle,
			AssetID => $assetCRBID,
        );
		
		print "handleEndTomorrow\n";
		print  $reservation . "\n";
		print  $reservationHeadline . "\n";
		print  $users_name . "\n";
		print  $users_email . "\n";
		print  formatDate( $reservationBeginDate ) . "\n";
		print  formatDate( $reservationEndDate ) . "\n";
		print  "Asset CRB Name: ".$assetCRBTitle . "\n";
		print  "Asset CRB IXA: ". $assetCRBID . "\n";
	
		# Now call upon the mailer sub routine passing the reservation's Name and User's name and email address.
		sendEndTomorrowEmail( $tempRes , \@reservationIPAddresses );
	}
}




#
# Send End Tomorrow Email
########################################################################################################

sub sendEndTomorrowEmail($@)
{
	use vars qw( $session $baseUrl );
	my $reservation = shift @_;
	my $ipAddresses = shift @_;

	# First we must get all variables needed. Get the entity of current reservation
	my $res_Entity = $session->GetEntity( "Reservation" , $reservation->reservationID );
	my $res_ID = $reservation->reservationID;
	my $res_Headline = $reservation->reservationHeadline;
	my $res_BeginDate = $reservation->BeginDate;
	my $res_EndDate = $reservation->EndDate;	
	my $user_Name = $reservation->User_name;
	my $user_Email = $reservation->User_email;
	my $asset_Name = $reservation->AssetName;
	my $asset_ID = $reservation->AssetID;
	my $ip_List = "";
	
	foreach my $ipAddress ( @$ipAddresses )
	{	
		$ip_List .= "<strong>" . $ipAddress . "</strong>, ";		
	}
	if ( $ip_List eq "" )
	{
		$ip_List = "<em>None currently associated with this reservation</em>";
	}
	else
	{
		$ip_List = substr $ip_List , 0 , length( $ip_List ) - 2; 		# Get rid of final comma
	}

	# Get reservation URL	
	my $res_URL = "";
	my $databaseSetName = $session->GetSessionDatabase()->GetDatabaseSetName();
	my $databaseName = $session->GetSessionDatabase()->GetDatabaseName();
	my $entityDefName = $res_Entity->GetEntityDefName();

	$res_URL = $baseUrl;
	$res_URL .= '?command=GenerateMainFrame&service=CQ';
	$res_URL .= "&schema=$databaseSetName&contextid=$databaseName";
	$res_URL .= "&entityDefName=$entityDefName&entityID=$res_ID";
	
	my $subject = " Reservation: " . $res_Headline . " will END Tomorrow!";
	
	$lmtemailer->loadTemplate( "/scripts/email/morningReservationEndTomorrow.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . $subject );
	$lmtemailer->setSendTo( $user_Email . "," . $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"res_Headline" , $res_Headline,
		"res_ID" , $res_ID,
		"asset_Name" , $asset_Name,
		"asset_ID" , $asset_ID,
		"res_BeginDate" , $res_BeginDate,
		"res_EndDate" , $res_EndDate,
		"user_Name" , $user_Name,
		"ip_List" , $ip_List,
		"res_URL" , $res_URL,
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
}





#
# Begin Next Week
########################################################################################################

sub handleBeginNextWeek(@)
{
	use vars qw( $session $baseUrl );
	my $reservations = shift @_;

	# Foreach reservation here we simply need to send an alert to the user. Nothing is done in the database

	foreach my $reservation ( @$reservations )
	{	
		my $res_Entity = $session->GetEntity( "Reservation" , $reservation );		
		my $reservationBeginDate = $res_Entity->GetFieldValue( "BeginDate" )->GetValue();
		my $reservationEndDate = $res_Entity->GetFieldValue( "EndDate" )->GetValue();
		my $reservationHeadline = $res_Entity->GetFieldValue( "Headline" )->GetValue();
		my $reservationCRB = $res_Entity->GetFieldValue( "CRBRef" )->GetValue();
		my $reservationAsset = $res_Entity->GetFieldValue( "AssetRef" )->GetValue();

		my $assetCRBTitle;
                my $assetCRBID;

		if( $reservationAsset ne "" )
		{
			my $asset_Entity = $session->GetEntity( "Asset" , $reservationAsset );
			$assetCRBTitle = $asset_Entity->GetFieldValue( "assetTitle" )->GetValue();
			$assetCRBID = $asset_Entity->GetFieldValue( "id" )->GetValue();
		}
		elsif( $reservationCRB ne "" )
		{
			my $crb_Entity = $session->GetEntity( "EE_DUT" , $reservationCRB );
			$assetCRBTitle = $crb_Entity->GetFieldValue( "Headline" )->GetValue();
			$assetCRBID = $crb_Entity->GetFieldValue( "id" )->GetValue();
		}

		my $res_User = $res_Entity->GetFieldValue( "User" )->GetValue();
		my $user_Entity = $session->GetEntity( "users" , $res_User );
		my $users_name = $user_Entity->GetFieldValue( "fullname" )->GetValue();
		my $users_email = $user_Entity->GetFieldValue( "email" )->GetValue();
		
		my $tempRes = Reservation->new( reservationID => $reservation,
			reservationHeadline => $reservationHeadline,
			User_name => $users_name,
			User_email => $users_email,
			BeginDate => formatDate( $reservationBeginDate ),
			EndDate => formatDate( $reservationEndDate ),
			AssetName => $assetCRBTitle,
			AssetID => $assetCRBID,
        );
		
		print "handleBeginNextWeek\n";
		print  $reservation . "\n";
		print  $reservationHeadline . "\n";
		print  $users_name . "\n";
		print  $users_email . "\n";
		print  formatDate( $reservationBeginDate ) . "\n";
		print  formatDate( $reservationEndDate ) . "\n";
		print  "Asset CRB Name: ".$assetCRBTitle . "\n";
		print  "Asset CRB IXA: ". $assetCRBID . "\n";
	
		# Now call upon the mailer sub routine passing the reservation's Name and User's name and email address.
		sendBeginNextWeekEmail( $tempRes );
	}
}




#
# Send Begin Next Week email
########################################################################################################

sub sendBeginNextWeekEmail($)
{
	use vars qw( $session $baseUrl );
	my $reservation = shift @_;
	my $res_Entity = $session->GetEntity( "Reservation" , $reservation->reservationID );
	my $res_ID = $reservation->reservationID;
	my $res_Headline = $reservation->reservationHeadline;
	my $res_BeginDate = $reservation->BeginDate;
	my $res_EndDate = $reservation->EndDate;	
	my $user_Name = $reservation->User_name;
	my $user_Email = $reservation->User_email;	
	my $asset_Name = $reservation->AssetName;
	my $asset_ID = $reservation->AssetID;
	my $ip_List = "";
	
	$ip_List = "<em>None as reservation is in future - Begins Tomorrow</em>";	

	# Get reservation URL	
	my $res_URL = "";
	my $databaseSetName = $session->GetSessionDatabase()->GetDatabaseSetName();
	my $databaseName = $session->GetSessionDatabase()->GetDatabaseName();
	my $entityDefName = $res_Entity->GetEntityDefName();

	$res_URL = $baseUrl;
	$res_URL .= '?command=GenerateMainFrame&service=CQ';
	$res_URL .= "&schema=$databaseSetName&contextid=$databaseName";
	$res_URL .= "&entityDefName=$entityDefName&entityID=$res_ID";

	my $subject = " Reservation: " . $res_Headline . " will BEGIN Tomorrow morning!";
	
	$lmtemailer->loadTemplate( "/scripts/email/morningReservationBeginNextWeek.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . $subject );
	$lmtemailer->setSendTo( $user_Email . "," . $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"res_Headline" , $res_Headline,
		"res_ID" , $res_ID,
		"asset_Name" , $asset_Name,
		"asset_ID" , $asset_ID,
		"res_BeginDate" , $res_BeginDate,
		"res_EndDate" , $res_EndDate,
		"user_Name" , $user_Name,
		"ip_List" , $ip_List,
		"res_URL" , $res_URL,
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
	
}





#
# End Next Week
########################################################################################################

sub handleEndNextWeek(@)
{
	use vars qw( $session $baseUrl );
	my $reservations = shift @_;

	# Foreach reservation here we simply need to send an alert to the user that the current reservation they have is about to end next week. 
	
	foreach my $reservation( @$reservations )
	{	
		my $res_Entity = $session->GetEntity( "Reservation" , $reservation );		
		my $reservationBeginDate = $res_Entity->GetFieldValue( "BeginDate" )->GetValue();
		my $reservationEndDate = $res_Entity->GetFieldValue( "EndDate" )->GetValue();
		my $reservationHeadline = $res_Entity->GetFieldValue( "Headline" )->GetValue();
		my $reservationAsset = $res_Entity->GetFieldValue( "AssetRef" )->GetValue();
		my $reservationCRB = $res_Entity->GetFieldValue( "CRBRef" )->GetValue();
		my $assetCRBTitle;
        my $assetCRBID;

		if( $reservationAsset ne "" )
		{
			my $asset_Entity = $session->GetEntity( "Asset" , $reservationAsset );
			$assetCRBTitle = $asset_Entity->GetFieldValue( "assetTitle" )->GetValue();
			$assetCRBID = $asset_Entity->GetFieldValue( "id" )->GetValue();
		}
		elsif( $reservationCRB ne "" )
		{
			my $crb_Entity = $session->GetEntity( "EE_DUT" , $reservationCRB );
			$assetCRBTitle = $crb_Entity->GetFieldValue( "Headline" )->GetValue();
			$assetCRBID = $crb_Entity->GetFieldValue( "id" )->GetValue();
		}

		my $reservationIPs = $res_Entity->GetFieldValue( "IPRef" )->GetValueAsList();
		my @reservationIPAddresses;

		foreach my $ip ( @$reservationIPs )
		{			
			# Now for each of these IPs that are currently (well should be!) in the Used State - we must free them
			my $ip_Entity = $session->GetEntity( "IPAddress" , $ip );
			my $ipAddr = $ip_Entity->GetFieldValue( "IPAddress" )->GetValue();			
			push( @reservationIPAddresses , $ipAddr );		
		}
			
		my $res_User = $res_Entity->GetFieldValue( "User" )->GetValue();
		my $user_Entity = $session->GetEntity( "users" , $res_User );
		my $users_name = $user_Entity->GetFieldValue( "fullname" )->GetValue();
		my $users_email = $user_Entity->GetFieldValue( "email" )->GetValue();
		
		my $tempRes = Reservation->new( reservationID => $reservation,
			reservationHeadline => $reservationHeadline,
			User_name => $users_name,
			User_email => $users_email,
			BeginDate => formatDate( $reservationBeginDate ),
			EndDate => formatDate( $reservationEndDate ),
			AssetName => $assetCRBTitle,
			AssetID => $assetCRBID,
        );
		
		print "handleEndNextWeek\n";
		print  $reservation . "\n";
		print  $reservationHeadline . "\n";
		print  $users_name . "\n";
		print  $users_email . "\n";
		print  formatDate( $reservationBeginDate ) . "\n";
		print  formatDate( $reservationEndDate ) . "\n";
		print  "Asset CRB Name: ".$assetCRBTitle . "\n";
		print  "Asset CRB IXA: ". $assetCRBID . "\n";
	
		# Now call upon the mailer sub routine passing the reservation's Name and User's name and email address.
		sendEndNextWeekEmail( $tempRes , \@reservationIPAddresses );
	}
}



#
# Send End Next Week
########################################################################################################

sub sendEndNextWeekEmail($@)
{
	use vars qw( $session $baseUrl );
	my $reservation = shift @_;
	my $ipAddresses = shift @_;

	# First we must get all variables needed. Get the entity of current reservation
	my $res_Entity = $session->GetEntity( "Reservation" , $reservation->reservationID );
	my $res_ID = $reservation->reservationID;
	my $res_Headline = $reservation->reservationHeadline;
	my $res_BeginDate = $reservation->BeginDate;
	my $res_EndDate = $reservation->EndDate;	
	my $user_Name = $reservation->User_name;
	my $user_Email = $reservation->User_email;
	my $asset_Name = $reservation->AssetName;
	my $asset_ID = $reservation->AssetID;
	my $ip_List = "";
	
	foreach my $ipAddress ( @$ipAddresses )
	{	
		$ip_List .= "<strong>" . $ipAddress . "</strong>, ";		
	}
	if ( $ip_List eq "" )
	{
		$ip_List = "<em>None currently associated with this reservation</em>";
	}
	else
	{
		$ip_List = substr $ip_List , 0 , length( $ip_List ) - 2; 		# Get rid of final comma
	}

	# Get reservation URL	
	my $res_URL = "";
	my $databaseSetName = $session->GetSessionDatabase()->GetDatabaseSetName();
	my $databaseName = $session->GetSessionDatabase()->GetDatabaseName();
	my $entityDefName = $res_Entity->GetEntityDefName();

	$res_URL = $baseUrl;
	$res_URL .= '?command=GenerateMainFrame&service=CQ';
	$res_URL .= "&schema=$databaseSetName&contextid=$databaseName";
	$res_URL .= "&entityDefName=$entityDefName&entityID=$res_ID";

	my $subject = " Reservation: " . $res_Headline . " en, first notification!";
	
	$lmtemailer->loadTemplate( "/scripts/email/morningReservationEndNextWeek.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . $subject );
	$lmtemailer->setSendTo( $user_Email . "," . $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"res_Headline" , $res_Headline,
		"res_ID" , $res_ID,
		"asset_Name" , $asset_Name,
		"asset_ID" , $asset_ID,
		"res_BeginDate" , $res_BeginDate,
		"res_EndDate" , $res_EndDate,
		"user_Name" , $user_Name,
		"ip_List" , $ip_List,
		"res_URL" , $res_URL,
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
}




#
# Return date in correct format
########################################################################################################

sub formatDate($)
{
	my $dbFormat = shift @_;
	my @split1 = split ' ' , $dbFormat;
	my @split2 = split '-' , $split1[ 0 ];

	my $day = $split2[ 2 ];
	my $month = $split2[ 1 ];
	my $year = $split2[ 0 ];

	return " " . $day . "-" . $month . "-" . $year . " ";
}




