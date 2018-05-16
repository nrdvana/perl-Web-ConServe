package Web::ConServe;

use Moo;
use Carp;
use mro;

# ABSTRACT: Conrad's conservative web service framework

=head1 SYNOPSIS

  package MyWebapp;
  use Web::ConServe -parent,
    -plugins => qw/ Foo Bar Baz /;
  with 'My::Moo::Role';
  
  # Method annotations like Catalyst, but the syntax of Web::Simple,
  # but the application object is a lot more like CGI::Application.
  # Request and response come from Plack.
  
  sub index : Serve( / ) {
    my $self= shift;
    return [422] unless my $x= $self->req->parameters->get('x');
    return [200, undef, ["Hello World"]];
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
  
  sub conserv_analyze_request {
    my $self= shift;
	$self->next::method();
	$self->req->analysis->{wants_json}= $self->req->header('Accept') =~ /application\/json/;
    $self->req->analysis->{we_like_them}= $self->req->address =~ /^10\./;
  }

=head1 DESCRIPTION

The purpose of ConServe is to provide a minimalist (but still fully usable)
base class for writing Plack apps.  To read about why and how, see the
L</DESIGN GOALS> section.  If you want to know how to accomplish common tasks,
see the L<Cookbook|Web::ConServe::Cookbook> page.

=head1 APPLICATION LIFECYCLE

In order to make the most of Web::ConServe, you should know a bit about how it works.

=over

=item Compilation

During compile time, the L</Serve> annotation on your methods are added to a list
stored in the class.  These gets compiled into a dispatcher when your first
instance of the class is created.  See L</conserve_dispatch_rules>,
L</conserve_dispatcher>.  This means you can customize the dispatch system
without needing to write your own annotation library.  You could even customize
it to be built per-instance so that you could change the available actions based
on configuration parameters.

=item Plack Creation

When the application is created as a Plack app, it creates an instance of your
object via the normal constructor.  Customize the initialization however you
normally would with L<Moo>.

=item Request Binding

When a new request comes in, the plack app calls L</clone> and passes in the
plack environment.  By default, L</clone> creates a shallow copy of the object,
so it's fast.  You can override that if you want.

After this step, C<< $self->plack_environment >> is defined.  Before this step
it is not, and the default builder methods for things like C<< $self->req >>
will throw exceptions.

=item Request Dispatch

After L</clone>, the plack app calls L</dispatch>.  This simply passes
the request object to the L</conserve_dispatcher> to find which method should
handle it, then calls that method with any arguments captured from the url.
In the process, the request object and other things may get lazy-built.
The builder methods are all standard Moo, so you can subclass them.
The return value from the action becomes the response, after pos-processing.
(see next)

If there was not a matching action, then the dispatcher sets the response code
as appropriate (404 for no path match, 405 for no method match, and 422 for
a match that didn't meet custom user conditions)

If the action throws an exception, the default is to let it bubble up the
Plack chain so that you can use Plack middleware to deal with it.  If you want
to trap exceptions, see the role L<Web::ConServe::Plugin::CatchAs500>, or
override L</conserve_dispatch> with your preferred exception handling.

=item Plack Response

The response is then passed to L</view> which converts it
to a Plack response object.  This is another useful point to subclass.  For
instance, if you wanted something like Catalyst's View system, you could add
that here.  You can also deal with any custom details or conventions you
came up with for the return values of your actions.

To facilitate plugins, you should always allow for native Plack responses
as input, and should probably always add the L</response_headers> into the
response before returning it.

=item Cleanup

You should consider the end of L</view> to be the last point when you can take
any action.  If that isn't enough, L<PSGI> servers might implement the
L</psgix.cleanup|PSGI::Extensions/SPECIFICATION> system for you to use.
Failing that, you could return a PSGI streaming coderef which runs some code
after the last chunk of data has been delivered to the client.
It would not be hard to write a plugin which chooses the best method.

=head1 IMPORTS

  use Web::ConServ qw/ -parent -plugins Foo Bar /;

is equivalent to

  use Moo;
  BEGIN { extends 'Web::ConServe'; }
  use Web::ConServe::Plugin::Foo '-plug';
  use Web::ConServe::Plugin::Bar '-plug';

Either way will give you the "Serve()" method annotation.

=cut

sub import {
	my ($class, @args)= @_;
	my $caller= caller;
	my $add_moo;
	my @with;
	while (@args) {
		if ($args[0] eq '-parent') { shift @args; $add_moo= 1 }
		elsif ($args[0] eq '-plugins') {
			shift @args;
			while (@args && $args[0] !~ /^-/) { push @with, 'Web::ConServe::Plugin::'.(shift @args); }
		}
		elsif ($args[0] eq '-with') {
			shift @args;
			while (@args && $args[0] !~ /^-/) { push @with, shift @args; }
		}
		else {
			croak "Un-handled export requested from Web::ConServe: $args[0]";
		}
	}
	eval 'package '.$caller.'; use Moo; extends "Web::ConServ";' or croak $@
		if $add_moo;
}

# Default allows subclasses to wrap it with modifiers
sub BUILD {}
sub DESTROY {}

=head1 MAIN API ATTRIBUTES

=head2 plack_environmnt

Reference to L</Plack>'s C<$env>.  This is C<undef> on the main application
instance.  For per-request instances, it is set by the L</clone> method.
This is a weak reference, and becomes undef when the plack environment is
destroyed, B<before> the per-request application gets destroyed.

=head2 env

Alias for L</plack_environment>

=head2 request

The request object.  Lazy-built instance of L<Web::ConServe::Request>.
Override C<_build_request> to subclass this.

=head2 req

Alias for L</request>.

=cut

has plack_environment => ( is => 'rw', weak_ref => 1 );
sub env { goto $_[0]->can('plack_environment') }

has request_class     => ( is => 'rw', default => sub { require Plack::Request; 'Plack::Request' } );
has request           => ( is => 'rw', lazy => 1, clearer => 1, predicate => 1 );
sub req { goto $_[0]->can('request') }

sub _build_request {
	my $self= shift;
	$self->request_class->new($self->plack_environment);
}

=head1 MAIN API METHODS

=head2 new

Standard Moo constructor.

=head2 clone

Like 'new', but inherit all existing attributes of the current instance.

=head2 dispatch

Dispatch a request to an action method, and return the application-specific
result.  You might choose to wrap this with exception handling, to catch
errors from the controller actions.

=head2 view

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

Calls L</clone> to create a new instance with the given plack environment,
then L</dispatch> to create an intermediate response, and then L</view>
to render that response as a Plack response arrayref.  You might choose to
wrap this with exception handling to trap errors from views.

=head2 to_app

Returns a Plack coderef that calls L</call>.

=cut

sub clone {
	my $self= shift;
	my $clone= bless { %$self }, ref $self;
	if (@_) {
		my $new_attrs= @_ == 1 && ref $_[0] eq 'HASH'? $_[0]
			: (@_ & 1) == 0? { @_ }
			: croak "Expected hashref or even number of key/value";
		for my $k (keys %$new_attrs) {
			$clone->$k($new_attrs->{$k});
		}
	}
	$clone;
}

sub dispatch {
	my $self= shift;
	my ($code, @args)= $self->conserve_dispatcher($self->request);
	return $code->($self, @args)
		if ref $code eq 'CODE';
	return [ $code ];
}

sub view {
	my ($self, $result)= @_;
	if (ref($result) ne 'ARRAY' && ref($result)->can('to_app')) {
		# save a step for Plack::Response
		return $result->finalize if $result->can('finalize');
		# Else execute a sub-app
		my $sub_app= $result->to_app;
		my $env= $self->plack_environment;
		my $sub_path= $env->{PATH_INFO};
		my $sub_script= $env->{SCRIPT_NAME};
		my $consumed= $self->conserve_dispatch_result->{path_match} // '';
		if (substr($sub_path, 0, length $consumed) eq $consumed) {
			substr($sub_path, 0, length $consumed)= '';
			$sub_path= '/' unless length $sub_path;
			$sub_script .= $consumed;
		}
		local $env->{PATH_INFO}= $sub_path;
		local $env->{SCRIPT_NAME}= $sub_script;
		$sub_app->($env);
	}
	return $result;
}

sub call {
	my ($self, $env)= @_;
	my $inst= $self->clone(plack_environment => $env);
	$inst->view($inst->dispatch());
}

sub to_app {
	my $self= shift;
	sub { $self->handle_request(shift) };
}

=head1 IMPLEMENTATION ATTRIBUTES

=head2 conserve_dispatch_rules

An arrayref listing the dispatch rules.  These default to the list collected
from the C<Serve> method attributes (and those of any parent class).
For example,

  sub foo : Serve( / ) {}
  sub bar : Serve( /bar GET,HEAD,OPTIONS ) {}

results in

  conserve_dispatch_rules => [
    { handler => \&foo, path => '/' },
    { handler => \&bar, path => '/bar', methods => {GET=>1, HEAD=>1, OPTIONS=>1} },
  ]

These are built into a dispatcher by L<conserve_compile_dispatch_rules>.
If you modify these at runtime, be sure to call L<clear_conserve_dispatcher>
to make sure it gets rebuilt.

=head2 conserve_dispatcher

A coderef which takes a request object and returns either a method and
arguments to which it should be dispatched, or diagnostics about why it
didn't match.

  my $result= conserve_dispatcher($request);
  if ($result->{rule}) {
    # success should provide ->{rule} and ->{captures} arrayref.
  } elsif (!defined $result->{path_match}) {
    # 404, no such path
  } elsif (defined $result->{method_mismatch}) {
    # 405, Unsupported method
    # method_mismatch is the method of the request
  } elsif (defined $result->{constraint_fail}) {
    # 422, Didn't meet constraints on rule
    # constraint_fail is the constraint-notation of the first false constraint
  }

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
	return grep { $_ !~ /^Serve\(([^)]+)\)/
			or do {
				my $rule= $class->conserve_parse_dispatch_rule($1, \my $err);
				defined $rule or croak "$err, in attribute $_";
				$rule->{handler}= $coderef;
				push @{$class_actions{$class}{$coderef}}, $rule;
				0;
			}
		}
		$super? $super->($class, $coderef, @_) : @_;
}

has conserve_dispatch_rules => ( is => 'lazy', clearer => 1, predicate => 1 );
sub _build_conserve_dispatch_rules {
	my $self= shift;
	[ map @$_, map { $_? values %$_ : () } map $class_actions{$_}, mro::get_linear_isa(ref $self) ];
}

has conserve_dispatcher     => ( is => 'lazy', clearer => 1, predicate => 1 );
sub _build_conserve_dispatcher {
	my $self= shift;
	$self->conserve_compile_dispatcher($self->conserve_dispatch_rules)
}

=head1 IMPLEMENTATION METHODS

=head2 conserve_parse_dispatch_rule

  my $rule_data= $self->conserve_parse_dispatch_rule( $rule_spec, \$err_msg )
                 or croak $err_msg;
  # input:   /foo/:bar/* GET,PUT local_client
  # output:  { path => '/foo/:bar/*', methods => {GET => 1, PUT => 1}, constraints => {local_client=>\1} } 

=head2 conserve_compile_dispatch_rules

  my $coderef= $self->conserve_compile_dispatch_rules( \@rules );

Compiles the list of rules (defaulting to L</conserve_dispatch_rules>) into a
coderef which can efficiently match them against a request object.  Rules may
be un-parsed strings or parsed data.

=cut

sub conserve_parse_dispatch_rule {
	my ($self, $text, $err_ref)= @_;
	my %rule;
	for my $part (split / +/, $text) {
		if ($part =~ m,^/,) {
			if (defined $rule{path}) {
				$$err_ref= 'Multiple paths defined' if $err_ref;
				return;
			}
			$rule{path}= $part;
			if (index ':', $part >= 0) {
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

sub conserve_compile_dispatch_rules {
	my ($self, $rules)= @_;
	$rules ||= $self->conserve_dispatch_rules;
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
		my ($self, $env)= @_;
		local $self->{plack_environment}= $env if $env;
		local $self->{request}= undef if $env;
		my $result={ captures => [] };
		_conserve_search_rules($self, \%tree, $self->env->{PATH_INFO}, $result);
		return $result;
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

sub _conserve_search_rules {
	my ($self, $node, $path, $result)= @_;
	my $next;
	# Step 1, quickly dispatch any static path, or exact-matching wildcard prefix
	print STDERR "test $path vs ".join(', ', keys %{$node->{path}})."\n";
	if ($node->{path} and ($next= $node->{path}{$path})) {
		# record that there was at least one full match
		$result->{path_match} //= $self->env->{PATH_INFO};
		# Check absolutes first
		if ($next->{rules}) {
			$self->_conserve_test_rule($_, $result) and return $_
				for @{ $next->{rules} };
		}
		# Then check any wildcard whose entire prefix matched
		if ($next->{wild}) {
			$self->_conserve_test_rule($_, $result) and return $_
				for @{ $next->{wild} };
		}
	}
	# Step 2, check for a path that we can capture a portion of, and recursively continue
	print STDERR "test $path vs $node->{sub_path_re}\n" if $node->{sub_path_re};
	if ($node->{sub_path_re}) {
		my ($prefix)= ($path =~ $node->{sub_path_re});
		while (defined $prefix) {
			print STDERR "try removing $prefix\n";
			$next= $node->{path}{$prefix} or die "invalid path tree";
			my ($wild, $suffix)= (substr($path, length $prefix) =~ m,([^/]*)(.*),);
			push @{$result->{captures}}, $wild;
			return if $self->_conserve_search_rules($next, $suffix, $result);
			pop @{$result->{captures}};
			$prefix= $next->{path_backtrack};
		}
	}
	# Step 3, check for a wildcard that can match the full remainder of the path
	print STDERR "test $path vs $node->{sub_wild_cap_re}\n" if $node->{sub_wild_cap_re};
	if ($node->{sub_wild_cap_re}) {
		my ($prefix)= ($path =~ $node->{sub_wild_cap_re});
		while (defined $prefix) {
			print STDERR "try removing $prefix\n";
			$next= $node->{path}{$prefix} or die "invalid path tree";
			my $remainder= substr($path, length($prefix));
			for my $wild_item (@{ $next->{wild_cap} }) {
				print STDERR "try $remainder vs $wild_item->[0]\n";
				if (my (@more_caps)= ($remainder =~ $wild_item->[0])) {
					# Record that we found a match up to the wildcard
					my $match= substr($self->env->{PATH_INFO}, 0, -length($remainder));
					$result->{path_match} //= $match;
					if ($self->_conserve_test_rule($wild_item->[1], $result)) {
						# it's actually the final match, so overwrite any previous result
						$result->{path_match}= $match;
						push @{$result->{captures}}, @more_caps;
						$result->{rule}= $wild_item->[1];
					}
				}
			}
			$prefix= $next->{wild_cap_backtrack};
		}
	}
	# No match, but might need to backtrack to a different wildcard from caller
	return undef;
}
sub _conserve_test_rule {
	my ($self, $rule, $result)= @_;
	$result->{rule}= $rule;
	return 1;
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

=back

To reach those broad goals, I picked these design features:

=item Minimal Deps

The only non-core dependencies are Moo and Plack.

=item Single Object

The webapp object represents the app but also represents the request.
All aspects of the request are accessible via C<$self>, so that you don't have
to pass around extra context objects, session objects, environment objects, etc.
This means your application gets cloned for each request, but being a single
hashref, this is fast.  This also means you can use lazy-build attributes.

=item Public Request Lifecycle

All aspects of the request lifecycle are a public part of the API.  There
is no "magic under the hood".  Users can depend on this mechanism remaining
unchanged.  The dispatch mechanism follows a mostly obvious design.

=back


=cut

