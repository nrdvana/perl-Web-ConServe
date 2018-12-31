package Web::ConServe::Plugin;

# ABSTRACT: Base class for Web::ConServe plugins

=head1 SYNOPSIS

  package Web::ConServe::Plugin::MyPlugin;
  use Web::ConServe::Plugin '-extend';
  sub plug {
    my $self= shift;
    $self->target_queue_role('My::Role');
    $self->exporter_also_import('util_function');
  }
  sub util_function :Export {
    ...
  }
  1;

=head1 DESCRIPTION

This base class sets up a plugin module which exports various symbols.  The plugin is not a Moo
class or Role; it should only define exportable functions and behavior (such as adding other
roles to the target package)

This class is built on L<Exporter::Extensible>, so you may use anything in that API for
declaring what to export.  The only mandatory export is C<-plug>, and it is already exported
so all you need to do is override the C<< sub plug {} >> method to do whatever you want your
plugin to do by default.

Since applying a role to the web app is probably the most common thing for a plugin to do, and
because this can be awkward to do from within a C<BEGIN> block, this module also provides a few
methods to assist with delayed application of roles to the target.  See L</target_queue_role>.

=cut

use Exporter::Extensible -exporter_setup => 1;
use Web::ConServe 'apply_role_at_end','add_base_class';
use Carp 'carp','croak';
export qw( -plug -extend carp croak );

=head1 EXPORTS

=head2 -extend

Alias for C<< qw/ -exporter_setup 1 carp croak / >>.

=head2 -plug

See L</plug>.

=head2 carp, croak

These functions from the Carp package are exportable, for convenience.

=cut

sub extend {
	my $self= shift;
	$self->exporter_also_import(-exporter_setup => 1, 'carp', 'croak');
}

=head1 METHODS

=head2 plug

This is the main method of a plugin.  The actions most likely to appear here are
L</target_queue_role> to apply roles to the consuming web app at the end of the BEGIN phase, or
L<Exporter::Extensible/exporter_also_import> to cause additional symbols to be imported into
the consuming app.

  sub plug {
    my $self= shift;
    $self->target_queue_role("MyRole");
    $self->exporter_also_import(":constants");
  }

=cut

sub plug {
	# To be overridden by subclasses
}

=head2 target_add_base_class

Adds another base class to the web app (in addition to Web::ConServe) unless the base class
already inherits from that class.  The effect is immediate.

=head2 target_queue_role

Applies a role to the target web app, but waits until after the BEGIN blocks.  More precisely,
it waits until L<Web::ConServe::Export/export_end>, which by default is called at the end of
the compilation phase of the target module.  This allows Perl to see all the methods of the
user's package before the role starts to inject and wrap methods, which is probably what you
wanted.

=head2 target_will_do

  my $bool= $self->target_will_do('Some::Role');

This tests whether the target C<< ->does('Some::Role') >> or if that role has been queued to
be applied later.

=head2 target_pending_roles

Returns B<the> arrayref of queued roles, if any roles are queued for the target class, else it
returns C<undef>.  If your plugin really needs to, it can use this to change the order that the
roles will be applied.

=cut

sub target_add_base_class {
	my $self= shift;
	add_base_class($self->{into}, @_);
}

sub target_queue_role {
	my $self= shift;
	apply_role_at_end($self->{into}, @_);
}

sub target_will_do {
	my ($self, $role)= @_;
	my $into= $self->{into};
	return $into->does($role)
		|| scalar grep $_ eq $role, @{ $self->target_pending_roles // [] };
}

sub target_pending_roles {
	my $self= shift;
	my $ext= $Web::ConServe::Exports::extend_in_progress{$self->{into}};
	$ext? $ext->pending_roles : undef;
}

1;
