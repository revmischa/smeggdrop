#!/usr/bin/perl

use strict;
use warnings;
use Config::General;
use Carp::Always;
use Data::Dump  qw/ddx/;
use POE         qw/Component::IRC::State Component::IRC::Plugin::Connector/;
use POE::Component::IRC::Plugin::AutoJoin;


use 5.01;

use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw/prefix_nick mk_msg/;

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
  my $tcl = Shittybot::TCL->spawn($conf->{state},$client);
  $states{$conf->{state}} = $tcl;
  ddx($conf->{state} . " has a tcl set!");
  print "Spawned TCL master for state $conf->{state}\n";
}


# POE::Session->create(
# 		     package_states  => [
# 					 main  => [qw/_default _start irc_001 irc_public/],
# 					],
# 		     heap  => {
# 			       irc   => $client,
# 			       conf  => $conf,
# 			       tcl   => $states{$conf->{state}},
# 			      },
# 		    );





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
    $client->send_chan($chan, 'PRIVMSG', $chan, "\001ACTION Have received a tcl command!");
  }
};


$client->reg_cb(irc_privmsg => $parse_privmsg);


# sub irc_public {
#   my ($kernel,$heap,$who,$channels,$message)  = @_[KERNEL,HEAP,ARG0 .. ARG2];

#   my $trigger = $heap->{conf}->{trigger};
#   print STDERR "got message: $message\n";
#   if ($message  =~ qr/$trigger/) {
#     print "Got trigger $message\n";
#     my $code  = $message;
#     $code     =~ s/$trigger//;

#     my $nick  = ($who =~ /^([^!]+)/)[0];
#     my $mask  = $who;
#     $mask     =~ s/^[^!]+!//;

#     my $out   = $heap->{tcl}->call($nick,$mask,'',${$channels}[0],$code);
    
#     $out =~ s/\001ACTION /\0777ACTION /g;
#     $out =~ s/[\000-\001]/ /g;
#     $out =~ s/\0777ACTION /\001ACTION /g;
#     my @lines = split( /\n/, $out);
#     my $limit = $heap->{conf}->{linelimit} || 20;
#     # split lines if they are too long
#     @lines = map { chunkby($_, 420) } @lines;
#     if (@lines > $limit) {
#         my $n = @lines; 
#         @lines = @lines[0..($limit-1)];
#         push @lines, "error: output truncated to ".($limit - 1)." of $n lines total"
#     }
#     $heap->{irc}->yield(privmsg  => ${$channels}[0]  => $_) for @lines;
#     #$heap->{irc}->yield(privmsg  => ${$channels}[0]  => $_) for (split (/\n/,$out));
#   }
# }



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

