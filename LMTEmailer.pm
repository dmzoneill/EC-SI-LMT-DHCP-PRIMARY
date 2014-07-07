#!/usr/bin/perl
use strict;
use warnings;
use lib '/usr/local/share/perl5/';

use MIME::Lite;
use File::Slurp;

package LMTEmailer;


sub new
{
	my $class = shift;

	my $self = {
		to => '',
		cc => '',
		from => 'shn.lab.support.and.admins@intel.com',
		subject => "[ LMT ] Report",
		templateHeaderFile => "/scripts/email/header.html",
		templateFooterFile => "/scripts/email/footer.html",
		templateFile => "/scripts/email/default.html",
		templateData => "",
	};

	bless( $self , $class );
	
	return $self;
}


sub loadTemplate
{
	my ( $self , $filename ) = @_;
	
	my $header = do { 
		local(*ARGV,$/); 
		@ARGV = $self->{ templateHeaderFile }; 
		<> 
	};

	my $footer = do { 
		local(*ARGV,$/); 
		@ARGV = $self->{ templateFooterFile }; 
		<> 
	};
	
	$self->{ templateFile } = $filename;
	
	my $contents = do { 
		local(*ARGV,$/); 
		@ARGV = $self->{ templateFile }; 
		<> 
	};

	$self->{ templateData } = $header . $contents . $footer;
}


sub replaceThese
{
	my ( $self , %replacements ) = @_;

	while( my ( $key , $value ) = each( %replacements ) )
	{
		$self->{ templateData } =~ s/$key/$value/g; 
	}
	
	my $thetime = `date`;
	
	$self->{ templateData } =~ s/TODAY/$thetime/g; 
}


sub setSendTo
{
	my ( $self , $emails ) = @_;
	$self->{ to } = $emails;
}


sub setSendFrom
{
	my ( $self , $emails ) = @_;
	$self->{ from } = $emails;
}


sub setSubject
{
	my ( $self , $subject ) = @_;
	$self->{ subject } = $subject;
}


sub setHeader
{
	my ( $self , $filename ) = @_;
	$self->{ templateHeaderFile } = $filename;
}


sub setFooter
{
	my ( $self , $filename ) = @_;
	$self->{ templateFooterFile } = $filename;
}


sub sendEmail
{	
	my $self = shift;

	my $msg = MIME::Lite->new(	
		From    => $self->{ from },
		To      => $self->{ to },
		Cc      => $self->{ cc },
		Subject => $self->{ subject },
		Type    => 'multipart/related'
	);

	$msg->attach(
		Type     => 'text/html',
		Data     => qq
		{
			$self->{ templateData }
		},
	);

	$msg->attach(
		Type	=> 'image/jpeg',
		Path	=> '/scripts/images/intel-small.jpg',
		Id	=> 'intel-small.jpg',
	);
		
	$msg->send;
}


1;


