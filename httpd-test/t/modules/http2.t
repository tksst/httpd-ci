use strict;
use warnings FATAL => 'all';

use Apache::Test;
use Apache::TestRequest;
use Apache::TestUtil;
use Apache::TestConfig ();

my $num_suite = 24;
my $vhost_suite = 3;

my $total_tests = 2 * $num_suite;

my $alpn_available = exists &Net::SSLeay::CTX_set_alpn_protos;
if ($alpn_available) {
    $total_tests += $vhost_suite;
}

plan tests => $total_tests, need_module 'http2', need_module 'Protocol::HTTP2::Client', need_min_apache_version('2.4.17');

Apache::TestRequest::module("http2");

my $config = Apache::Test::config();
my $host       = $config->{vhosts}->{h2c}->{servername};
my $port       = $config->{vhosts}->{h2c}->{port};

my $shost      = $config->{vhosts}->{h2}->{servername};
my $sport      = $config->{vhosts}->{h2}->{port};
my $serverdir  = $config->{vars}->{t_dir};
my $htdocs     =  $serverdir . "/htdocs";

require Protocol::HTTP2::Client;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Net::SSLeay;
use AnyEvent::TLS;

Net::SSLeay::initialize();

sub connect_and_do {
    my %args = (
        @_
    );
    my $scheme = $args{ctx}->{scheme};
    my $host   = $args{ctx}->{host};
    my $port   = $args{ctx}->{port};
    my $client = $args{ctx}->{client};
    my $w = AnyEvent->condvar;

    tcp_connect $host, $port, sub {
        my ($fh) = @_ or do {
            print "connection failed: $!\n";
            $w->send;
            return;
        };
        
        my $tls;
        my $tls_ctx;
        if ($scheme eq 'https') {
            $tls = "connect";
            eval {
                # ALPN (Net-SSLeay > 1.55, openssl >= 1.0.1)
                if ( $alpn_available ) {
                    $tls_ctx = AnyEvent::TLS->new( method => "TLSv1_2", );
                    Net::SSLeay::CTX_set_alpn_protos( $tls_ctx->ctx, ['h2'] );
                }
                else {
                    $tls_ctx = AnyEvent::TLS->new();
                }
            };
            if ($@) {
                print "Some problem with SSL CTX: $@\n";
                $w->send;
                return;
            }
        }
        
        my $handle;
        $handle = AnyEvent::Handle->new(
            fh       => $fh,
            tls      => $tls,
            tls_ctx  => $tls_ctx,
            autocork => 1,
            on_error => sub {
                $_[0]->destroy;
                print "connection error\n";
                $w->send;
            },
            on_eof => sub {
                $handle->destroy;
                $w->send;
            }
        );
        
        # First write preface to peer
        while ( my $frame = $client->next_frame ) {
            $handle->push_write($frame);
        }
        
        $handle->on_read(sub {
            my $handle = shift;
            
            $client->feed( $handle->{rbuf} );
            $handle->{rbuf} = undef;
            
            while ( my $frame = $client->next_frame ) {
                $handle->push_write($frame);
            }
            
            # Terminate connection if all done
            $handle->push_shutdown if $client->shutdown;
        });
    };
    $w->recv;
    
}

################################################################################
#
# Add a request to the client, will be started whenever a STREAM to
# the server is available.
#
sub add_request {
    my ($scheme, $client, $host, $port);
    my %args = (
        method  => 'GET',
        headers => [],
        rc      => 200,
        on_done => sub {
            my %args = ( @_ );
            my $ctx  = $args{ctx};
            my $req  = $args{request};
            my $resp = $args{response};
            my $hr = $resp->{headers};
            my %headers = @$hr;
            ok t_cmp($headers{':status'}, $req->{rc}, 
                "$req->{method} $ctx->{scheme}://$ctx->{host}:$ctx->{port}$req->{path}");
        },
        @_
    );
    $client = $args{ctx}->{client};
    $scheme = $args{ctx}->{scheme};
    $host   = $args{ctx}->{host};
    $port   = $args{ctx}->{port};
    
    $client->request(
        ':scheme'    => $scheme,
        ':authority' => $args{authority} || $host . ':' . $port,
        ':path'      => $args{path},
        ':method'    => $args{method},
        headers      => $args{headers},
        on_done      => sub {
            my ($headers, $data) = @_;
            $args{on_done}(
                ctx      => $args{ctx}, 
                request  => \%args,
                response => { headers => \@$headers, data => $data }
            );        
        }
    );
}

################################################################################
#
# Add a list of request that will be processed in order. Only when the previous
# request is done, will a new one be started.
#
sub add_sequential {
    my ($scheme, $client, $host, $port);
    my %args     = ( @_ );
    my $ctx      = $args{ctx};
    my $requests = $args{requests};
    
    $client = $args{ctx}->{client};
    $scheme = $args{ctx}->{scheme};
    $host   = $args{ctx}->{host};
    $port   = $args{ctx}->{port};
    
    my $request = shift @$requests;
    
    if ($request) {
        my %r = (
            method  => 'GET',
            headers => [],
            rc      => 200,
            on_done => sub {
                my %args = ( @_ );
                my $ctx  = $args{ctx};
                my $req  = $args{request};
                my $resp = $args{response};
                my $hr = $resp->{headers};
                my %headers = @$hr;
                ok t_cmp($headers{':status'}, $req->{rc}, 
                    "$req->{method} $ctx->{scheme}://$ctx->{host}:$ctx->{port}$req->{path}");
            },
            %$request
        );
        
        print "test case: $r{descr}: $r{method} $ctx->{scheme}://$ctx->{host}:$ctx->{port}$r{path}\n";
        $client->request(
            ':scheme'    => $scheme,
            ':authority' => $r{authority} || $host . ':' . $port,
            ':path'      => $r{path},
            ':method'    => $r{method},
            headers      => $r{headers},
            on_done      => sub {
                my ($headers, $data) = @_;
                $r{on_done}(
                    ctx      => ${ctx}, 
                    request  => \%r,
                    response => { headers => \@$headers, data => $data }
                );
                add_sequential(
                    ctx => $ctx,
                    requests => $requests
                );
            }
        );
    }
}

sub cmp_content_length {
    my %args = ( @_ );
    my $ctx  = $args{ctx};
    my $req  = $args{request};
    my $resp = $args{response};
    my $hr = $resp->{headers};
    my %headers = @$hr;
    ok t_cmp($headers{':status'}, $req->{rc}, "response status");
    ok t_cmp(length $resp->{data}, $req->{content_length}, "content-length");
}

sub cmp_content {
    my %args = ( @_ );
    my $ctx  = $args{ctx};
    my $req  = $args{request};
    my $resp = $args{response};
    my $hr = $resp->{headers};
    my %headers = @$hr;
    ok t_cmp($headers{':status'}, $req->{rc}, "response status");
    ok t_cmp($resp->{data}, $req->{content}, "content comparision");
}

sub cmp_file_response {
    my %args = ( @_ );
    my $ctx  = $args{ctx};
    my $req  = $args{request};
    my $resp = $args{response};
    my $hr = $resp->{headers};
    my %headers = @$hr;
    ok t_cmp($headers{':status'}, $req->{rc}, "response status");
    open(FILE, "<$htdocs$req->{path}") or die "cannot open $req->{path}";
    undef $/;
    my $content = <FILE>;
    close(FILE);
    ok t_is_equal($resp->{data}, $content);
}

sub check_redir {
    my %args = ( @_ );
    my $ctx  = $args{ctx};
    my $req  = $args{request};
    my $resp = $args{response};
    my $hr = $resp->{headers};
    my %headers = @$hr;
    ok t_cmp($headers{':status'}, 302, "response status");
    ok t_cmp(
        $headers{location},
        "$ctx->{scheme}://$ctx->{host}:$ctx->{port}$req->{redir_path}", 
        "location header"
    );
}

################################################################################
#
# Perform common tests to h2c + h2 hosts
#
sub do_common {
    my %args = (
        scheme => 'http',
        host   => 'localhost',
        port   => 80,
        @_
    );
    my $true_tls = ($args{scheme} eq 'https' and $alpn_available);
    
    $args{client} = Protocol::HTTP2::Client->new( upgrade => 0 );
    
    my $r = [
        { 
            descr => 'TC0001, expecting 200',
            path => '/' 
        },
        {
            descr => 'TC0002, expecting 404',
            rc => 404, 
            path => '/not_here' 
        },
        {
            descr => 'TC0005, cmp index.html file',
            path => '/modules/h2/index.html',
            on_done => \&cmp_file_response
        },
        {
            descr => 'TC0006, cmp image file',
            path => '/modules/h2/003/003_img.jpg',
            on_done => \&cmp_file_response
        },
    ];
        
    if (have_module 'mod_rewrite') {
        push $r, {
            descr => 'TC0007, rewrite handling',
            path => '/modules/h2/latest.tar.gz',
            redir_path => "/modules/h2/xxx-1.0.2a.tar.gz",
            on_done => \&check_redir
        }
    }
    else {
        skip "skipping test as mod_rewrite not available" foreach(1..2);
    }
    
    if (have_cgi) {
        my $sni_host = $true_tls? 'localhost' : '';
        my $content = <<EOF;
<html><body>
<h2>Hello World!</h2>
TLS_SNI="$sni_host"
</body></html>
EOF

        push $r, {
            descr => 'TC0008, hello.pl with ssl vars',
            path    => '/modules/h2/hello.pl',
            content => $content,
            on_done => \&cmp_content,
        };
        
        $content = <<EOF;
<html><body>
<p>No query was specified.</p>
</body></html>
EOF
        push $r, {
            descr => 'TC0009, necho.pl without arguments',
            path    => '/modules/h2/necho.pl',
            content => $content,
            rc      => 400,
            on_done => \&cmp_content,
        };
        push $r, {
            descr => 'TC0010, necho.pl 2x10',
            path    => '/modules/h2/necho.pl?count=2&text=0123456789',
            content => "01234567890123456789",
            on_done => \&cmp_content,
        };
        push $r, {
            descr => 'TC0011, necho.pl 10x10',
            path    => '/modules/h2/necho.pl?count=10&text=0123456789',
            content_length => 100,
            on_done => \&cmp_content_length,
        };
        push $r, {
            descr => 'TC0012, necho.pl 100x10',
            path    => '/modules/h2/necho.pl?count=100&text=0123456789',
            content_length => 1000,
            on_done => \&cmp_content_length,
        };
        push $r, {
            descr => 'TC0013, necho.pl 1000x10',
            path    => '/modules/h2/necho.pl?count=1000&text=0123456789',
            content_length => 10000,
            on_done => \&cmp_content_length,
        };
        push $r, {
            descr => 'TC0014, necho.pl 10000x10',
            path    => '/modules/h2/necho.pl?count=10000&text=0123456789',
            content_length => 100000,
            on_done => \&cmp_content_length,
        };
        push $r, {
            descr => 'TC0015, necho.pl 100000x10',
            path    => '/modules/h2/necho.pl?count=100000&text=0123456789',
            content_length => 1000000,
            on_done => \&cmp_content_length,
        };
    }
    else {
        skip "skipping test as mod_cgi not available" foreach(1..1);
    }
 
    add_sequential(
        ctx => \%args,
        requests => $r
    );
    connect_and_do( ctx => \%args );
}

################################################################################
#
# Perform tests for virtual host setups, requires a client with SNI+ALPN
#
sub do_vhosts {
    my %args = (
        scheme => 'http',
        host   => 'localhost',
        port   => 80,
        @_
    );
    $args{client} = Protocol::HTTP2::Client->new( upgrade => 0 );
    
    my $r = [
        { 
            descr => 'VHOST000, expecting 200',
            path => '/' 
        },
        {
            descr => 'VHOST001, expect 404 or 421 (using Host:)',
            rc     => 421, 
            path   => '/misdirected', 
            header => [ 'host' => 'test.example.org' ] 
        },
        {
            descr => 'VHOST002, expect 404 or 421 (using :authority)',
            rc     => 421, 
            path   => '/misdirected', 
            authority => 'test.example.org:1234'
        },
    ];
        
    add_sequential(
        ctx => \%args,
        requests => $r
    );
    connect_and_do( ctx => \%args );
}

################################################################################
#
# Bring it on
#
do_common( 'scheme' => 'http', 'host' => $host, 'port' => $port );
do_common( 'scheme' => 'https', 'host' => $shost, 'port' => $sport );
if ($alpn_available) {
    do_vhosts( 'scheme' => 'https', 'host' => $shost, 'port' => $sport );
}

