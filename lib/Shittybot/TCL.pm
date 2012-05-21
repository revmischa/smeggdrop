package Shittybot::TCL;

use 5.01;
use Moose;

use Data::Dump  qw/ddx/;
use Data::Dumper qw(Dumper);

use Shittybot::TCL::ForkedTcl;

use Tcl;
use TclEscape;

BEGIN {
    with 'MooseX::Callbacks';
    with 'MooseX::Traits';
};

my $TCL;

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

sub spawn {
    my ($class, %opts) = @_;

    my $self = $class->new_with_traits(%opts);
    $self->{tcl} = $self->load_state;

    return $self;
}

sub load_state {
  my $self      = shift;

  return $TCL if $TCL;
  $TCL = $self->create_tcl;

  # dangerous call backs
  #$tcl->CreateCommand('chanlist',sub{join(' ',$self->{irc}->channel_list($_[3]))});
  return $TCL;
}

sub create_tcl {
  my ($self) = @_;

  my $state_path = $self->state_path;
  my $tcl = Tcl->new();
  $tcl->Init;
  #$tcl->Eval("proc putlog args {}");
  $tcl->CreateCommand('putlog',sub{ddx(@_)});
  $tcl->Eval("proc chanlist args { cache::get irc chanlist }");
  $tcl->Eval("set smeggdrop_state_path $state_path");
  $tcl->EvalFile('smeggdrop.tcl');
  $tcl = Shittybot::TCL::ForkedTcl->new( interp => $tcl );
  $tcl->Init();
  return $tcl;
}


sub call {
  my $self  = shift;
  my ($nick, $mask, $handle, $channel, $code, $loglines) = @_;

  # see if there is a native handler for this proc
  my ($proc, $args) = split(/\s+/, $code, 2);
  # builtin procs start with &
  my ($builtin) = $proc =~ /^\s*\&(\w+)\b/;
  if ($builtin) {
      return if $self->dispatch($builtin, $self, $nick, $mask, $handle, $channel, $builtin, $args, $loglines);  # return if handled by builtin
  }

  my $ochannel = $channel;
  ddx(@_);
  ($nick, $mask, $handle, $channel, $code) = map { tcl_escape($_) } ($nick, $mask, $handle, $channel, $code);

  my $tcl = $self->{tcl};

  my @nicks = keys %{$self->{irc}->channel_list($ochannel)};
  my @tcl_nicks = map { tcl_escape($_) } @nicks;
  my $chanlist = "[list ".join(' ',@tcl_nicks)."]";

  # update the log
  if (ref($loglines)) {
      #ddx("loglines! ".scalar(@$loglines));
      my $add_to_log = tcl_escape("cache put irc chanlist $chanlist");
      my @cmds = map {
          my ($time,$nick,$mask,$line) = @{$_};
          $line = tcl_escape( $line );
          my $cmd = "pubm:smeggdrop_log_line $nick $mask $handle $channel $line";
          #ddx($cmd);
          $cmd
      } @$loglines;
      my $logcmd = join($/, @cmds);
      #ddx($logcmd);
      ddx($tcl->Eval($logcmd));
  }

  # update the chanlist
  my $update_chanlist = tcl_escape("cache put irc chanlist $chanlist");
  my $chancmd = "pub:tcl:perform $nick $mask $handle $channel $update_chanlist";

  # perform the actual command
  return $tcl->Eval("$chancmd;\npub:tcl:perform $nick $mask $handle $channel $code");
#  return $tcl->Eval("pub:tcl:perform $nick $mask $handle $channel $code");
}

#not sure about this
sub tcl_escape {
    return TclEscape::escape($_[0]);
}

__PACKAGE__->meta->make_immutable;
