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

sub simple_path {
	my $c= Web::ConServe->new();
	my @actions= (
		{ path => '/foo', methods => { GET => 1 } },
		{ path => '/bar', methods => { GET => 1 } },
		{ path => '/baz', methods => { GET => 1 } },
	);
	my $search_fn= $c->conserve_compile_actions(\@actions);
	my @tests= (
		[ '/foo' => { %{$actions[0]}, path_match => '/foo', captures => [] } ],
		[ '/bar' => { %{$actions[1]}, path_match => '/bar', captures => [] } ],
		[ '/baz' => { %{$actions[2]}, path_match => '/baz', captures => [] } ],
	);
	for (@tests) {
		my ($path, $action_info)= @$_;
		my $env= make_env(PATH_INFO => $path);
		my $req_c= $c->accept_request($env);
		is_deeply( [$search_fn->($req_c)], [$action_info], "path $path" );
	}
}
subtest simple_path => \&simple_path;

sub path_with_capture {
	my $c= Web::ConServe->new();
	my @actions= (
		{ path => '/foo/*',     methods => { GET => 1 } },
		{ path => '/foo/*/bar', methods => { GET => 1 } },
		{ path => '/fo*/bar',   methods => { GET => 1 } },
		{ path => '/foo*/baz',  methods => { GET => 1 } },
	);
	my $search_fn= $c->conserve_compile_actions(\@actions);
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
		is_deeply( [$search_fn->($req_c)], \@expected, "path $path" );
	}
}
subtest path_with_capture => \&path_with_capture;

#use Class::Method::Modifiers;
#around 'Web::ConServe::_conserve_build_action_tree' => sub {
#	my $orig = shift;
#	my $ret = $orig->(@_);
#	diag explain $ret;
#	$ret;
#};

sub path_with_named_capture {
	my $c= Web::ConServe->new();
	my @actions= (
		{ path => '/foo/*',     methods => { GET => 1 }, capture_names => ['x'] },
		{ path => '/foo/*/bar', methods => { GET => 1 }, capture_names => ['y'] },
		{ path => '/fo*/bar',   methods => { GET => 1 }, capture_names => ['x'] },
		{ path => '/foo*/baz',  methods => { GET => 1 }, capture_names => ['x'] },
	);
	my $search_fn= $c->conserve_compile_actions(\@actions);
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
		is_deeply( [$search_fn->($req_c)], \@expected, "path $path" );
	}
}
subtest path_with_named_capture => \&path_with_named_capture;

done_testing;
