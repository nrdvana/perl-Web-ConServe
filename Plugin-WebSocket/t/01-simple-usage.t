#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;

use_ok('Web::ConServe::Plugin::WebSocket');

package Example1;
use Web::ConServe -extend, -plugins => "WebSocket";
sub dispatch_websocket_message { return 2; }

package main;

ok( Example1->can('websocket'), 'role applied' );
is( Example1->dispatch_websocket_message, 2, 'got our version of dispatch');

done_testing;
