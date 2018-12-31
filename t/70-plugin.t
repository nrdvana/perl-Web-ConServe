#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';
use Web::ConServe;
use Web::ConServe::Plugin;

subtest simple_plugin => \&test_simple_plugin;
sub test_simple_plugin {
	ok( eval(q{
		package ExamplePlugin1; $INC{'ExamplePlugin1.pm'}= 1;
		use Web::ConServe::Plugin '-extend';
		sub plug {
			my $self= shift;
			eval qq{sub $self->{into}::foo { return 42; } 1 } or die $@;
		}
		1;
	}), 'define plugin' ) or diag $@;
	ok( eval(q{
		package ExampleApp1;
		use Web::ConServe '-extend', '-plugins', '+ExamplePlugin1';
		1;
	}), 'define app' ) or diag $@;
	ok( ExampleApp1->can('foo'), 'method foo() added' );
	is( ExampleApp1->foo, 42, 'expected return val' );
	done_testing;
}

subtest plugin_with_role => \&test_plugin_with_role;
sub test_plugin_with_role {
	ok( eval(q{
		package ExamplePlugin2Role; $INC{'ExamplePlugin2Role.pm'}= 1;
		use Moo::Role;
		sub foo { return 43; }
		requires "bar";
		1;
	}), 'defined role' ) or diag $@;
	ok( eval(q{
		package ExamplePlugin2; $INC{'ExamplePlugin2.pm'}= 1;
		use Web::ConServe::Plugin '-extend';
		sub plug {
			main::ok( ! $_[0]->target_will_do('ExamplePlugin2Role'), 'role not queued' ); 
			$_[0]->target_queue_role('ExamplePlugin2Role');
			main::ok( $_[0]->target_will_do('ExamplePlugin2Role'), 'role queued' ); 
		}
		1;
	}), 'defined plugin' ) or diag $@;
	ok( eval(q{
		package ExampleApp2;
		use Web::ConServe '-extend_begin', '-plugins', '+ExamplePlugin2';
		has 'bar' => ( is => 'rw' );
		extend_end;
	}), 'defined app' ) or diag $@;
	
	ok( ExampleApp2->does('ExamplePlugin2Role'), 'role applied' );
	is( ExampleApp2->foo, 43, 'foo returned 43' );
	
	done_testing;
}

done_testing;
