#########################################################################
#########################################################################
### 
### LMT DHCP Configuration
###
### Looks for problem records with back refereneces affecting nightly script
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
use File::stat;
use strict;
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


findRecords();




###
#########################################################################

sub findRecords
{
	my $backReferenceRecords = $session->BuildQuery( "Reservation" );
	$backReferenceRecords->BuildField( "id" );
	$backReferenceRecords->BuildField( "Headline" );
	$backReferenceRecords->BuildField( "User.fullname" );
	$backReferenceRecords->BuildField( "User.email" );

	my @activeFilter1 = ( "" );
	my $query_ActiveFilter1 = $backReferenceRecords->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$query_ActiveFilter1->BuildFilter( "IPRef" , $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL , \@activeFilter1 );	
	
	my @activeFilter2 = ( "" );
	my $query_ActiveFilter2 = $backReferenceRecords->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$query_ActiveFilter2->BuildFilter( "IPRef.StaticCRB" , $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL , \@activeFilter2 );	
	
	# execute the query
	my $resultSet = $session->BuildResultSet( $backReferenceRecords );
	$resultSet->Execute();
	
	# The results set comes back as link list datastructure
	# MoveNext() move to the head of the next
	my $status = $resultSet->MoveNext();

	# MoveNext returns 1 (true) when there is another one in the list
	while ( $status == 1 )
	{
		my $id = $resultSet->GetColumnValue( 1 );
		my $headline = $resultSet->GetColumnValue( 2 );
		my $user = $resultSet->GetColumnValue( 3 );
		my $useremail = $resultSet->GetColumnValue( 4 );
		
		reportProblemEmailer( $id , $headline , $user , $useremail );
				
		# Move to the next node in the linked list
		$status = $resultSet->MoveNext();
	}		
		
}




###
### Used to send email if dhcp configuration changes
#########################################################################

sub reportProblemEmailer
{
	my $id = shift;
	my $headline = shift;
	my $user = shift;
	my $useremail = shift;

	
	$lmtemailer->setHeader( "/scripts/email/error_header.html" );
	$lmtemailer->loadTemplate( "/scripts/email/error.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . " URGENT PROBLEMATIC RECORD" );
	$lmtemailer->setSendTo( "david.rogers\@intel.com," . $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"ID" , $id,		
		"HEADLINE" , $headline,		
		"USER" , $user,		
		"USEREMAIL" , $useremail,		
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
}



