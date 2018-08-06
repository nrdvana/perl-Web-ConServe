package Web::ConServe::PathMatch;
use DDP { use_prototypes => 0 };
use Moo;
use Data::Dumper;
our $DEBUG; #= sub { warn @_; };

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

# Nodes test the remainder of the path vs. a list of regexes
# [
#    \@actions_ending_here,
#    $backtrack_path_key,
#    \%patterns_set, (temporary)
#    @patterns,
# ]
# pattern: [ $regex, \%subnodes, \@actions ]
#
# The nodes are optimized as arrayrefs, rather than hashes or objects.
# These constants help maintain sanity in the code.
use constant {
	NODE_LEAF_PATHS       => 0,
	NODE_BACKTRACK        => 1,
	NODE_PATTERNS_SET     => 2,
	NODE_FIRST_PATTERN    => 3,
	NODE_PATTERN_REGEX    => 0,
	NODE_PATTERN_ORDER    => 1,
	NODE_PATTERN_SUBNODES => 2,
	NODE_PATTERN_ACTIONS  => 3,
};

sub _build_tree {
	my ($self, $actions)= @_;
	$actions //= $self->nodes;
	# Tree up the actions according to prefix
	my $root= [];
	for my $action (@$actions) {
		my $node= $root;
		my $from_subnodes;
		my (@capture_names, $prefix, $wild);
		$DEBUG->("considering action with pattern $action->{path}") if $DEBUG;
		my @parts= split m,(\*+[^/]*),, $action->{path};
		for my $p (0..$#parts) {
			my $pathpart= $parts[$p];
			# If it is a literal string, then ...
			if (substr($pathpart,0,1) ne '*') {
				# If it is the final part, list this action under NODE_LEAF_PATHS
				if ($p == $#parts) {
					if ($from_subnodes) {
						push @{ $from_subnodes->{$pathpart}[NODE_LEAF_PATHS]{''} }, $action;
					} else {
						push @{ $node->[NODE_LEAF_PATHS]{$pathpart} }, $action;
					}
				}
				# Else step into a sub-node.  If at root, step into '' pattern's sub-nodes
				else {
					$from_subnodes //= $node->[NODE_PATTERNS_SET]{''}[NODE_PATTERN_SUBNODES] //= {};
					$node= $from_subnodes->{$pathpart} //= [];
				}
			}
			# Else if it is not a double-star capture...
			elsif ($pathpart !~ /\*\*/) {
				my $pattern= $node->[NODE_PATTERNS_SET]{$pathpart} //= [];
				$pattern->[NODE_PATTERN_ORDER] //= keys %{$node->[NODE_PATTERNS_SET]};
				# prepare to enter sub-node on next loop
				$from_subnodes= ($pattern->[NODE_PATTERN_SUBNODES] //= {});
				# But if this was the end, then record the action as ''->''
				push @{ $from_subnodes->{''}[NODE_LEAF_PATHS]{''} }, $action
					unless $p < $#parts;
			}
			# Else a double star capture.  No further sub-nodes are possible.
			else {
				# Special handling for terminating '**' with no other match text
				if ($pathpart eq '**' and $p == $#parts) {
					# if $wild is '**' and previous char is '/', the wildcard can match
					# end-of-string one character sooner
					if ($p && substr($parts[$p-1],-1) eq '/') {
						my $earlier_node= $from_subnodes->{substr($parts[$p-1],0,-1)} //= [];
						my $pattern= $earlier_node->[NODE_PATTERNS_SET]{''} //= [];
						$pattern->[NODE_PATTERN_ORDER] //= keys %{$earlier_node->[NODE_PATTERNS_SET]};
						push @{ $pattern->[NODE_PATTERN_ACTIONS] }, $action;
					}
				}
				my $remainder= join('', @parts[$p..$#parts]);
				my $pattern= $node->[NODE_PATTERNS_SET]{$remainder} //= [];
				$pattern->[NODE_PATTERN_ORDER] //= keys %{$node->[NODE_PATTERNS_SET]};
				push @{ $pattern->[NODE_PATTERN_ACTIONS] }, $action;
				last;
			}
		}
	}
	# For each ->{...}{cap} node, make a {cap_regex} to find the longest prefix
	$DEBUG->("before regexes, tree is:".Data::Dumper::Dumper($root)) if $DEBUG;
	$self->_make_subpath_regexes($root);
	$DEBUG->("after regexes, tree is:".Data::Dumper::Dumper($root)) if $DEBUG;
	return $root;
}

sub _make_subpath_regexes {
	my ($self, $node, $prefix)= @_;
	# The patterns that come first are anything with single-star in them followed by '*'
	# followed by anything with '**' in them followed by '**', followed by ''.
	# Otherwise patterns are preserved in the order they were seen.
	my @patterns= sort {
			($a eq '') cmp ($b eq '')
			or ($a eq '**') cmp ($b eq '**')
			or ($a =~ /\*\*/) cmp ($b =~ /\*\*/)
			or ($a eq '*') cmp ($b eq '*')
			or $node->[NODE_PATTERNS_SET]{$a}[NODE_PATTERN_ORDER] <=> $node->[NODE_PATTERNS_SET]{$b}[NODE_PATTERN_ORDER]
		} keys %{$node->[NODE_PATTERNS_SET]};
	# for each pattern, convert it to the form
	#  [ $regex, \%subnodes, \@actions ]
	for my $pattern (@patterns) {
		my $pat_item= $node->[NODE_PATTERNS_SET]{$pattern};
		push @$node, $pat_item;
		# If the pattern includes subnodes:
		if ($pat_item->[NODE_PATTERN_SUBNODES]) {
			my $re_text= !length $pattern? '^'
				: $pattern eq '*'? '^([^/]+)'
				: do {
					my @parts= split /(\*)/, $pattern;
					'^'.join('', map { $_ eq '*'? '([^/]+)' : "\Q$_\E" } grep length, @parts);
				};
			# sort keys by length
			my @keys= sort keys %{ $pat_item->[NODE_PATTERN_SUBNODES] };
			$re_text .= '('.join('|', map "\Q$_\E", reverse @keys).')';
			$pat_item->[NODE_PATTERN_REGEX]= qr/$re_text/;
			
			# Find every case of a longer string which also has a prefix, and record the fallback
			my %seen;
			for my $key (@keys) {
				# Recursive to sub-nodes
				$self->_make_subpath_regexes($pat_item->[NODE_PATTERN_SUBNODES]{$key}, $key);
				$seen{$key}++;
				
				# then check for prefixes, to set up backtracking linked list
				for (map substr($key, 0, $_), reverse 1..length($key)-1) {
					if ($seen{$_}) {
						$pat_item->[NODE_PATTERN_SUBNODES]{$key}[NODE_BACKTRACK]= $_;
						last;
					}
				}
			}
		}
		# else its a wildcard.  but '' is a special case of '**'
		elsif ($pattern eq '') {
			$pat_item->[NODE_PATTERN_REGEX]= qr/^()$/;
		}
		else {
			# convert pattern to regex
			# \Q\E add escapes to "/", which is inconvenient below, so gets handled specifically here
			my @parts= split m{ ( \*\*? | / ) }x, $pattern;
			my $re_text= '^'.join('', map { $_ eq '/'? '/' : $_ eq '*'? '([^/]+)' : $_ eq '**'? '(.*?)' : "\Q$_\E" } @parts).'$';
			# WHEE!  Processing regular expressions with regular expressions!
			# "/**/" needs to match "/" and "/**" needs to match ""
			$re_text =~ s, / \( \. \* \? \) ( / | \$ ) ,(?|/(.*?)|())$1,xg;
			# If prefix ends with '/', then "**/" can also match ""
			$re_text =~ s,\^ \( \. \* \? \) / ,(?|(.*?)/|()),x
				if substr($prefix, -1) eq '/';
			$pat_item->[NODE_PATTERN_REGEX]= qr/$re_text/;
		}
	}
}

# 1.  Check full path vs. hash of constants.  If exists, iterate each action.
# 2.  For each other option in node:
# 2.1   Compare regex of option vs. path.  If matches:
# 2.1.1    If option has a hashref, pop one element from the captures and descend into sub-node.
# 2.1.2    Upon return, use "backtrack" (if any) to descend into a different sub-node.
# 2.1.2    Else, iterate actions in remaining elements of arraay

sub _search_tree {
	my ($self, $node, $path, $callback, $captures)= @_;
	my $actions;
	# Step 1, quickly dispatch any static path, or exact-matching wildcard prefix
	$DEBUG->("test '$path' vs constant (".join(', ', map "'$_'", keys %{$node->[NODE_LEAF_PATHS]}).')') if $DEBUG;
	if ($node->[NODE_LEAF_PATHS] && ($actions= $node->[NODE_LEAF_PATHS]{$path})) {
		$DEBUG->("  checking ".@$actions." actions") if $DEBUG;
		$callback->($_, $captures) && return 1
			for @$actions;
	}
	# Step 2, check for a path that we can capture a portion of, or otherwise match with a regex.
	# Node contains a list of patterns, each with a regex, an optional subtree, and optional actions.
	# $opt: [ qr/.../, \%subtree, @actions ];
	for my $pat (@{$node}[NODE_FIRST_PATTERN..$#$node]) {
		$DEBUG->("test '$path' vs pattern ".$pat->[NODE_PATTERN_REGEX]) if $DEBUG;
		if (my @cap= ($path =~ $pat->[NODE_PATTERN_REGEX])) {
			# If the option has sub-paths, then descend into one of those
			if ($pat->[NODE_PATTERN_SUBNODES]) {
				my $prefix= pop @cap;
				# The regex captures the longest prefix, but there might be shorter prefixes
				# that yield a match.  The prefixes are recorded as ->[NODE_BACKTRACK], so
				# loop through them like a linked list.
				while (defined $prefix) {
					my $subnode= $pat->[NODE_PATTERN_SUBNODES]{$prefix}
						or die "BUG: invalid path tree (no '$prefix' subtree when '$path' matches ".$pat->[NODE_PATTERN_REGEX].")";
					my $remainder= substr($path, $-[-1]+length($prefix));
					$DEBUG->((@cap? "captured ".join('', map "'$_' ", @cap).", " : '')."descend into '$prefix'") if $DEBUG;
					$self->_search_tree($subnode, $remainder, $callback, [ @$captures, @cap ]) && return 1;
					
					$DEBUG->("backtrack to ".($subnode->[NODE_BACKTRACK]//'previous node')) if $DEBUG;
					$prefix= $subnode->[NODE_BACKTRACK];
				}
			}
			# Else the regex does not represent a prefix, and we have finished
			# a match, and need to check all the actions.
			else {
				@cap= ( @$captures, @cap );
				$DEBUG->("  checking ".@{$pat->[NODE_PATTERN_ACTIONS]}." actions") if $DEBUG;
				$callback->($_, \@cap) && return 1
					for @{$pat->[NODE_PATTERN_ACTIONS]};
			}
		}
	}
	# No match, but might need to backtrack to a different wildcard from caller
	return undef;
}

1;
