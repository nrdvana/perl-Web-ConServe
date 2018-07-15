#! /usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';

use_ok 'Web::ConServe::Request' or BAIL_OUT;

my $req= new_ok( 'Web::ConServe::Request', [ env => make_env(PATH_INFO => '/foo') ], 'env attr in list' );
is( $req->env->{PATH_INFO}, '/foo' );

$req= new_ok( 'Web::ConServe::Request', [ make_env(PATH_INFO => '/foo') ], 'env direct' );
is( $req->env->{PATH_INFO}, '/foo' );

$req= new_ok( 'Web::ConServe::Request', [ { env => make_env(PATH_INFO => '/foo') } ], 'env attr in hash' );
is( $req->env->{PATH_INFO}, '/foo' );

done_testing;
