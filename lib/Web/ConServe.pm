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
use B::Hooks::EndOfScope;
use namespace::clean;

# ABSTRACT: Conrad's conservative web service framework

=head1 SYNOPSIS

  package MyWebapp;
  use Web::ConServe -parent, -plugins => 'Res';
  
  has things => ( is => 'rw', required => 1 );
  
  sub list_things :Serve( GET /thing/ ) {
    my $self= shift;
    return res_json($self->things);
  }
  sub create_thing :Serve( POST /thing/ ) {
    my $self= shift;
    push @{ $self->things }, { name => $self->param('name') };
    return res_redirect('/thing/'.$#{$self->things});
  }
  sub get_thing :Serve( GET /thing/:id ) {
    my ($self, $id)= @_;
    $id >= 0 && $id < @{$self->things}
      or return res_notfound;
    return res_json($self->things->[$id]);
  }

  require MyWebapp;
  MyWebapp->new(things => [])->to_app;

=head1 DESCRIPTION

This little framework is the result of many observations I've made over the
years of using of other web frameworks.  In a language that advertises There
Is More Than One Way To Do It, the main web frameworks tend to make an awful
lot of decisions for you, including a lot of small "bikeshed" details, and
end up with a large learning curve.
Two notable exceptions are L<Plack> and L<Web::Simple>.  While I appreciate
their minimalism, after testing them on some real-world projects I find them
lacking in convenience for common problems.

The purpose of Web::ConServe is to provide a minimalist but convenient and
highly flexible base class for writing Plack apps.  It aims to be a sensible
starting point for small or large projects rather than a pre-made one-stop
solution.  The L</APPLICATION LIFECYCLE> section tells you pretty much all
you need to know about the design, and if you're already familiar with Plack
then the learning curve should be pretty small.

=head1 NOTABLE FEATURES

  package MyWebapp;
  use Web::ConServe -parent,      # Automatically set up Moo and base class
    -plugins => qw/ Res /;        # Supports a plugin system
  with 'My::Moo::Role';           # Fully Moo compatible
  
  # Actions are declared with method attributes like Catalyst,
  # but using a path syntax like Dancer or Web::Simple
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
    # 'db' and 'session' are attributes you define yourself, or via plugins
    $self->db->resultset('User')->find($self->session->{userid});
  }
  
  # You can match on user-defined details of the request.
  # Just set flags on the incoming request, then match them in the action.
  
  sub BUILD {
    my $self= shift;
    if ($self->req) {
        my $flags= $self->req->flags;
        $flags->{wants_json}= $self->req->header('Accept') =~ /application\/json/i;
        $flags->{we_like_them}= $self->req->address =~ /^10\./;
    }
  }
  
  sub user_add : Serve( POST /users/add wants_json we_like_them ) { ... }

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

The class you declared gets created via the normal Moo C<new> constructor.
Customize the initialization however you normally would with L<Moo>.
One or more application instance might be created in construction of a Plack
app hierarchy.

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

If there was not a matching rule, then L</dispatch> sets the response code
as appropriate: 404 for no path match, 405 for no method match, and 422 for
a match that didn't meet custom user conditions.

If the action method throws an exception, the default is to let it bubble up
the Plack chain so that you can use Plack middleware to deal with it. If you
want to trap exceptions, see the role L<Web::ConServe::Plugin::CatchAs500>,
or wrap L</dispatch> with your preferred exception handling.

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

  use Web::ConServe qw/ -extend -plugins Foo Bar -with XYZ /;

is equivalent to

  use Moo;
  BEGIN { extends 'Web::ConServe'; }
  use Web::ConServe::Plugin::Foo '-plug';
  use Web::ConServe::Plugin::Bar '-plug';
  ...
  # end_of_scope
  with "XYZ";

Note that this allows plugins to change the class/role hierarchy as well as
inject symbols into the current package namespace, such as 'sugar' methods.
The parent classes you add here happen at BEGIN-time, and the roles you add
happen at the end of the compilation phase, saving you some boilerplate and
cleaning up your code.

=over

=item -extend

Sets the current package to extend from Web::ConServe, and initialize Moo
for the current package.  You must also call C<<extend_end;>> at the end of
your package., and also initializes
some things for the plugin system.  Always specify this flag when creating a
new Web::ConServe application (unless you have a good reason not to).  You
must also then specify C<<extend_end;>> at the end of your package (or any
time earlier).

This gives you the effect of C<< use Moo; BEGIN { extends 'Web::ConServe'; } >>
including enabling strict and warnings.

Note that omitting this flag allows you to use or export things from
Web::ConServe without defining a new application.

=item -plugins

Declares that all following arguments (until the next option flag) are Plugin
names, which by default are suffixes to the namespace L<Web::ConServe::Plugin>.
You can specify an absolute package name by prefixing it with C<+>.
Each will be invoked in a C<BEGIN> block with the option C<-plug> which may
have wide-ranging effects, as documented in the plugin.

=item -extends

Declares that all following arguments (until next option) are class names to
be added using C<< extends "$PKG" >>.

=item -with

Declares that all following arguments (until next option) are role names to be
added using C<< with "$ROLE" >>.  Roles are added at the *end* of the code in
the module, to allow role features like C<requires> to work better.

=back

=cut

sub import {
	my $class= shift;
	local $Carp::Internal{(__PACKAGE__)}= 1;
	Web::ConServe::Exports->import_into(scalar(caller), @_);
}
package Web::ConServe::Exports {
	use Exporter::Extensible -exporter_setup => 1;
	export qw( -extend -extend_begin -extend_end extend_end -plugins(*) -with(*) -extends(*) add_base_class apply_role_at_end );

	sub pending_roles { $_[0]{pending_roles} //= [] }
	sub has_pending_roles { defined $_[0]{pending_roles} }

	sub pending_methods { $_[0]{pending_methods} //= [] }
	sub has_pending_methods { defined $_[0]{pending_methods} }

	our %extend_in_progress;
	sub extend {
		my $self= shift;
		$self->extend_begin;
		B::Hooks::EndOfScope::on_scope_end(sub { $self->extend_end });
	}
	sub extend_begin {
		my $self= shift;
		my $pkg= $self->{into};
		$pkg && !ref $pkg
			or Carp::croak("-extend can only be applied to packages");
		eval 'package '.$pkg.'; use Moo; extends "Web::ConServe"; 1'
			or Carp::croak($@);
		$extend_in_progress{$pkg}= $self;
		$self->exporter_also_import('extend_end');
	}
	sub extend_end {
		my $self= shift;
		unless (ref $self) {
			$self //= caller;
			$self= $extend_in_progress{$self} or return;
		}
		# Apply roles that were waiting for the end of compilation
		if ($self->has_pending_roles) {
			my $with= $self->{into}->can('with');
			$with? $with->(@{$self->pending_roles})
			: Moo::Role->apply_roles_to_package($self->{into}, @{$self->pending_roles});
			delete $self->{pending_roles};
		}
		# Run any code that needs to be run
		if ($self->has_pending_methods) {
			$self->$_ for @{ $self->pending_methods };
			delete $self->{pending_methods};
		}
		delete $extend_in_progress{$self->{into}};
	}
	
	sub _args_til_next_opt {
		my @list;
		for (@_) {
			last if $_ =~ /^[^+A-Z]/;
			push @list, $_;
		}
		@list;
	}

	sub plugins {
		my $self= shift;
		my @plug= &_args_til_next_opt;
		for my $name (@plug) {
			$name= $name =~ /^\+/? substr($name,1) : 'Web::ConServe::Plugin::'.$name;
			Module::Runtime::require_module($name);
			$name->import_into($self->{into}, '-plug');
		}
		return scalar @plug;
	}

	sub with {
		my $self= shift;
		my @list= &_args_til_next_opt;
		apply_role_at_end($self->{into}, @list);
		return scalar @list;
	}

	sub extends {
		my $self= shift;
		my @list= &_args_til_next_opt;
		eval 'package '.$self->{into}.'; extends @list; 1' or Carp::croak($@)
			if @list;
		return scalar @list;
	}

	# Exportable function for use as back-end equivalent of Moo's 'extends "Foo";'
	sub add_base_class {
		my $pkg= shift;
		no strict 'refs';
		my @current= @{ $pkg . '::ISA' };
		$pkg->isa($_) or push @current, $_
			for @_;
		my $ex= $pkg->can('extends')
			or Carp::croak("Package $pkg does not currently define function 'extends'");
		$ex->(@current);
	}

	# Exportable function that acts like Moo's 'with "Foo";', but applies after the BEGIN blocks
	sub apply_role_at_end {
		my ($pkg, @roles)= @_;
		if ($extend_in_progress{$pkg}) {
			push @{ $extend_in_progress{$pkg}{pending_roles} }, @roles;
		} else {
			my $apply= $pkg->can('with');
			$apply? $apply->(@roles)
			: Moo::Role->apply_roles_to_package($pkg, @roles);
		}
	}
};

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

The class to use for incoming requests.  The class must take a Plack C<$env> as
a constructor parameter.  Setting this to a custom class allows you to use lazy
attributes on the request object rather than overriding L</accept_request> and
doing all the processing up-front.

=head2 request

  $self->req->params->get('x');  # alias 'req' is preferred

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

=head2 to_app

Returns a Plack coderef that calls L</call>.   You might choose to override
this to combine plack middleware with your app, so that the callers don't
need to deal with those details.

=head2 call

Main do-it-all method to handle a Plack request.

  my $plack_result= $app->call( $plack_env );

Calls L</accept_request> to create a new instance with the given plack
environment, then L</dispatch> to create an intermediate response, and then
L</view> to render that response as a proper Plack response.  You might
choose to wrap this with exception handling to trap errors from views.

=cut

sub to_app {
	my $self= shift;
	sub { $self->call(shift) };
}

sub call {
	my ($self, $env)= @_;
	# Make sure actions_cache is initialized
	$self->actions_cache;
	my $inst= $self->accept_request($env);
	$inst->view($inst->dispatch());
}

=head2 accept_request

  my $new_instance= $app->accept_request( $plack_env );

Clone the application and initialize the L</request> attribute from the Plack
environment.  The default implementation creates a request from
L</request_class> and then calls L</clone>.

=head2 clone

Like C<new>, but inherit all existing attributes of the current instance.
This creates a B<shallow clone>.  Override this if you need to avoid sharing
certain resources between instances.  You might also want to deep-clone
critical attributes to make sure they don't get altered during a request,
or better (on newer Perls) mark them readonly with L<Const::Fast>.

=cut

sub accept_request {
	my ($self, $plack_env)= @_;
	$self->actions_cache; # Make sure lazy-initialized before clone
	my $req= $self->request_class->new($plack_env);
	$self->clone(app_instance => $self, request => $req);
}

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

=head2 dispatch

  my $something= $app->dispatch; # using app->req

Dispatch a request to an action method, and return the application-specific
result.  If no action matches, it returns an appropriate plack response of an
HTTP error code.  This method populates C<< req->action >> and
C<< req->action_rejects >>.

You might choose to wrap this with exception handling, to catch errors from
the controller actions.

=head2 find_actions

  my (@actions_data)= $app->find_actions( $request );

Return a list of hashrefs, each one an expanded copy of an action whose path
matched.  The following official fields can be added, in addition to anything
the match function returns.

=over

=item path_match

The portion of the path which matched the action's pattern not including a
final C<**> pattern.  This assists with setting up nested controllers.

=item captures

The arrayref of strings captured from the URI.
(one for each wildcard or place-holder in the pattern)

=item capture_by_name

If any captures were named, this is a hashref of C<< $name => $value >>.

=item mismatch

If the action failed to match, this is the reason.

=back

The action data are returned in the reverse order they were tested,
and the search stops at the first complete match, so the search was
successful if and only if C<< !defined $actions_data[0]{mismatch} >>.
Other actions whose path matched but failed the C<match_fn> (like HTTP Method,
flags, etc) will follow in the list, for debugging purposes and to be able to
return the correct HTTP status code.

See L<Web::ConServe::PathMatch> for details on which matches take priority,
and notes on debugging.

=head2 dispatch_fail_response

This analyzes C<< ->req->action_rejects >> to come up with an appropriate HTTP
status code, returned as a plack response arrayref.  It is called internally by
L</dispatch> if there wasn't a matching action.  It is a separate method to
enable easy subclassing or re-use.

=cut

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

=head2 view

  my $plack_result= $app->view( $something );

Convert an application-specific result into a Plack response arrayref/coderef.
By default, this checks for blessed objects which have method C<to_app>, and
then runs them as a plack app with a modified C<PATH_INFO> and C<SCRIPT_NAME>
according to which action got dispatched.  Note that this also handles
L<Plack::Response> objects.

You may customize this however you like, and plugins are likely to wrap it
with method modifiers as well.  Keep in mind though that the best performance
is achieved with custom behavior on the objects you return, rather than lots
of "if" checks after the fact.

=cut

sub view {
	my ($self, $result)= @_;
	if (ref($result) eq 'ARRAY') {
		if (@$result == 3 && $result->[0] >= 400 && @{$result->[2]} == 0) {
			# If response is a plain HTTP status error, and has no content,
			# add default content.
			push @{$result->[2]}, status_message($result->[0]);
		}
	}
	elsif (ref($result) && ref($result)->can('to_app')) {
		# Save a step for Plack::Response
		return $result->finalize if $result->can('finalize');
		# Else execute another app
		return $result->to_app->($self->req->env);
	}
	return $result;
}

=head1 IMPLEMENTATION DETAILS

=head2 conserve_actions_for_class

  my $array= Web::ConServe->conserve_actions_for_class($class, %opts);

Return an arrayref of actions defined on the classes.

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
  # input:   "/foo/:bar/* GET,PUT local_client"
  # output:  {
  #            path => '/foo/*/*',
  #            methods => { GET => 1, PUT => 1 },
  #            flags => { local_client => FLAG_TRUE },
  #            capture_names => ['bar',''],
  #            match_fn => sub { ... },
  #          } 

=cut

use constant FLAG_TRUE => \1;
sub conserve_parse_action {
	my ($class, $text, $err_ref)= @_;
	my %action;
	# Remove quotes (which are unnecessary, but users might like for syntax hilighting)
	if ($text =~ /^(["'])(.*?)\g{-2}$/) {
		# TODO: add warnings about mistaken quoted string behavior
		$text= $2;
	}
	for my $part (grep length, split / +/, $text) {
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

sub _conserve_find_actions {
	my ($self, $req)= @_;
	$req //= $self->req;
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
    flags => { $flag1 => $value1, ... } # set of required user-defined flags
  }

=over

=item path

The path must always start with '/', and must have all its named captures
replaced with C<*> or C<**>.  See <Web::ConServe::PathMatch> for details
about patterns and priorities.

=item capture_names

In the C<Serve(...)> code-attributes, paths may contain C<':name'> to indicate
a named capture.  That isn't valid for the C<path> spec, so those names are
moved to this array after parsing.  Use a name of C<''> for un-named captures.

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

=head1 SEE ALSO

=over

=item L<PSGI> / L<Plack>

Interface specification and tools to make web apps and web servers more inter-
operable.

=item L<Plack::Builder>

Module for defining an app as a composition of other apps "mounted" at paths.
Based on manually-written objects.

Great for combining smaller apps, but not something you'd want to build a
large-scale app with.

=item L<Catalyst>

Full-featured web service framework with emphasis on MVC structure and methods
that get automatically invoked in sequence. Moose-based.  Supports (and now
heavily based on) Plack.

Downsides: lots of dependencies, and makes OO programming awkward with separate
controller and context variables that need passed around everywhere.
Also has a big learning curve.

=item L<Dancer>

Full-featured web service framework with emphasis on minimal syntax.  Dancer2
is Moo-based, and Plack compatible.

Downsides: everything is global (which if I'm not mistaken, makes parallel
event-driven requests impossible), and most of the implementation is hidden,
making it hard to change the details of its behavior without a big learning
curve.  Also heavy on dependencies.

=item L<Mojolicious>

Full-featured web service framework with emphasis on event-driven style,
and having a complete copy of CPAN within it's own namespace.  Based on its
own object system.  B<Not> Plack-compatible.

The complete copy of CPAN is very well written, but requires you to learn a
new API for everything you already knew, and which you can't use for other
purposes without depending on the whole of Mojo.

=item L<Web::Simple>

Extremely minimal framework that routes requests to coderefs which can return
further dispatch routing paths.

Downsides: The closures-within-closures-within-closures don't lead to clean
code.  If you avoid closures, then it suffers from the Catalyst problem of
needing a pair of objects passed around everywhere.

=item L<CGI::Application>

Old and simple-ish framework with "controller-object-holds-refs-to-everything"
and "return-value-is-response" pattern that I like, but which has all the
wrong defaults for modern web programming.

=back

=cut

