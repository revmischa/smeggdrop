package Shittybot::TCL::ForkedTcl;
use Moose;
use Tcl;
use Storable qw(freeze thaw); #used to serialize arguments
use ForkRing;
use Data::Dump  qw/ddx/;

# This wraps a TCL interpreter in a Fork Ring
# So if the interpretter dies then the old hot one is still alive
# This assumes a cool operating system like Linux
# where FORK actually is useful. If you're not using a cool operating
# system you probably don't want this.

has tcl => ( is => 'rw', isa => 'ForkRing' );
has inited => ( is => 'rw', isa => 'Int', default => 0 );
has interp => ( is => 'ro', isa => 'Tcl' );


sub Init {
    my ($self) = @_;
    $self->inited(1);
    my $tcl = $self->interp();
    my $callback = sub {
        my ($self,$data) = @_;
        my ($command,$arg) = @{ thaw($data) };
        my $evalfile = $arg;
        if ($command eq "Eval") {
            ddx("Sending Eval $arg");
            return $tcl->Eval( $arg );
        } elsif ($command eq "EvalFile") {
            ddx("Sending EvalFile $arg");
            return $tcl->EvalFile( $evalfile );
        } else {
            die "What is command: $command?";
        }
    };
    my $fork_ring = ForkRing->new( code => $callback, timeoutSeconds => 30 );
    $self->tcl( $fork_ring );
}

sub Eval {
    my ($self,@args) = @_;
    die "Not initiliazed" unless $self->inited();
    my @cargs = ("Eval", @args);
    return $self->strip_or_die(
                               $self->tcl()->send( freeze \@cargs )
                              );

}

sub EvalFile {
    my ($self,@args) = @_;
    die "Not initiliazed" unless $self->inited();
    my @cargs = ("EvalFile", @args);
    return $self->strip_or_die( 
                               $self->tcl()->send( freeze \@cargs )
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

1;
