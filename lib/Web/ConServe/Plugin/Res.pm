package Web::ConServe::Plugin::Res;

use Web::ConServe::Plugin -extend;
use Web::ConServe::QuickHttpStatus;
use HTTP::Status;

# ABSTRACT: Export lots of short-hand response notations

=head1 SYNOPSIS

  use Web::ConServe qw/ -parent -plugin Res /;

  sub ... {
     ...
     return res_redirect './foo';
     ...
     return res_redirect_perm '/new_location.html';
     ...
     return res_forbidden 'Invalid API Key';
     ...
     defined $self->param('x') or return res_unprocessable 'x is required';
     ...
     return res_json { a => 1, b => 2 };
  }

=head1 DESCRIPTION

This module exports lots of little convenient functions to return the most
common sorts of responses without much typing.  ...but still specific enough
to hopefully avoid name conflicts. ;-)  Currently all exported symbols start
with "res_" or "http".

You can also use this module as a simple exporter of symbols rather than a
plugin:

  use Web::ConServe::Plugin::Res qw/ http404 res_json /;

=cut

sub plug {
	my $self= shift;
	$self->exporter_also_import(':all');
}

=head1 EXPORTS

=head2 http###

Each of the defined HTTP codes in HTTP::Status becomes a function.  These use the
numbers, since the goal is short-hand.  Show off your hardcore inner geek by
littering your codebase with HTTP status numbers!  Or use these more legible
aliases:

=over 14

=cut

for (grep /^HTTP_/, @HTTP::Status::EXPORT_OK) {
	no strict 'refs';
	my $code= HTTP::Status->$_;
	*{"http$code"}= $EXPORT{"http$code"}=
		sub { Web::ConServe::QuickHttpStatus->new_shorthand($code, @_) };
}

=item res_redirect

http302

=item res_redirect_other

http303

=item res_redirect_perm

http308

=item res_redirect_temp

http307

=item res_badreq

http400

=item res_forbidden

http403

=item res_notfound

http404

=item res_unprocessable

http422

=item res_error

http500

=item res_notimplemented

http501

=item res_unavailable

http503

=item res_timeout

http504

=back

=cut

*res_redirect=      *http302;
*res_redirect_other=*http303;
*res_redirect_perm= *http308;
*res_redirect_temp= *http307;

*res_badreq=        *http400;
*res_forbidden=     *http403;
*res_notfound=      *http404;
*res_unprocessable= *http422;

*res_error=         *http500;
*res_notimplemented=*http501;
*res_unavailable=   *http503;
*res_timeout=       *http504;

export qw(
	res_redirect res_redirect_other res_redirect_perm res_redirect_temp
	res_badreq res_forbidden res_notfound res_unprocessable
	res_error res_notimplemented res_unavailable res_timeout
);

=head2 res_html

  return res_html '<html><body><center>Test</center></body></html>';

Returns the arguments as the content portion of a standard Plack response
with header C<content-type: text/html; charset=UTF-8>.

=head2 res_json

  return res_json { foo => 'bar' };  # from perl
  return res_json '["foo","bar"]';   # raw json

Return the argument as a plack response, converted to json if it wasn't
already, and adds header C<content-type: application/json>.

=cut

# Return something with HTML content type
sub res_html {
	return Plack::Response->new(200, ['Content-Type' => 'text/html; charset=UTF-8'], [@_]);
}

# Return something as JSON
sub res_json {
	my $json= shift;
	if (!ref $json) {
		$json =~ /^[\[\{\"]/ or croak "res_json argument is a scalar that does not appear to be json";
	} else {
		$json= JSON::MaybeXS->new->ascii->canonical->convert_blessed->encode($json);
	}
	return Plack::Response->new(200, ['Content-Type' => 'application/json'], [$json]);
}

export qw( res_html res_json );

1;
