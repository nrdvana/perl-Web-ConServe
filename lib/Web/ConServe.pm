package Web::ConServe;

use Moo;
use Carp;
use mro;
use Web::ConServe::Request;
use Web::ConServe::Plugin::Res;
use Module::Runtime;
use namespace::clean;

# ABSTRACT: Conrad's conservative web service framework

=head1 SYNOPSIS

  package MyWebapp;
  use Web::ConServe -parent,      # Automatically set up Moo and base class
    -plugins => qw/ Res /;        # Supports a plugin system
  with 'My::Moo::Role';           # Fully Moo compatible
  
  # Actions declared with method attributes like Catalyst,
  # but using the path syntax like Web::Simple
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
it operates.

=over

=item Compilation

During Perl's compile phase, the L</Serve> annotations on your methods are
parsed and added to a list of actions.  When the first instance of your class
is created, the actions get "compiled" into a search function.  Parent classes
and plugins can also add rules.  You can override many pieces of this process.
See L</conserve_actions> and L</conserve_search_action_fn>.

=item App Creation

When the application is created as a Plack app, it creates an instance of your
object via the normal constructor.  Customize the initialization however you
normally would with L<Moo>.

=item Plack Creation

if you want to add Plack middleware as a built-in part of your app, you can
override L</to_app>.

=item Request Binding

When a new request comes in, the plack app calls L</accept_request> which
clones the app and sets the L</request> attribute.  You can override that
method, or simply set a custom L</request_class>.

=item Request Dispatch

Next the plack app calls L</dispatch>.  This looks for the best matching
rule for the request, then if found, calls that method.  The return value
from the method becomes the response, after pos-processing.

If there was not a matching rule, then the dispatcher sets the response code
as appropriate (404 for no path match, 405 for no method match, and 422 for
a match that didn't meet custom user conditions)

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

To facilitate plugins, you should always allow for native Plack responses
as input.

=item Cleanup

You should consider the end of L</view> to be the last point when you can take
any action.  If that isn't enough, L<PSGI> servers might implement the
L</psgix.cleanup|PSGI::Extensions/SPECIFICATION> system for you to use.
Failing that, you could return a PSGI streaming coderef which runs some code
after the last chunk of data has been delivered to the client.
It would not be hard to write a plugin which chooses the best method.

=back

=head1 IMPORTS

  use Web::ConServe qw/ -parent -plugins Foo Bar /;

is equivalent to

  use Moo;
  BEGIN { extends 'Web::ConServe'; }
  use Web::ConServe::Plugin::Foo '-plug';
  use Web::ConServe::Plugin::Bar '-plug';

Note that this allows plugins to change the class/role hierarchy as well as
inject symbols into the current package namespace, such as 'sugar' methods.

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
Override this if you need to avoid sharing certain resources between instances.
You might also want to deep-clone attributes to make sure they don't get
altered during a request. The default is to call C<new> with a shallow copy of
C<$self>'s attributes.

=head2 accept_request

  my $new_instance= $app->accept_request( $plack_env );

Clone the application and initialize the L</request> attribute from the Plack
environment.  The default implementation creates a request from
L</request_class> and then calls L</clone>.

=head2 search_actions

  my (@actions_data)= $app->search_actions( $request );

Return a list of hashrefs, one for each action which had a full path-match
against the request.  The search stops at the first complete match, so the
search was successful if and only if C<< !defined $actions_data[0]{mismatch} >>.
Other actios whose patch matched but failed the custom failters (like method,
flags, etc) will follow in the list, for debugging purposes and to be able to
return the correct HTTP error code.

Each hashref is a shallow copy of the action, and may have additional fields
describing the result of the match operation.

=head2 dispatch

  my $something= $app->dispatch; # using app->req
  my $something= $app->dispatch( $request_object );

Dispatch a request to an action method, and return the application-specific
result.  If no action matches, it returns an appropriate plack response of an
HTTP error code.

You might choose to wrap this with exception handling, to catch errors from
the controller actions.

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

  my $plack_result= $app->call( $plack_env );

Calls L</accept_request> to create a new instance with the given plack
environment, then L</dispatch> to create an intermediate response, and then
L</view> to render that response as a Plack response arrayref.  You might
choose to wrap this with exception handling to trap errors from views.

=head2 to_app

Returns a Plack coderef that calls L</call>.

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
	my $req= $self->request_class->new($plack_env);
	$self->clone(request => $req);
}

sub search_actions {
	my ($self, $req)= @_;
	return $self->conserve_search_action_fn->($req // $self->req);
}

sub dispatch {
	my $self= shift;
	my @matches= $self->search_actions($self->req);
	my $action= shift @matches
		if @matches && !defined $matches[0]{mismatch};
	
	$self->req->action($action);
	$self->req->action_rejects(\@matches);
	
	return $action->{handler}->($self, @{$action->{captures}})
		if $action;
	
	# If nothing matched, then return 404
	return Web::ConServe::Plugin::Res::res_not_found()
		unless @matches;
	# If all matches returned 'mismatch=method', then return 405
	return Web::ConServe::Plugin::Res::res_bad_method()
		unless grep $_->{mismatch} ne 'method', @matches;
	# Else some specific user requirement was not met, so return 422
	return Web::ConServe::Plugin::Res::res_unprocessable();
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
	return $result;
}

sub call {
	my ($self, $env)= @_;
	my $inst= $self->accept_request($env);
	$inst->view($inst->dispatch());
}

sub to_app {
	my $self= shift;
	sub { $self->call(shift) };
}

=head1 IMPLEMENTATION ATTRIBUTES

=head2 conserve_actions

An arrayref listing the actions of this class and any parent class.
These default to the list collected from the C<Serve> method attributes.
For example,

  sub foo : Serve( / ) {}
  sub bar : Serve( /bar GET,HEAD,OPTIONS ) {}

results in

  conserve_actions => [
    { handler => \&foo, path => '/' },
    { handler => \&bar, path => '/bar', methods => {GET=>1, HEAD=>1, OPTIONS=>1} },
  ]

These are built into a dispatcher by L<conserve_compile_actions>.
If you modify these at runtime, be sure to call L<clear_conserve_search_action_fn>
to make sure it gets rebuilt.

=head2 conserve_search_action_fn

A coderef which implements the same API as L</search_actions>.

=cut

our %class_actions;
sub FETCH_CODE_ATTRIBUTES {
	my ($class, $coderef)= (shift, shift);
	my $super= __PACKAGE__->next::can;
	return (grep { ref $_ ne 'CODE' } @{$class_actions{$class}{$coderef} || []}),
		($super? $super->($class, $coderef, @_) : ());
}
sub MODIFY_CODE_ATTRIBUTES {
	my ($class, $coderef)= (shift, shift);
	my $super= __PACKAGE__->next::can;
	my (@known, @unknown);
	@known= grep { $_ =~ /^Serve\(([^)]+)\)/ or do { push(@unknown, $_); 0 } } @_;
	for (@known) {
		my $rule= $class->conserve_parse_action($1, \my $err);
		defined $rule or croak "$err, in attribute $_";
		$rule->{handler}= $coderef;
		push @{$class_actions{$class}{$coderef}}, $rule;
	}
	return $super? $super->($class, $coderef, @unknown) : @unknown;
}

has conserve_actions => ( is => 'lazy', clearer => 1, predicate => 1, trigger => \&clear_conserve_search_action_fn );
sub _build_conserve_actions {
	my $self= shift;
	my @all_inherited= grep defined, map $class_actions{$_}, mro::get_linear_isa(ref $self);
	[ map @$_, map { $_? values %$_ : () } @all_inherited ];
}

has conserve_search_action_fn => ( is => 'lazy', clearer => 1, predicate => 1 );
sub _build_conserve_search_action_fn {
	my $self= shift;
	$self->conserve_compile_actions($self->conserve_actions)
}

=head1 IMPLEMENTATION METHODS

=head2 conserve_parse_action

  my $rule_data= $self->conserve_parse_action( $action_spec, \$err_msg )
                 or croak $err_msg;
  # input:   /foo/:bar/* GET,PUT local_client
  # output:  { path => '/foo/:bar/*', match_fn => sub { ... } } 

=head2 conserve_compile_actions

  my $coderef= $self->conserve_compile_actions( \@rules );

Compiles the list of rules (defaulting to L</conserve_actions>) into a
coderef which can efficiently match them against a request object.  Rules may
be un-parsed strings or parsed data.  This is the default implementation
behind L</search_actions>.

=cut

sub conserve_parse_action {
	my ($self, $text, $err_ref)= @_;
	my %rule;
	for my $part (split / +/, $text) {
		if ($part =~ m,^/,) {
			if (defined $rule{path}) {
				$$err_ref= 'Multiple paths defined' if $err_ref;
				return;
			}
			$rule{path}= $part;
			if (index($part, ':') >= 0) {
				$rule{capture_names}= [ $part =~ /:(\w+)/g ];
				$rule{path} =~ s/:(\w+)/\*/g;
			}
		} elsif ($part =~ /^[A-Z]/) {
			$rule{methods}{$_}++ for split ',', $part;
		} elsif ($part =~ /^\w/) {
			my ($name, $value)= split /=/, $part, 2;
			$rule{constraints}{$name}= defined $value? $value : \1;
		}
		else {
			$$err_ref= "Can't parse rule, at '$part'" if $err_ref;
			return;
		}
	}
	return \%rule;
}

sub conserve_compile_actions {
	my ($self, $rules)= @_;
	$rules ||= $self->conserve_actions;
	# Tree up the rules according to prefix
	my %tree= ( path => {} );
	for my $rule (@$rules) {
		my $remainder= $rule->{path};
		my $node= $tree{path};
		my @capture_names;
		while (1) {
			# Find the longest non-wildcard prefix of path
			my ($prefix, $wild, $suffix)= $remainder =~ m,^([^*]*)(\**)(.*),
				or die "Bug: '$remainder'";
			if (!length $wild) { # path ends at this node
				push @{ $node->{$prefix}{rules} }, $rule
					if $node;
				last;
			}
			elsif ($wild eq '*') {
				length $prefix or die "bug";
				$node= ($node->{$prefix}{path} ||= {});
			}
			elsif ($wild eq '**') {
				length $prefix or die "bug";
				# After a wildcard, it is impossible to continue iteratively capturing,
				# because no way to know how many characters to consume.  So, just build a
				# list of regexes to try.  First match wins.
				if (length $suffix) {
					$suffix =~ s,(\*+), $1 eq '*' ? '([^/]+)' : '(.*?)' ,ge;
					push @{ $node->{$prefix}{wild_cap} }, [ qr/$suffix/, $rule ];
				} else {
					push @{ $node->{$prefix}{wild} }, $rule;
				}
				last;
			}
			$remainder= $suffix;
		}
	}
	# For each ->{...}{cap} node, make a {cap_regex} to find the longest prefix
	&_conserve_make_subpath_cap_regexes for \%tree;
	sub {
		my ($self, $req)= @_;
		$req //= $self->req;
		my $result= { captures => [] };
		$self->_conserve_search_actions($req, \%tree, $req->env->{PATH_INFO}, $result);
		my @ret;
		push @ret, $result->{action} if defined $result->{action};
		push @ret, @{ $result->{action_rejects} } if defined $result->{action_rejects};
		return @ret;
	};
}

sub _conserve_make_subpath_cap_regexes {
	my $node= $_;
	return unless $node->{path};
	# add all of wild to the end of wild_cap.
	# (could have added them sooner, but want them to be at end of the list)
	for (values %{$node->{path}}) {
		push @{ $node->{wild_cap} }, map [qr/(.*)/, $_], @{ $node->{wild} }
			if $node->{wild};
	}
	
	for my $var ('path','wild_cap') {
		# Make a list of all sub-paths which involve a capture
		my @keys_with_cap= sort { $a cmp $b }
			grep $node->{path}{$_}{$var},
			keys %{$node->{path}}
			or return;
		
		# Build regex OR expression of each path, with longer strings taking precedence
		my $or_expression= join '|', map "\Q$_\E", reverse @keys_with_cap;
		$node->{'sub_'.$var.'_re'}= qr,^($or_expression),;
	
		# Find every case of a longer string which also has a prefix, and record the fallback
		my %seen;
		for my $key (@keys_with_cap) {
			$seen{$key}++;
			for (map substr($key, 0, $_), reverse 1..length($key)-1) {
				if ($seen{$_}) {
					$node->{path}{$key}{$var.'_backtrack'}= $_;
					last;
				}
			}
		}
	}
	# recursively
	&_conserve_make_subpath_cap_regexes for values %{$node->{path}};
}

sub _conserve_search_actions {
	my ($self, $req, $node, $path, $result)= @_;
	my $next;
	# Step 1, quickly dispatch any static path, or exact-matching wildcard prefix
	#print STDERR "test $path vs ".join(', ', keys %{$node->{path}})."\n";
	if ($node->{path} and ($next= $node->{path}{$path})) {
		# record that there was at least one full match
		$result->{path_match}= $req->path_info;
		# Check absolutes first
		if ($next->{rules}) {
			$self->_conserve_search_actions_check($_, $req, $result) && return 1
				for @{ $next->{rules} };
		}
		# Then check any wildcard whose entire prefix matched
		if ($next->{wild}) {
			$self->_conserve_search_actions_check($_, $req, $result) && return 1
				for @{ $next->{wild} };
		}
	}
	# Step 2, check for a path that we can capture a portion of, and recursively continue
	#print STDERR "test $path vs $node->{sub_path_re}\n" if $node->{sub_path_re};
	if ($node->{sub_path_re}) {
		my ($prefix)= ($path =~ $node->{sub_path_re});
		while (defined $prefix) {
			#print STDERR "try removing $prefix\n";
			$next= $node->{path}{$prefix} or die "invalid path tree";
			my ($wild, $suffix)= (substr($path, length $prefix) =~ m,([^/]*)(.*),);
			push @{$result->{captures}}, $wild;
			return 1 if $self->_conserve_search_actions($req, $next, $suffix, $result);
			pop @{$result->{captures}};
			$prefix= $next->{path_backtrack};
		}
	}
	# Step 3, check for a wildcard that can match the full remainder of the path
	#print STDERR "test $path vs $node->{sub_wild_cap_re}\n" if $node->{sub_wild_cap_re};
	if ($node->{sub_wild_cap_re}) {
		my ($prefix)= ($path =~ $node->{sub_wild_cap_re});
		while (defined $prefix) {
			#print STDERR "try removing $prefix\n";
			$next= $node->{path}{$prefix} or die "invalid path tree";
			my $remainder= substr($path, length($prefix));
			for my $wild_item (@{ $next->{wild_cap} }) {
				#print STDERR "try $remainder vs $wild_item->[0]\n";
				if (my (@more_caps)= ($remainder =~ $wild_item->[0])) {
					push @{ $result->{captures} }, @more_caps;
					# Record that we found a match up to the wildcard
					my $match= substr($req->path_info, 0, -length($remainder));
					$result->{path_match}= $match;
					return 1 if $self->_conserve_search_actions_check($wild_item->[1], $result);
					# Restore previous captures
					splice @{$result->{captures}}, -scalar @more_caps;
				}
			}
			$prefix= $next->{wild_cap_backtrack};
		}
	}
	# No match, but might need to backtrack to a different wildcard from caller
	return undef;
}

# Path matches, so then check other conditions needed for match.
# Also combine all the relevant data into the hashref for the action.
sub _conserve_search_actions_check {
	my ($self, $action, $req, $result)= @_;
	my $info= defined $action->{match_fn}? $action->{match_fn}->($req) : {};
	%$info= (
		%$action,
		path_match => $result->{path_match},
		captures   => [ @{ $result->{captures} } ],
		%$info
	);
	if ($info->{capture_names}) {
		my %cap;
		@cap{ @{$info->{capture_names}} }= @{ $info->{captures} };
		$info->{captures_by_name}= \%cap;
	}
	if ($info->{mismatch}) {
		push @{ $result->{action_rejects} }, $info;
		return 0;
	} else {
		$result->{action}= $info;
		return 1;
	}
}

1;

=head1 DESIGN GOALS

In order of priority, the goals are:

=over

=item Be lightweight

The less memory an app consumes, the more workers you can run.
The fewer dependencies you have, the faster you can build docker images.
The less modules you load at runtime, the less memory footprint you have.
Your app restarts faster.

=item Be simple

The lower the learning curve, the faster a developer can make full use of
a module.  The simpler the design, the less code you need to write to do
something unusual, and the less hair you pull out when you make a mistake.

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
to larger applications, because rarely do people actually know the full scopre
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

All aspects of the request lifecycle are a public part of the API.  There
is little "magic under the hood".  Users can depend on this mechanism remaining
unchanged.  The dispatch mechanism follows a mostly obvious design with methods
at each point where someone might want to customize it.

=item Sugar-friendly

The C<use>-line for C<Web::ConServe> has a syntax in the style of a command
line argument list, making it easy to specify a list of inheritance changes or
plugins.

With the default plugin system allowing both imports and OOP changes, this
should make everyone's wildest dreams possible while requring a very minimal
declaration at the top of the file.

=item Loose "MVC"

Rather than View and Controller being separate classes, I made the webapp class
itself be the controller, with a suggested but optional C<view>.  Users can
decide the level of abstraction they want here.

The Model is completely up to the user and can be loaded as an attribute.

=item Compiled Dispatcher

The most complexity of the entire framework is in the compilation phase of the
dispatcher.  It trees up the available actions in a data structure that allows
efficient search of matching actions, so it should scale to arbitrarily large
applications.  The API is simply "A coderef which returns a list of actions
matching a request", so the implementation can change as needed without
breaking anything, and users are free to implement their own if they have a
faster way of matching actions.

=item Chainable

Also part of scalability, the Request object has convenience methods to help
dispatch a request to a sub-controller.

=item No Policy Where Not Needed

There a a hundred ways to load configuration into a Moo object, so my opinion
doesn't need to be part of the framework.

There are dozens of ways to deal with exceptions, including Plack middleware,
so I choose a default of not catching them at all.

User sessions can already be handled by Plack middleware, so I defer to that
with examples.  (and those could be wrapped into a Plugin)

There is no official filesystem layout, so users can use whatever layout makes
the most sense for their usage.

=back

=cut

