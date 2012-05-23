package Shittybot::Command::Context;

# represents the context in which a current command is being executed

use Moose;

has 'command' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'channel' => (
    is => 'ro',
    isa => 'Str|Undef',
);

has 'nick' => (
    is => 'ro',
    isa => 'Str|Undef',
);

has 'mask' => (
    is => 'ro',
    isa => 'Str|Undef',
);

has 'loglines' => (
    is => 'ro',
    isa => 'ArrayRef',
    default => sub { [] },
);

sub args {
    my ($self) = @_;

    my $cmd = $self->command;
    $cmd =~ s/^(\s*\S+\s*)//;
    return $cmd;
}

__PACKAGE__->meta->make_immutable;

