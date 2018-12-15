package Web::ConServe::Plugin::WebSocket;

use Web::ConServe::Plugin -extend;
use AnyEvent;
use AnyEvent::WebSocket::Server;
require Carp;
require Scalar::Util;

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

This plugin applies the role 'Web::ConServe::Plugin::WebSocket::Role' to your class, with the
following attributes and methods:

=cut

sub plug {
	my $self= shift;
	Moo::Role->apply_roles_to_package($self->{into}, 'Web::ConServe::Plugin::WebSocket::Role');
}

=head1 ATTRIBUTES

=head2 websocket

After calling L</websocket_upgrade_connection>, this holds a reference to an instance of
L<AnyEvent::WebSocket::Client>.  When the websocket client receives messages, they get
dispatched to L</dispatch_websocket_message> of this controller instance.

=head2 websocket_id

After calling L<websocket_upgrade_connection>, this is set to a unique-per-parent-instance
ID number.  This ID number is used to distinguish a controller instance from all the others
that have become websocket handlers.  See L</websocket_instances>.

=head2 websocket_instances

This is a hashref located in the app-instance.  When a per-request instance upgrades to a
websocket, it registers itself with the parent and receives the websocket_id to identify it.

To sum it up:

  $self->app_instance->websocket_instances->{$self->websocket_id} == $self

=head1 METHODS

=head2 websocket_upgrade_connection

  sub my_controller :Serve(/some/path) {
    my $self= shift;
    # You probably want to run permission checks here, before proceeding.
    shift->websocket_upgrade_connection

This method takes the Plack environment of the current controller and grabs the file handle
via C<psgix.io>, and then runs a L<AnyEvent::WebSocket::Server> handshake on it.  If the
connection cannot be upgraded, this returns a suitable Plack error response.  If it succeeds,
this will return a suitable Plack streaming coderef response.

=head2 dispatch_websocket_message

You must supply this method.  It may be empty if you don't need it.  It receives the message
as its only parameter.  The C<< $self >> instance this is called on will be the same instance
which originally called L</websocket_upgrade_connection>.  (and yes, this instance will get
destroyed once the websocket closes or when the parent app_instance is destroyed.)

=cut

package Web::ConServe::Plugin::WebSocket::Role {

	use Moo::Role;
	use Log::Any '$log';
	
	# The websocket of this per-request instance
	has websocket           => ( is => 'rw' );
	has websocket_id        => ( is => 'rw' );
	has websocket_instances => ( is => 'lazy', default => sub { +{} } );
	has _websocket_server   => ( is => 'lazy', default => sub { AnyEvent::WebSocket::Server->new } );
	has _websocket_next_id  => ( is => 'rw' );
	has _websocket_psgi_res => ( is => 'rw' );

	sub websocket_upgrade_connection {
		my $self= shift;
		# This method should only be called on per-request instances
		Carp::croak "No request or parent instance - cannot upgrade connection"
			unless $self->req and $self->app_instance;

		my $fh= $self->req->env->{'psgix.io'};
		return [ 501, [], [ 'This server does not support websockets' ]]
			unless $fh;

		my $connections= $self->app_instance->websocket_instances;
		my $id= $self->app_instance->_websocket_next_id // 1;
		$self->websocket_id($id);
		$self->app_instance->_websocket_next_id($id+1);

		$connections->{$id}= $self;
		$log->debug("App $self will become websocket $id");

		Scalar::Util::weaken($self);       # callbacks below should not hold onto these
		Scalar::Util::weaken($connections);#
		$self->app_instance->_websocket_server->establish_psgi($self->req->env)->cb(sub {
			my ($conn)= eval { shift->recv };
			if ($@ || !$self) {
				$log->warn("Rejected connection $id: $@");
				close($fh);
				delete $connections->{$id} if $connections;
				return;
			}
			$self->websocket($conn);
			$conn->on(each_message => sub {
				my ($connection, $message)= @_;
				$log->debug("Message from websocket $id");
				eval { $self && $self->dispatch_websocket_message($message); 1 }
					|| $log->error("${self}->dispatch_websocket_message died: $@")
			});
			$conn->on(finish => sub {
				$log->info("Finishing websocket connection $id");
				close($fh);
				delete $connections->{$id} if $connections;
			});
		});
		return sub {
			# Don't actually want the responder, because the WebSocket::Server handled
			# the response.  Not sure the correct way to handle this... so just never
			# reply to the responder to delay indefinitely?
			my $responder= shift;
			$self->_websocket_psgi_res($responder) if $self;
		};
	}
	
	requires 'dispatch_websocket_message';
};

1;