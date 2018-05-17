package ConServeTestUtil;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT= qw(
	make_env
);
our %EXPORT_TAGS= ( all => \@EXPORT );

sub make_env {
	return {
		REQUEST_METHOD => 'GET',
		PATH_INFO => '/',
		QUERY_STRING => '',
		SERVER_NAME => 'localhost',
		SERVER_PORT => 0,
		'psgi.version' => [1,1],
		'psgi.url_scheme' => 'https',
		'psgi.input' => undef,
		'psgi.errors' => \*STDERR,
		'psgi.multithread' => 0,
		'psgi.multiprocess' => 0,
		'psgi.run_once' => 0,
		'psgi.nonblocking' => 0,
		'psgi.streaming' => 0,
		@_
	}
}

1;
