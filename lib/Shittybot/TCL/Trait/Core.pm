package Shittybot::TCL::Trait::Core;

# exports some common utility functions from perl to TCL

use Moose::Role;
use Digest::SHA1 qw/sha1_hex/;

after 'init_interp' => sub {
    my ($self) = @_;

    $self->export_procs_to_slave(core => {
        'saychan' => \&say,
        'sha1' => \&sha1_hex,
    });
};

# say something in the current channel
sub say {
    my ($self, @args) = @_;

    $self->reply("args: @args");
    return;
}

1;
