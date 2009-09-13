package Plack::Impl::AnyEvent;
use strict;
use warnings;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use Plack::Util;
use HTTP::Status;
use IO::Handle;

sub new {
    my($class, %args) = @_;

    my $self = bless {}, $class;
    $self->{host} = delete $args{host} || undef;
    $self->{port} = delete $args{port} || undef;

    $self;
}

sub run {
    my($self, $app) = @_;

    my $guard = tcp_server $self->{host}, $self->{port}, sub {

        my ( $sock, $peer_host, $peer_port ) = @_;

        if ( !$sock ) {
            return;
        }

        my $env = {
            SERVER_PORT       => $self->{prepared_port},
            SERVER_NAME       => $self->{prepared_host},
            SCRIPT_NAME       => '',
            'psgi.version'    => [ 1, 0 ],
            'psgi.errors'     => *STDERR,
            'psgi.url_scheme' => 'http',
            'psgi.async'      => 1,
            'psgi.run_once'     => Plack::Util::FALSE,
            'psgi.multithread'  => Plack::Util::FALSE,
            'psgi.multiprocess' => Plack::Util::FALSE,
            REMOTE_ADDR       => $peer_host,
        };

        # Note: broken pipe in test is maked by Test::TCP.
        my $handle;
        $handle = AnyEvent::Handle->new(
            fh       => $sock,
            timeout  => 3,
            on_eof   => sub { undef $handle; undef $env; },
            on_error => sub { undef $handle; undef $env; warn $! },
            on_timeout => sub { undef $handle; undef $env; },
        );

        my $parse_header;
        $parse_header = sub {
            my ( $handle, $chunk ) = @_;
            $chunk =~ s/[\r\l\n\s]+$//;
            if ( $chunk =~ /^([^()<>\@,;:\\"\/\[\]?={} \t]+):\s*(.*)/i ) {
                my ($k, $v) = ($1,$2);
                $k =~ s/-/_/;
                $k = uc $k;
                if ($k !~ /^(?:CONTENT_LENGTH|CONTENT_TYPE)$/i) {
                    $k = "HTTP_$k";
                }

                if (exists $env->{ $k }) {
                    $env->{ $k } .= ", $v";
                } else {
                    $env->{ $k } = $v;
                }
            }
            if ( $chunk =~ /^$/ ) {
                my $start_response = sub {
                    my ($status, $headers) = @_;
                    $handle->push_write("HTTP/1.0 $status @{[ HTTP::Status::status_message($status) ]}\r\n");
                    while (my ($k, $v) = splice(@$headers, 0, 2)) {
                        $handle->push_write("$k: $v\r\n");
                    }
                    $handle->push_write("\r\n");
                    return Plack::Util::response_handle(
                        write => sub { $handle->push_write($_[0]) },
                        close => sub { $handle->push_shutdown },
                    );
                };
                my $do_it = sub {
                    my $res = $app->($env, $start_response);
                    return if scalar(@$res) == 0;

                    $start_response->($res->[0], $res->[1]);

                    my $body = $res->[2];
                    if ( ref $body eq 'GLOB') {
                        my $read; $read = sub {
                            my $w; $w = AnyEvent->io(
                                fh => $body,
                                poll => 'r',
                                cb => sub {
                                    $body->read(my $buf, 4096);
                                    $handle->push_write($buf);
                                    if ($body->eof) {
                                        undef $w;
                                        $body->close;
                                        $handle->push_shutdown;
                                    } else {
                                        $read->();
                                    }
                                },
                            );
                        };
                        $read->();
                    }
                    else {
                        my $cb = sub { $handle->push_write($_[0]) };
                        Plack::Util::foreach( $body, $cb );
                        $handle->push_shutdown();
                    }
                };
                if ($env->{CONTENT_LENGTH} && $env->{REQUEST_METHOD} =~ /^(?:POST|PUT)$/) {
                    # XXX Oops
                    $handle->push_read(
                        chunk => $env->{CONTENT_LENGTH}, sub {
                            my ($handle, $data) = @_;
                            open my $input, "<", \$data;
                            $env->{'psgi.input'}      = $input;
                            $do_it->();
                        }
                    );
                } else {
                    my $data = '';
                    open my $input, "<", \$data;
                    $env->{'psgi.input'}      = $input;
                    $do_it->();
                }
            }
            else {
                $handle->push_read( line => $parse_header );
            }
          };

        $handle->push_read(
            line => sub {
                my $handle = shift;
                local $_ = shift;
                m/^(\w+)\s+(\S+)(?:\s+(\S+))?\r?$/;
                $env->{REQUEST_METHOD}  = $1;
                my $request_uri = $2;
                $env->{SERVER_PROTOCOL} = $3 || 'HTTP/0.9';

                my ( $file, $query_string )
                            = ( $request_uri =~ /([^?]*)(?:\?(.*))?/s );    # split at ?
                $env->{PATH_INFO} = $file;
                $env->{QUERY_STRING} = $query_string || '';

                # HTTP/0.9 didn't have any headers (H::S::S's author think)
                if ( $env->{SERVER_PROTOCOL} =~ m{HTTP/(\d(\.\d)?)$} and $1 >= 1 ) {
                    $handle->push_read(
                        line => $parse_header,
                    );
                }
            }
        );
        return;
      }, sub {
        my ( $fh, $host, $port ) = @_;
        $self->{prepared_host} = $host;
        $self->{prepared_port} = $port;
        return 0;
      };
    $self->{listen_guard} = $guard;
}

sub run_loop {
    AnyEvent->condvar->recv;
}

1;
__END__

# note: regexps taken from HSS

=head1 NAME

Plack::Impl::AnyEvent - AnyEvent based HTTP server

=head1 SYNOPSIS

  my $server = Plack::Impl::AnyEvent->new(
      host => $host,
      port => $port,
  );
  $server->run($app);

=head1 DESCRIPTION

This implementation is considered highly experimental.

=cut
