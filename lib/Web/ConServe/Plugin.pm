package Web::ConServe::Plugin;

use Exporter::Extensible -exporter_setup => 1;
export qw( -plug -extend carp croak );

sub plug {
	# To be overridden by subclasses
}

sub extend {
	my $self= shift;
	$self->exporter_also_import(-exporter_setup => 1, 'carp', 'croak');
}

# Export carp methods that lazy-load carp module
sub carp {
	require Carp; goto &Carp::carp;
}
sub croak {
	require Carp; goto &Carp::croak;
}

1;
