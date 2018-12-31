package Web::ConServe::Plugin::WebSocket;

use Web::ConServe::Plugin -extend;
use AnyEvent;
use AnyEvent::WebSocket::Server;
require Web::ConServe::Plugin::WebSocket::Role;

# ABSTRACT: Upgrade a plack connection to become a websocket

=head1 SYNOPSIS

Create a controller path for initiating the websocket:

  use Web::ConServe -parent, -plugins => 'WebSocket';

  sub ws :Serve('/ws') {
    my $self= shift;
    return $self->websocket_upgrade_connection;
  }

Create a method to handle the incoming websocket messages:

  sub dispatch_websocket_message {
    my ($self, $message)= @_;
    # $message is an instance of AnyEvent::WebSocket::Message
    ...
  }

Send websocket messages:

  # to the client connected to this instance
  # ->websocket is an instance of AnyEvent::WebSocket::Client
  $self->websocket->send("Hello World");
  
  # to all ws clients connected to any instance of this app:
  for (values $self->app_instance->websocket_instances->%*) {
    next if $_ == $self;
    say "Sending to client " . $_->websocket_id;
    $_->websocket->send($message);
  }

=head1 DESCRIPTION

This plugin applies the role L<Web::ConServe::Plugin::WebSocket::Role> to your class.
See that package for details.

=cut

sub plug {
	my $self= shift;
	$self->target_queue_role('Web::ConServe::Plugin::WebSocket::Role');
}

1;