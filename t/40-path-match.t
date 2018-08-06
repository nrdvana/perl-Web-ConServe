#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';
use Web::ConServe::Request;

use_ok 'Web::ConServe::PathMatch'
	or BAIL_OUT;

subtest literal_path => \&literal_path;
sub literal_path {
	my @actions= (
		{ path => '/foo' },
		{ path => '/bar' },
		{ path => '/baz' },
	);
	my $matcher= Web::ConServe::PathMatch->new(nodes => \@actions);
	my @tests= (
		[ '/foo' => { %{$actions[0]}, captures => [] } ],
		[ '/bar' => { %{$actions[1]}, captures => [] } ],
		[ '/baz' => { %{$actions[2]}, captures => [] } ],
	);
	#local $Web::ConServe::PathMatch::DEBUG= sub { warn "$_[0]\n" };
	for (@tests) {
		my ($path, @expected)= @$_;
		my @actual;
		ok( $matcher->search($path, sub { push @actual, { %{$_[0]}, captures => $_[1] }; 1 }) );
		is_deeply( \@actual, \@expected, "path $path" );
	}
}

subtest path_with_capture => \&path_with_capture;
sub path_with_capture {
	my @actions= (
		{ path => '/foo/*',     },
		{ path => '/foo/*/bar', },
		{ path => '/fo*/bar',   },
		{ path => '/foo*/baz',  },
	);
	my $matcher= Web::ConServe::PathMatch->new(nodes => \@actions);
	my @tests= (
		[ '/foo'       => () ],
		[ '/foo/1'     => { %{$actions[0]}, captures => [1] } ],
		[ '/foo/1/bar' => { %{$actions[1]}, captures => [1] } ],
		[ '/foo/bar'   => { %{$actions[0]}, captures => ['bar'] }, { %{$actions[2]}, captures => ['o'] } ],
		[ '/foo2/bar'  => { %{$actions[2]}, captures => ['o2'] } ],
		[ '/foo2/baz'  => { %{$actions[3]}, captures => ['2'] } ],
		[ '/foo/'      => () ],
		[ '/foo//bar'  => () ],
	);
	for (@tests) {
		my ($path, @expected)= @$_;
		my @actual;
		$matcher->search($path, sub { push @actual, { %{$_[0]}, captures => $_[1] }; 0 });
		is_deeply( \@actual, \@expected, "path $path" );
	}
}

subtest wildcard_nuances => \&test_wildcard_nuances;
sub test_wildcard_nuances {
	my @actions= (
		{ path => '/foo/*.*' },
		{ path => '/foo/*' },
		{ path => '/foo/**/json' },
		{ path => '/foo/**/*' },
		{ path => '/bar/**' },
		{ path => '/bar/**/x/**/y' },
		{ path => '/bar/**/d/*' },
		{ path => '/bar/**/t*' },
	);
	#local $Web::ConServe::PathMatch::DEBUG= sub { warn "$_[0]\n" };
	my $matcher= Web::ConServe::PathMatch->new(nodes => \@actions);
	my @tests= (
		[ '/'            => () ],
		[ '/foo'         => () ],
		[ '/foo/3'       => 
			{ %{$actions[1]}, captures => [3] },
			{ %{$actions[3]}, captures => ['',3] },
		],
		[ '/foo/3/'      => () ],
		[ '/foo/3//'     => () ],
		[ '/foo/3/xyz'   => { %{$actions[3]}, captures => [3,'xyz'] } ],
		[ '/foo/3/json'  =>
			{ %{$actions[2]}, captures => [3] },
			{ %{$actions[3]}, captures => [3,'json'] }
		],
		[ '/foo/index.html' =>
			{ %{$actions[0]}, captures => ['index','html'] },
			{ %{$actions[1]}, captures => ['index.html'] },
			{ %{$actions[3]}, captures => ['', 'index.html'] },
		],
		[ '/bar'         => { %{$actions[4]}, captures => [''] } ],
		[ '/bar/'        => { %{$actions[4]}, captures => [''] } ],
		[ '/bar/z'       => { %{$actions[4]}, captures => ['z'] } ],
		[ '/bar/z/'      => { %{$actions[4]}, captures => ['z/'] } ],
		[ '/bar/1/x/2/y' =>
			{ %{$actions[5]}, captures => [1,2] },
			{ %{$actions[4]}, captures => ['1/x/2/y'] },
		],
		[ '/bar/1/a/x/2/y' =>
			{ %{$actions[5]}, captures => ['1/a',2] },
			{ %{$actions[4]}, captures => ['1/a/x/2/y'] },
		],
		[ '/bar/1/x/2/1/2/3/y' =>
			{ %{$actions[5]}, captures => [1,'2/1/2/3'] },
			{ %{$actions[4]}, captures => ['1/x/2/1/2/3/y'] },
		],
		[ '/bar/t' =>
			{ %{$actions[4]}, captures => [ 't' ] },
		],
		[ '/bar/42/d/'   => { %{$actions[4]}, captures => ['42/d/'] } ],
		[ '/bar/d'       => { %{$actions[4]}, captures => ['d'] } ],
		[ '/bar/d/'      => { %{$actions[4]}, captures => ['d/'] } ],
		[ '/bar/d/2'     =>
			{ %{$actions[6]}, captures => ['',2] },
			{ %{$actions[4]}, captures => ['d/2'] },
		],
	);
	for (@tests) {
		my ($path, @expected)= @$_;
		my @actual;
		$matcher->search($path, sub { push @actual, { %{$_[0]}, captures => $_[1] }; 0 });
		is_deeply( \@actual, \@expected, "path $path" )
			or diag explain \@actual;
	}
}

done_testing;
