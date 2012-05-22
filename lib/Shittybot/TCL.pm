package Shittybot::TCL;

use 5.01;
use Moose;

use Data::Dump  qw/ddx/;
use Data::Dumper qw(Dumper);

use Shittybot::TCL::ForkedTcl;

use Tcl;
use TclEscape;
use Try::Tiny;

BEGIN {
    with 'MooseX::Callbacks';
    with 'MooseX::Traits';
};

our $TCL;
our $TCL_STATE_LOADED;

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
    handles => [qw/ export_to_tcl /],
);

sub _build_tcl { 
    my ($self) = @_;

    return $TCL if $TCL;

    # init the interpreter
    my $interp = Tcl->new;

    # create forkring tcl interpreter
    my $tcl = Shittybot::TCL::ForkedTcl->new( interp => $interp );
    $tcl->Init;

    $TCL = $tcl;
    return $tcl;
}

sub BUILD {
    my ($self) = @_;

    $self->tcl;
    $self->load_state;

    # export perl vars and methods to TCL here:
    $self->tcl->export_to_tcl(
	namespace => 'core',
	subs => {
	},
    );
}

sub load_state {
    my ($self) = @_;

    return if $TCL_STATE_LOADED;

    $self->load_state_object("procs");
    $self->load_state_object("vars");

    $TCL_STATE_LOADED = 1;
}

sub load_state_object {
    my ($self, $type) = @_;

    # path to vars/procs/metadata
    my $state_path = $self->state_path;

    # load data mapping from index and data files
    my $map = $self->load_index("$state_path/$type");

    warn "Loaded " . (scalar(keys %$map)) . " $type\n";
    my $ok = 0;
    while (my ($name, $data) = each %$map) {
	try {
	    if ($type eq 'vars') {
		my ($kind, $val) = split(' ', $data, 2);
		if ($kind eq 'scalar') {
		    $self->tcl->interp->Eval("set {$name} $val", Tcl::EVAL_GLOBAL);
		} elsif ($kind eq 'array') {
		    $self->tcl->interp->Eval("array set {$name} $val", Tcl::EVAL_GLOBAL);
		} else {
		    die "unknown saved var type $kind";
		}
	    } elsif ($type eq 'procs') {
		$self->tcl->interp->Eval("proc {$name} $data");
	    } else {
		die "wtf";
	    }

	    $ok++;
	} catch {
	    my ($err) = @_;
	    warn "Failed to load $name: $err";
	}
    }
    warn "Installed $ok $type\n";
}

# loads a mapping of item => filename from disk
sub load_index {
    my ($self, $dir) = @_;

    my $index_fh;
    my $lines;
    open($index_fh, "$dir/_index") or die $!;
    {
	local $/;
	$lines = <$index_fh>
    }
    close($index_fh);

    $lines =~ s/\n/\\\n/smg;
    my %index = $self->tcl->interp->Eval("list $lines");

    # load data from files
    # TODO: asynchrify this for massively improved loading time plz
    my $ret = {};
    while (my ($name, $sha1) = each %index) {
	my $data_fh;
	my $data_path = "$dir/$sha1";
	unless (open($data_fh, $data_path)) {
	    warn "Failed to load $name from state: $!";
	    next;
	}

	my $data;
	{
	    local $/;
	    $data = <$data_fh>;
	}
	close($data_fh);

	unless ($data) {
	    warn "Failed to load anything from $data_path";
	    next;
	}

	$ret->{$name} = $data;
    }

    return $ret;
}

# eval a command in a forked process and print the result to irc
sub perform {
    my ($self, $nick, $mask, $handle, $channel, $code) = @_;

    my $ok = 0;
    my $res;
    try {
	# evals through ForkedTcl
	$res = $self->tcl->Eval($code);
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

sub call {
  my ($self, $nick, $mask, $handle, $channel, $code, $loglines) = @_;

  # update the chanlist
  #my $update_chanlist = tcl_escape("cache put irc chanlist $chanlist");

  # perform the command
  return $self->perform($nick, $mask, $handle, $channel, $code);
}

#not sure about this
sub tcl_escape {
    return TclEscape::escape($_[0]);
}

__PACKAGE__->meta->make_immutable;
