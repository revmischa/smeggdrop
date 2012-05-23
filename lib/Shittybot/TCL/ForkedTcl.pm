package Shittybot::TCL::ForkedTcl;

use Moose;

use Tcl;
use Storable qw(freeze thaw); #used to serialize arguments
use ForkRing;
use Data::Dump  qw/ddx/;
use Data::Dumper;
use Try::Tiny;
use TclEscape;
use Shittybot::Command::Context;
use AnyEvent;
use Digest::SHA1;
use bytes;

# NOTE: forking is disabled atm
# TODO: most of the stuff in here probably belongs in TCL.pm

# This wraps a TCL interpreter in a Fork Ring
# So if the interpretter dies then the old hot one is still alive
# This assumes a cool operating system like Linux
# where FORK actually is useful. If you're not using a cool operating
# system you probably don't want this.

has tcl_forkring => (
    is => 'rw',
    isa => 'ForkRing',
);

has 'initted' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
);

has 'tcl' => (
    is => 'ro',
    isa => 'Shittybot::TCL',
    required => 1,
    weak_ref => 1,
);

sub BUILD {
    my ($self) = @_;

    $self->init;
} 

sub init {
    my ($self) = @_;

    my $callback = sub {
        my ($baby, $data) = @_;

	return try {
	    my ($command, $ctx_ref) = @{ thaw($data) };

	    # deserialize context
	    my $ctx = Shittybot::Command::Context->new(%$ctx_ref);

	    my $res;
	    if ($command eq "Eval") {
		$res = $self->safe_eval($ctx);
	    } else {
		die "What is command: $command?";
	    }

	    return $res;
	} catch {
	    my ($err) = @_;
	    return $err;
	}
    };

    # create forkring
    my $fork_ring = ForkRing->new(
	code => $callback,
	timeoutSeconds => 15,
    );
    $self->tcl_forkring($fork_ring);

    $self->initted(1);
}

# forks child, asks it to eval a command context
sub fork_eval {
    my $self = shift;
    my Shittybot::Command::Context $ctx = shift;

    die "Not initialized" unless $self->initted;

    # for now skip forking. it breaks anyevent.
    return $self->tcl->versioned_eval($ctx);

    # (disabled) fork and eval in child
    my @cargs = ("Eval", { %$ctx });
    return $self->strip_or_die(
	$self->tcl_forkring->send(freeze \@cargs)
    );
}

sub EvalFile {
    my ($self,@args) = @_;
    die "Not initiliazed" unless $self->initted();
    my @cargs = ("EvalFile", @args);
    return $self->strip_or_die( 
	$self->tcl_forkring->send(freeze \@cargs)
    );
}

sub strip_or_die {
    my ($self,$hash) = @_;
    if ($hash->{success}) {
        return $hash->{results};
    } elsif ($hash->{failure}) {
        return "Failure: ".$hash->{results};
    } else {
        ddx("Unknown message");
        ddx($hash);
        die "Unknown message!";
    }
}

# not sure about this
sub tcl_escape {
    return TclEscape::escape($_[0]);
}

1;
