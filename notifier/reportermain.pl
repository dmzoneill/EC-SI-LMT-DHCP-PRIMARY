#########################################################################
#########################################################################
### 
### LMT Nightly Scanner and reporter
### This is used to increment inactive days and change states depending on conditions
###
### Re Written by liam.ryan@intel.com , david.m.oneill@intel.com ( dave@feeditout.com )
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

use CQPerlExt;
use Time::Local;
use Switch;
use POSIX;
use Class::Struct;
use Net::SMTP;
use Date::Parse;
use Class::Struct;
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





struct InactiveIP =>
{
    ip  => '$' ,
    daysnotactive => '$' ,
    state => '$' ,
    hostname => '$' ,
};

struct StaticIP =>
{
    ip => '$' ,
    hostname => '$' ,
};

struct UsedIP =>
{
    ip => '$' ,
    hostname => '$' ,
};



my @newStolen;
my @freeState;
my @stolenState;
my @usedState;
my @dhcpState;
my @staticState;


my @room1 = ( '10.243.18.0/24' , 'SIE1 - SW Lab' );
my @room2 = ( '10.237.213.0/24' , 'SIE1 - SW Servers' );
my @room3 = ( '10.237.212.0/24' , 'SIE1 - SW Rack Room' );
my @room4 = ( '10.237.214.0/24' , 'SIE1 - SW Rack Room2' );
my @rooms = ( \@room1 , \@room2 , \@room3 , \@room4 );



# loop through each room, syncing db information into defined boards file
foreach my $room ( @rooms )
{    
    # Start iterating through each IP address in the IPAddress record
    # Depending on the state it is in, perform the relevent actions.
    my $querydef = $session->BuildQuery( "IPAddress" );
    $querydef->BuildField( "id" );
    $querydef->BuildField( "IPAddress" );
    
    my @activeFilter = ( $room->[ 0 ] );
    my $query_ActiveFilter = $querydef->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
    $query_ActiveFilter->BuildFilter( "Subnet" , $CQPerlExt::CQ_COMP_OP_EQ , \@activeFilter );
    
    my $resultSet = $session->BuildResultSet( $querydef );
    $resultSet->Execute();
    
    
    my $status;
    
    $status = $resultSet->MoveNext();
    
    while( $status == 1 )
    {
        # Keep looping through all IP addresses. Get the state and the relevent action is chosen with the switch statement
        
        my $Entity_IP = $session->GetEntity( "IPaddress" ,$resultSet->GetColumnValue( 1 ) );
        my $IPState = $Entity_IP->GetFieldStringValue( "state" );
        
        printf( "\nWorking on %s", $resultSet->GetColumnValue( 2 ) );
        
        switch( $IPState )
        {        
            case "Free"
            {
                handleFreeIP( $resultSet->GetColumnValue( 1 ) );
            }
            case "Static"
            {
                handleStaticIP( $resultSet->GetColumnValue( 1 ) );
            }
            case "Used"
            {
                handleUsedIP( $resultSet->GetColumnValue( 1 ) );
            }
            case "DHCP"
            {
                push( @dhcpState , $resultSet->GetColumnValue( 2 ) );
            }
            case "Stolen"
            {
                push( @stolenState , $resultSet->GetColumnValue( 2 ) ); 
            }        
        }       
        
        $status = $resultSet->MoveNext();
    }
        
    my $dayofweek = scalar substr( ( localtime() ) , 0 , 3 ); 
        
    sendReport( $room->[ 1 ] , $room->[ 0 ] );   

	@newStolen = ();
	@freeState = ();
	@stolenState = ();
	@usedState = ();
	@dhcpState = ();
	@staticState = ();

	
}



###
### Logic for dealing with a record marked as free. 
### In this sub routine we must check if the equipment is reachable by pinging it. 
### If so it is marked as stolen, if not it is marked as free
###
### @param $ipID, id of record entry in IPTable in CQ
#########################################################################

sub handleFreeIP
{
	use vars qw( @staticState @dhcpState @usedState @stolenState @freeState @newStolen );
    my $ipID = shift;																									
    chomp( $ipID );																										
    my $Entity_FreeIP = $session->GetEntity( "IPAddress" , $ipID );														
    my $DaysNotActive = $Entity_FreeIP->GetFieldStringValue( "DaysNotActive" );											
    my $StaticAsset = $Entity_FreeIP->GetFieldStringValue( "StaticAsset" );												
    my $NodeDetails = $Entity_FreeIP->GetFieldStringValue( "NodeDetails" );												
    my $IPAddr = $Entity_FreeIP->GetFieldStringValue( "IPAddress" );													
    if ($DaysNotActive ne "0" || $StaticAsset ne "" || $NodeDetails ne "")												
    {
        print"\nEntered if around line " . __LINE__ . "sub - handleFreeIP \n";
        $session -> EditEntity( $Entity_FreeIP , "Modify" );															
        $Entity_FreeIP -> SetFieldValue( "DaysNotActive" , "0" );														
        $Entity_FreeIP -> SetFieldValue( "StaticAsset" , "");															
        $Entity_FreeIP -> SetFieldValue( "NodeDetails" , "");															

        printf ( "\nCleaning Up %s as it is Free\n" , $Entity_FreeIP -> GetFieldStringValue("IPAddress"));				

        my $ModIP_Status = $Entity_FreeIP -> Validate();																

        if ( $ModIP_Status eq "" )																						
        {
            $Entity_FreeIP -> Commit();																					
            print "\nCommit Successful"
        }
        else
        {
            $Entity_FreeIP -> Revert();																					
            print "\nvalidation failed, reverting";
        }
    }
    if ( pinghost( $IPAddr ) )
    {
        print "\n ping successful, setting" .$IPAddr. "to stolen \n";
        $session -> EditEntity( $Entity_FreeIP , "Stolen" );															
        if ( $Entity_FreeIP -> Validate() eq "" )																		
        {
            $Entity_FreeIP -> Commit();																					
            printf( "\n%s is pingable even though its free. Set state to stolen\n",$IPAddr );							
            push( @newStolen , $IPAddr );																				
            push( @stolenState , $IPAddr );																						
        }
        else
        {
            $Entity_FreeIP -> Revert();																					
            print "\n damn, validation failed :( \n";
        }
    }
    else
    {
        print "\n adding to free array\n";
        push( @freeState , $IPAddr );																					
    }

}



###
### Logic for dealing with a record marked as static.
### In this sub routine we must check if the equipment is reachable by pinging it.
### If it is not increment number of inactive days
### 
### @param $ipID, id of record entry in IPTable in CQ
#########################################################################

sub handleStaticIP
{	
	use vars qw( @staticState @dhcpState @usedState @stolenState @freeState @newStolen );
    my $ipID = shift;																										
    chomp($ipID);	
	
    my $Entity_StaticIP = $session -> GetEntity( "IPaddress" , $ipID );													
    my $DaysNotActive = $Entity_StaticIP -> GetFieldStringValue( "DaysNotActive" );										
    my $IPAddr = $Entity_StaticIP -> GetFieldStringValue( "IPAddress" );												
    my $CRBRef = $Entity_StaticIP -> GetFieldStringValue( "StaticCRB" );												
    my $hostname = hostname( $IPAddr );																			
	
    if ( pinghost( $IPAddr ) )															
    {
        print "\nReply from target system, Checking DaysNotActive\n";
        if ( $DaysNotActive > 0 )																						
        {
            print "\nDaysNotActive is greater than 0\n";
            $session->EditEntity( $Entity_StaticIP , "Modify" );							
            $Entity_StaticIP->SetFieldValue( "DaysNotActive" , "0" );													
            my $ModIP_Status = $Entity_StaticIP->Validate();															

            if ( $ModIP_Status eq "" )																					
            {																											
                $Entity_StaticIP->Commit();																				
                printf( "\n$IPAddr has become active again. Resettings Days inactive\n" );								
            }																											
            else																										
            {																											
                $Entity_StaticIP -> Revert();																			
                print "\nValidation failed - " . $ModIP_Status . "\n";
            }																											
        }																												
    }																												
    else																												
    {
        print "\n No reply from target system\n" . __LINE__;
        $session->EditEntity( $Entity_StaticIP , "Modify" );
        $DaysNotActive++;
        chomp( $DaysNotActive );
        $Entity_StaticIP->SetFieldValue( "DaysNotActive" , $DaysNotActive );
		my $ModIP_Status = '';
        $ModIP_Status = $Entity_StaticIP->Validate();
		
        if ( $ModIP_Status eq "" )
        {
            $Entity_StaticIP->Commit();
            printf( "\n$IPAddr 's inactive days is incremented to %d days due to ping failure\n" , $DaysNotActive );
        }
        else
        {
            $Entity_StaticIP->Revert();
            print  "ERROR validating\n";
        }

    }
    my $tempIP = StaticIP->new(ip => $IPAddr , hostname => $hostname, );
    push(@staticState,$tempIP);
}



###
### Logic for dealing with a record marked as used. Check if its pingable. 
### If not pingable within 4 days, the reservation owner 
### is emailed and told to sort it out by 7 days
### 
### @param $ipID, id of record entry in IPTable in CQ
#########################################################################

sub handleUsedIP
{
    use vars qw( @staticState @dhcpState @usedState @stolenState @freeState @newStolen );
    my $ipID = shift;
    chomp( $ipID );
	
    my $Entity_UseIP = $session->GetEntity( "IPaddress" , $ipID );
    my $DaysNotActive = $Entity_UseIP->GetFieldStringValue( "DaysNotActive" );
    my $IPAddr = $Entity_UseIP->GetFieldStringValue( "IPAddress" );
	
    if ( pinghost ( $IPAddr ) )    
    {
        print "\nhost is reachable\n";
        if ( $DaysNotActive > 0 )
        {
            print "\nDays not active > 0\n";
            {
				$session -> EditEntity( $Entity_UseIP , "Modify" );
				$Entity_UseIP -> SetFieldValue( "DaysNotActive" , "0" );
				my $ModIP_Status = $Entity_UseIP -> Validate();
				if ( $ModIP_Status eq "" )
				{
					$Entity_UseIP->Commit();
					printf( "\n$IPAddr has become active again. Resettings Days inactive\n" );
				}
				else
				{
					$Entity_UseIP->Revert();
					printf( "\nFailure to reset Days not Active for $IPAddr" );
				}
            }
        }
    }
    else																												
    {
        print "\nhost not reachable\n";
        $session -> EditEntity( $Entity_UseIP , "Modify" );
        my $currentDaysInactive = $DaysNotActive;
        $currentDaysInactive++;
        $Entity_UseIP -> SetFieldValue( "DaysNotActive" , $currentDaysInactive );
        my $mod_Status = $Entity_UseIP->Validate();
        if ( $mod_Status eq "" )
        {
			$Entity_UseIP -> Commit();
        }
        else
        {
			$Entity_UseIP -> Revert();
			print( "\nError Incrementing Inactive Days for $ipID!\n" );
        }
    }
    my $hostname = hostname($IPAddr);
    my $tempIP = UsedIP->new( ip => $IPAddr , hostname => $hostname, );
    push(@usedState,$tempIP);
}



###
### Send the email report to admins
### If not pingable within 4 days, the reservation owner 
### is emailed and told to sort it out by 7 days
### 
### @param $lab , $subnet
#########################################################################

sub sendReport
{    
	use vars qw( @staticState @dhcpState @usedState @stolenState @freeState @newStolen );
	my $Lab = shift;
	my $subnet = shift;
	my @email_rcpt;
	
	push ( @email_rcpt , 'shn.lab.support.and.admins@intel.com' );

    my $numNewStolenIPs = @newStolen;
    my $numInactiveIPs;
    my $numFreeIPs = @freeState;
    my $numStaticIPs = @staticState;
    my $numStolenIPs = @stolenState;
    my $numUsedIPs = @usedState;
    my $numDHCPIPs = @dhcpState;

    my @inactiveIPs = getInactiveIPs( $subnet );
    $numInactiveIPs = @inactiveIPs;

    my $subject = " $Lab IP Management - $numNewStolenIPs new IPs Stolen - $numInactiveIPs currently Inactive - $numFreeIPs currently Free";
	
	$lmtemailer->loadTemplate( "/scripts/email/reportmain.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . $subject );
	$lmtemailer->setSendTo( $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"LAB" , $Lab,
		"SUBNET" , $subnet,
		"numNewStolenIPs" , $numNewStolenIPs,
		"numStolenIPs" , $numStolenIPs,
		"numUsedIPs" , $numUsedIPs,
		"numFreeIPs" , $numFreeIPs,
		"numInactiveIPs" , $numInactiveIPs,
		"numStaticIPs" , $numStaticIPs,
		"numDHCPIPs" , $numDHCPIPs,
		"NEWSTOLENIPS" ,  printIPs('newstolen' , $subnet),
		"OLDSTOLENIPS" ,  printIPs('stolen' , $subnet),
		"INACTIVEIPS" ,  printIPs('inactive' , $subnet),
		"USEDIPS" ,  printIPs('newstolen' , $subnet),
		"STATICIPS" ,  printIPs('static' , $subnet),
		"DHCPIPS" ,  printIPs('dhcp' , $subnet),
		"FREEIPS" ,  printIPs('free' , $subnet),
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
}






###
### Gets a list of inactive ips
###
### NB NB NB NB NB NB NB NB NB NB
#########################################################################


sub getInactiveIPs
{
	print "LINE : " . __LINE__ . " SUB : getInactiveIPs SUBJECT : called\n";

	my $subnet1 = shift;
	
	my @inactiveIPs;

	my @dayLimit = ( "3" );
	my @activeFilter = ( $subnet1 );

	my $querydef = $session->BuildQuery( "IPAddress" );

	$querydef->BuildField( "DaysNotActive" );
	$querydef->BuildField( "IPAddress" );
	$querydef->BuildField( "state" );


	my $queryfielddef = $querydef->GetQueryFieldDefs();
	my $idfield = $queryfielddef->ItemByName( "DaysNotActive" );
	$idfield->SetSortType( $CQPerlExt::CQ_SORT_DESC );
	$idfield->SetSortOrder( 1 );

	my $query_Filter = $querydef->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$query_Filter->BuildFilter( "DaysNotActive" , $CQPerlExt::CQ_COMP_OP_GT , \@dayLimit );
	$query_Filter->BuildFilter( "Subnet" , $CQPerlExt::CQ_COMP_OP_EQ , \@activeFilter );

	my $resultSet = $session->BuildResultSet( $querydef );
	$resultSet->Execute();

	my $status = $resultSet->MoveNext();

	while ($status == 1)
	{
		my $tempIP = InactiveIP->new
		(
			ip => $resultSet->GetColumnValue( 2 ) ,
                        daysnotactive => $resultSet->GetColumnValue( 1 ) ,
                        state => $resultSet->GetColumnValue( 3 ) ,
			hostname => hostname( $resultSet->GetColumnValue( 2 ) ) ,
                );

		push( @inactiveIPs , $tempIP );
		$status = $resultSet->MoveNext();
	}

	return @inactiveIPs;
}





###
### Pings a device to check if its online
###
### @param ip address of the target machine
### @return boolean whether the machine was responsive
#########################################################################

sub pinghost
{
    my $ipaddr = shift;

    my $command = "ping -c 1 $ipaddr";
    my $result = `$command`;
    my $desunr = "Destination Host Unreachable";

    if ( $result =~ m/$desunr/ )
    {
            return 0;
    }
    elsif ( $result =~ /\(0% packet loss\)/i )
    {
            return 1 ;
    }
    else
    {
            return 0;
    }	
}



###
### ??????????????????
###
### @param 
### @return 
#########################################################################


sub printIPs
{
	use vars qw( @staticState @dhcpState @usedState @stolenState @freeState @newStolen );
    print "LINE : " . __LINE__ . " SUB : printIPs SUBJECT : called\n";
    
    use Switch;

    my $choice = shift;
	my $subnet = shift;
    my @printArray;
    my @inactiveArray;
    my @staticArray;
    my @usedArray;

    my $returnString = "";
    my $count = 0;

    switch( $choice )
    {
            case "free"
            {
                    print "LINE : " . __LINE__ . " SUB : printIPs SUBJECT : switch ( free )\n";
                    @printArray = ( @freeState );
            }
            case "stolen"
            {
                    print "LINE : " . __LINE__ . " SUB : printIPs SUBJECT : switch ( stolen )\n";
                    @printArray = ( @stolenState );
            }
            case "newstolen"
            {
                    print "LINE : " . __LINE__ . " SUB : printIPs SUBJECT : switch ( newstolen )\n";
                    @printArray = ( @newStolen );
            }
            case "inactive"
            {
                    print "LINE : " . __LINE__ . " SUB : printIPs SUBJECT : switch ( inactive )\n";
					@inactiveArray = getInactiveIPs( $subnet );
            }
            case "used"
            {
                    print "LINE : " . __LINE__ . " SUB : printIPs SUBJECT : switch ( used )\n";
                    @usedArray = ( @usedState );
            }
            case "static"
            {
                    print "LINE : " . __LINE__ . " SUB : printIPs SUBJECT : switch ( static )\n";
                    @staticArray = ( @staticState );
            }
            case "dhcp"
            {
                    print "LINE : " . __LINE__ . " SUB : printIPs SUBJECT : switch ( dhcp )\n";
                    @printArray = ( @dhcpState );
            }
            else
            {
                    die( __LINE__ . "No Array Choice. Exiting" );
            }
    }

    my $inactiveCount = @inactiveArray;
    my $staticCount = @staticArray;
    my $usedCount = @usedArray;

    if( @printArray > 0 )
    {
            foreach my $ip ( @printArray )
            {
                    $returnString .= "$ip | Hostname: <strong>" . hostname( $ip ) . "</strong><br />";
            }
    }
    elsif( $inactiveCount > 0 )
    {
            foreach my $ip ( @inactiveArray )
            {
                    my $hostname = $ip->hostname;
                    if( $hostname eq "" )
                    {
                            $hostname = "Unavailable";
                    }
                    $returnString .= $ip->ip . " (<strong>" . $ip->daysnotactive . "</strong> Days) | Type: " . $ip->state . " | Hostname: <strong>" . $hostname . "</strong><br />";
            }

    }
    elsif( $staticCount > 0 )
    {
            foreach my $ip ( @staticArray )
            {
                    my $hostnamePart = $ip->hostname;
                    if( $hostnamePart eq "" )
                    {
                            $hostnamePart = "Unavailable";
                    }
                    $returnString .= $ip->ip . " | Hostname: <strong>" . $hostnamePart . "</strong><br />";
            }
    }
    elsif( $usedCount > 0 )
    {
            foreach my $ip ( @usedArray )
            {
                    my $hostnamePart = $ip->hostname;
                    if( $hostnamePart eq "" )
                    {
                            $hostnamePart = "Unavailable";
                    }

                    $returnString .= $ip->ip . " | Hostname: <strong>" . $hostnamePart . "</strong><br />";
            }
    }
    else
    {
            $returnString = "No <strong>IPs</strong> in this category!";
    }

    return ( $returnString );
}




###
### Does DNS Or Reverse lookup of names and or ips addresses
###
### @param ip address of the machine
#########################################################################

sub hostname
{	
	print "LINE : " . __LINE__ . " SUB : hostname SUBJECT : called\n";
	
	my $arg_ip = shift;	
	my ( @bytes , @octets , $packedaddr , $raw_addr , $host_name , $ip );
	
	if( $_[ 0 ] =~ /[a-zA-Z]/g )
	{
		print "LINE : " . __LINE__ . " SUB : hostname SUBJECT : get host by name\n";
		$raw_addr = ( gethostbyname( $arg_ip ) )[ 4 ];
		@octets = unpack( "C4" , $raw_addr );
		$host_name = join( "." , @octets );
	}
	else
	{
		print "LINE : " . __LINE__ . " SUB : hostname SUBJECT : get host by addr\n";
		@bytes = split( /\./ , $arg_ip );
		$packedaddr = pack( "C4" , @bytes );
		$host_name = ( gethostbyaddr( $packedaddr , 2 ) )[ 0 ];
	}
	
	print "LINE : " . __LINE__ . " SUB : hostname SUBJECT : return ( $host_name )\n";
	
	return( $host_name );
}


