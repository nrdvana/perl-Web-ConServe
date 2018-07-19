package Web::ConServe::QuickHttpStatus;

use Moo;
use Carp;
require Plack::Response;
require JSON::MaybeXS;
require HTTP::Status;
require URI;
use namespace::clean;

# ABSTRACT: Response object for generic HTTP status messages

=head1 DESCRIPTION

This object provides a quick way to return an HTTP status code and also do a
little bit of content negotiation so that it arrives at the user in a useful
manner.

=head1 CONSTRUCTOR

=head2 new_shorthand

  return Web::ConServe::QuickHttpStatus->new_shorthand( 404 => 'No such image' );
  return Web::ConServe::QuickHttpStatus->new_shorthand( 302 => '../../list' );

This method takes a status code, an optional string, and an optional hashref.
The code determines how to interpret the string.  200, 400 and 500 messages use
it as the content, and 300 errors use it as a Location header.

=head2 new

Standard Moo constructor

=cut

our $json_encoder; # lazy-built to JSON::MaybeXS, by default

sub new_shorthand {
	my $class= shift;
	my $code= shift;
	my %args= ( code => $code );
	# If the next argument is not a hashref, then it is either location or message
	if (@_ && ref $_[0] ne 'HASH') {
		if ($code >= 300 && $code < 400) {
			$args{location}= shift;
		} else {
			$args{message}= shift;
		}
	}
	# Optional next argument must be a hashref
	if (@_) {
		ref $_[0] eq 'HASH' && @_ == 1
			or croak "Unexpected extra arguments to QuickHttpStatus constructor";
		@args{keys %{$_[0]}}= values %{$_[0]};
	}
	return $class->new(\%args);
}

sub BUILD {
	my ($self, $args)= @_;
	# These are not true attributes, so need to manually capture them
	for (qw( headers location content_type content_length content_encoding cookies )) {
		$self->$_($args->{$_}) if defined $args->{$_};
	}
}

=head1 ATTRIBUTES

=head2 code

HTTP status code (integer)

=head2 message

Plain text message to be delivered to user.  Can be converted to L</json> or
L</body> if those are not supplied.  Defaults to the official status code
message like "NOT FOUND" (from module L<HTTP::Status>)

=head2 json

Data (not encoded) to be delivered to user, if user accepts JSON.  Defaults to
C<< { message => ..., success => ... } >>.

=head2 body

Content to use as body of request, overriding any other automatic conversions
or guesses.

=head2 plack_response

A L<Plack::Response> object, where you can add headers or further override how
the response will be rendered.

=head2 headers, header, content_type, content_length, content_encoding, location, cookies

These are all aliases to the same attribute of L<Plack::Response>.

=cut

has code    => ( is => 'rw', required => 1 );
has message => ( is => 'rw' );
has json    => ( is => 'rw' );
has body    => ( is => 'rw' );

# use this for all headers activity
has plack_response => ( is => 'lazy', handles => [qw(
	headers
	header
	content_type
	content_length
	content_encoding
	location
	cookies
)] );

sub _build_plack_response { Plack::Response->new(shift->code) }

# Different API than Plack::Response, so don't publish it
sub _finalize {
	my ($self, $env)= @_;
	$self->location($self->_make_location_absolute($env, $self->location))
		if $self->code >= 300 && $self->code < 400 && defined $self->location;
	# If body, return as-is.  Don't guess content-type.
	if (defined $self->body) {
		$self->plack_response->body($self->body);
		return $self->plack_response->finalize;
	}
	# else if http request should have body, then try to generate something
	if (_needs_body($self->code) || defined $self->json || defined $self->message) {
		my $ct= $self->content_type;
		$self->content_type($self->_choose_content_type($env))
			unless $ct;
		$self->plack_response->body($self->_render_body($env));
	} else {
		$self->plack_response->body(['']);
	}
	return $self->plack_response->finalize;
}

sub _make_location_absolute {
	my ($self, $env, $location)= @_;

	# Special cases for relative locations
	if ($location =~ qr,^[/.],) {
		if ($location =~ qr,^[.],) { # relative to dispatched action
			my $action_path= ($env->{'Web_ConServe.action_path'} // $env->{PATH_INFO});
			$location= ($env->{SCRIPT_NAME} // '') . $action_path . '/' . $location;
		}
		else { # else relative to SCRIPT_NAME
			$location= ($env->{SCRIPT_NAME} // '') . $location;
		}
		# path cleanup
		$location =~ s,/(\.?/)+,/,;
		$location =~ s,(/([^/]+)/\.\./), $2 eq '..' ? $1 : '/' ,ge
			if index($location, '/..') >= 0;
	}
	
	my $u= URI->new($location);
	
	$u->scheme($env->{'psgi.url_scheme'})
		unless length $u->scheme;
	
	$u->host($env->{HTTP_HOST} // $env->{SERVER_NAME})
		unless length $u->host;
	
	my $port= $env->{SERVER_PORT};
	$u->port($port)
		unless $u->port == $port;
	
	return "$u";
}

sub _choose_content_type {
	my ($self, $env)= @_;
	# If no content type, guess from Accept header and what fields we have
	my @accept= ($env->{HTTP_ACCEPT} // '') =~ /([^,;]+)/g;
	my $accept_text= grep m|^text/|, @accept;
	my $accept_json= (grep m|/json|, @accept)
		|| ($env->{PATH_INFO} =~ /\.json$/i);
	my $have_json= defined $self->json;
	my $have_message= defined $self->message;
	# Use json if user forced us or client forced us.
	if (($have_json and !$have_message) or ($accept_json and !$accept_text)) {
		return 'application/json';
	}
	# Else use text/plain
	return 'text/plain';
}

my %needs_body= (
	202 => 0, 204 => 0, 205 => 0,
	300 => 1,
);
sub _needs_body {
	my $code= shift;
	return $needs_body{$code} // ($code >= 400? 1 : $code < 300? 1 : 0 );
}

sub _render_body {
	my ($self, $env)= @_;
	# Render the message or json according to outgoing content-type.
	my $ct= $self->content_type;
	if ($ct eq 'application/json') {
		my $json= $self->json // {
			message => $self->message // HTTP::Status::status_message($self->code),
			success => $self->code < 400? \1 : \0,
		};
		$json= ($json_encoder//=JSON::MaybeXS->new->ascii)->encode($json)
			if ref $json;
		return [ $json ];
	}
	else {
		warn "Can't encode message as content type $ct" unless $ct eq 'text/plain';
		return [ $self->message // HTTP::Status::status_message($self->code) ];
	}
}

=head1 METHODS

=head2 to_app

This allows this object to act like a Plack application.  This gives it access
to the request while being rendered, so that it can do things like
intelligently resolve the relative location URLs and inspect the Accept header.

=cut

sub to_app {
	my $self= shift;
	sub { $self->_finalize(@_) }
}

1;
