#! /usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';

use_ok 'Web::ConServe::QuickHttpStatus' or BAIL_OUT;

sub res { Web::ConServe::QuickHttpStatus->new_shorthand(@_) }
# use canonical ordering, for test stability
$Web::ConServe::QuickHttpStatus::json_encoder= JSON::MaybeXS->new->ascii->canonical;

my @tests= (
	{
		name => 'accept text, no message',
		in => [ 200 ],
		env => [ PATH_INFO => '/foo', HTTP_ACCEPT => 'text/plain' ],
		out => [ 200, ['Content-Type','text/plain'], ['OK'] ]
	},
	{
		name => 'json via URI',
		in => [ 200 ],
		env => [ PATH_INFO => '/foo.json' ],
		out => [ 200, ['Content-Type','application/json'], ['{"message":"OK","success":true}'] ]
	},
	{
		name => 'Accept overrides URI',
		in => [ 200 ],
		env => [ PATH_INFO => '/foo.json', HTTP_ACCEPT => 'text/plain' ],
		out => [ 200, ['Content-Type','text/plain'], ['OK'] ]
	},
	{
		name => 'Custom status message',
		in => [ 200, 'Testing 1 2 3' ],
		env => [ PATH_INFO => '/foo.json', HTTP_ACCEPT => 'text/plain' ],
		out => [ 200, ['Content-Type','text/plain'], ['Testing 1 2 3'] ]
	},
	{
		name => 'Json is only option',
		in => [ 200, { json => { a => 1, b => 2 } } ],
		env => [ PATH_INFO => '/foo', HTTP_ACCEPT => 'text/plain' ],
		out => [ 200, ['Content-Type','application/json'], ['{"a":1,"b":2}'] ]
	},
	{
		name => 'Json or html, choose by Accept',
		in => [ 200, "a=1, b=2", { json => { a => 1, b => 2 } } ],
		env => [ PATH_INFO => '/foo', HTTP_ACCEPT => 'text/plain' ],
		out => [ 200, ['Content-Type','text/plain'], ['a=1, b=2'] ]
	},
	{
		name => 'Json or html, choose by Accept',
		in => [ 200, "a=1, b=2", { json => { a => 1, b => 2 } } ],
		env => [ PATH_INFO => '/foo', HTTP_ACCEPT => 'application/json' ],
		out => [ 200, ['Content-Type','application/json'], ['{"a":1,"b":2}'] ]
	},
	
	{
		name => 'Redirect',
		in => [ 302, "/foo/bar/baz" ],
		env => [ HTTP_HOST => 'xyz', SERVER_PORT => 0, PATH_INFO => '/foo', HTTP_ACCEPT => 'application/json' ],
		out => [ 302, ['Location','https://xyz:0/foo/bar/baz'], [''] ]
	},
	{
		name => 'Redirect from script_name',
		in => [ 302, '/bar' ],
		env => [ HTTP_HOST => 'xyz', SERVER_PORT => 443, SCRIPT_NAME => '/foo', PATH_INFO => '/' ],
		out => [ 302, ['Location','https://xyz/foo/bar'], [''] ]
	},
	{
		name => 'Redirect relative to action',
		in => [ 302, './bar' ],
		env => [ HTTP_HOST => 'xyz', SERVER_PORT => 443, SCRIPT_NAME => '/foo', PATH_INFO => '/baz' ],
		out => [ 302, ['Location','https://xyz/foo/baz/bar'], [''] ]
	},
	{
		name => 'Redirect parent dir to action',
		in => [ 302, '../bar' ],
		env => [ HTTP_HOST => 'xyz', SERVER_PORT => 443, SCRIPT_NAME => '/foo', PATH_INFO => '/baz' ],
		out => [ 302, ['Location','https://xyz/foo/bar'], [''] ]
	},
	{
		name => 'Redirect parent dir to action base',
		in => [ 302, '../bar' ],
		env => [ HTTP_HOST => 'xyz', SERVER_PORT => 443, SCRIPT_NAME => '/foo', PATH_INFO => '/baz', 'Web_ConServe.action_path' => '/' ],
		out => [ 302, ['Location','https://xyz/bar'], [''] ]
	},
	
	{
		name => 'Error, json success=false',
		in => [ 400, "Test" ],
		env => [ PATH_INFO => '/foo', HTTP_ACCEPT => 'application/json' ],
		out => [ 400, ['Content-Type','application/json'], ['{"message":"Test","success":false}'] ]
	},
);

for (@tests) {
	my $env= make_env(@{ $_->{env} });
	is_deeply( res(@{ $_->{in} })->to_app->($env), $_->{out}, $_->{name} );
}

done_testing;
