package Web::ConServe::Request;

use Moo;
use Carp;
use namespace::clean;
extends 'Plack::Request';

# ABSTRACT: Extended Plack::Request object used by Web::ConServe

=head1 DESCRIPTION

This subclass of L<Plack::Request> adds several L<Web::ConServe>-specific
details, like L</flags>, L</action> and so on.  It is also L<Moo>-based, for
easier further subclassing.

=head1 CONSTRUCTOR

  Web::ConServe::Request->new( \%moo_attributes );
  Web::ConServe::Request->new( \%plack_env );

The constructor of Plack::Request takes a hashref of the Plack environment.
This isn't a convenient default for extending with Moo, but I did it anyway!
If you pass a hashref that has the plack-specific required key 'PATH_INFO',
then the hashref is treated as the L</env> attribute.  Else the hashref is
handled as a normal Moo hash of attributes.

=cut

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

=head1 ATTRIBUTES

See L<Plack::Request> for inherited attributes.

=head2 flags

A hashref of user-defined flags, optionally used for action matching.

=head2 action

The matching action, if any.  This is assigned by L<Web::ConServe/dispatch>.

=head2 action_rejects

An arrayref of actions which had matching paths but failed the match for other
reasons (like method or flags).  This is assigned by L<Web::ConServe/dispatch>.

=head2 capture_parameters

A L<Hash::MultiValue> of any parameters captured from the URL.  This is lazy-
built from the L</action>.  (don't access it before C<action> has been set)

=head2 parameters

In Plack::Request, C<parameters> is a combination of query params and body
params.  In this classs, it also include L</capture_parameters>.

=head2 action_inner_env

If the current action ends with wildcard C<**>, then it implies that you
wanted to take the remainder of the URL and do something with it, possibly
forwarding it to an inner controller.  This method returns a Plack
environment for that inner controller, with an adjusted C<SCRIPT_NAME>
and C<PATH_INFO>.  Lazy-built.  Throws an exception if action doesn't end in
wildcard.

=cut

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
		(exists $self->action->{captures_by_name}? %{ $self->action->{captures_by_name} } : () ),
		$self->query_parameters->flatten,
		$self->body_parameters->flatten,
	);
}

my $warned= 0;
sub param {
	carp "DO NOT USE Plack::Request->param() !!   Use req->parameters or self->param or self->params instead."
		unless $warned++;
	shift->next::method(@_);
}

has action_inner_env => ( is => 'lazy', clearer => 1 );
sub _build_action_inner_env {
	my $self= shift;
	my $env= $self->env;
	# Sanity checks
	$self->action or croak "No action set on request";
	#$self->action->{path} =~ /\*\*$/ or croak "Action does not end with a wildcard";
	my $path_match= $self->action->{path_match} or croak "Action does not spectify path_match";
	my $remainder= $self->action->{captures}[-1] // '';
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
