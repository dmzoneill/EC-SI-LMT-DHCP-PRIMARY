//============================================================================
// Name        : servicescan.cpp
// Author      : David O Neill ( dave@feeditout.com )
// Version     : 1.0
// Copyright   : Copyright Intel Corporation 2011
// Description : php's lack of threads
//============================================================================

#include <iostream>
#include <cstdlib> 
#include <string>
#include <stdio.h>
#include <pthread.h>
#include <sstream>

using namespace std;



void * exec( void * cmd );
pthread_t t1;
pthread_mutex_t mutex1 = PTHREAD_MUTEX_INITIALIZER;
int counter = 0;



int main( int argc , char * argv[] )
{
	string subnets[ 7 ];
	subnets[ 0 ] = "10.237.212.";
	subnets[ 1 ] = "10.237.213.";
	subnets[ 2 ] = "10.237.214.";
	subnets[ 3 ] = "10.237.216.";
	subnets[ 4 ] = "10.243.18.";
	subnets[ 5 ] = "10.243.22.";
	subnets[ 6 ] = "10.243.23.";

	int scannum = atoi( argv[ 1 ] ); 

	int fourthOctect = 1;

	while ( fourthOctect < 255 )
	{
		if ( counter < 5 )
		{
			cout << "Creating thread ";
			cout << subnets[ scannum ];
			cout << " ";
			cout << fourthOctect;
			cout << "\n";

			std::stringstream out;
			out << fourthOctect;

			string command = "php /var/www/html/servicepw.php "+ subnets[ scannum ] + out.str() + " 1";

			if( pthread_create( &t1 , NULL , exec , ( void * ) command.c_str() ) != 0 )
			{
				cout << "Error creating thread\n";
			}
			sleep( 1 );

			fourthOctect++;
		}
		else
		{
			sleep( 2 );
		}
	}

	return 0;
}

void * exec( void * cmd )
{
	char * foo = ( char * ) cmd;

	int newcounter;

	pthread_mutex_lock( &mutex1 );
	newcounter = counter;
	newcounter++;
	counter = newcounter;
	pthread_mutex_unlock( &mutex1 );

	FILE* pipe = popen( foo , "r" );
	if( pipe == NULL )
	{
		cout << "handle error: ";
		cout << foo;
		cout << "\n";
	}
	else if ( pipe )
	{
		char buffer[ 128 ];
		while ( !feof( pipe ) )
		{
			if ( fgets( buffer , 128 , pipe ) != NULL )
			{
				printf( "%s" , buffer );
			}
		}
		pclose( pipe );
	}
	else
	{
		perror( "open failed" );
	}

	pthread_mutex_lock( &mutex1 );
	newcounter = counter;
	newcounter--;
	counter = newcounter;
	pthread_mutex_unlock( &mutex1 );

}
