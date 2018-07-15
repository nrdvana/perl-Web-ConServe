package Web::ConServe::Request;
use Moo;
use Carp;
use namespace::clean;
extends 'Plack::Request';

sub BUILDARGS {
	my $class= shift;
	(@_ != 1)? { @_ }
	: defined $_[0]{PATH_INFO}? { env => $_[0] }
	: $_[0]
}

# I would expect FOREIGNBUILDARGS to receive the output of BUILDARGS,
# but it doesn't, so make a redundant call.
sub FOREIGNBUILDARGS {
	shift->BUILDARGS(@_)->{env};
}

has flags              => ( is => 'rw', default => sub { +{} } );
has action             => ( is => 'rw' );
has action_rejects     => ( is => 'rw' );

has capture_parameters => ( is => 'lazy', clearer => 1 );
sub _build_capture_parameters {
	my $self= shift;
	Hash::MultiValue->new(%{ $self->action->{captures_by_name} || {} });
}

has parameters         => ( is => 'lazy', clearer => 1 );
sub _build_parameters {
	my $self= shift;
	Hash::MultiValue->new(
		%{ $self->action->{captures_by_name} || {} },
		@{ $self->_query_parameters },
		@{ $self->_body_parameters }
	);
}

my $warned= 0;
sub param {
	carp "DO NOT USE Plack::Request->param() !!   Use req->parameters or self->param or self->params instead."
		unless $warned++;
	shift->next::method(@_);
}

sub action_inner_env {
	my $self= shift;
	my $env= $self->env;
	# Sanity checks
	$self->action or croak "No action set on request";
	$self->action->{pattern} =~ /\*\*$/ or croak "Action does not end with a wildcard";
	my $path_match= $self->action->{path_match} or croak "Action does not spectify path_match";
	my $remainder= $self->captures->[-1] // '';
	$remainder =~ s,^/*,/,;
	my $base= ($env->{SCRIPT_NAME} // '') . $path_match;
	$base =~ s,/+$,,;
	return {
		%$env,
		SCRIPT_NAME => $base,
		PATH_INFO   => $remainder,
	};
}

1;
