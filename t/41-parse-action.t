#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';

use_ok 'Web::ConServe'
	or BAIL_OUT;

my @tests= (
	[ '/foo',
	  { path => '/foo' },
	],
	[ '/foo/*',
	  { path => '/foo/*' },
	],
	[ '/foo/*/123',
	  { path => '/foo/*/123' },
	],
	[ '/foo/:id/123',
	  { path => '/foo/*/123', capture_names => [ 'id' ] },
	],
	[ '/foo/*/:id/x',
	  { path => '/foo/*/*/x', capture_names => [ '', 'id' ] },
	],
	[ '/foo:id/*/:uuid',
	  { path => '/foo*/*/*', capture_names => [ 'id','','uuid' ] },
	],
);
for (@tests) {
	my ($spec, $expected)= @$_;
	my $action= Web::ConServe->conserve_parse_action($spec);
	delete $action->{match_fn}; # can't compare
	is_deeply( $action, $expected, $spec );
}

done_testing;
