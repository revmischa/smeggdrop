package Shittybot::TCL::Trait::Core;

# exports some common utility functions from perl to TCL

use Moose::Role;

after 'init_interp' => sub {
    my ($self) = @_;

    $self->export_procs_to_slave(core => {
	'say' => \&say,
    });
};

# say something in the current channel
sub say {
    my ($self, @args) = @_;

    $self->reply(@args);
    return;
}

1;
