package Shittybot::TCL;

use 5.01;
use Moose;

use Data::Dump  qw/ddx/;
use Data::Dumper qw(Dumper);

use Shittybot::TCL::ForkedTcl;
use Shittybot::Command::Context;

use Tcl;
use TclEscape;
use Try::Tiny;

BEGIN {
    with 'MooseX::Callbacks';
    with 'MooseX::Traits';
};

# save currently loaded interpreter to share across irc clients
our $TCL;

has 'state_path' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'irc' => (
    is => 'ro',
    isa => 'Shittybot',
    required => 1,
);

has 'tcl' => (
    is => 'ro',
    isa => 'Shittybot::TCL::ForkedTcl',
    lazy_build => 1,
    handles => [qw/ export_to_tcl get_tcl_var interp context /],
);

sub _build_tcl { 
    my ($self) = @_;

    return $TCL if $TCL;

    # init the interpreter
    my $interp = Tcl->new;

    # create forkring tcl interpreter
    my $tcl = Shittybot::TCL::ForkedTcl->new(
	interp => $interp,
	state_path => $self->state_path,
    );

    $TCL = $tcl;
    return $tcl;
}

sub BUILD {}

# eval a command and print the result in irc
sub call {
    my ($self, $ctx) = @_;

    my $channel = $ctx->channel;
    my $nick = $ctx->nick;

    my $ok = 0;
    my $res;
    try {
	# evals through ForkedTcl (possibly)
	$res = $self->tcl->Eval($ctx);
	$ok = 1;
    } catch {
	my ($err) = @_;
	$err =~ s/(at lib.+)$//smg;
	$self->irc->send_to_channel($channel, "$nick: Error evaluating: $err");
	$ok = 0;
    };
    
    return unless $ok;

    $self->irc->send_to_channel($channel, $res);
}

# say something in the current channel
sub reply {
    my ($self, @msg) = @_;

    my $context = $self->context;
    my $chan = $context->channel or die "Failed to find current context channel";
    $self->irc->send_to_channel($chan => "@msg");

    return;
}

__PACKAGE__->meta->make_immutable;
