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
my $baseURL = $lmtcommon->get( 'common' , 'cqbaseurl' );




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

my @endToday;


# Create A Query that Gets all Reservations that Start/End Today and Tomorrow
my $reservationQuery = $session->BuildQuery( "Reservation" );
$reservationQuery->BuildField( "ID" );
$reservationQuery->BuildField( "BeginDate" );
$reservationQuery->BuildField( "EndDate" );


# Now we must build a filter to get Today and Tomorrows Date
my ( $sec , $min , $hour , $mday , $mon , $year , $wday , $yday , $isdst ) = localtime time;
my $today = int( $mon + 1 ) . "/" . $mday . "/" . int( 1900 + $year );
my @dateFilter = ( $today );
my @completeFilter = ( "Complete" );


my $query_CompleteFilter = $reservationQuery->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
$query_CompleteFilter->BuildFilter( "state" , $CQPerlExt::CQ_COMP_OP_NOT_IN , \@completeFilter );
$query_CompleteFilter->BuildFilter( "EndDate" , $CQPerlExt::CQ_COMP_OP_LTE , \@dateFilter );


# Get today and tomorrow in Unix Time as we will need them for comparison reasons below
my $todayUnixTime = mktime( '0' , '0' , '0' , $mday , $mon , $year );
my $resultSet = $session->BuildResultSet( $reservationQuery );
$resultSet->Execute();
my $status = $resultSet->MoveNext();


while ( $status == 1 )
{
	#Now these are all the reservations that END Today
	push( @endToday , $resultSet->GetColumnValue( 1 ) );
	$status = $resultSet->MoveNext();
}


my $numEndToday = @endToday;
printf( "%d items in the EndToday Queue\n\n" , $numEndToday );


if ( @endToday > 0 )
{	
	handleEndToday(\@endToday);
}


# Now we must update the submitted field for all new IPs
my $queryIPDef = $session->BuildQuery( "IPAddress" );
my @submitFilter = ( "true" );
$queryIPDef->BuildField( "id" );
my $query_Filter = $queryIPDef->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
$query_Filter->BuildFilter( "isSubmit" , $CQPerlExt::CQ_COMP_OP_NOT_IN , \@submitFilter );


my $resultIPSet = $session->BuildResultSet( $queryIPDef );
$resultIPSet->Execute();


my $ip_Status = $resultIPSet->MoveNext();

while ( $ip_Status == 1 )
{
	my $entity_IP = $session->GetEntity( "IPAddress" , $resultIPSet->GetColumnValue( 1 ) );
	$session->EditEntity( $entity_IP , "Modify" );
	$entity_IP->SetFieldValue( "isSubmit" , "true" );
	
	my $ip_EditStatus = $entity_IP->Validate();

	if ( $ip_EditStatus eq "" )
	{
		$entity_IP->Commit();
	}
	else
	{
		$entity_IP->Revert();
	}
	$ip_Status = $resultIPSet->MoveNext();
}


syncReservations();		# Make sure that all active reservations's assets are in the 'Reserved' State


sub syncReservations
{
	my $reservationQuery = $session->BuildQuery( "Reservation" );
	$reservationQuery->BuildField( "ID" );
	$reservationQuery->BuildField( "AssetRef" );

	my @activeFilter = ( 'Active' );
	my $query_ActiveFilter = $reservationQuery->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$query_ActiveFilter->BuildFilter( "state" , $CQPerlExt::CQ_COMP_OP_EQ , \@activeFilter );
	$query_ActiveFilter->BuildFilter( "AssetRef" , $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL , [""] );

	$resultSet->Execute();
	my $status = $resultSet->MoveNext();

	while ( $status == 1 )
	{
		if( $resultSet->GetColumnValue( 2 ) ne "" )
		{	
			my $assetEntity = $session->GetEntity( "Asset" , $resultSet->GetColumnValue( 2 ) );
		
			if ( $assetEntity->GetFieldValue( "State" )->GetValue() ne "Reserved" )
			{
				# uh oh, the user didn't click save on asset after creating the reservation
				printf( "Asset: %s is not in reserved state when it should be\n" , $assetEntity->GetFieldValue( "id" )->GetValue() );

				$session->EditEntity( $assetEntity , "Reserved" );

				if ( $assetEntity->Validate() eq "" )
				{
					$assetEntity->Commit();
				}
				else
				{
					$assetEntity->Revert();
				}
			}
		}
		
		$status = $resultSet->MoveNext();
		
	}
}


sub handleEndToday(@)
{
	my $reservations = shift @_;

	# Now we must loop through each of these reservations. 
	# For each reservation we must send a notification email to users stateing they should return equipment
	# We must also set all IPs to the Used State and include details of this in email
	# We must then delete the reservation

	foreach my $reservation ( @$reservations )
	{			
		
		my $res_Entity = $session->GetEntity( "Reservation",$reservation);		
		my $reservationBeginDate = $res_Entity->GetFieldValue( "BeginDate" )->GetValue();
		my $reservationEndDate = $res_Entity->GetFieldValue( "EndDate" )->GetValue();
		my $reservationHeadline = $res_Entity->GetFieldValue( "Headline" )->GetValue();
		my $reservationAsset = $res_Entity->GetFieldValue( "AssetRef" )->GetValue();
		my $reservationCRB = $res_Entity->GetFieldValue( "CRBRef" )->GetValue();
		my $reservationIPs = $res_Entity->GetFieldValue( "IPRef" )->GetValueAsList();
		
		my @reservationIPAddresses;
		
		foreach my $ip ( @$reservationIPs )
		{			
			# Catch IP addresses
			my $ip_Entity = $session->GetEntity( "IPAddress" , $ip );
			my $ipAddr = $ip_Entity->GetFieldValue( "IPAddress" )->GetValue();
			push( @reservationIPAddresses , $ipAddr );	
		}
		
		my $assetCRBTitle;
	        my $assetCRBID;
	
		if( $reservationAsset ne "" )
		{
			my $asset_Entity = $session->GetEntity( "Asset" , $reservationAsset );
			$assetCRBTitle = $asset_Entity->GetFieldValue( "assetTitle" )->GetValue();
			$assetCRBID = $asset_Entity->GetFieldValue( "id" )->GetValue();			
		}
		elsif ( $reservationCRB ne "" )
		{			
			my $crb_Entity = $session->GetEntity( "EE_DUT" , $reservationCRB );
			$assetCRBTitle = $crb_Entity->GetFieldValue( "Headline" )->GetValue();
			$assetCRBID = $crb_Entity->GetFieldValue( "id" )->GetValue();
		}		
			
		# Next get user details so that we can send an email
		my $res_User = $res_Entity->GetFieldValue( "User" )->GetValue();
		my $user_Entity = $session->GetEntity( "users" , $res_User );
		my $users_name = $user_Entity->GetFieldValue( "fullname" )->GetValue();
		my $users_email = $user_Entity->GetFieldValue( "email" )->GetValue();
		
		# Note that there is a Complete Action hook that frees any IPs that are associated with the reservation.		
		# Now call upon the mailer sub routine passing the reservation's Name and User's name and email address.

		my $tempRes = Reservation->new(reservationID => $reservation,
			reservationHeadline => $reservationHeadline,
			User_name => $users_name,
			User_email => $users_email,
			BeginDate => formatDate( $reservationBeginDate ),
			EndDate => formatDate( $reservationEndDate ),
			AssetName => $assetCRBTitle,
			AssetID => $assetCRBID,
        );
		
		print "$assetCRBID\n";		
		
		my $ttt = $res_Entity->EditEntity( "Complete" );		
		my $res_Status = $res_Entity->Validate();
				
		if( $res_Status eq "" )
		{
			my $status = $res_Entity->Commit();				
		}
		else
		{
			$res_Entity->Revert();
		}
						
		#sendEndTodayEmail( $tempRes , \@reservationIPAddresses );
	}
}



sub sendEndTodayEmail($@)
{
	use vars qw( $baseURL $mailHost );
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
		$ip_List .= "<br />It is essential that you  <strong>STOP</strong> using these IP addresses now!";
	}

	# Get reservation URL	
	my $res_URL = "";
	my $databaseSetName = $session->GetSessionDatabase()->GetDatabaseSetName();
	my $databaseName = $session->GetSessionDatabase()->GetDatabaseName();
	my $entityDefName = $res_Entity->GetEntityDefName();

	$res_URL = $baseURL;
	$res_URL .= '?command=GenerateMainFrame&service=CQ';
	$res_URL .= "&schema=$databaseSetName&contextid=$databaseName";
	$res_URL .= "&entityDefName=$entityDefName&entityID=$res_ID";

	my $subject = " Reservation: " . $res_Headline . " has ENDED NOW!";
		
	$lmtemailer->loadTemplate( "/scripts/email/nightReservationEndToday.html" );
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


sub formatDate($)
{
	my $dbFormat = shift @_;
	my @split1 = split ' ', $dbFormat;
	my @split2 = split '-', $split1[ 0 ];
	my $day = $split2[ 2 ];
	my $month = $split2[ 1 ];
	my $year = $split2[ 0 ];
	return " " . $day . "-" . $month . "-" . $year . " ";
}

