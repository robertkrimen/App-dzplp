package App::dzplp;
# ABSTRACT: Run dzpl via a persistent Dist::Dzpl server

use strict;
use warnings;

use Net::ClientServer;
use AnyEvent::Handle;
use Cwd qw/ cwd /;
use JSON;
use Try::Tiny;

sub run {
    my $self = shift;
    my @arguments = @_;

    my $platform = Net::ClientServer->new(
        name => 'dzplp',
        home => 1,
        port => 5110,
        daemon => 1,
        fork => 1,
        start => sub {
            $0 = 'dzplp',
            umask 002;
            if ( 1 ) {
                for my $package (sort grep { 1 } App::dzplp::FindDistZilla->find) {
                    eval "require $package";
                    next if $@;
                }
            }
            require Dist::Dzpl::App;
            require JSON;
        },
        serve => sub {
            $SIG{CHLD} = 'DEFAULT';
            my $client = shift;
            return if $client->eof;
            my @json;
            while ( <$client> ) {
                chomp;
                last unless $_;
                push @json, "$_\n";
            }
            my $json = join '', @json;
            Net::ClientServer->stdin2socket( $client );
            Net::ClientServer->stdout2socket( $client );
            Net::ClientServer->stderr2socket( $client );
            #open STDERR, ">&STDOUT" or die "Can't redirect STDERR to STDOUT: $!";

            my $data =  
                try { JSON->new->decode( $json ) }
                catch { die "Unable to decode json: $_:\n$json" };
        
            my ( $directory, $arguments ) = @$data{qw/ directory arguments /};
            die "Missing directory" unless $directory;
            die "Missing arguments" unless $arguments;

            chdir $directory or die "Unable to chdir ($directory): $!";
            print "> Changed to $directory\n";

            chomp $arguments;
            my @arguments = split m/ /, $arguments;
            print "> Run \"$arguments\"\n";
            print "> \$^X is $^X\n" if 0;

            try {
                Dist::Dzpl::App->run( undef, @arguments );
            }
            catch {
                my $error = $_;
                chomp $error;
                warn "$error => $!";
            };

            $client->close;
        },
    );

    $platform->start;

    my $socket;
    while ( ! ( $socket = $platform->client_socket ) ) {
        print "> Waiting for server to start\n";
        sleep 1;
    }
    print "> Connected via $socket\n";

    my $done = AnyEvent->condvar;
    my $ae;
    $ae = AnyEvent::Handle->new(
        fh => $socket,
        on_eof => sub {
#            undef $ae;
            $done->send;
        },
        on_error => sub {
        },
        on_read => sub {
            my $hdl = shift;
            $hdl->push_read( line => sub {
                my ( undef, $line ) = @_;
                print $line, "\n";
            } );
        },
    );

    $ae->push_write( JSON->new->pretty->encode( {
        arguments => join( ' ', @ARGV ),
        directory => cwd,
    } ) );
    $ae->push_write( "\n" );

    $done->recv;
}

package App::dzplp::FindDistZilla;

use Module::Pluggable search_path => ['Dist::Zilla'], sub_name => 'find';

1;
