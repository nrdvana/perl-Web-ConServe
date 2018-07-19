package Web::ConServe::PathMatch;

use Moo;

# ABSTRACT: Default implementation of path matching for Web::ConServe

=head1 DESCRIPTION

This is the default path-matching implementation for Web::ConServe.
It handles the task of taking a set of path-patterns and efficiently
matching them against an incoming path.

The path patterns are "shell glob style with an rsync twist".  In short,
C<'*'> captures a non-empty string that doesn't contain a path separator,
and C<**> matches any string including path separators.  As a special case,
if C<**> is bounded by path separators (or end of string) it may match
negative-one characters (in other words, C<'/**/'> may match C<'/'>).

=head1 ATTRIBUTES

=head2 nodes

An arryref of hashrefs identified by a path.  Each hashref must have a
field C<'path'>.

=head2 tree

The internal search tree (trie, really) for efficient matching.  You don't
need to see this, but it might help with debugging.  The tree is generated
during construction.

=cut

has nodes => ( is => 'ro', required => 1 );
has tree  => ( is => 'lazy', clearer => 1, predicate => 1 );

# Trigger tree construction before end of new()
sub BUILD { shift->tree }

=head1 METHODS

=head2 search

  $path_match->search( $path, sub {
    my ($node, $captures)= @_;
    ...
  });

Find the node whose path pattern matches C<$path>.  C<$captures> is an
arrayref of the portions of the string that matched the wildcards.

Because multiple patterns might match, the callback should return 1 if it is
done, and 0 if it wants to see the next match.  The sequence of nodes passed
to the callback will always give the longest prefix match first, and favor
literal matches over wildcard matches.

The search function returns true if the callback returns true at any point,
and false otherwise.

=cut

sub search {
	my ($self, $path, $callback)= @_;
	return $self->_search_tree($self->tree, $path, $callback, []);
}

sub _build_tree {
	my ($self, $actions)= @_;
	$actions //= $self->nodes;
	# Tree up the actions according to prefix
	my %tree= ( path => {} );
	for my $action (@$actions) {
		my $remainder= $action->{path};
		my $node= $tree{path};
		my @capture_names;
		while (1) {
			# Find the longest non-wildcard prefix of path, followed by '*' or '**'
			my ($prefix, $wild, $suffix)= $remainder =~ m,^([^*]*)(\*?\*?)(.*),
				or die "Bug: '$remainder'";
			if (!length $wild) { # path ends at this node
				push @{ $node->{$prefix}{exact} }, $action;
				last;
			}
			elsif ($wild eq '*') {
				length $prefix or die "bug";
				$node= ($node->{$prefix}{path} ||= {});
			}
			elsif ($wild eq '**') {
				length $prefix or die "bug";
				
				# wildcard-at-end goes into list of ->{wild}
				if (!length $suffix) {
					push @{ $node->{$prefix}{wild} }, $action;
					# If the previous character was '/', then the wild can also apply to
					# end-of-string one character sooner.
					if (substr($prefix,-1) eq '/') {
						push @{ $node->{substr($prefix,0,-1)}{wild_cap} }, [ qr/^()$/, $action ];
					}
				}
				# wildcard-in-middle goes into a list of ->{wild_cap},
				else {
					# After a wildcard, it is impossible to continue iteratively capturing,
					# because no way to know how many characters to consume.  So, just build a
					# list of regexes to try.  First match wins.
					
					# \Q\E add escapes to "/", which is inconvenient below, so gets handled specifically here
					my @parts= ( '**', split m{ ( \*\*? | / ) }x, $suffix );
					my $regex_text= '^'.join('', map { $_ eq '/'? '/' : $_ eq '*'? '([^/]+)' : $_ eq '**'? '(.*?)' : "\Q$_\E" } @parts).'$';
					# WHEE!  Processing regular expressions with regular expressions!
					# "/**/" needs to match "/" and "/**" needs to match ""
					$regex_text =~ s, / \( \. \* \? \) ( / | \$ ) ,(?|/(.*?)|())$1,xg;
					# If prefix ends with '/', then "**/" can also match ""
					$regex_text =~ s,\^ \( \. \* \? \) / ,(?|(.*?)/|()),x
						if substr($prefix,-1) eq '/';
					push @{ $node->{$prefix}{wild_cap} }, [ qr/$regex_text/, $action ];
				}
				last;
			}
			else {
				die "bug";
			}
			$remainder= $suffix;
		}
	}
	# For each ->{...}{cap} node, make a {cap_regex} to find the longest prefix
	&_make_subpath_cap_regexes for \%tree;
	\%tree;
}

sub _make_subpath_cap_regexes {
	my $node= $_;
	return unless $node->{path};
	
	# Make a list of all sub-paths which involve a capture
	my @keys_with_cap= sort { $a cmp $b }
		grep $node->{path}{$_}{path} || $node->{path}{$_}{wild} || $node->{path}{$_}{wild_cap},
		keys %{$node->{path}}
		or return;
	
	# Build regex OR expression of each path, with longer strings taking precedence
	my $or_expression= join '|', map "\Q$_\E", reverse @keys_with_cap;
	$node->{sub_path_re}= qr,^($or_expression),;
	
	# Find every case of a longer string which also has a prefix, and record the fallback
	my %seen;
	for my $key (@keys_with_cap) {
		$seen{$key}++;
		for (map substr($key, 0, $_), reverse 1..length($key)-1) {
			if ($seen{$_}) {
				$node->{path}{$key}{path_backtrack}= $_;
				last;
			}
		}
	}
	# recursively
	&_make_subpath_cap_regexes for values %{$node->{path}};
}

our $DEBUG;
sub _search_tree {
	my ($self, $node, $path, $callback, $captures, $from_slash)= @_;
	my $next;
	# Step 1, quickly dispatch any static path, or exact-matching wildcard prefix
	$DEBUG->("test '$path' vs constant (".join(', ', map "'$_'", keys %{$node->{path}}).')') if $DEBUG;
	if ($node->{path} and ($next= $node->{path}{$path}) and $next->{exact}) {
		$callback->($_, $captures) && return 1
			for @{ $next->{exact} };
	}
	# Step 2, check for a path that we can capture a portion of, and recursively continue
	if ($node->{sub_path_re}) {
		$DEBUG->("test '$path' vs capture $node->{sub_path_re}") if $DEBUG;
		my ($prefix)= ($path =~ $node->{sub_path_re});
		while (defined $prefix) {
			$DEBUG->("try removing '$prefix'") if $DEBUG;
			$next= $node->{path}{$prefix} or die "invalid path tree";
			
			# First, check for single-component captures
			my $remainder= substr($path, length($prefix));
			my ($wild, $suffix)= ($remainder =~ m,([^/]*)(.*),);
			# If starting from '/' in the pattern, a '*' must match at least one character
			my $next_from_slash= length $prefix? substr($prefix, -1) eq '/' : $from_slash;
			if (length $wild || !$next_from_slash) {
				return 1 if $self->_search_tree($next, $suffix, $callback, [ @$captures, $wild ], $next_from_slash);
			}
			
			# Else check for wildcard captures.  This isn't recursive because there's no way
			# to know how much path to capture, so just check each action's regex in sequence.
			if ($next->{wild_cap}) {
				for my $wild_item (@{ $next->{wild_cap} }) {
					$DEBUG->("try '$remainder' vs $wild_item->[0]") if $DEBUG;
					if (my (@more_caps)= ($remainder =~ $wild_item->[0])) {
						return 1 if $callback->($wild_item->[1], [ @$captures, @more_caps ]);
					}
				}
			}
			if ($next->{wild}) {
				$DEBUG->("try '$remainder' vs '**'") if $DEBUG;
				$callback->($_, [ @$captures, $remainder ])
					&& return 1
					for @{ $next->{wild} };
			}
			
			$DEBUG->("backtrack to ".($next->{path_backtrack}//'previous node')) if $DEBUG;
			$prefix= $next->{path_backtrack};
		}
	}
	# No match, but might need to backtrack to a different wildcard from caller
	return undef;
}

1;
