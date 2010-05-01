#!/usr/bin/perl

use strict;
use warnings;
use Config::General;
use Carp::Always;
use Data::Dump  qw/ddx/;


use 5.01;
use Data::Dumper;
use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw/prefix_nick prefix_user prefix_host/;

use lib 'lib';

use Shittybot::TCL;


## anyevent stuff
my $cond = AnyEvent->condvar;
my $client = new AnyEvent::IRC::Client;


## settings:
my $config = Config::General->new("bot.conf") or die "Failed to read config file";
my %configuration = $config->getall or die "Failed to parse configuration file";

my $conf = $configuration{Server}->{Buttes};
my $botnick = $conf->{nickname};
my $botchan = '#shittybot'; #.$conf->{Channels}->{default}; <-- this is not working for some reason :(
my $botreal = $conf->{realname};
my $botident = $conf->{username};
my $botserver = $conf->{address};
my $nickservpw = undef;


my %states;

if (!$states{$conf->{state}}) {
  my $tcl = Shittybot::TCL->spawn($conf->{state}, $client);
  $states{$conf->{state}} = $tcl;
  ddx($conf->{state} . " has a tcl set!");
  print "Spawned TCL master for state $conf->{state}\n";
}




## callbacks
my $conn = sub {
  my ($client, $err) = @_;
  return unless $err;
  say "Can't connect: $err";
  my $init_timer = AnyEvent->timer(after => 5, cb => sub { init() })
};

$client->reg_cb(connect => $conn);
$client->reg_cb
  (registered => sub {
     my $self = shift;
     say "Registered on IRC server";
     $client->enable_ping(60);
   },
   disconnect => sub {
     say "disconnected: $_[1]! trying to reconnect...";
     init();
  },
   part => sub {
     my ($self, $nick, $channel, $is_myself, $msg) = @_;
     return unless $nick eq $client->nick;
     say "SAPart from $channel, rejoining";
     $client->send_srv('JOIN', $channel);
  },
  kick => sub {
    my ($self, $nick, $channel, $msg, $nick2) = @_;
    return unless $nick eq $client->nick;
    say "Kicked from $channel; rejoining";
    $client->send_srv('JOIN', $channel);
  },
  nick_change => sub {
    my ($self, $old_nick, $new_nick, $is_myself) = @_;
    return unless $is_myself;
    return if $new_nick eq $botnick;
    getNick($botnick);
  });


$client->ctcp_auto_reply ('VERSION', ['VERSION', 'Smeggdrop']);

# default crap
$client->reg_cb
  (debug_recv =>
   sub {
     my ($self, $ircmsg) = @_;
     #say dump($ircmsg);
     if ($ircmsg->{command} eq '307') { # is a registred nick reply
       # do something
     }
   });

## getting it's nick back

my $nickTimer = AnyEvent->timer (after => 10, interval => 30, # NICK RECOVERY INTERVAL
				 cb =>
				 sub {
				   getNick($botnick) unless $client->is_my_nick($botnick);
				 });

sub getNick {
  my $nick = shift;
  # change your nick here
  $client->send_srv('PRIVMSG' => "NickServ", "ghost $nick $nickservpw") if defined $nickservpw;
  $client->send_srv('NICK', $nick);
}


## example of parsing

my $trigger = $conf->{trigger};

my $parse_privmsg = sub {
  my ($self, $msg) = @_;

  my $chan = $msg->{params}->[0];
  my $from = $msg->{prefix};
  #print Dump($msg);
  if ($msg->{params}->[-1] =~ m/^!lol (.*)/) {
    $client->send_chan($chan, 'PRIVMSG', $chan, "\001ACTION lol @ $1"); # <--- action here
  }
  if ($msg->{params}->[-1] =~ m/^!whois$/) {
    say $client->send_msg('WHOIS', prefix_nick($from));
  }
  if ($msg->{params}->[-1] =~ qr/$trigger/) {
    my $code = $msg->{params}->[-1];
    $code =~ s/$trigger//;
    my $nick = prefix_nick($from);
    my $mask = prefix_user($from)."@".prefix_host($from);
    say "Got trigger: [$trigger] $code";
    my $out =  $states{$conf->{state}}->call($nick, $mask, '', $chan, $code);
    $client->send_chan($chan, 'PRIVMSG', $chan, $_) foreach split '\n' => $out;
  }
};


$client->reg_cb(irc_privmsg => $parse_privmsg);




sub init {
  $client->send_srv('PRIVMSG' => "NickServ", "identify $nickservpw") if defined $nickservpw;
  $client->connect
    (
     $botserver, 6667, { nick => $botnick, user => $botident, real => $botreal }
    );
  $client->send_srv('JOIN', $botchan);
  $client->clear_chan_queue($botchan); # ..You may wanted to join #bla and the server redirects that and sends you that you joined #blubb. You may use clear_chan_queue to remove the queue after some timeout after joining, so that you don't end up with a memory leak.
  $client->send_chan($botchan, 'PRIVMSG', $botchan, 'hy');
#  $client->send_chan($botchan, 'NOTICE', $botchan, 'notice lol');
}

init();

$cond->wait;

sub chunkby {
        my ($a,$len) = @_;
        my @out = ();
        while (length($a) > $len) {
                push @out,substr($a,0,$len);
                $a = substr($a,$len);
        }
        push @out, $a if ($a);
        return @out;
}

