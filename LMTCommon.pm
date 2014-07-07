#!/usr/bin/perl

use strict;
use warnings;

package LMTCommon;

sub new 
{
	my $class = shift;

	my %hash = ();
	
	my $self = {
		iniFile => "/scripts/config.ini",
		data => \%hash
	};

	bless( $self , $class );
	
	$self->read();
	
	return $self;
}

sub get
{
	my( $self , $section , $key ) = @_;
	
	return $self->{ 'data' }->{ $section }->{ $key };
}

sub read
{
	my( $self ) = @_;
	
	open( MYFILE, $self->{ 'iniFile' } );
	
	my $section = "";
	my $in_section = 0;
	my $option = 0;

	while( my $line = <MYFILE> ) 
	{
		next if $line =~ /^#/;        # skip comments
		next if $line =~ /^\s*$/;     # skip empty lines

		if( $line =~ /^\[([a-zA-Z0-9\-_]+)\]$/ ) 
		{
			$section = $1;
			$in_section = 1;
			my %hash = ();
			$self->{ 'data' }->{ $section } = \%hash;
		}
		elsif( $line =~ /^([a-zA-Z0-9\-_]+)\s*=\s*(.*)$/ && $in_section == 1 ) 
		{
			my $optionkey = $1;
			my $optionval = $2;			
			$self->{ 'data' }->{ $section }->{ $optionkey } = $optionval;	
		}
	}
}

1;