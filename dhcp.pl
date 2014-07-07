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



###
### Config Destinations
#########################################################################

# target destination
my $dhcpd_target = "/etc/dhcpd.conf"; 
# used as template
my $dhcpd_template = "/scripts/templates/dhcpd.conf"; 
# output of new config
my $dhcpd_temp = "/scripts/temp.conf"; 
#backup of known working config
my $dhcpd_last_good_config = "/scripts/backup/dhcpd.conf" ; 
# customer pxe info
my $customer_pxe_info = "/var/www/html/pxe/pxe.txt";



###
### Other config
#########################################################################
my $pxeFileLastModified = 0; # updated by sub load_pxeinfo();



###
### Backup
#########################################################################

system "crontab -l >/var/www/html/data/crontab"; # output crontab 
system "chmod 777 /var/www/html/data/crontab"; 
system "cp /scripts/boards/* /var/www/html/data/";
system "chmod 777 /var/www/html/data/boards*";
system "chown apache:apache /var/www/html/data/boards*";
system "cp " . $dhcpd_target . " " . $dhcpd_last_good_config;
system "cp " . $dhcpd_template . " " . $dhcpd_temp;



###
### SIE-XXX is the entry in the lmt crb_location column
### boards.xxx is the output file
### A | B | C | D is where its going to be place in the dhcpd.conf
### Last entry is to doublecheck that ip assignment is
### assigned to the right vlan
### Otherwise the switch will ignore the lease on the wrong vlan
#########################################################################

my @room1 = ( 'SIE1-SW' , '/boards/boards.SW' , 'A' , 18 );
my @room2 = ( 'SIE1-SV' , '/boards/boards.SV' , 'B' , 18  );
my @room3 = ( 'Data Center' , '/boards/boards.DataCenter' , 'C' , 213 );
my @room4 = ( 'SIE1-ServerRack' , '/boards/boards.ServerRack' , 'D' , 213 );
my @room5 = ( 'SIE1-RackRoom' , '/boards/boards.RackRoom' , 'E' , 212 );
my @room6 = ( 'SIE1-RackRoom2' , '/boards/boards.RackRoom2' , 'F' , 214 );
#my @room5 = ( 'SIE2-TME' , '/boards/boards.TME' , 'E' , 22 );
my @room7 = ( 'NTS' , '/boards/boards.NTS' , 'Z' , 0 );
my @rooms = ( \@room1 , \@room2 , \@room3 , \@room4 , \@room5 , \@room6 );

my $template = load_template( $dhcpd_temp );
my $pxeinfo = load_pxeinfo( $customer_pxe_info );
my $diff = 0;

# loop through each room, syncing db information into defined boards file
foreach my $room ( @rooms )
{
	# create boards files
	syncDB( $room->[0] , $room->[1] , $room->[2] , $room->[3] );
	# create dhcpd hosts entries for temp.conf
	if( $room->[0] ne 'NTS' )
	{
		my $host_section = generate_host_section( "/scripts" . $room->[1] , $room->[2] , $pxeinfo );
		# add dhcpd hosts entries into temp.conf
		$template = addToConf( $host_section , $template , $room->[2] );
	}	
	
	if( $diff == 0 )
	{
		$diff = diff( $room->[1] , '/var/www/html' );
	}
}

$template = addDateToConf( $template );

# output confugured configuration into temp.conf
open ( OUTPUT , ">$dhcpd_temp" ) or die "$PROGRAM_NAME: Failed to open output file $dhcpd_temp ($ERRNO)\n";
print OUTPUT $template;
close OUTPUT;

if( $diff == 1 || $pxeFileLastModified < 360 )
{
	print "diff|change\n";
	# Move the temp.conf to /etc/dhcpd.conf
	system "cp " . $dhcpd_temp . " " . $dhcpd_target;
	# restart the server
	print "Attempting to restart dhcpd \n";
	system "/etc/init.d/dhcpd restart";
	dhcpChangedEmailer();
}
else
{
	print "diff|nochange\n";
}



#########################################################################
#########################################################################
###
### Functions
###
#########################################################################



###
### Were there changes
### Diff the new boards files with the old ones files 
###
### @param room, the board file eg. boards.Rackroom
### @param location of the old boards file ( they were copied into /var/www/html/data )
### @return true false ( update dhcp )
#########################################################################

sub diff
{
	my $room = shift;
	my $oldLocation = shift;	
	my @path = split( '/' , $room ); 		
	my $str = "diff /scripts" . $room . " /var/www/html/data/" . $path[2] . " | wc -l 2>&1";
	my $result = `$str`;

	if( $result == "0" )
	{
		print "nochange|$room\n";
		return 0;
	}
	else
	{
		print "change|$room\n";
		return 1;
	}
}




###
### Grabs all Ip reservations from LMT EE_DUT table
### puts them into boards.<LAB> files
###
### @param lab, SIE1-SW etc
### @param boardsfile, the file to save the db info into
### @param boardsSection
### @param vlan
#########################################################################

sub syncDB
{
	my $Lab = shift; # parameter 1
	my $boardsFile = shift; # parameter 2
	my $boardsSection = shift; # parameter 3
	my $vlan = shift; # parameter 4
		
	# Open and truncate (clear) the output file
	# eg /scripts/boards.TME
	open ( MYFILE , '>/scripts/' . $boardsFile );	
	
	print "begin|$Lab\n";
	
	##
	## IP ADDRESS STATIC CRBS
	##
	
	# Fancy clearquest sql query
	print "updatecrbs|$Lab|$boardsFile|$boardsSection|$vlan\n";
	my $staticCRBS = $session->BuildQuery( "ipaddress" );
	$staticCRBS->BuildField( "StaticCRB.id" );
	$staticCRBS->BuildField( "IPAddress" );
	$staticCRBS->BuildField( "StaticCRB.MACAddress1" );
	$staticCRBS->BuildField( "StaticCRB.rootPath" );
	$staticCRBS->BuildField( "StaticCRB.CurrentUser.fullname" );
	$staticCRBS->BuildField( "StaticCRB.CurrentUser.email" );
	$staticCRBS->BuildField( "State" );
	$staticCRBS->BuildField( "StaticCRB.CRB_Location" );	

	# where CRB_Location = $lab
	my @activeFilter1 = ( $Lab );
	my $query_ActiveFilter1 = $staticCRBS->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$query_ActiveFilter1->BuildFilter( "StaticCRB.CRB_Location" , $CQPerlExt::CQ_COMP_OP_EQ , \@activeFilter1 );	
	
	# we dont want blank mac addresses
	my @activeFilter2 = ( );
	my $query_ActiveFilter2 = $staticCRBS->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$query_ActiveFilter2->BuildFilter( "StaticCRB.MACAddress1" , $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL , \@activeFilter2 );	
	
	# execute the query
	my $resultSet = $session->BuildResultSet( $staticCRBS );
	$resultSet->Execute();
	
	# The results set comes back as link list datastructure
	# MoveNext() move to the head of the next
	my $status = $resultSet->MoveNext();

	# MoveNext returns 1 (true) when there is another one in the list
	while ( $status == 1 )
	{
		# GetColumnValue( int ) is directly related to the query above
		my $ID = $resultSet->GetColumnValue( 1 );
		my $ipaddr = $resultSet->GetColumnValue( 2 );
		my $MACAddress = $resultSet->GetColumnValue( 3 );
		my $rootPath = $resultSet->GetColumnValue( 4 );
		my $fullname = $resultSet->GetColumnValue( 5 );
		my $email = $resultSet->GetColumnValue( 6 );
		my $state = $resultSet->GetColumnValue( 7 );		
		my $location = $resultSet->GetColumnValue( 8 );	
		
		if( $location eq $Lab )
		{
			# No root path? well then add the default
			if ( $rootPath eq "" )
			{
				$rootPath = "/BLANK/ROOT/PATH";
			}
			
			# Check Validity of mac address
			if( checkMacAddress( $MACAddress , $ID ) != 0 || $Lab eq "NTS" )
			{		
				my $ip = checkIpAddress( $ipaddr , $vlan , $ID );			
				
				# Check validity of the IP address
				if( $ip eq $ipaddr || $Lab eq "NTS" )
				{
					# enter info into boards file
					print "$ID|crbentry|$MACAddress|$ipaddr|$vlan|$rootPath|$boardsFile|$fullname|$email|$state|$location\n";
					print MYFILE "$ID $MACAddress $ipaddr $rootPath\n";	
				}
				else
				{
					if( $ip == -1 )
					{
						print "$ID|crb|iperror|$MACAddress|$ipaddr|$vlan|$rootPath|$boardsFile|$fullname|$state|$location\n";
					}
					else
					{
						print "$ID|crb|iperrorvlan|$MACAddress|$ipaddr|$vlan|$rootPath|$boardsFile|$fullname|$state|$location\n";
					}
				}
			}
			else
			{
				print "$ID|crb|macerror|$MACAddress|$ipaddr|$vlan|$rootPath|$boardsFile|$fullname|$location\n";
			}
		}

		# Move to the next node in the linked list
		$status = $resultSet->MoveNext();
	}	
		
		
	##
	## IP ADDRESS STATIC ASSETS
	##
	
	print "updateassets|$Lab|$boardsFile|$boardsSection|$vlan\n";
	
	my $query = $session->BuildQuery( "ipaddress" );
	$query->BuildField( "StaticAsset.id" );
	$query->BuildField( "IPAddress" );
	$query->BuildField( "StaticAsset.MACAddress1" );
	$query->BuildField( "StaticAsset.State" );
	$query->BuildField( "State" );
	$query->BuildField( "StaticAsset.Location" );	

	my @activeFilter1 = ( );
	my $filter1 = $query->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$filter1->BuildFilter( "StaticAsset.MACAddress1" , $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL , \@activeFilter1 );
	
	my @activeFilter2 = ( $Lab );
	my $filter2 = $query->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$filter2->BuildFilter( "StaticAsset.Location" , $CQPerlExt::CQ_COMP_OP_EQ , \@activeFilter2 );

	my $resultSet = $session->BuildResultSet( $query );
	$resultSet->Execute();
	my $status = $resultSet->MoveNext();
	
	while ( $status == 1 )
	{
		my $ixa = $resultSet->GetColumnValue( 1 );
		my $ipaddr = $resultSet->GetColumnValue( 2 );		
		my $mac = $resultSet->GetColumnValue( 3 );	
		my $assetstate = $resultSet->GetColumnValue( 4 );	
		my $state = $resultSet->GetColumnValue( 5 );
		my $location = $resultSet->GetColumnValue( 6 );	

		if( $location eq $Lab )
		{
			if( ( $ipaddr ne "" ) )
			{							
				my $rootPath = "/BLANK/ROOT/PATH";
				
				# Check Validity of mac address
				if( checkMacAddress( $mac , $ixa ) != 0 || $Lab eq "NTS" )
				{		
					my $ip = checkIpAddress( $ipaddr , $vlan , $ixa );			
					
					# Check validity of the IP address
					if( $ip eq $ipaddr || $Lab eq "NTS" )
					{
						# enter info into boards file						
						print "$ixa|assetentry|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$assetstate|$state|$location\n";
						print MYFILE "$ixa $mac $ipaddr $rootPath\n";	
					}
					else
					{
						if( $ip == -1 )
						{
							print "$ixa|asset|iperror|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$assetstate|$state|$location\n";
						}
						else
						{
							print "$ixa|asset|iperrorvlan|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$assetstate|$state|$location\n";
						}
					}
				}							
				else
				{
					print "$ixa|asset|macerror|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$assetstate|$state|$location\n";
				}
			}	
		}
		$status = $resultSet->MoveNext();
	}
	
	
	##
	## IP ADDRESS ASSET RESERVATIONS
	##
	
	print "updateassetreservations|$Lab|$boardsFile|$boardsSection|$vlan\n";
	
	my $query = $session->BuildQuery( "ipaddress" );
	$query->BuildField( "reservations.AssetRef.id" );
	$query->BuildField( "IPAddress" );
	$query->BuildField( "reservations.AssetRef.MACAddress1" );	
	$query->BuildField( "reservations.AssetRef.State" );
	$query->BuildField( "State" );
	$query->BuildField( "reservations.AssetRef.Location" );
	$query->BuildField( "reservations.User.email" );

	my @activeFilter1 = ( );
	my $filter1 = $query->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$filter1->BuildFilter( "reservations.AssetRef.MACAddress1" , $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL , \@activeFilter1 );	
	
	my @activeFilter2 = ( $Lab );
	my $filter2 = $query->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$filter2->BuildFilter( "reservations.AssetRef.Location" , $CQPerlExt::CQ_COMP_OP_EQ , \@activeFilter2 );
	
	my $resultSet = $session->BuildResultSet( $query );
	$resultSet->Execute();
	my $status = $resultSet->MoveNext();
	
	while ( $status == 1 )
	{
		my $ixa = $resultSet->GetColumnValue( 1 );
		my $ipaddr = $resultSet->GetColumnValue( 2 );		
		my $mac = $resultSet->GetColumnValue( 3 );	
		my $assetstate = $resultSet->GetColumnValue( 4 );
		my $state = $resultSet->GetColumnValue( 5 );
		my $location = $resultSet->GetColumnValue( 6 );
		my $email = $resultSet->GetColumnValue( 6 );

		if( $location eq $Lab )
		{
			my $rootPath = "/BLANK/ROOT/PATH";
					
			# Check Validity of mac address
			if( checkMacAddress( $mac , $ixa ) != 0 || $Lab eq "NTS" )
			{		
				my $ip = checkIpAddress( $ipaddr , $vlan , $ixa );			
				
				# Check validity of the IP address
				if( $ip eq $ipaddr || $Lab eq "NTS" )
				{
					# enter info into boards file						
					print "$ixa|assetreservationentry|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$assetstate|$state|$location|$email\n";
					print MYFILE "$ixa $mac $ipaddr $rootPath\n";	
				}
				else
				{
					if( $ip == -1 )
					{
						print "$ixa|assetreservation|iperror|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$assetstate|$state|$location\$email\n";
					}
					else
					{
						print "$ixa|assetreservation|iperrorvlan|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$assetstate|$state|$location|$email\n";
					}
				}
			}							
			else
			{
				print "$ixa|assetreservation|macerror|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$assetstate|$state|$location|$email\n";
			}
		}		
		$status = $resultSet->MoveNext();
	}
	
	
	##
	## IP ADDRESS CRB RESERVATIONS
	##
	
	print "updatecrbreservations|$Lab|$boardsFile|$boardsSection|$vlan\n";
	print "updatecrbreservations|$Lab|$boardsFile|$boardsSection|$vlan\n";
	
	my $query = $session->BuildQuery( "ipaddress" );
	$query->BuildField( "reservations.CRBRef.id" );
	$query->BuildField( "IPAddress" );
	$query->BuildField( "reservations.CRBRef.MACAddress1" );	
	$query->BuildField( "reservations.CRBRef.rootPath" );
	$query->BuildField( "reservations.CRBRef.Owner.fullname" );
	$query->BuildField( "reservations.CRBRef.Owner.email" );
	$query->BuildField( "State" );
	$query->BuildField( "reservations.CRBRef.CRB_Location" );

	my @activeFilter1 = ( );
	my $filter1 = $query->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$filter1->BuildFilter( "reservations.CRBRef.MACAddress1" , $CQPerlExt::CQ_COMP_OP_IS_NOT_NULL , \@activeFilter1 );	
	
	my @activeFilter2 = ( $Lab );
	my $filter2 = $query->BuildFilterOperator( $CQPerlExt::CQ_BOOL_OP_AND );
	$filter2->BuildFilter( "reservations.CRBRef.CRB_Location" , $CQPerlExt::CQ_COMP_OP_EQ , \@activeFilter2 );
	
	my $resultSet = $session->BuildResultSet( $query );
	$resultSet->Execute();
	my $status = $resultSet->MoveNext();
	
	while ( $status == 1 )
	{
		my $ixa = $resultSet->GetColumnValue( 1 );
		my $ipaddr = $resultSet->GetColumnValue( 2 );		
		my $mac = $resultSet->GetColumnValue( 3 );	
		my $rootPath = $resultSet->GetColumnValue( 4 );
		my $fullname = $resultSet->GetColumnValue( 5 );
		my $email = $resultSet->GetColumnValue( 6 );
		my $state = $resultSet->GetColumnValue( 7 );
		my $location = $resultSet->GetColumnValue( 8 );	
		
		if( $location eq $Lab )
		{
			# No root path? well then add the default
			if ( $rootPath eq "" )
			{
				$rootPath = "/BLANK/ROOT/PATH";
			}
					
			# Check Validity of mac address
			if( checkMacAddress( $mac , $ixa ) != 0 || $Lab eq "NTS" )
			{		
				my $ip = checkIpAddress( $ipaddr , $vlan , $ixa );			
				
				# Check validity of the IP address
				if( $ip eq $ipaddr || $Lab eq "NTS" )
				{
					# enter info into boards file						
					print "$ixa|crbreservationentry|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$fullname|$email|$state|$location\n";
					print MYFILE "$ixa $mac $ipaddr $rootPath\n";	
				}
				else
				{
					if( $ip == -1 )
					{
						print "$ixa|crbreservation|iperror|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$fullname|$email|$state|$location\n";
					}
					else
					{
						print "$ixa|crbreservation|iperrorvlan|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$fullname|$email|$state|$location\n";
					}
				}
			}							
			else
			{
				print "$ixa|crbreservation|macerror|$mac|$ipaddr|$vlan|$rootPath|$boardsFile|$fullname|$email|$state|$location\n";
			}
		}		
		$status = $resultSet->MoveNext();
	}
		
	
		
	# Close off the boards file
	close ( MYFILE ); 
}





###
### Static ip address preference, then reserved, else return 0
### If there is static and reserved ip address for a mac address 
### We'll choose the static assignemnt, ignoring the reserved
### also check the validity of the address
###
### @param reserved, the reserved address in the database
### @param static, the static ip address in the database
### @param vlan, the vlan it should be in
### @return ip address, or 0 indicating dodgy data
#########################################################################

sub checkIpAddress
{
	my $ip = shift;
	my $vlan = shift;
	my $id = shift;
	
	# Static gets priority
	if( $ip =~ /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/ )
	{
		my @octets = split( /\./ , $ip );
		
		# Check to see if the ip address is assigned to the right subnet
		if( $octets[2] == $vlan )
		{
			# All good
			return $ip;
		}
		else
		{
			# Ip Lease in the wrong vlan
			return 0;
		}
	}
		
	# Bad ip address
	else
	{
		# send alert
		return -1;
	}
}





###
### Mac address checker
### return 1 if good, 0 if not
###
### @param mac, the mac address to check
### @return 1 = true, 0 false
#########################################################################

sub checkMacAddress
{
	my $mac = shift;

	if( $mac =~ /^(([0-9a-fA-F]{2}[:-]{1}){5}([0-9a-fA-F]{2}))$/ )
	{		
		return 1;
	}
	else
	{
		# send alert
		return 0;
	}
}





###
### Load template file
### Return template data
###
### @param template, location of template file to load
### @return the data in the file
#########################################################################

sub load_template
{
    my $template = shift;
	
    # Read in the template
    if ( open( DATA , "<$template") ) 
	{
		print "opened|$template\n";
		my $data;
		$data .= $ARG while( <DATA> );
		close DATA;		
		return $data;
	}
	
	# Failed Reading file
	else
	{
		# send alert
		print "openfail|$template\n";
	}    
}






###
### Load customer pxe options
### Return pxe data
###
### @param pxefile, location of pxe file to load
### @return the data in the file
#########################################################################

sub load_pxeinfo
{
    my $template = shift;
	
    # Read in the template
    if ( open( DATA , "<$template") ) 
	{
		$pxeFileLastModified = time - stat( $template )->mtime;
		print "opened|$template\n";
		my $data;
		$data .= $ARG while( <DATA> );
		close DATA;
		return $data;
	}
	
	# Failed Reading file
	else
	{
		# send alert
		print "openfail|$template\n";
	}    
}




###
### Get customer info from loaded data
### Match mac / ip in pxe file
### Return data only if matched
### Return pxe array or 0 not found
###
### @param pxefile, the data loaded from the pxe file
### @param mac, the mac address to check for
### @ip the ip to check for
### @return the data in the file
#########################################################################

sub customer_pxe_match
{
    my $pxeinfo = shift;
	my $mac = shift;
	my $ip = shift;
	
    my @lines = split( "\n" , $pxeinfo );
	
	foreach my $line ( @lines )
	{
		my ( $email , $macadd , $ipadd , $rootpath , $vend , $nextserver , $filename ) = split( /\|/ , $line );
				
		if( $macadd eq $mac && $ipadd eq $ip )
		{
			return ( $rootpath , $vend , $nextserver , $filename );
		}
	} 
	
	return ();
}





###
### Generate config data from boards file
### Creates host section for static ip by mac address leases
###
### @param boardsfile
### @return hostS (plural) config for entry into dhcpd.conf
#########################################################################

sub generate_host_section
{
	my $boardsfile = shift;
	my $hostsection = shift;
	my $pxeinfo = shift;
	my $config = '';
	
	$hostsection =~ s/^\s+//;
	$hostsection =~ s/\s+$//;
	
	# open the boards file
	if ( open( BOARDS , "<$boardsfile" ) )
	{
		print "createhostsentries|$boardsfile\n";
		
		my $count = 1;
		
		# read line by line
		while( <BOARDS> )
		{
			# split by space
			my @entry = split( / / , $_ );			
			
			if( @entry >= 4 )
			{	
				# doublecheck mac address
				if ( $entry[1] =~ /^(([0-9a-fA-F]{2}[:-]{1}){5}([0-9a-fA-F]{2}))$/ )
				{
					# doublecheck ip address
					if( $entry[2] =~ /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/ )
					{
						# check root path for addition
						# at later date						
						$entry[3] =~ s/\015?\012?$//; 
						
						my @boardpxe = customer_pxe_match( $pxeinfo , $entry[1] , $entry[2] );											
						
						if( @boardpxe != 0 )
						{
							# $rootpath , $vend , $nextserver , $filename
							
							$config .= "\t\t\t";
							$config .= "host board-" . $entry[0] . "-" . $hostsection . "-" . $count;
							$config .= "\n\t\t\t";
							$config .= "{";
							$config .= "\n\t\t\t\t";
							$config .= "hardware ethernet " .  $entry[1];
							$config .= ";\n\t\t\t\t";
							$config .= "fixed-address " . $entry[2];
							$config .= ";\n\n";
							$config .= "\t\t\t\t### Customer PXE info\n";
							 
							if( $boardpxe[0] ne "" )
							{
								$config .= "\t\t\t\toption root-path \"" . $boardpxe[0] . "\";\n";
							}													
							
							if( $boardpxe[1] ne "" )
							{
								$config .= "\t\t\t\toption vendor-encapsulated-options " . $boardpxe[1] . ";\n";
							}								
							
							if( $boardpxe[2] ne "" )
							{
								$config .= "\t\t\t\tnext-server " . $boardpxe[2] . ";\n";
							}								
													
							if( $boardpxe[3] ne "" )
							{
								$config .= "\t\t\t\tfilename \"" . $boardpxe[3] . "\";\n";
							}	
							
							$config .= "\t\t\t}";
							$config .= "\n\n";
							
						}
						else
						{
						
							## keep appending new hosts into config
							$config .= "\t\t\t";
							$config .= "host board-" . $entry[0] . "-" . $hostsection . "-" . $count;
							$config .= "\n\t\t\t";
							$config .= "{";
							$config .= "\n\t\t\t\t";
							$config .= "hardware ethernet " .  $entry[1];
							$config .= ";\n\t\t\t\t";
							$config .= "fixed-address " . $entry[2];
							$config .= ";\n\t\t\t\t";
							$config .= "option root-path \"" . $entry[3] . "\";\n";		
							$config .= "\t\t\t\toption vendor-encapsulated-options 06:01:0B:08:07:AA:AA:01:0A:ED:D9:1C:00;\n";
							$config .= "\t\t\t\tnext-server 10.237.217.28;\n";
							$config .= "\t\t\t\tfilename \"BStrap/X86pc/BStrap.0\";\n";
							$config .= "";
							$config .= "\t\t\t}";
							$config .= "\n\n";
						
						}
						
						$count++;

					}
					else
					{
						# send alert
						print "iperror|" . $entry[2] . "\n";
					}
				}
				else
				{
					# send alert
					print "macerror|" . $entry[1] . "\n";
				}
			}
			else
			{				
				# send alert
				print "hosterror|" . $boardsfile . "\n";
			}			
		}
		close BOARDS;
		
		# finally return the config for all the boards
		print "generated|" . $hostsection . "\n";
		return $config;
	}
	
	# Error opening boardsfile
	else
	{
		# send alert
		print "openfail|$boardsfile|$ERRNO\n";
		return 0;
	}	
}





###
### Enters host informmation into dhcp config file
### At sections defined as A B C D E
### Refer to rooms array defintion near top of document
###
### @param newdata, the data to be entered at that section
### @param dhcpconf, the template for the dhcp config file
### @param letter, the section where to enter the data
### @return the updated config file 
#########################################################################

sub addToConf
{
	my $newdata = shift; 
	my $dhcpconf = shift; 
	my $letter = shift;
	
	print "dhcpd|sectionadd|$letter\n";

# Drop the new config into the template
$dhcpconf =~ s/\n\t\t\t### HOST SECTION $letter START.*\n\t\t\t### HOST SECTION $letter END.*?\n/
\t\t\t### HOST SECTION $letter START
\t\t\t# This section of the file is autogenerated by
\t\t\t# \/scripts\/dhcp.pl
\t\t\t#
$newdata
\t\t\t### HOST SECTION $letter END
/s
  or die "Couldn't add $letter\n";

	return $dhcpconf;
}





###
### Enters last update into dhcp config file
###
### @param newdata, the data to be entered at that section
### @param dhcpconf, the template for the dhcp config file
### @return the updated config file 
#########################################################################

sub addDateToConf
{
	my $dhcpconf = shift; 
	
	print "dhcpd|lastupdate\n";
	
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my @weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
	my ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = gmtime();
	my $year = 1900 + $yearOffset;
	my $theGMTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";

	# Drop the new config into the template
	$dhcpconf =~ s/### LAST UPDATE SECTION/### Last update : $theGMTime/s or die "Couldn't add last update section\n";

	return $dhcpconf;
}






###
### Used to send email if dhcp configuration changes
#########################################################################

sub dhcpChangedEmailer
{
	$lmtemailer->loadTemplate( "/scripts/email/default.html" );
	$lmtemailer->setSubject( $lmtcommon->get( 'emailoptions' , 'email_subject-prefix' ) . " DHCP: updated!" );
	$lmtemailer->setSendTo( $lmtcommon->get( 'contacts' , 'email_level1' ) );
	$lmtemailer->setSendFrom( $lmtcommon->get( 'contacts' , 'email_level1' ) );

	my %replace = ( 
		"MESSAGE" , "The DHCP server configuration has been updated and the service has been restarted"
	);

	$lmtemailer->replaceThese( %replace );
	$lmtemailer->sendEmail();
}



