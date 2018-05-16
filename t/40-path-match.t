#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;

use_ok 'Web::ConServe'
	or BAIL_OUT;

sub make_env {
	return {
		REQUEST_METHOD => 'GET',
		PATH_INFO => '/',
		QUERY_STRING => '',
		SERVER_NAME => 'localhost',
		SERVER_PORT => 0,
		'psgi.version' => [1,1],
		'psgi.url_scheme' => 'https',
		'psgi.input' => undef,
		'psgi.errors' => \*STDERR,
		'psgi.multithread' => 0,
		'psgi.multiprocess' => 0,
		'psgi.run_once' => 0,
		'psgi.nonblocking' => 0,
		'psgi.streaming' => 0,
		@_
	}
}

sub simple_path {
	my $c= Web::ConServe->new();
	my @rules= (
		{ path => '/foo', methods => { GET => 1 } },
		{ path => '/bar', methods => { GET => 1 } },
		{ path => '/baz', methods => { GET => 1 } },
	);
	my $dispatcher= $c->conserve_compile_dispatch_rules(\@rules);
	my @tests= (
		[ '/foo' => 0 ],
		[ '/bar' => 1 ],
		[ '/baz' => 2 ],
	);
	for (@tests) {
		my ($path, $rule_idx)= @$_;
		my $env= make_env(PATH_INFO => $path);
		is_deeply( $dispatcher->($c->clone(plack_environment => $env))->{rule}, $rules[$rule_idx], "path $path" );
	}
}
subtest simple_path => \&simple_path;

sub path_with_capture {
	my $c= Web::ConServe->new();
	my @rules= (
		{ path => '/foo/*',     methods => { GET => 1 } },
		{ path => '/foo/*/bar', methods => { GET => 1 } },
		{ path => '/fo*/bar',   methods => { GET => 1 } },
		{ path => '/foo*/baz',  methods => { GET => 1 } },
	);
	my $dispatcher= $c->conserve_compile_dispatch_rules(\@rules);
	my @tests= (
		[ '/foo'       => 9999 ],
		[ '/foo/1'     => 0 ],
		[ '/foo/1/bar' => 1 ],
		[ '/foo/bar'   => 0 ],
		[ '/foo2/bar'  => 2 ],
		[ '/foo2/baz'  => 3 ],
	);
	for (@tests) {
		my ($path, $rule_idx)= @$_;
		my $env= make_env(PATH_INFO => $path);
		is_deeply( $dispatcher->($c->clone(plack_environment => $env))->{rule}, $rules[$rule_idx], "path $path" );
	}
}
subtest path_with_capture => \&path_with_capture;

done_testing;
