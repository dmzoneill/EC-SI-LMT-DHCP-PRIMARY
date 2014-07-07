###
### Includes
#########################################################################

use lib "/scripts";

use CQPerlExt;
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



my @vlan1 = ( "10.237.212." , 212 );
my @vlan2 = ( "10.237.213." , 213  );
my @vlan3 = ( "10.237.214." , 214 );
my @vlan4 = ( "10.243.18." , 18 );
my @vlans = ( \@vlan1 , \@vlan2 , \@vlan3 , \@vlan4 );

my $ipfreedata = "";

foreach my $vlan ( @vlans )
{
	my @statefilter = ( "Free" );
	my @ipfilter = ( $vlan->[ 0 ] );

	# Create A Query that Gets all Reservations that Start/End Today and Tomorrow
	my $reservationQuery = $session->BuildQuery( "IPAddress" );
	$reservationQuery->BuildField( "id" );
	$reservationQuery->BuildField( "IPAddress" );

	my $query_CompleteFilter = $reservationQuery->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$query_CompleteFilter->BuildFilter( "State" , $CQPerlExt::CQ_COMP_OP_EQ , \@statefilter );
	$query_CompleteFilter->BuildFilter( "IPAddress" , $CQPerlExt::CQ_COMP_OP_LIKE , \@ipfilter );

	my $resultSet = $session->BuildResultSet( $reservationQuery );
	$resultSet->Execute();


	# You can use this one line:
	$rows = $resultSet->ExecuteAndCountRecords(); 

	$ipfreedata .= $vlan->[ 1 ] . "," .$rows . "|"; 
}

$ipfreedata = `echo '$ipfreedata' > /var/www/html/logs/freeips.txt`;
