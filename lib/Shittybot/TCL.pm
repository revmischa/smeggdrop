package Shittybot::TCL;

use Moose;

use bytes;
use feature 'say';

use Data::Dump  qw/ddx/;
use Data::Dumper qw(Dumper);

use Shittybot::TCL::Loader;
use Shittybot::Command::Context;

use Tcl;
use TclEscape;
use Try::Tiny;

BEGIN {
    with 'MooseX::Callbacks';
    with 'MooseX::Traits';
};

# master interpreter and indexes of procs/vars
our $INTERP;
our $INDICES = {};
sub indices { $INDICES }

has 'state_path' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'irc' => (
    is => 'ro',
    isa => 'Shittybot',
    required => 1,
    handles => [qw/ channel_msg /],
);

# the actual TCL interpreter
has 'interp' => (
    is => 'ro',
    isa => 'Tcl',
    handles => [qw/ export_to_tcl Eval EvalFile /],
    builder => '_build_interp',
);

# path to saved state on disk
has 'state_path' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

sub BUILD {
    my ($self) = @_;

    $self->init_interp;
}

sub slave_name {
    my ($self) = @_;
    return $self->irc->network;
}

sub _build_interp { 
    my ($self) = @_;

    my $lib_path = $self->tcl_library_path;

    # init the actual interpreter
    my $interp = $INTERP || Tcl->new;
    $INTERP ||= $interp;
    my $SLAVE_NAME = $self->slave_name;

    # prepare master interp
    #foreach my $lib (qw/http_package tclcurl/) {
    #    $interp->Eval(qq!source "$lib_path/${lib}.tcl"!, Tcl::EVAL_GLOBAL);
    #}

    # create slave interp from master
    my $slave = $interp->CreateSlave($SLAVE_NAME, 1);

    # load core tcl procs

    foreach my $lib (qw/meta_proc commands meta cache dict http_package tclcurl http/) {
        $interp->Eval(qq!interp invokehidden $SLAVE_NAME  source "$lib_path/${lib}.tcl"!, Tcl::EVAL_GLOBAL);
    }
    #$interp->Eval(qq!$SLAVE_NAME alias http_get http_get!);
    #$interp->Eval(qq!$SLAVE_NAME alias http http!);

    # clock is hidden or something?
    #$interp->Eval(qq!interp expose $SLAVE_NAME clock!);

    my $is_safe = $interp->Eval(qq!interp issafe $SLAVE_NAME!);
    unless ($is_safe) {
        warn "WARNING: RUNNING WITH UNSAFE SLAVE INTERPRETER!!";
    }

    return $slave;
}

sub tcl_library_path {
    my ($self) = @_;
    # get path to lib/
    # SKEEZY HACK: replace with something smarter
    use FindBin;
    my @lib_paths = ("$FindBin::Bin/tcl","./tcl");
    my $lib_path = undef; 
    foreach my $path (@lib_paths) {
       if (-e $path) { 
           $lib_path = $path;
           last;
       }
    }
    die "Could not find tcl source dir" unless defined($lib_path);
    return $lib_path;
}

# evaluates $command, tracking changes to vars and procs
sub versioned_eval {
    my ($self, $tcl) = @_;

    # save state before eval
    my $pre_state = $self->state;

    # evaluate tcl in interpreter
    my ($res, $ok) = $self->_safe_eval($tcl);

    # return err msg on failure

    # how do we know if we should reload state? i forget
    #$self->reload_state_if_necessary($pre_state);

    return ($res, $ok) unless $ok;

    # get state after eval, compare with before state
    my $post_state = $self->state;

    # compare before and after state
    my $changes = $self->compare_states($pre_state, $post_state);

    $self->update_saved_state($changes);

    return ($res, $ok);
}

#####

sub reload_vars_and_procs {
    my ($self, $interp) = @_;
    # load saved procs/vars/meta
    my $loader = Shittybot::TCL::Loader->new(
        interp => $interp,
        state_path => $self->state_path,
        indices => $self->indices,
    );
    $loader->load_state;
}

# modify this in traits to install custom procs/vars
sub init_interp {
    my ($self) = @_;
    $self->reload_vars_and_procs($self->interp);
}

# say something in the current channel
sub reply {
    my ($self, @msg) = @_;

    my $context = $self->context;
    my $chan = $context->channel or die "Failed to find current context channel";
    warn "chan: $chan, msg: @msg";
    $self->channel_msg($chan => "@msg");

    return;
}

# get the value of a tcl var
sub get_tcl_var {
    my ($self, $var, $flags) = @_;

    return $self->interp->GetVar($var);
}

# evals tcl with a safe slave interpreter
# returns ($result, $success)
# if $success == 0, $result will be err str
sub _safe_eval {
    my ($self, $ctx) = @_;

    my $res;
    my $ok;
    try {
        # export current command context as vars in the context:: namespace
        $self->export_ctx_to_tcl($ctx);

        $res = $self->interp->eval_in_safe($ctx->{command});

        # didn't explode! score
        $ok = 1;
    } catch {
        my ($err) = @_;
        $err =~ s/(at lib.+)$//smg;
        $err =~ s/(at \/.+ line \d+\.)$//smg;
        $res = "Error: $err";
        $ok = 0;
    };

    return ($res, $ok);
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
        unless (defined $v) {
            warn "Got undef for $category $k";
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
    # can probably fold both of these into one method. left as an
    # excersize for the reader.

    while (my ($k, $v) = each %{ $pre->{$category} }) {
        # skip context info
        next if index($k, 'context::') == 0;

        my $post_v = $post->{$category}{$k};

        # did it change?
        next unless ( (! $v && $post_v) || ($v && ! $post_v) || $v ne $post_v );

        # $k changed from $v to $post_v
        $changed->{$category}{$k} = $post_v;
    }
    while (my ($k, $v) = each %{ $post->{$category} }) {
        # skip context info
        next if index($k, 'context::') == 0;

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
    my @proc_names = $interp->eval_in_safe('info procs');

    foreach my $proc (@proc_names) {
        my $args = $interp->eval_in_safe("info args {$proc}");
        my $body = $interp->eval_in_safe("info body {$proc}");
        $res->{$proc} = "{$args} {$body}";
    }

    return $res;
}

# returns hashref of var => serialized
sub vars {
    my ($self) = @_;

    my $res = {};
    my $interp = $self->interp;
    my @var_names = $interp->eval_in_safe('info vars');

    foreach my $var (@var_names) {
        # is it an array?
        my $is_array = $interp->eval_in_safe("array exists {$var}");
        if ($is_array) {
            $res->{$var} = 'array {' . $interp->eval_in_safe("array get {$var}") . '}';
        } else {
            $res->{$var} = 'scalar {' . $interp->eval_in_safe("set {$var}") . '}';
        }
    }

    return $res;
}

# deserialize context from interpreter vars
sub context {
    my ($self) = @_;

    my @vars_to_import = qw/channel nick mask command nicks/;
    my %ctx;
    foreach my $var (@vars_to_import) {
        my $val = $self->get_tcl_var('context::' . $var);
        $ctx{$var} = $val;
    }

    return Shittybot::Command::Context->new(%ctx);
}

# serialize current command context as tcl vars in context::*
sub export_ctx_to_tcl {
    my ($self, $ctx) = @_;

    # set current ctx vars
    my @vars_to_export = qw/channel nick mask command nicks/;
    my %export_map;
    my $prefix = '';
    foreach my $var (@vars_to_export) {
        my $val = $ctx->$var;
        $val = '' unless defined $val;
        
        # this blows up on non-scalar refs. how to export arrays/hashes?
        if (ref($val) && ref($val) eq 'ARRAY') {
            $self->interp->icall('set', "::$var", $val);
        } else {
            $export_map{$prefix . $var} = ref $val ? $val : \$val;
        }
    }

    # warn Dumper(\%export_map);

    $self->export_to_tcl(
        namespace => 'context',
        subs => { stub => sub {} },  # if there are no subs, it won't create the namespace :(
        vars => \%export_map,
    );
}

# procs = hashref of proc name => callback
sub export_procs_to_slave {
    my ($self, $namespace, $procs) = @_;

    # alias from parent to slave
    while (my ($name, $cb) = each %$procs) {
        # wrap callback to include $self
        my $cb_wrapped = sub {
            my $ret = $cb->($self, @_);
            return $ret;
            return $ret if defined($ret);
            return "";
        };

        my $fullname = join('::', $namespace, $name);
        say "Exporting $fullname builtin to slave";

        # export to parent interp
        $self->export_to_tcl(
            namespace => $namespace,
            subs => { $name => $cb_wrapped },
        );
    }
}

__PACKAGE__->meta->make_immutable;

package Tcl;
use strict;
use Try::Tiny;
use Data::Dump qw/ddx/;
use Carp qw/croak/;

sub eval_in_safe {
    my ($self, $command) = @_;
    my $ary = wantarray;
    my @res;
    #my @args = $self->SplitList($command);
    #ddx(\@args);
    try {
        @res = $ary ? ($self->Eval($command)) : (scalar $self->Eval($command));
    } catch {
        croak "Error evaluating '$command': $_";
    };
    return $ary ? @res : $res[0];
}

1;
