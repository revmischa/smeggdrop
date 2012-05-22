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

# This wraps a TCL interpreter in a Fork Ring
# So if the interpretter dies then the old hot one is still alive
# This assumes a cool operating system like Linux
# where FORK actually is useful. If you're not using a cool operating
# system you probably don't want this.

has tcl_forkring => (
    is => 'rw',
    isa => 'ForkRing',
);
has inited => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
);
has interp => (
    is => 'ro',
    isa => 'Tcl',
    handles => [qw/ export_to_tcl /],
);

sub Init {
    my ($self) = @_;
    $self->inited(1);
    my $interp = $self->interp;
    my $callback = sub {
        my ($baby, $data) = @_;

	return try {
	    my ($command, $ctx_ref) = @{ thaw($data) };

	    # deserialize context
	    my $ctx = Shittybot::Command::Context->new(%$ctx_ref);

	    my $res;
	    if ($command eq "Eval") {
		$res = $self->_eval($ctx);
	    } else {
		die "What is command: $command?";
	    }

	    return $res;
	} catch {
	    my ($err) = @_;
	    return $err;
	};
    };
    my $fork_ring = ForkRing->new( code => $callback, timeoutSeconds => 15 );
    $self->tcl_forkring($fork_ring);
}

sub get_tcl_var {
    my ($self, $var, $flags) = @_;

    return $self->interp->GetVar($var);
}

# eval $arg from forked child
sub _eval {
    my ($self, $ctx) = @_;

    my $interp = $self->interp;
    my $res;
    my $ok;
    try {
	$self->export_ctx_to_tcl($ctx);
	my $command = $ctx->command;
	$res = $interp->Eval($command);
	$ok = 1;
    } catch {
	my ($err) = @_;
	$res = "Error: $err";
	$ok = 0;
    };

    return $res;
}

# serialize current command context as tcl vars in context::*
sub export_ctx_to_tcl {
    my ($self, $ctx) = @_;

    # set current ctx vars
    my @vars_to_export = qw/channel nick mask handle command/;
    my %export_map;
    my $prefix = 'context:';
    foreach my $var (@vars_to_export) {
	my $val = $ctx->$var;
	$val = '' unless defined $val;
	
	# this blows up on non-scalar refs. how to export arrays/hashes?
	$export_map{$prefix . $var} = ref $val ? $val : \$val;
    }

    warn Dumper(\%export_map);

    $self->export_to_tcl(
	namespace => '',  # if this is set to anything other than '' the variables vanish!
	vars => \%export_map,
    );
}

# forks child, asks it to eval a command context
sub Eval {
    my $self = shift;
    my Shittybot::Command::Context $ctx = shift;

    die "Not initialized" unless $self->inited;

    return $self->_eval($ctx);

    my @cargs = ("Eval", { %$ctx });

    return $self->strip_or_die(
	$self->tcl_forkring->send(freeze \@cargs)
    );
}

sub EvalFile {
    my ($self,@args) = @_;
    die "Not initiliazed" unless $self->inited();
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
