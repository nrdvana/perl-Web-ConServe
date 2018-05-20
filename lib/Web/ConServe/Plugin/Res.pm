package Web::ConServe::Plugin::Res;
use strict;
use warnings;
use Carp 'croak';
use Web::ConServe::QuickHttpStatus;
use Exporter;

sub import {
	# If argument is '-plug', then substitute the default plugin behaviors
	for (0..$#_) {
		splice(@_, $_, 1, ':all') if $_[$_] eq '-plug';
	}
	goto \&Exporter::import;
}

our @EXPORT_OK= qw(
	res_redirect res_redirect_other res_redirect_perm res_redirect_temp
	res_badreq res_forbidden res_notfound res_unprocessable
	res_error res_notimplemented res_unavailable res_timeout
	res_html res_json
);
our %EXPORT_TAGS= ( all => \@EXPORT_OK );

for (keys %Web::ConServe::QuickHttpStatus::known_status_codes) {
	no strict 'refs';
	my $code= $_;
	*{push @EXPORT_OK, "http$_"}= sub { Web::ConServe::QuickHttpStatus->new_shorthand($code, @_) };
}

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

1;
