#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';
use Web::ConServe::Request;

use_ok 'Web::ConServe'
	or BAIL_OUT;

subtest simple_path => \&simple_path;
sub simple_path {
	my @actions= (
		{ path => '/foo' },
		{ path => '/bar' },
		{ path => '/baz' },
	);
	my $c= Web::ConServe->new(actions => \@actions);
	my @tests= (
		[ '/foo' => { %{$actions[0]}, path_match => '/foo', captures => [] } ],
		[ '/bar' => { %{$actions[1]}, path_match => '/bar', captures => [] } ],
		[ '/baz' => { %{$actions[2]}, path_match => '/baz', captures => [] } ],
	);
	for (@tests) {
		my ($path, @expected)= @$_;
		my $env= make_env(PATH_INFO => $path);
		my $req_c= $c->accept_request($env);
		my @found= $req_c->find_actions;
		delete $_->{match_fn} for @found; # can't compare coderef
		is_deeply( \@found, \@expected, "path $path" );
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
	my $c= Web::ConServe->new(actions => \@actions);
	my @tests= (
		[ '/foo'       => () ],
		[ '/foo/1'     => { %{$actions[0]}, path_match => '/foo/1', captures => [1] } ],
		[ '/foo/1/bar' => { %{$actions[1]}, path_match => '/foo/1/bar', captures => [1] } ],
		[ '/foo/bar'   => { %{$actions[0]}, path_match => '/foo/bar', captures => ['bar'] } ],
		[ '/foo2/bar'  => { %{$actions[2]}, path_match => '/foo2/bar', captures => ['o2'] } ],
		[ '/foo2/baz'  => { %{$actions[3]}, path_match => '/foo2/baz', captures => ['2'] } ],
	);
	for (@tests) {
		my ($path, @expected)= @$_;
		my $env= make_env(PATH_INFO => $path);
		my $req_c= $c->accept_request($env);
		my @found= $req_c->find_actions;
		delete $_->{match_fn} for @found; # can't compare coderef
		is_deeply( \@found, \@expected, "path $path" );
	}
}

#use Class::Method::Modifiers;
#around 'Web::ConServe::_conserve_build_action_tree' => sub {
#	my $orig = shift;
#	my $ret = $orig->(@_);
#	diag explain $ret;
#	$ret;
#};

subtest path_with_named_capture => \&path_with_named_capture;
sub path_with_named_capture {
	my @actions= (
		{ path => '/foo/*',     capture_names => ['x'] },
		{ path => '/foo/*/bar', capture_names => ['y'] },
		{ path => '/fo*/bar',   capture_names => ['x'] },
		{ path => '/foo*/baz',  capture_names => ['x'] },
	);
	my $c= Web::ConServe->new(actions => \@actions);
	my @tests= (
		[ '/foo'       => () ],
		[ '/foo/1'     => { %{$actions[0]}, path_match => '/foo/1', captures => [1], captures_by_name => { x => 1 } } ],
		[ '/foo/1/bar' => { %{$actions[1]}, path_match => '/foo/1/bar', captures => [1], captures_by_name => { y => 1 } } ],
		[ '/foo/bar'   => { %{$actions[0]}, path_match => '/foo/bar', captures => ['bar'], captures_by_name => { x => 'bar' } } ],
		[ '/foo2/bar'  => { %{$actions[2]}, path_match => '/foo2/bar', captures => ['o2'], captures_by_name => { x => 'o2' } } ],
		[ '/foo2/baz'  => { %{$actions[3]}, path_match => '/foo2/baz', captures => ['2'], captures_by_name => { x => 2 } } ],
	);
	for (@tests) {
		my ($path, @expected)= @$_;
		my $env= make_env(PATH_INFO => $path);
		my $req_c= $c->accept_request($env);
		my @found= $req_c->find_actions;
		delete $_->{match_fn} for @found; # can't compare coderef
		is_deeply( \@found, \@expected, "path $path" );
	}
}

subtest wildcard_nuances => \&test_wildcard_nuances;
sub test_wildcard_nuances {
	my @actions= (
		{ path => '/foo/*',         capture_names => ['id'] },
		{ path => '/foo/**/json' },
		{ path => '/foo/**/*',      capture_names => ['','x'] },
		{ path => '/bar/**' },
		{ path => '/bar/**/x/**/y' },
	);
	#local $Web::ConServe::DEBUG_FIND_ACTIONS= sub { warn "$_[0]\n" };
	my $c= Web::ConServe->new(actions => \@actions);
	my @tests= (
		[ '/',            => () ],
		[ '/foo',         => () ],
		[ '/foo/3',       => { %{$actions[0]}, path_match => '/foo/3', captures => [3], captures_by_name => { id => 3 } } ],
		[ '/foo/3/xyz',   => { %{$actions[2]}, path_match => '/foo/3/xyz', captures => [3,'xyz'], captures_by_name => { '' => 3, x => 'xyz' } } ],
		[ '/foo/3/json',  => { %{$actions[1]}, path_match => '/foo/3/json', captures => [3], } ],
		[ '/bar/',        => { %{$actions[3]}, path_match => '/bar/', captures => [''] } ],
		[ '/bar',         => { %{$actions[3]}, path_match => '/bar',  captures => [''] } ],
		[ '/bar/z',       => { %{$actions[3]}, path_match => '/bar/',  captures => ['z'] } ],
		[ '/bar/z/',      => { %{$actions[3]}, path_match => '/bar/',  captures => ['z/'] } ],
		[ '/bar/1/x/2/y', => { %{$actions[4]}, path_match => '/bar/1/x/2/y',  captures => [1,2] } ],
		[ '/bar/1/a/x/2/y', => { %{$actions[4]}, path_match => '/bar/1/a/x/2/y',  captures => ['1/a',2] } ],
		[ '/bar/1/x/2/1/2/3/y', => { %{$actions[4]}, path_match => '/bar/1/x/2/1/2/3/y',  captures => [1,'2/1/2/3'] } ],
	);
	for (@tests) {
		my ($path, @expected)= @$_;
		my $env= make_env(PATH_INFO => $path);
		my $req_c= $c->accept_request($env);
		my @found= $req_c->find_actions;
		delete $_->{match_fn} for @found; # can't compare coderef
		is_deeply( \@found, \@expected, "path $path" );
	}
}

done_testing;
