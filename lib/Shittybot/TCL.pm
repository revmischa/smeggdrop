#!/usr/bin/perl
package Shittybot::TCL;

use 5.01;
use strict;
use warnings;
use Data::Dump  qw/ddx/;
use Data::Dumper qw(Dumper);
#use Shittybot::TCL::Child;

use Shittybot::TCL::ForkedTcl;

use Tcl;
use TclEscape;

my $TCL;

sub new {
  my $class = shift;
  my $state = shift; #statepath!
  my $irc   = shift;

  my $self = {};

  $self->{state}  = $state;
  $self->{irc}    = $irc;

  bless ($self,$class); # this is bad
  return $self;
}

sub spawn {
  my $class = shift;
  my $state = shift;
  my $irc   = shift;
  my $self  = $class->new($state, $irc);
  $self->{tcl}  = $self->load_state($self->{state});
  return $self;
}


sub load_state {
  my $self      = shift;
  my $statepath = shift;

  return $TCL if $TCL;
  $TCL = $self->create_tcl($statepath);

  # dangerous call backs
  #$tcl->CreateCommand('chanlist',sub{join(' ',$self->{irc}->channel_list($_[3]))});
  return $TCL;
}

sub create_tcl {
  my ($self,$statepath) = @_;
  my $tcl = Tcl->new();
  $tcl->Init;
  #$tcl->Eval("proc putlog args {}");
  $tcl->CreateCommand('putlog',sub{ddx(@_)});
  $tcl->Eval("proc chanlist args { cache::get irc chanlist }");
  $tcl->Eval("set smeggdrop_state_path $statepath");
  $tcl->EvalFile('smeggdrop.tcl');
  $tcl = Shittybot::TCL::ForkedTcl->new( interp => $tcl );
  $tcl->Init();
  return $tcl;
}


sub call {
  my $self  = shift;
  my ($nick, $mask, $handle, $channel, $code) = @_;
  my $ochannel = $channel;
  ddx(@_);
  ($nick, $mask, $handle, $channel, $code) = map { tcl_escape($_) } ($nick, $mask, $handle, $channel, $code);

  my $tcl = $self->{tcl};

  my @nicks = keys %{$self->{irc}->channel_list($ochannel)};
  my @tcl_nicks = map { tcl_escape($_) } @nicks;
  my $chanlist = "[list ".join(' ',@tcl_nicks)."]";

  # update the chanlist
  my $update_chanlist = tcl_escape("cache put irc chanlist $chanlist");
  my $chancmd = "pub:tcl:perform $nick $mask $handle $channel $update_chanlist";
  # perform the actual command
  return $tcl->Eval("$chancmd;\npub:tcl:perform $nick $mask $handle $channel $code");
}

#not sure about this
sub tcl_escape {
    return TclEscape::escape($_[0]);
}

1;
