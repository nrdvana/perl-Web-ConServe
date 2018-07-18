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
		{ req => { PATH_INFO => '/foo' },         res => [200,[],['foo_wild','']] },
		{ req => { PATH_INFO => '/bar' },         res => [404,[],['Not Found']] },
		{ req => { PATH_INFO => '/foo/1' },       res => [200,[],['foo',1]] },
		{ req => { PATH_INFO => '/foo/3/json' },  res => [200,[],['foo_json',3]] },
		{ req => { PATH_INFO => '/foo/3/xyz' },   res => [200,[],['foo_any',3,'xyz']] },
		{ req => { PATH_INFO => '/foo/3/x/y/z' }, res => [200,[],['foo_wild_x_wild','/3/','/y/z']] },
		{ req => { PATH_INFO => '/foo/3/y/z' },   res => [200,[],['foo_wild','/3/y/z']] },
	);
	for (@tests) {
		my ($req, $expected)= @{$_}{'req','res'};
		my $env= make_env(%$req);
		my $actual= $plack_app->($env);
		is_deeply( $actual, $expected, 'response '.$req->{PATH_INFO} );
	}
}

package CapturesAreParameters {
	use Web::ConServe -parent;
	sub foo : Serve('/object/:obj_id') {
		my $self= shift;
		return [200,[],[ 'foo', [@_], $self->params ]];
	}
	sub cap_mid : Serve('/object/*/subthing/:id') {
		my $self= shift;
		return [200,[],[ 'cap_mid', [@_], $self->params ]];
	}
}

subtest CapturesAreParameters => \&test_CapturesAreParameters;
sub test_CapturesAreParameters {
	my $app_inst= new_ok( 'CapturesAreParameters', [] );
	my $plack_app= $app_inst->to_app;
	my @tests= (
		[ '/object/1', 200, [1], { obj_id => 1 } ],
		[ '/object/1/2', 404 ],
		[ '/object/42/subthing', 404 ],
		[ '/object/42/subthing/3', 200, [42, 3], { id => 3 } ],
		[ '/object/42/subthing/', 404 ],
		[ '/object//subthing/3', 404 ],
		[ '/object/subthing/3', 404 ],
	);
	for (@tests) {
		my ($path, $code, $args, $params)= @$_;
		my $env= make_env(PATH_INFO => $path);
		my $response= $plack_app->($env);
		no warnings 'uninitialized';
		is( $response->[0], $code, "path $path = $code" )
		&& is_deeply( $response->[2][1], $args, "path $path args" )
		&& is_deeply( $response->[2][2], $params, "path $path params" )
			or diag explain $response;
	}
}

done_testing;
