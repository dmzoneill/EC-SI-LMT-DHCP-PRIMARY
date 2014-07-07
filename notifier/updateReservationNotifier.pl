
#########################################################################
#########################################################################

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
use Time::Local;
use Date::Parse;
use LMTCommon;
use LMTEmailer;




###
### Ini Reader
#########################################################################
my $lmtcommon = new LMTCommon;
my $lmtemailer = new LMTEmailer;




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




sub in_array 
{     
	my ( $arr,$search_for ) = @_;     
	my %items = map { $_ => 1 } @$arr; # create a hash out of the array values     
	return ( exists( $items{ $search_for } ) ) ? 1 : 0; 
}




#
# Asset Reservations
########################################################################################################

my $submittedQuery = $session->BuildQuery( "Reservation" );

# reservation details
$submittedQuery->BuildField( "ID" );
$submittedQuery->BuildField( "Headline" );
$submittedQuery->BuildField( "State" );
$submittedQuery->BuildField( "BeginDate" );
$submittedQuery->BuildField( "EndDate" );
$submittedQuery->BuildField( "Project" );

# associated asset
$submittedQuery->BuildField( "AssetRef.id" );
$submittedQuery->BuildField( "AssetRef.AssetTitle" );

# associated user
$submittedQuery->BuildField( "history.action_timestamp" );
$submittedQuery->BuildField( "User.fullname" );
$submittedQuery->BuildField( "User.email" );

# history timestamp
$submittedQuery->BuildField( "history.action_timestamp" );

# associated ip
$submittedQuery->BuildField( "IPRef.IPAddress" );
#$submittedQuery->BuildField( "IPRef.id" );

# 01 July 2008 11:03:42
my ( $sec , $min , $hour , $mday , $mon , $year , $wday , $yday , $isdst ) = localtime time;

my $resultSet = $session->BuildResultSet( $submittedQuery );
$resultSet->Execute();
my $status = $resultSet->MoveNext();

my @notifiedAssets = ();

while ( $status == 1 )
{
	my $resID = $resultSet->GetColumnValue( 1 );
	my $resHeadline = $resultSet->GetColumnValue( 2 );
	my $resState = $resultSet->GetColumnValue( 3 );
	my $resBegin = $resultSet->GetColumnValue( 4 );
	my $resEnd = $resultSet->GetColumnValue( 5 );
	my $resProject = $resultSet->GetColumnValue( 6 );	
	my $assetID = $resultSet->GetColumnValue( 7 );
	my $assetHeadline = $resultSet->GetColumnValue( 8 );		
	my $resTimeStamp = $resultSet->GetColumnValue( 9 );
	my $resFullname = $resultSet->GetColumnValue( 10 );
	my $resEmail = $resultSet->GetColumnValue( 11 );	
	my $lastmodified = $resultSet->GetColumnValue( 12 );
	my $resIP = $resultSet->GetColumnValue( 13 );	
	

	my $start = ( int( $year ) + 1900 ) . "-" . (int( $mon ) + 1) ."-" . $mday  . " $hour:$min:$sec";
	my ( $years , $months , $days , $hours , $mins , $secs ) = split /\W+/, $lastmodified;
	my $stop = $years . "-" . $months . "-" . $days . " " . $hours . ":" . $mins . ":" . $secs;
	my $diff  = str2time( $start ) - str2time( $stop );
		
	
	if( $diff < 360 && $diff > -60 ) # negative 60 for time diffs between servers
	{	
		print "Asset reservation\n";
		printf "It was modified %d seconds ago\n", $diff;
		
		print "Reservation id : $resID\n";
		print "Reservation Headline : $resHeadline\n";
		print "Reservation State : $resState\n";
		print "Reservation Begin : $resBegin\n";
		print "Reservation End : $resEnd\n";
		print "Reservation Project : $resProject\n";
		print "Asset id : $assetID\n";
		print "Asset Headline : $assetHeadline\n";
		print "Asset IP : $resIP\n";
		print "Reservation timestamp : $resTimeStamp\n";
		print "Reservation Fullname : $resFullname\n";
		print "Reservation Email : $resEmail\n";
		
		if( $assetID ne "" )
		{
			sendReservationEmail( $resID , $resHeadline , $resState , $resBegin , $resEnd , $resProject , $assetID , $assetHeadline , $resIP ,  $resTimeStamp , $resFullname , $resEmail , "Asset" );
		}
		
		push( @notifiedAssets , '$assetID' );
	}
		
	$status = $resultSet->MoveNext();
}







#
# CRB ip reservation
########################################################################################################

my $submittedQuery = $session->BuildQuery( "Reservation" );

# reservation details
$submittedQuery->BuildField( "ID" );
$submittedQuery->BuildField( "Headline" );
$submittedQuery->BuildField( "State" );
$submittedQuery->BuildField( "BeginDate" );
$submittedQuery->BuildField( "EndDate" );
$submittedQuery->BuildField( "Project" );

# associated asset
$submittedQuery->BuildField( "CRBRef.id" );
$submittedQuery->BuildField( "CRBRef.Headline" );

# associated user
$submittedQuery->BuildField( "history.action_timestamp" );
$submittedQuery->BuildField( "User.fullname" );
$submittedQuery->BuildField( "User.email" );

# history timestamp
$submittedQuery->BuildField( "history.action_timestamp" );

# associated ip
$submittedQuery->BuildField( "IPRef.IPAddress" );
#$submittedQuery->BuildField( "IPRef.id" );

# 01 July 2008 11:03:42
my ( $sec , $min , $hour , $mday , $mon , $year , $wday , $yday , $isdst ) = localtime time;

my $resultSet = $session->BuildResultSet( $submittedQuery );
$resultSet->Execute();
my $status = $resultSet->MoveNext();

my @notifiedips = ();

while ( $status == 1 )
{
	my $resID = $resultSet->GetColumnValue( 1 );
	my $resHeadline = $resultSet->GetColumnValue( 2 );
	my $resState = $resultSet->GetColumnValue( 3 );
	my $resBegin = $resultSet->GetColumnValue( 4 );
	my $resEnd = $resultSet->GetColumnValue( 5 );
	my $resProject = $resultSet->GetColumnValue( 6 );	
	my $assetID = $resultSet->GetColumnValue( 7 );
	my $assetHeadline = $resultSet->GetColumnValue( 8 );		
	my $resTimeStamp = $resultSet->GetColumnValue( 9 );
	my $resFullname = $resultSet->GetColumnValue( 10 );
	my $resEmail = $resultSet->GetColumnValue( 11 );	
	my $lastmodified = $resultSet->GetColumnValue( 12 );
	my $resIP = $resultSet->GetColumnValue( 13 );	
	

	my $start = ( int( $year ) + 1900 ) . "-" . (int( $mon ) + 1) ."-" . $mday  . " $hour:$min:$sec";
	my ( $years , $months , $days , $hours , $mins , $secs ) = split /\W+/, $lastmodified;
	my $stop = $years . "-" . $months . "-" . $days . " " . $hours . ":" . $mins . ":" . $secs;
	my $diff  = str2time( $start ) - str2time( $stop );
		
	
	if( $diff < 360 && $diff > -60 ) # negative 60 for time diffs between servers
	{	
		print "Asset reservation\n";
		printf "It was modified %d seconds ago\n", $diff;
		
		print "Reservation id : $resID\n";
		print "Reservation Headline : $resHeadline\n";
		print "Reservation State : $resState\n";
		print "Reservation Begin : $resBegin\n";
		print "Reservation End : $resEnd\n";
		print "Reservation Project : $resProject\n";
		print "Asset id : $assetID\n";
		print "Asset Headline : $assetHeadline\n";
		print "Asset IP : $resIP\n";
		print "Reservation timestamp : $resTimeStamp\n";
		print "Reservation Fullname : $resFullname\n";
		print "Reservation Email : $resEmail\n";
		
		if( $assetID ne "" )
		{
			sendReservationEmail( $resID , $resHeadline , $resState , $resBegin , $resEnd , $resProject , $assetID , $assetHeadline , $resIP ,  $resTimeStamp , $resFullname , $resEmail , "CRB" );
		}
		
		push( @notifiedips , '$assetID' );
	}
		
	$status = $resultSet->MoveNext();
}






sub sendReservationEmail
{
	my $resID = shift;
	my $resHeadline = shift;
	my $resState = shift;
	my $resBegin = shift;
	my $resEnd = shift;
	my $resProject = shift;
	my $ID = shift;
	my $Headline = shift;
	my $IP = shift;
	my $resTimeStamp = shift;
	my $resFullname = shift;
	my $resEmail = shift;
	my $type = shift;
	
	if( $IP ne "" )
	{	
		$ip_List = "<strong>" . $IP . "</strong>";		
	}
	else
	{
		$ip_List = "<em>No IP Addresses Associated with this Reservation</em>";
	}

	my $subject = " Reservation " . $res_Headline . " Has Been Submitted / Modified!";

	$lmtemailer->loadTemplate( "/scripts/email/updateReservationNotifier.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . $subject );
	$lmtemailer->setSendTo( $resEmail . "," . $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"RESFULLNAME" , $resFullname,
		"TYPE" , $type,
		"ASSETHEADLINE" , $assetHeadline,
		"IDNO" , $ID,
		"HEADLINE" , $Headline,
		"IPLIST" , $ip_List,
		"RESHEADLINE" , $resHeadline,
		"RESID" , $resID,
		"RESBEGIN" , $resBegin,
		"RESEND" , $resEnd,
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
