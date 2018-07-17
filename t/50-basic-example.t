#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';

package Example1 {
	use Web::ConServe qw/ -parent /;
	sub test1 : Serve('GET /foo') {
		shift; return [200,[],[ test1 => @_ ]]
	}
	sub test2 : Serve("GET /bar") {
		shift; return [200,[],[ test2 => @_ ]]
	}
}

subtest Example1 => \&test_Example1;
sub test_Example1 {
	my $app_inst= new_ok( 'Example1', [] );
	my $plack_app= $app_inst->to_app;

	my @tests= (
		{ req => { PATH_INFO => '/foo' }, call => [ 'test1' ] },
		{ req => { PATH_INFO => '/bar' }, call => [ 'test2' ] },
	);
	for (@tests) {
		my ($req, $call)= @{$_}{'req','call'};
		my $env= make_env(%$req);
		my $res= $plack_app->($env);
		is_deeply( $res, [200,[],$call], 'response '.$req->{PATH_INFO} );
	}
}

package Example2 {
	use Web::ConServe qw/ -parent /;
	sub foo : Serve(GET /foo/:id) {
		shift; return [200,[],[ foo => @_ ]]
	}
	sub foo_json : Serve('GET /foo/:id/json') {
		shift; return [200,[],[ foo_json => @_ ]]
	}
	sub foo_any : Serve('GET /foo/:id/*') {
		shift; return [200,[],[ foo_any => @_ ]]
	}
	sub foo_wild : Serve('GET /foo**') {
		shift; return [200,[],[ foo_wild => @_ ]]
	}
	sub foo_wild_x_wild : Serve('GET /foo**x**') {
		shift; return [200,[],[ foo_wild_x_wild => @_ ]]
	}
}

subtest Example2 => \&test_Example2;
sub test_Example2 {
	#local $Web::ConServe::DEBUG_FIND_ACTIONS= sub { warn "$_[0]\n" };
	my $app_inst= new_ok( 'Example2', [] );
	my $plack_app= $app_inst->to_app;

	my @tests= (
		{ req => { PATH_INFO => '/foo' }, res => [200,[], ['foo_wild','']] },
		{ req => { PATH_INFO => '/bar' }, res => [404,[], ['Not Found']] },
		{ req => { PATH_INFO => '/foo/1' }, res => [200,[], ['foo',1]] },
		{ req => { PATH_INFO => '/foo/3/json' }, res => [200,[], ['foo_json',3]] },
		{ req => { PATH_INFO => '/foo/3/xyz' }, res => [200,[], ['foo_any',3,'xyz']] },
		{ req => { PATH_INFO => '/foo/3/x/y/z' }, res => [200,[],['foo_wild_x_wild','/3/','/y/z']] },
		{ req => { PATH_INFO => '/foo/3/y/z' }, res => [200,[],['foo_wild','/3/y/z']] },
	);
	for (@tests) {
		my ($req, $expected)= @{$_}{'req','res'};
		my $env= make_env(%$req);
		my $actual= $plack_app->($env);
		is_deeply( $actual, $expected, 'response '.$req->{PATH_INFO} );
	}
}

package WildcardNuances {
	use Web::ConServe qw/ -parent /;
	sub foo : Serve('GET /foo/:id') {
		shift; return [200,[],[ foo => @_ ]]
	}
	sub foo_json : Serve('GET /foo/**/json') {
		shift; return [200,[],[ foo_json => @_ ]]
	}
	sub foo_any : Serve('GET /foo/**/*') {
		shift; return [200,[],[ foo_any => @_ ]]
	}
	sub bar : Serve('GET /bar/**') {
		shift; return [200,[],[ bar => @_ ]]
	}
	sub bar_x_y : Serve('GET /bar/**/x/**/y') {
		shift; return [200,[],[ bar_x_y => @_ ]]
	}
}

subtest WildcardNuances => \&test_WildcardNuances;
sub test_WildcardNuances {
	#local $Web::ConServe::DEBUG_FIND_ACTIONS= sub { warn "$_[0]\n" };
	my $app_inst= new_ok( 'WildcardNuances', [] );
	my $plack_app= $app_inst->to_app;

	my @tests= (
		{ req => { PATH_INFO => '/' }, res => [404,[], ['Not Found']] },
		{ req => { PATH_INFO => '/foo' }, res => [404,[], ['Not Found']] },
		{ req => { PATH_INFO => '/foo/3' }, res => [200,[], ['foo',3]] },
		{ req => { PATH_INFO => '/foo/3/xyz' }, res => [200,[], ['foo_any',3,'xyz']] },
		{ req => { PATH_INFO => '/foo/3/json' }, res => [200,[],['foo_json',3]] },
		{ req => { PATH_INFO => '/bar/' }, res => [200,[],['bar','']] },
		{ req => { PATH_INFO => '/bar' }, res => [200,[],['bar','']] },
		{ req => { PATH_INFO => '/bar/z' }, res => [200,[],['bar','z']] },
		{ req => { PATH_INFO => '/bar/z/' }, res => [200,[],['bar','z/']] },
		{ req => { PATH_INFO => '/bar/1/x/2/y' }, res => [200,[],['bar_x_y',1,2]] },
	);
	for (@tests) {
		my ($req, $expected)= @{$_}{'req','res'};
		my $env= make_env(%$req);
		my $actual= $plack_app->($env);
		is_deeply( $actual, $expected, 'response '.$req->{PATH_INFO} );
	}
}

done_testing;
