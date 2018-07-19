package Web::ConServe;

use v5.14;
use Moo 2;
use Carp;
use mro;
use Web::ConServe::Request;
use Web::ConServe::PathMatch;
use Const::Fast 'const';
use Module::Runtime;
use HTTP::Status 'status_message';
use namespace::clean;

# ABSTRACT: Conrad's conservative web service framework

=head1 SYNOPSIS

  package MyWebapp;
  use Web::ConServe -parent,      # Automatically set up Moo and base class
    -plugins => qw/ Res /;        # Supports a plugin system
  with 'My::Moo::Role';           # Fully Moo compatible
  
  # Actions are declared with method attributes like Catalyst,
  # but using a path syntax like Web::Simple
  # but the application object is a lot more like CGI::Application.
  # Request and Response are Plack-style.
  # You can return Plack arrayref notation, or use sugar methods
  # for more readable code.
  # There is a minimal but extensible content negotiation system.
  
  sub index : Serve( / ) {
    my $self= shift;
    my $x= $self->param('x')
      or return res_unprocessable('param x is required');
    return res_html("Hello World");
  }
  
  # You get Moo attributes, and can lazy-build.
  # One object is created for the app, and then cloned for each
  # request, preserving any lazy-built attributes from the first
  # instance, but resetting any built during a request.
  
  has user_object => ( is => 'lazy' );
  sub _build_user_object {
    my $self= shift;
    $self->db->resultset('User')->find($self->session->{userid});
  }
  
  # You can match on details of the request
  
  sub user_add : Serve( /users/add POST wants_json we_like_them ) { ... }
  
  # and it's fully customizable
  
  sub BUILD {
    my $self= shift;
    if ($self->req) {
        my $flags= $self->req->flags;
        $flags->{wants_json}= $self->req->header('Accept') =~ /application\/json/;
        $flags->{we_like_them}= $self->req->address =~ /^10\./;
        # you can subclass the request object for prettier code.
    }
  }

=head1 DESCRIPTION

The purpose of ConServe is to provide a minimalist (but still convenient)
base class for writing Plack apps.  To read about why and how, see the
L</DESIGN GOALS> section.  If you want to know how to accomplish common tasks,
see the L<Cookbook|Web::ConServe::Cookbook> page.

=head1 APPLICATION LIFECYCLE

In order to make the most of Web::ConServe, you should be fully aware of how
it operates.  (I think this is true for any tool, which is why I love
minimalist designs.)

=over

=item Compilation

During Perl's compile phase, the L</Serve> annotations on your methods are
parsed and added to a list of actions.  When the first instance of your class
is created, the actions get "compiled" into a search function.  Parent classes
and plugins can also add actions.  You can override many pieces of this process.
See L</actions> and L</search_actions>.

=item Main Object Creation

The class you declared gets created at startup via the normal Moo C<new>
constructor.  Customize the initialization however you normally would with
L<Moo>.

=item Plack App Creation

The main object gets wrapped as a Plack app (coderef) via L</to_app>.
If you want to add Plack middleware as a built-in part of your app, you can
do so by overriding this method.

=item Request Binding

When a new request comes in, the plack app calls L</accept_request> which
clones the main object and sets the L</request> attribute.  You can override
that method, or simply set a custom L</request_class>.

=item Request Dispatch

Next the plack app calls L</dispatch>.  This looks for the best matching
action for the request, then if found, calls that method.  The return value
from the method becomes the response, after pos-processing (described next).

If there was not a matching rule, then the dispatcher sets the response code
as appropriate: 404 for no path match, 405 for no method match, and 422 for
a match that didn't meet custom user conditions.

If the method throws an exception, the default is to let it bubble up the
Plack chain so that you can use Plack middleware to deal with it.  If you want
to trap exceptions, see the role L<Web::ConServe::Plugin::CatchAs500>, or
wrap L</dispatch> with your preferred exception handling.

=item View / Post-processing

The response is then passed to L</view> which converts it to a Plack response
object.  This is another useful point to subclass.  For instance, if you
wanted something like Catalyst's View system, or HTTP content negotiation, you
could add that here.  You can also deal with any custom details or conventions
you came up with for the return values of your actions.

=item Cleanup

You should consider the end of L</view> to be the last point when you can take
any action.  If that isn't enough, L<PSGI> servers might implement the
L<psgix.cleanup|PSGI::Extensions/SPECIFICATION> system for you to use.
Failing that, you could return a PSGI streaming coderef which runs some code
after the last chunk of data has been delivered to the client.

=back

=head1 IMPORTS

  use Web::ConServe qw/ -parent -plugins Foo Bar -with XYZ /;

is equivalent to

  use Moo;
  BEGIN { extends 'Web::ConServe'; }
  use Web::ConServe::Plugin::Foo '-plug';
  use Web::ConServe::Plugin::Bar '-plug';
  BEGIN { with "XYZ"; }

Note that this allows plugins to change the class/role hierarchy as well as
inject symbols into the current package namespace, such as 'sugar' methods.
The roles or parent classes you add here happen at BEGIN-time, saving you
some typing and cleaning up your code.  Plugins are assumed to belong to the
Web::ConServe::Plugin namespace, but roles are not.

=over

=item -parent

Declares that Moo should be invoked, and Web::ConServe should be installed
as the parent class.

=item -plugins

Declares that all following arguments (until the next option flag) are Plugin
package suffixes to the namespace L<Web::ConServe::Plugin>.  Each will be
invoked in a C<BEGIN> block with the option C<-plug> which may have wide-
ranging effects, as documented in the plugin.

=item -extends

Declares that all following arguments (until next option) are class names to
be added using C<< extends "$PKG" >>.

=item -with

Declares that all following arguments (until next option) are role names to be
added using C<< with "$ROLE" >>.

=back

=cut

sub import {
	my ($class, @args)= @_;
	my $caller= caller;
	my ($add_moo, @plug, @extend, @with);
	while (@args) {
		if ($args[0] eq '-parent') {
			shift @args;
			$add_moo= 1;
		}
		elsif ($args[0] eq '-plugins') {
			shift @args;
			while (@args && $args[0] !~ /^-/) { push @plug, shift @args; }
		}
		elsif ($args[0] eq '-with') {
			shift @args;
			while (@args && $args[0] !~ /^-/) { push @with, shift @args; }
		}
		elsif ($args[0] eq '-extends') {
			shift @args;
			while (@args && $args[0] !~ /^-/) { push @extend, shift @args; }
		}
		else {
			croak "Un-handled export requested from Web::ConServe: $args[0]";
		}
	}
	eval 'package '.$caller.'; use Moo; extends "Web::ConServe"; 1' or croak $@
		if $add_moo;
	if (@plug) {
		for (@plug) {
			$_= "Web::ConServe::Plugin::$_";
			Module::Runtime::is_module_name($_) or croak "Invalid plugin name '$_'";
		}
		eval join(';', 'package '.$caller, (map "use $_ '-plug';", @plug), 1) or croak $@;
	}
	eval 'package '.$caller.'; extends @extend; 1' or croak $@
		if @extend;
	eval 'package '.$caller.'; with @with; 1' or croak $@
		if @with;
}

# Default allows subclasses to wrap it with modifiers
sub BUILD {}
sub DESTROY {}

=head1 MAIN API ATTRIBUTES

=head2 actions

Arrayref of all available actions for this object.  Defaults to all the
C<Serve()> attributes in the current class, plus any inherited from parent
classes or plugins.

For example,

  sub foo : Serve( / ) {}
  sub bar : Serve( /bar GET,HEAD,OPTIONS ) {}

becomes

  [
    { handler => \&foo, path => '/' },
    { handler => \&bar, path => '/bar', methods => {GET=>1, HEAD=>1, OPTIONS=>1} },
  ]

It is best not to modify this array, especially not on a per-request instance,
but if you do, don't forget to clear/rebuild the attribute L</actions_cache>.
The action hashrefs are read-only (see L<Const::Fast>).

See L</conserve_register_action> to make class-level changes.

See L</ACTIONS> for the specification of an action.

=head2 actions_cache

This is some unspecified data under the control of L</find_actions> which
might store the result of some compilation process on the list of actions.
If you change the list of actions in any way, you should call
L</clear_actions_cache>.

=cut

has actions           => ( is => 'lazy', clearer => 1, predicate => 1 );
sub _build_actions {
	my $self= shift;
	$self->conserve_actions_for_class(ref $self or $self, inherited => 1);
}

has actions_cache    => ( is => 'lazy', clearer => 1, predicate => 1 );
sub _build_actions_cache {
	my $self= shift;
	Web::ConServe::PathMatch->new(nodes => $self->actions);
}

=head2 app_instance

There are application instances created for use with Plack, and then request
instances created for each incoming request.  If this current instance is
bound to a request, it will have C<app_instance> referencing the object it
was cloned from, and also have L</request> set.

=head2 request_class

The request class that will be used by default.  Setting this might be better
than overriding L</accept_request> if you prefer to use lazy attributes on the
request object instead of doing all the processing up-front.

=head2 request

  $self->req->params->get('x');  # alias 'req' is faster

The request object.  The C<request> (and C<req>) accessor is read-only,
because the request should never change from what was delivered to the
constructor.  It is undefined on the initial application instance, but
set on the per-request instance returned by L</accept_request>.

Override L</accept_request> to control how it is created or add
custom analysis of the incoming request.

=head2 req

Alias for C<< $self->request >>.

=head2 param

  my $x= $self->param('x');

Shortcut for C<< $self->req->parameters->get(...) >>, which ignores list
context and always returns a single value even for multi-valued parameters.

=head2 params

  my @x= $self->params->get_all('x');

Shortcut for C<< $self->req->parameters >>, which is an instance of
L<Hash::MultiValue>.

=cut

has app_instance      => ( is => 'ro' );
has request_class     => ( is => 'rw', default => sub { 'Web::ConServe::Request' } );
has request           => ( is => 'ro', reader => 'req' );
sub request { shift->req }
sub param   { shift->req->parameters->get(@_) }
sub params  { shift->req->parameters }

=head1 MAIN API METHODS

=head2 new

Standard Moo constructor.

=head2 clone

Like C<new>, but inherit all existing attributes of the current instance.
This creates a B<shallow clone>.  Override this if you need to avoid sharing
certain resources between instances.  You might also want to deep-clone
critical attributes to make sure they don't get altered during a request,
or better (on newer Perls) mark them readonly with L<Const::Fast>.

=head2 accept_request

  my $new_instance= $app->accept_request( $plack_env );

Clone the application and initialize the L</request> attribute from the Plack
environment.  The default implementation creates a request from
L</request_class> and then calls L</clone>.

=head2 find_actions

  my (@actions_data)= $app->find_actions( $request );

Return a list of hashrefs, one for each action which had a full path-match
against the request.  The search stops at the first complete match, so the
search was successful if and only if C<< !defined $actions_data[0]{mismatch} >>.
Other actions whose path matched but failed the C<match_fn> (like HTTP Method,
flags, etc) will follow in the list, for debugging purposes and to be able to
return the correct HTTP status code.

Each hashref is a shallow clone of the action, and may have additional fields
describing the result of the match operation.

If you're having trouble with the pattern matching or captures, you can set

  local $Web::ConServe::DEBUG_FIND_ACTIONS= sub { warn "$_[0]\n" };

to get some diagnostics.

=head2 dispatch

  my $something= $app->dispatch; # using app->req

Dispatch a request to an action method, and return the application-specific
result.  If no action matches, it returns an appropriate plack response of an
HTTP error code.

You might choose to wrap this with exception handling, to catch errors from
the controller actions.

=head2 dispatch_fail_response

This analyzes C<< ->req->action_rejects >> to come up with an appropriate HTTP
status code, returned as a plack response arrayref.  It is called internally by
L</dispatch> if there wasn't a matching action.  It is a separate method to
enable easy subclassing or re-use.

=head2 view

  my $plack_result= $app->view( $something );

Convert an application-specific result into a Plack response arrayref.
By default, this checks for objects which are not arrayrefs and have method
C<to_app>, and then runs them as a plack app with a modified PATH_INFO
and SCRIPT_NAME according to which acton got dispatched.  Note that this also
handles L<Plack::Response> objects.

You may customize this however you like, and plugins are likely to wrap it
with method modifiers as well.  Keep in mind though that the best performance
is achieved with custom behavior on the objects you return, rather than lots
of "if" checks after the fact.

=head2 call

Main do-it-all method to handle a Plack request.

  my $plack_result= $app->call( $plack_env );

Calls L</accept_request> to create a new instance with the given plack
environment, then L</dispatch> to create an intermediate response, and then
L</view> to render that response as a proper Plack response.  You might
choose to wrap this with exception handling to trap errors from views.

=head2 to_app

Returns a Plack coderef that calls L</call>.   You might choose to override
this to combine plack middleware with your app, so that the callers don't
need to deal with those details.

=cut

sub clone {
	my $self= shift;
	ref($self)->new(
		%$self,
		(@_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]}
		: (@_ & 1) == 0? @_
		: croak "Expected hashref or even number of key/value"
		)
	);
}

sub accept_request {
	my ($self, $plack_env)= @_;
	$self->actions_cache; # Make sure lazy-initialized before clone
	my $req= $self->request_class->new($plack_env);
	$self->clone(app_instance => $self, request => $req);
}

sub _conserve_find_actions;
*find_actions= *_conserve_find_actions;

sub dispatch {
	my $self= shift;
	my @matches= $self->find_actions($self->req);
	my $action= shift @matches
		if @matches && !defined $matches[0]{mismatch};
	
	$self->req->action($action);
	$self->req->action_rejects(\@matches);
	
	return $action
		? $action->{handler}->($self, @{$action->{captures}})
		: $self->dispatch_fail_response;
}

sub dispatch_fail_response {
	my $self= shift;
	my @rejects= @{ $self->req->action_rejects };
	return [404, [], []]
		unless @rejects;
	# If all matches returned 'mismatch=method', then return 405 Method Not Allowed
	my @not_method_problem= grep $_->{mismatch} ne 'method', @rejects;
	return [$rejects[0]{http_status}//405, [], []]
		unless @not_method_problem;
	# If any match returned 'mismatch=permission', return 403 Forbidden
	my ($forbidden)= grep $_->{mismatch} eq 'permission', @not_method_problem;
	return [$forbidden->{http_status}//403, [], []]
		if defined $forbidden;
	# Else just return first mismatch with default code of 422 Unprocessable
	return [$not_method_problem[0]{http_status}//422, [], []];
}

sub view {
	my ($self, $result)= @_;
	if (ref($result) ne 'ARRAY' && ref($result)->can('to_app')) {
		# save a step for Plack::Response
		return $result->finalize if $result->can('finalize');
		# Else execute a sub-app
		my $sub_app= $result->to_app;
		my $env= $self->req->action_inner_env;
		$sub_app->($env);
	}
	elsif (@$result == 3 && $result->[0] >= 400 && @{$result->[2]} == 0) {
		# If response is a plain HTTP status error, and has no content,
		# add default content.
		push @{$result->[2]}, status_message($result->[0]);
	}
	return $result;
}

sub call {
	my ($self, $env)= @_;
	my $inst= $self->accept_request($env);
	$inst->view($inst->dispatch());
}

sub to_app {
	my $self= shift;
	# Make sure actions_cache is initialized
	$self->actions_cache;
	sub { $self->call(shift) };
}

=head1 IMPLEMENTATION DETAILS

=head2 conserve_actions_for_class

  my $array= Web::ConServe->conserve_actions_for_class($class, %opts);

Return the arrayrefs of actions defined on the classes.

Options:

=over

=item inherited

Include all actions from parent classes of the given class.

=item lvalue

Return the actual arrayref holding the actions, for modification by Plugins,
etc.  Changes are B<not> reflected on existing object instances, only newly
created ones.  Note that all action hashrefs are still read-only.

=back

=head2 conserve_register_action

  $class->conserve_register_action( \%action );

Add an action to the package-level list for C<$class>.  The action is passed to
L<Const::Fast/const> to ensure safe behavior without needing to make copies.

=cut

our %class_actions;  # List of actions, keyed by ->{$class}

sub conserve_actions_for_class {
	my ($self, $class, %opts)= @_;
	if ($opts{inherited}) {
		croak "lvalue and inherited are mutually exclusive" if $opts{lvalue};
		my @all= grep defined, map $class_actions{$_}, @{mro::get_linear_isa($class)};
		return [ map @$_, @all ];
	}
	return ($class_actions{$class} //= [])
		if $opts{lvalue};
	return [ @{ $class_actions{$class} // [] } ];
}

sub conserve_register_action {
	my ($class, $action)= @_;
	ref $class and croak "register_action should be called on a class, not an instance\n"
		."(yes I could just DoWhatYouMean, but there's a good chance you're doing it wrong if you call this on an instance)";
	const my %act => %$action;
	push @{$class_actions{$class}}, \%act;
}

=head2 conserve_parse_action

  my $rule_data= $self->conserve_parse_action( $action_spec, \$err_msg )
                 or croak $err_msg;
  # input:   /foo/:bar/* GET,PUT local_client
  # output:  {
  #            path => '/foo/*/*',
  #            methods => { GET => 1, PUT => 1 },
  #            flags => { local_client => FLAG_TRUE },
  #            capture_names => ['bar',''],
  #            match_fn => sub { ... },
  #          } 

=cut

sub FLAG_TRUE { \1 }
sub conserve_parse_action {
	my ($class, $text, $err_ref)= @_;
	my %action;
	# Remove quotes (which are unnecessary, but users might like for syntax hilighting)
	if ($text =~ /^(["'])(.*?)\g{-2}$/) {
		# TODO: add warnings about mistaken quoted string behavior
		$text= $2;
	}
	for my $part (split / +/, $text) {
		if ($part =~ m,^/,) {
			if (defined $action{path}) {
				$$err_ref= 'Multiple paths defined' if $err_ref;
				return;
			}
			if (index($part, ':') >= 0) {
				# If :NAME, the capture name is 'NAME'
				# If '*', the capture name is empty-string
				$action{capture_names}= [ $part =~ /(?|:(\w+)|\*())/g ];
				# Afterward, replace the name with a '*', for simpler processing
				$part =~ s/:(\w+)/\*/g;
			}
			$action{path}= $part;
		}
		elsif ($part =~ /^[A-Z]/) {
			$action{methods}{$_}++ for split ',', $part;
		}
		elsif ($part =~ /^\w/) {
			my ($name, $value)= split /=/, $part, 2;
			$action{flags}{$name}= defined $value? $value : FLAG_TRUE;
		}
		else {
			$$err_ref= "Can't parse action, at '$part'" if $err_ref;
			return;
		}
	}
	unless (defined $action{path}) {
		$$err_ref= "path is required (starting with leading '/')" if $err_ref;
		return;
	}
	# Every action comes with a match coderef, so that subclasses can wrap
	# eachother's coderef with additional testing or return values.
	$action{match_fn}= $class->_conserve_create_action_match_fn(\%action);
	return \%action;
}

=head2 :Serve(...)

The C<:Serve(...)> code-attributes are simply perl's attribute system,
described in C<perldoc attributes>.  Each time one is encountered during the
initial parse of the class, Perl calls the method L</MODIFY_CODE_ATTRIBUTES>.
The implementation in C<Web::ConServe> filters out C<Serve()> and passes it to
L</conserve_parse_action>, and then passes that to L</conserve_register_action>.

=over

=item If you want to change the way Serve is parsed:

Override method L</conserve_parse_action>.

=item If you want to add other attributes:

Make a new Plugin, then have that plugin add itself as a parent class, then
implement your own C<MODIFY_CODE_ATTRIBUTES> and C<FETCH_CODE_ATTRIBUTES>.

=item If you want to create actions on a class:

Call L</conserve_register_action>.

=item If you want to create actions on an instance:

Clone and modify L</actions> and then call L</clear_actions_cache>.

=back

=cut

our %method_attrs;   # List of attributes keyed by ->{$class}{$coderef}

sub FETCH_CODE_ATTRIBUTES {
	my ($class, $coderef)= (shift, shift);
	my $super= __PACKAGE__->next::can;
	return @{$method_attrs{$class}{$coderef} || []},
		($super? $super->($class, $coderef, @_) : ());
}
sub MODIFY_CODE_ATTRIBUTES {
	my ($class, $coderef)= (shift, shift);
	my $super= __PACKAGE__->next::can;
	my @unknown;
	for (@_) {
		if ($_ =~ /^Serve\((.*?)\)$/) {
			my $action= $class->conserve_parse_action($1, \my $err);
			defined $action or croak "$err, in attribute $_";
			$action->{handler}= $coderef;
			push @{$method_attrs{$class}{$coderef}}, $_;
			$class->conserve_register_action($action);
		}
		else {
			push @unknown, $_;
		}
	}
	return $super? $super->($class, $coderef, @unknown) : @unknown;
}

our $DEBUG_FIND_ACTIONS;
sub _conserve_find_actions {
	my ($self, $req)= @_;
	$req //= $self->req;
	local $Web::ConServe::PathMatch::DEBUG= $DEBUG_FIND_ACTIONS if $DEBUG_FIND_ACTIONS;
	my @result;
	$self->actions_cache->search($req->env->{PATH_INFO}, sub {
		my ($action, $captures)= @_;
		my %info= (
			%$action,
			path_match => $req->env->{PATH_INFO},
			captures   => $captures,
			$action->{match_fn}->($self, $action, $req)
		);
		# If path ends in wildcard, remove the final capture length from the path_match
		if ($action->{path} =~ /\*\*$/ and @$captures) {
			substr($info{path_match}, length($info{path_match}) - length($captures->[-1]))= '';
		}
		# If action defines capture names, build the captures_by_name
		if ($info{capture_names}) {
			my %cap;
			@cap{ @{$info{capture_names}} }= @{ $info{captures} };
			delete $cap{''}; # used as placeholder for un-named captures
			$info{captures_by_name}= \%cap;
		}
		# If match_fn reported a mismatch, keep searching
		if ($info{mismatch}) {
			push @result, \%info;
			return 0;
		} else {
			unshift @result, \%info;
			return 1;
		}
	});
	return @result;
}

sub _conserve_create_action_match_fn {
	my ($class, $action)= @_;
	# TODO: maybe eval this into a more optimized form
	my $methods= $action->{methods};
	my $flags= $action->{flags};
	$methods && $flags? sub {
			return mismatch => 'method'
				unless exists $methods->{$_[2]->env->{REQUEST_METHOD}};
			for (keys %{$flags}) {
				my $expected= $flags->{$_};
				my $actual= $_[2]->flags->{$_};
				return mismatch => 'flag'
					unless defined $actual && $expected eq $actual
						or $expected == FLAG_TRUE && $actual;
			}
			return;
		}
	: $methods? sub {
			return mismatch => 'method'
				unless exists $methods->{$_[2]->env->{REQUEST_METHOD}};
			return;
		}
	: $flags? sub {
			for (keys %{$flags}) {
				my $expected= $flags->{$_};
				my $actual= $_[2]->flags->{$_};
				return mismatch => 'flag'
					unless defined $actual && $expected eq $actual
						or $expected == FLAG_TRUE && $actual;
			}
			return;
		}
	: sub { return; };
}

1;

=head1 ACTIONS

Each action is a plain hashref.  Why not a class? because I expect that
it would be highly likely that multiple plugins would try to add additional
attributes to the Action, and then end up in an inheritance hierarchy war.
Roles could resolve some of this, but then there would still be the hassle
of composing the Action class to conform to the needs of all the plugins,
and the timing of that composition.  The only behavior that needs overridden
anyway is the check for whether an action matches a request, and that can be
done easy enough as a coderef within the hash.

An action has the following pre-defined fields:

  {
    path => '/path/*/**',               # path, with captures
    capture_names => [ 'id', 'x' ],     # optional name of wildcards in path
    handler => sub { ... },             # code to execute when dispatching
    match_fn => sub { ... }             # test whether action matches request
    methods => { $METHOD => 1, ... },   # set of allowed HTTP methods
    flags => { $flag1 => $value1, ... } # set of required flags
  }

=over

=item path

The path must always start with '/'.  A single star character indicates that a
portion of the URL should be captured up to the next '/'.  For instance,
C<'/user*/foo'> can capture the user ID from the URL C<"/user12345/foo">.
If you add a double star at the end of the path, it means that the remainder
of the URL should be captured, but not considered "consumed".  This helps with
dispatching to a sub-controller.  You may also use a double star within the
middle of a path, but this is less efficient and not recommended.  As a special
case, C<'/**'> may match an empty string, and C<'/**/'> may match C<'/'>.

=item capture_names

In the C<Serve(...)> code-attributes, you can use C<':name'> to indicate a
named capture.  That isn't valid in the internal path spec, and what you do
instead is list one name for each wildard in the path.  Use a name of C<''>
for un-named captures.

=item handler

The coderef to execute when dispatching the action.

  handler => sub {
    my ($app_instance, @captures)= @_;
    ...
  }

=item match_fn

The coderef to execute when testing whether an action matches a request.

  match_fn => sub {
    my ($app_instance, $action, $request)= @_;
    ...
  }

This is only called when the path already matches, so it only needs to check
C<method> and C<flags> (and anything else you add).

The return value is B<a list of (key,value) pairs> to include in the search
result of L</find_actions>.  If the action does not match, one of the returned
keys should be C<mismatch>, and the value should indicate why.  The value
C<'method'> indicates an HTTP 405, the value C<'permission'> indicates HTTP
403, and any other value indicates HTTP 422 unless you also customize
L</dispatch_fail_response>.

=item methods

This is a set of the HTTP methods supported by this action.  Method names must
be uppercase.

=item flags

This is a set of key/value pairs which must be found on the request.  These
are entirely user-defined, and the user is responsible for initializing the
C<< $self->req->flags >> for this comparison.

For example, C<< flags => { x => 1 } >> means that C<< $self->req->flags->{x} == 1 >>
must be true.  If you want to indicate that a flag must be true, rather than a
specific value, use C<< flags => { x => Web::ConServe::FLAG_TRUE } >>.

=back

=head1 DESIGN GOALS

In order of priority, the goals are:

=over

=item Be lightweight

The less memory an app consumes, the more workers you can run.
The fewer dependencies you have, the faster you can build docker images.
The more efficient the dispatch cycle, the less processor you need.
Your app restarts faster.

=item Be obvious

The lower the learning curve, the faster a developer can make full use of
a module.  The more obvious the design, the less questions the developer
will have. The simpler the design, the less code you need to write to do
something unusual, and the less hair you pull out tracking down bugs.

=item Be extensible

Nothing is more annoying than finding out that you can't extend a framework in
the way that you want in the time you have available.

=item Be convenient

Somewhat at odds with minimalism, but make sure that users can quickly
accomplish common tasks without jumping through hoops.
I<Don't> force the developer to use the latest fancy fad in programming style
because they won't be used to it and will bog down development.
I<Don't> provide a feature that the programmer can easily add themselves
or that people frequently want to customize.  I<Do> provide recipes for how
to add these common features, or plugins that provide them the common way.

=item Scale

Even though it's simple/lightweight, the framework should be able to scale
to larger applications, because rarely do people actually know the full scope
of a project before they start.

=back

To reach those broad goals, I picked these design features:

=over

=item Single Object Focus

The user's webapp class is used for both the App instance and the per-request
instance, and most behavior happens as methods on this class, giving users the
ability to alter almost any behavior with simple method overriding.

The webapp object is derived from Moo, so it is easy to subclass, and easy to
share behavior using Roles.  Per-request data can be calculated with lazy-built
attributes without worrying about leaking data between requests.

I did also split some of the behavior into the Request object, for clarity,
but I don't anticipare much of it needing to be customized.

=item Public Request Lifecycle

Each step of the request lifecycle is a public part of the API.  There
is little "magic under the hood".  Users can depend on this mechanism remaining
unchanged.  The dispatch mechanism follows a mostly obvious design, and I split
each step into its own small method in hopes that just subclassing or wrapping
these methods can handle any customization that someone needs.

=item Sugar-friendly

The C<use>-line for C<Web::ConServe> has a syntax in the style of a command
line argument list, making it easy to pull in plugins or roles and ask for
other behavior all in a flat list.

With the plugin system allowing both imports and Moo inheritance changes,
this should make everyone's wildest dreams possible while requring a very
minimal declaration at the top of the file.

=item Loose "MVC"

Rather than View and Controller being separate classes, I made the webapp class
itself be the controller, with a suggested but optional C<view>.  Users can
decide the level of abstraction they want here.

The Model is completely up to the user and can be loaded as an attribute.

=item Cached Dispatcher

The most complexity of the entire framework is in the compilation phase of the
dispatcher.  It trees up the available actions in a data structure that allows
efficient search of matching actions, so it should scale to arbitrarily large
applications.  But, the tree isn't public to the API, so the implementation
can change as needed without breaking anything, and users are free to
implement their own if they have a faster way of matching actions.

=item Nestable

Also part of scalability, the Request object has convenience methods to help
dispatch a request to a sub-controller.  You can then create arbitrary trees
of controllers.

=item No Policy Where Not Needed

There a a hundred ways to load configuration into a Moo object, so my opinion
doesn't need to be part of the framework.

There are dozens of ways to deal with exceptions, including Plack middleware,
so I choose a default of not catching them at all.

User sessions can already be handled by Plack middleware, so I defer to that
with examples.  (and those could be wrapped into a Plugin)

There is no official filesystem layout, so users can use whatever layout makes
the most sense for their usage.

Everyone and their cat has a favorite logging system, and even the one for PSGI
is an optional extension.  So let logging be done with an optional Plugin.

=back

=cut

