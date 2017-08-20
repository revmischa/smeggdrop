package Shittybot::TCL::Trait::Core;

# exports some common utility functions from perl to TCL

use Moose::Role;
use Digest::SHA1 qw/sha1_hex/;
use LWP::UserAgent;
use feature 'say';
use Data::Dump qw/ddx/;

before 'init_interp' => sub {
    my ($self) = @_;

    $self->export_procs_to_slave(core => {
        'bot_say' => \&bot_say,
        'print' => \&_print,
        'sha1' => \&sha1_hex,
        'curl' => \&curl,
    });
};

sub _print {
    my ($self, @args) = @_;

    say @args;
}

# say something in the current channel
sub bot_say {
    my ($self, @args) = @_;

    $self->reply("@args");
    return;
}

sub curl {
    my ($self, @args) = @_;

    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new(GET => $args[0]);
    my $res = $ua->request($req);
    return [$res->code, $res->content];
}

1;
