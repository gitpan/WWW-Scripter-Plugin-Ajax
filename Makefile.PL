#!/usr/bin/perl

BEGIN { require 5.006; }
use ExtUtils::MakeMaker;
%prq = (
        constant                        => 1.03, # multip. const. @ 1ce
        constant::lexical               => 0,
        Encode                          => 2.09, # decode $ref
        HTML::DOM::Event                => 0,
	HTML::DOM::Exception            => 0,
        HTML::DOM::Interface            => 0,
        HTTP::Cookies                   => 0,
	HTTP::Headers                   => 0, # version ???
        HTTP::Headers::Util             => 0,
        HTTP::Request                   => 0, # version ???
	LWP::Protocol                   => 0,
        Scalar::Util                    => 1.09,
        URI                             => 1, # new_abs
	URI::Escape                     => 0, # version ???
        warnings                        => 0,
        WWW'Scripter'Plugin'JavaScript  => 0,
        XML::DOM::Lite                  => 0, # version???
# for testing:
	File'Spec'Functions                =>  0,
	HTML::DOM::Exception               => .013, # code
	HTTP'Daemon                        =>  0,
	HTTP::Response => 0, # version???
	lib => 0,
	strict => 0,
	Test::More => 0,
	utf8 => 0,
	WWW::Scripter => 0,
        WWW'Scripter'Plugin'JavaScript     => .002, # new init interface
);


WriteMakefile(
    NAME                => 'WWW::Scripter::Plugin::Ajax',
    AUTHOR              => 'Father Chrysostomos <sprout & cpan . org>',
    VERSION_FROM        => 'lib/WWW/Scripter/Plugin/Ajax.pm',
    ABSTRACT_FROM       => 'lib/WWW/Scripter/Plugin/Ajax.pm',
    PL_FILES            => {},
    PREREQ_PM           => \%prq,
    dist               => { COMPRESS => 'gzip -9f', SUFFIX => 'gz',
                            TAR => 'COPYFILE_DISABLE=1 tar' },
    clean              => { FILES => 'WWW-Scripter-Plugin-Ajax-*' },
);
