#########################################################################
#########################################################################
### 
### LMT DHCP Configuration
### Synchronization Script
###
### Re Written by david.m.oneill@intel.com ( dave@feeditout.com )
### Escalations and support
### Gerard Laffan 
### Stephen Bergin
###
#########################################################################
#########################################################################



###
### Includes
#########################################################################

use lib "/scripts";

use CQPerlExt; # ClearQuest Perl
use Socket; # socket for sql connection
use Sys::Hostname; # system
use POSIX qw(SIGALRM); # die?
use Net::SMTP; # sendmail
use English;
use LMTCommon;


###
### Ini Reader
#########################################################################
my $lmtcommon = new LMTCommon;



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



###
### Pull all assets
#########################################################################

open ( MYFILE , '>/scripts/log/LMTall.txt' );	

##
## ALL CRBS
##

my $query = $session->BuildQuery( "EE_DUT" );
$query->BuildField( "id" );
$query->BuildField( "CRB_Location" );
$query->BuildField( "MACAddress1" );
$query->BuildField( "State" );
$query->BuildField( "staticip.IPAddress" );
$query->BuildField( "CurrentUser.email" );

# execute the query
my $resultSet = $session->BuildResultSet( $query );
$resultSet->Execute();

# The results set comes back as link list datastructure
# MoveNext() move to the head of the next
my $status = $resultSet->MoveNext();

# MoveNext returns 1 (true) when there is another one in the list
while ( $status == 1 )
{
	# GetColumnValue( int ) is directly related to the query above
	my $id = $resultSet->GetColumnValue( 1 );
	my $location = $resultSet->GetColumnValue( 2 );
	my $mac1 = $resultSet->GetColumnValue( 3 );
	my $state = $resultSet->GetColumnValue( 4 );
	my $ip = $resultSet->GetColumnValue( 5 );
	my $email = $resultSet->GetColumnValue( 6 );	
	
	print MYFILE "crb|$id|$ip|$mac1|$location|$state|$email\n";
	
	# Move to the next node in the linked list
	$status = $resultSet->MoveNext();
}	




##
## ALL ASSETS
##

my $query = $session->BuildQuery( "ASSET" );
$query->BuildField( "id" );
$query->BuildField( "Location" );
$query->BuildField( "State" );
$query->BuildField( "MACAddress1" );
$query->BuildField( "ipAddress.IPAddress" );


# execute the query
my $resultSet = $session->BuildResultSet( $query );
$resultSet->Execute();

# The results set comes back as link list datastructure
# MoveNext() move to the head of the next
my $status = $resultSet->MoveNext();

# MoveNext returns 1 (true) when there is another one in the list
while ( $status == 1 )
{
	# GetColumnValue( int ) is directly related to the query above
	my $id = $resultSet->GetColumnValue( 1 );
	my $location = $resultSet->GetColumnValue( 2 );
	my $state = $resultSet->GetColumnValue( 3 );
	my $mac = $resultSet->GetColumnValue( 4 );
	my $ip = $resultSet->GetColumnValue( 5 );
		
	print MYFILE "asset|$id|$ip|$mac|$location|$state\n";
	
	# Move to the next node in the linked list
	$status = $resultSet->MoveNext();
}	

close MYFILE;