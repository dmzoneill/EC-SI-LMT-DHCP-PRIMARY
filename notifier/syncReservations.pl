#########################################################################
#########################################################################
# This sub routine Syncs Active Reservations and Associated Assets
# Get all Reservations that are Active and ensure their corresponding assets are in the Reserved State




###
### Includes
#########################################################################

use lib "/scripts";

use CQPerlExt;
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






syncReservations();



sub syncReservations
{
	my $reservationQuery = $session->BuildQuery("Reservation");

	$reservationQuery->BuildField("ID");
	$reservationQuery->BuildField("AssetRef");

	my @activeFilter = ('Active');

	my $query_ActiveFilter = $reservationQuery->BuildFilterOperator($CQPerlExt::CQ_BOOL_OP_AND);
	$query_ActiveFilter->BuildFilter("state", $CQPerlExt::CQ_COMP_OP_EQ,\@activeFilter);
	$query_ActiveFilter->BuildFilter( "AssetRef" , $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL , [""] );

	my $resultSet = $session->BuildResultSet($reservationQuery);

	$resultSet->Execute();

	my $status = $resultSet->MoveNext();

	while ($status == 1)
	{
		my $assetEntity = $session->GetEntity("Asset",$resultSet->GetColumnValue(2));
	
		if ($assetEntity->GetFieldValue("State")->GetValue() ne "Reserved")
		{
			# uh oh, the user didn't click save on asset after creating the reservation
			printf("Asset: %s is not in reserved state when it should be\n",$assetEntity->GetFieldValue("id")->GetValue());

			$session->EditEntity($assetEntity,"Reserved");

			if ($assetEntity->Validate() eq "")
			{
				$assetEntity->Commit();
			}
			else
			{
				$assetEntity->Revert();
			}
		}

		$status = $resultSet->MoveNext();
	}


	# Now sometimes reservations finish but the Asset stays in reserved state
	my $assetQuery = $session->BuildQuery("Asset");

	$assetQuery->BuildField("id");
	$assetQuery->BuildField("reservations");

	my @reservedFilter = ('Reserved');
	my @reservationsFilter = ('');

	my $query_ReservedFilter = $assetQuery->BuildFilterOperator($CQPerlExt::CQ_BOOL_OP_AND);

	$query_ReservedFilter->BuildFilter("state", $CQPerlExt::CQ_COMP_OP_EQ,\@reservedFilter);
	# $query_ReservedFilter->BuildFilter("reservations", $CQPerlExt::CQ_COMP_OP_EQ,\@reservationsFilter);

	my $resultSet = $session->BuildResultSet($assetQuery);

	$resultSet->Execute();

	my $status = $resultSet->MoveNext();

	while ($status == 1)
	{
		if ($resultSet->GetColumnValue(2) eq "")
		{

			my $assetEntity = $session->GetEntity("Asset",$resultSet->GetColumnValue(1));
	
			$session->EditEntity($assetEntity,"Available");

			if ($assetEntity->Validate() eq "")
			{
				$assetEntity->Commit();
			}
			else
			{
				$assetEntity->Revert();
			}
				
		}
		
		$status = $resultSet->MoveNext();
	}

}
