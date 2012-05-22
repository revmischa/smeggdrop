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

# the actual TCL interpreter
has 'interp' => (
    is => 'ro',
    isa => 'Tcl',
    handles => [qw/ export_to_tcl /],
);

# path to saved state on disk
has 'state_path' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

# indices of proc/var => file
has 'indices' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} },
);

sub BUILD {
    my ($self) = @_;

    my $interp = $self->interp;
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

    my $fork_ring = ForkRing->new(
	code => $callback,
	timeoutSeconds => 15,
    );
    $self->tcl_forkring($fork_ring);

    $self->load_state;
    $self->initted(1);
}

# wrap a Tcl eval in a perl eval
# returns ($result, $success)
# if $success == 0, $result will be err str
sub safe_eval {
    my ($self, $ctx) = @_;

    my $res;
    my $ok;
    try {
	$self->export_ctx_to_tcl($ctx);
	my $command = $ctx->command;

	$res = $self->interp->Eval($command);

	$ok = 1;
    } catch {
	my ($err) = @_;
	#$err =~ s/(at lib.+)$//smg;
	$res = "Error: $err";
	$ok = 0;
    };

    return ($res, $ok);
}

sub load_state {
    my ($self) = @_;

    $self->load_state_object("procs");
    $self->load_state_object("vars");
}

sub load_state_object {
    my ($self, $type) = @_;

    # load data mapping from index and data files
    my $map = $self->load_index($type);

    warn "Read " . (scalar(keys %$map)) . " $type from index...\n";
    my $ok = 0;
    while (my ($name, $data) = each %$map) {
	try {
	    if ($type eq 'vars') {
		my ($kind, $val) = split(' ', $data, 2);
		if ($kind eq 'scalar') {
		    $self->interp->Eval("set {$name} $val", Tcl::EVAL_GLOBAL);
		} elsif ($kind eq 'array') {
		    $self->interp->Eval("array set {$name} $val", Tcl::EVAL_GLOBAL);
		} else {
		    die "unknown saved var type $kind";
		}
	    } elsif ($type eq 'procs') {
		$self->interp->Eval("proc {$name} $data");
	    } else {
		die "wtf";
	    }

	    $ok++;
	} catch {
	    my ($err) = @_;
	    warn "Failed to load $name: $err";
	}
    }
    warn "Installed $ok $type.\n";
}

# loads a mapping of item => filename from disk
sub load_index {
    my ($self, $type) = @_;

    # path to vars/procs/metadata
    my $state_path = $self->state_path;

    my $index_fh;
    my $lines;
    open($index_fh, "$state_path/$type/_index") or die $!;
    {
	local $/;
	$lines = <$index_fh>
    }
    close($index_fh);

    $lines =~ s/\n/\\\n/smg;
    my %index = $self->interp->Eval("list $lines");

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
	    warn "Failed to load anything from $data_path";
	    next;
	}

	$ret->{$name} = $data;
    }

    return $ret;
}

sub get_tcl_var {
    my ($self, $var, $flags) = @_;

    return $self->interp->GetVar($var);
}

# evaluates $command, tracking changes to vars and procs
sub versioned_eval {
    my ($self, $command) = @_;

    # save state before eval
    my $pre_state = $self->state;

    # evaluate command in tcl interpreter
    my ($res, $ok) = $self->safe_eval($command);

    # return err msg on failure
    return $res unless $ok; 

    # get state after eval, compare with before state
    my $post_state = $self->state;

    # compare before and after state
    my $changes = $self->compare_states($pre_state, $post_state);

    $self->update_saved_state($changes);

    return $res;
}

# updates the proc and var state files and indices
sub update_saved_state {
    my ($self, $changes) = @_;

    my $procs = $changes->{procs} || {};
    my $vars  = $changes->{vars}  || {};

    $self->save(procs => $procs);
    $self->save(vars  => $vars);
}

# write to disk and update index
sub save {
    my ($self, $category, $data) = @_;

    my $index = $self->indices->{$category}
        or die "Didn't find loaded index for $category";

    my $dir = $self->state_path . "/$category";

    while (my ($k, $v) = each %$data) {
	my $sha1 = Digest::SHA1::sha1_hex($k);

	# sanity check
	my $current = $index->{$k};
	if ($current && $current ne $sha1) {
	    warn "Found value for $k in index but it was not what we expected! ($current != $sha1)";
	    next;
	}

	# locate file
	my $state_path = "$dir/$sha1";
	my $state_fh;
	unless (open($state_fh, ">", $state_path)) {
	    warn "Failed to save $k: $!";
	    next;
	}

	# write current value
	print $state_fh $v;
	close($state_fh);

	warn "Updated $k in $state_path with '$v'\n";

	# update index
	$index->{$k} = $sha1;
    }

    $self->save_index($category, $index);
}

sub save_index {
    my ($self, $category, $index) = @_;

    my $index_path = $self->state_path . "/$category/_index";
    my $fh;
    unless (open($fh, ">", $index_path)) {
	warn "Error saving index: $!";
	return;
    }

    # serialize index
    while (my ($k, $v) = each %$index) {
	print $fh "{$k} $v\n";
    }

    close($fh);
}

# compare procs and vars before and after eval, returns changes
sub compare_states {
    my ($self, $pre, $post) = @_;

    my $changed = {};

    foreach my $category ('procs', 'vars') {
	while (my ($k, $v) = each %{ $pre->{$category} }) {
	    my $post_v = $post->{$category}{$k};

	    # did it change?
	    next unless ( (! $v && $post_v) || ($v && ! $post_v) || $v ne $post_v );

	    # $k changed from $v to $post_v
	    $changed->{$category}{$k} = $post_v;
	}
	while (my ($k, $v) = each %{ $post->{$category} }) {
	    # already got this one?
	    next if $changed->{$category}{$k};

	    my $pre_v = $pre->{$category}{$k};

	    # did it change?
	    next unless ( (! $v && $pre_v) || ($v && ! $pre_v) || $v ne $pre_v );

	    # $k changed from $pre_v to $v
	    $changed->{$category}{$k} = $v;
	}
    }

    return $changed;
}

# return contents of all procs and vars
sub state {
    my ($self) = @_;

    return {
	procs => $self->procs,
	vars => $self->vars,
    };
}

# returns hashref of proc => body
sub procs {
    my ($self) = @_;

    my $res = {};
    my $interp = $self->interp;
    my @proc_names = $interp->Eval('info procs');

    foreach my $proc (@proc_names) {
	my $args = $interp->Eval("info args {$proc}");
	my $body = $interp->Eval("info body {$proc}");
	$res->{$proc} = "{$args} {$body}";
    }

    return $res;
}

# returns hashref of var => serialized
sub vars {
    my ($self) = @_;

    my $res = {};
    my $interp = $self->interp;
    my @var_names = $interp->Eval('info vars');

    foreach my $var (@var_names) {
	# is it an array?
	my $is_array = $interp->Eval("array exists {$var}");
	if ($is_array) {
	    $res->{$var} = 'array {' . $interp->Eval("array get {$var}") . '}';
	} else {
	    $res->{$var} = 'scalar {' . $interp->Eval("set {$var}") . '}';
	}
    }

    return $res;
}

# deserialize context from interpreter vars
sub context {
    my ($self) = @_;

    my @vars_to_import = qw/channel nick mask command/;
    my %ctx;
    foreach my $var (@vars_to_import) {
	my $val = $self->get_tcl_var('context:' . $var);
	$ctx{$var} = $val;
    }

    return Shittybot::Command::Context->new(%ctx);
}

# serialize current command context as tcl vars in context::*
sub export_ctx_to_tcl {
    my ($self, $ctx) = @_;

    # set current ctx vars
    my @vars_to_export = qw/channel nick mask command/;
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

    die "Not initialized" unless $self->initted;

    # for now skip forking. it breaks anyevent.
    return $self->versioned_eval($ctx);

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
