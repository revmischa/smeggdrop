package Shittybot::TCL::Loader;

# Loads saved state (procs/vars/meta) from disk

use Moose;
use feature 'say';
use Tcl;
use Try::Tiny;
use bytes;

has 'interp' => (
    is => 'ro',
    isa => 'Tcl',
    required => 1,
);

has 'state_path' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

# indices of proc/var => file
has 'indices' => (
    is => 'ro',
    isa => 'HashRef',
    required => 1,
);

# load procs/vars/meta from disk
sub load_state {
    my ($self) = @_;

    say "Loading state...";
    $self->load_state_object("procs");
    $self->load_state_object("vars");
}

# load a set of serialized objects (procs, vars) from disk,
# deserialize and install them in the tcl interp
sub load_state_object {
    my ($self, $type) = @_;

    # load data mapping from index and data files
    my $map = $self->load_index($type);

    warn "Read " . (scalar(keys %$map)) . " $type from index... ";
    my $ok = 0;
    while (my ($name, $data) = each %$map) {
	try {
	    if ($type eq 'vars') {
		my ($kind, $val) = split(' ', $data, 2);
		if ($kind eq 'scalar') {
		    $self->interp->eval_in_safe("set {$name} $val", Tcl::EVAL_GLOBAL);
		} elsif ($kind eq 'array') {
		    $self->interp->eval_in_safe("array set {$name} $val", Tcl::EVAL_GLOBAL);
		} else {
		    die "unknown saved var type $kind";
		}
	    } elsif ($type eq 'procs') {
		$self->interp->eval_in_safe("proc {$name} $data");
	    } else {
		die "wtf";
	    }

	    $ok++;
	} catch {
	    my ($err) = @_;
	    warn "Failed to load $name: $err";
	}
    }
    warn "installed $ok $type.\n";
}

# loads a mapping of item => filename from disk
sub load_index {
    my ($self, $type) = @_;

    # path to vars/procs/metadata
    my $state_path = $self->state_path;

    my $index_fh;
    my $lines;
    my $index_path = "$state_path/$type/_index";
    die "$index_path does not exist" unless -e $index_path;
    open($index_fh, $index_path) or die $!;
    {
	local $/;
	$lines = <$index_fh>
    }
    close($index_fh);

    $lines =~ s/\n/\\\n/smg;
    my %index = $self->interp->eval_in_safe("list $lines");

    # save raw index for later
    $self->indices->{$type} = \%index;

    # load data from files
    # TODO: asynchrify this for massively improved loading time plz
    my $ret = {};
    while (my ($name, $sha1) = each %index) {
	my $data_fh;
	my $data_path = "$state_path/$type/$sha1";
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
	    warn "Failed to load anything from $data_path. Deleting.\n";
	    unlink $data_path;
	    next;
	}

	$ret->{$name} = $data;
    }

    return $ret;
}

__PACKAGE__->meta->make_immutable;
