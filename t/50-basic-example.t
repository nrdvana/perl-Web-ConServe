#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';

package Example1 {
	use Web::ConServe qw/ -parent /;
	has last_call => ( is => 'rw' );
	sub test1 : Serve(GET /foo) { shift; return [200,[],[ test1 => @_ ]] }
	sub test2 : Serve(GET /bar) { shift; return [200,[],[ test2 => @_ ]] }
}

my $app_inst= new_ok( 'Example1', [] );
my $plack_app= $app_inst->to_app;

my @tests= (
	{ req => { PATH_INFO => '/foo' }, call => [ 'test1' ] },
	{ req => { PATH_INFO => '/bar' }, call => [ 'test2' ] },
);
for (@tests) {
	my ($req, $call)= @{$_}{'req','call'};
	subtest 'req '.$req->{PATH_INFO} => sub {
		my $env= make_env(%$req);
		my $res= $plack_app->($env);
		is_deeply( $res, [200,[],$call], 'response' );
	};
}

done_testing;
