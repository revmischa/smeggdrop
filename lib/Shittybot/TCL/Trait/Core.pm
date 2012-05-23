package Shittybot::TCL::Trait::Core;

# exports some common utility functions from perl to TCL

use Moose::Role;

after 'BUILD' => sub {
    my ($self) = @_;

    $self->export_to_tcl(
	namespace => 'core',
	subs => {
	    'say' => sub { $self->say(@_) },
	},
    );
};

# say something in the current channel
sub say {
    my ($self, @args) = @_;

    $self->reply(@args);
    return;
}

1;
