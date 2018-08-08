#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use ConServeTestUtil ':all';
use Plack::Test;
use HTTP::Request::Common qw( GET POST );

package ArrayApp {
	use Web::ConServe -parent, -plugins => 'Res';
	use Try::Tiny;

	has things => ( is => 'rw', required => 1 );

	sub list_things :Serve( GET /thing/ ) {
		my $self= shift;
		return res_json($self->things);
	}
	sub create_thing :Serve( POST /thing/ ) {
		my $self= shift;
		push @{ $self->things }, { name => $self->param('name') };
		return res_redirect('/thing/'.$#{$self->things});
	}
	sub get_thing :Serve( GET /thing/:id ) {
		my ($self, $id)= @_;
		$id >= 0 && $id < @{$self->things}
			or return res_notfound;
		return res_json($self->things->[$id]);
	}
	#around call => sub {
	#	my ($orig, @args)= @_;
	#	try {
	#		$orig->(@args);
	#	} finally {
	#		warn $_[0] if @_;
	#	};
	#};
};

my $t= Plack::Test->create(ArrayApp->new(things=>[])->to_app);
my @tests= (
	[ 'Nothing at root', (GET '/'), 404 ],
	[ 'Empty array',     (GET '/thing/'), 200, '[]' ],
	[ 'Create elem 0',   (POST '/thing/', [ name => 'Foo' ]), 302 ],
	[ 'Get elem 0',      (GET '/thing/0'), 200, '{"name":"Foo"}' ],
	[ 'Create elem 1',   (POST '/thing/', [ name => 'Bar' ]), 302 ],
	[ 'Get elem 0',      (GET '/thing/0'), 200, '{"name":"Foo"}' ],
	[ 'Get elem 1',      (GET '/thing/1'), 200, '{"name":"Bar"}' ],
);
for (@tests) {
	my ($name, $req, $res_code, $res_content)= @$_;
	my $res= $t->request($req);
	is( $res->code, $res_code, $name .' response code' );
	is( $res->decoded_content, $res_content, $name . ' response content' )
		if defined $res_content;
}

done_testing;
