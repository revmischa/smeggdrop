#!/usr/bin/perl

use strict;
use warnings;

#use Carp::Always;
use Data::Dump qw/ddx dump/;

use Encode;
use 5.01;
use utf8;
use Data::Dumper;
use AnyEvent::IRC::Client;
use AnyEvent::Socket;
use AnyEvent::IRC::Util qw/prefix_nick prefix_user prefix_host/;

use lib 'lib';
use Shittybot;
use Shittybot::TCL;
use Shittybot::Auth;
binmode STDOUT, ":utf8";



# this needs to be loaded after Tcl
use Config::JFDI;

## anyevent main CV
my $cond = AnyEvent->condvar;

# load shittybot.yml/conf/ini/etc
my $config_raw = Config::JFDI->new(name => 'shittybot');
my $config = $config_raw->get;

my $networks = $config->{networks}
    or die "Unable to find network configuration";

# spawn client for each network
while (my ($net, $net_conf) = each %$networks) {
    make_client($net_conf);
}

$cond->wait;


###########

sub spawn_tcl {
    my ($client) = @_;

    my $state_dir = $config->{state_directory};
    my $traits = $config->{traits} || [];

    my @traits = map { "Shittybot::TCL::Trait::$_" } @$traits;

    my $tcl = Shittybot::TCL->new_with_traits(
	state_path => $state_dir, 
	irc => $client,
	traits => \@traits,
    );
    say "Spawned TCL interpreter for state $state_dir";

    return $tcl;
}

sub make_client {
    my ($network_conf) = @_;

    # config
    my $botnick    = $network_conf->{nickname};
    my $bindip     = $network_conf->{bindip};
    my $channels   = $network_conf->{channels};
    my $botreal    = $network_conf->{realname};
    my $botident   = $network_conf->{username};
    my $botserver  = $network_conf->{address};
    my $botport    = $network_conf->{port} || 6667;
    my $operuser   = $network_conf->{operuser};
    my $operpass   = $network_conf->{operpass};
    my $nickserv   = $network_conf->{nickserv} || 'NickServ';
    my $nickservpw = $network_conf->{nickpass};

    my $ownername  = $network_conf->{ownername};
    my $ownerpass  = $network_conf->{ownerpass};
    my $sessionttl = $network_conf->{sessionttl};

    # validate config
    return unless $channels;
    $channels = [$channels] unless ref $channels;

    # create client and interperter
    my $client = Shittybot->new(
	config => $config,
	network_config => $network_conf,
    );
    $client->{_tcl} = spawn_tcl($client);

    if ($ownername && $ownerpass && $sessionttl) {
	$client->{auth} = new Shittybot::Auth(
	    'ownernick' => $network_conf->{ownername},
	    'ownerpass' => $network_conf->{ownerpass},
	    'sessionttl' => $network_conf->{sessionttl} || 0,
	);
    }

    # save channel list for the interpreter
    $client->{config_channel_list} = $channels;

    # closures to be defined
    my $init;
    my $getNick;

    ## getting it's nick back
    $getNick = sub {
        my $nick = shift;
        # change your nick here
        $client->send_srv('PRIVMSG' => $nickserv, "ghost $nick $nickservpw") if defined $nickservpw;
        $client->send_srv('NICK', $nick);
    };

    ## callbacks
    my $conn = sub {
        my ($client, $err) = @_;
        return unless $err;
        say "Can't connect: $err";
	#keep reconecting
	$client->{reconnects}{$botserver} = AnyEvent->timer(
		  after => 1,
		  interval => 10,
		  cb => sub {
		     $init->();
		   },
            );
    };

    $client->reg_cb(connect => $conn);
    $client->reg_cb(
        registered => sub {
            my $self = shift;
            say "Registered on IRC server";
	    delete $client->{reconnects}{$botserver};
            $client->enable_ping(60);

            # oper up
            if ($operuser && $operpass) {
                $client->send_srv(OPER => $operuser, $operpass);
            }

            # save timer
            $client->{_nickTimer} = AnyEvent->timer(
                after => 10,
                interval => 30, # NICK RECOVERY INTERVAL
                cb => sub {
                    $getNick->($botnick) unless $client->is_my_nick($botnick);
                },
            );
         },
	ctcp => sub {
	    my ($self, $src, $target, $tag, $msg, $type) = @_;
	    say "$type $tag from $src to $target: $msg";
	},
	error => sub {
	    my ($self, $code, $msg, $ircmsg) = @_;
	    print STDERR "ERROR: $msg " . dump($ircmsg) . "\n";
	},
         disconnect => sub {
	     my ($self, $reason) = @_;
             delete $client->{_nickTimer};
             delete $client->{rejoins};
             say "disconnected: $reason. trying to reconnect...";
 
	     #keep reconecting
	     $client->{reconnects}{$botserver} = AnyEvent->timer(
                after => 10,
                interval => 10,
                cb => sub {
		    $init->();
                },
            );
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

	     # keep trying to rejoin
	     $client->{rejoins}{$channel} = AnyEvent->timer(
                after => 10,
                interval => 60,
                cb => sub {
		    $client->send_srv('JOIN', $channel);
                },
            );
         },
         join => sub {
	     my ($self, $nick, $channel, $is_myself) = @_;
             return unless $is_myself;

	     delete $client->{rejoins}{$channel};
	},
	nick_change => sub {
	    my ($self, $old_nick, $new_nick, $is_myself) = @_;
	    return unless $is_myself;
	    return if $new_nick eq $botnick;
	    $getNick->($botnick);
	},
    );


    $client->ctcp_auto_reply ('VERSION', ['VERSION', 'Smeggdrop']);

    # default crap
    $client->reg_cb
        (debug_recv =>
         sub {
             my ($self, $ircmsg) = @_;
	     return unless $ircmsg->{command};
             #say dump($ircmsg);
             if ($ircmsg->{command} eq '307') { # is a registred nick reply
                 # do something
             }
         });

    my $trigger = $network_conf->{trigger};

    my $parse_privmsg = sub {
        my ($self, $msg) = @_;

        my $chan = $msg->{params}->[0];
        my $from = $msg->{prefix};

	my $nick = prefix_nick($from);
	my $mask = prefix_user($from)."@".prefix_host($from);

	if ($client->{auth}) {
	    return if grep { $from =~ qr/$_/ } @{$client->{auth}->ignorelist};
	}

	my $txt = $msg->{params}->[-1];

	if ($txt =~ qr/^admin\s/ && $client->{auth}) {
	    my $data = $txt;
	    $data =~ s/^admin\s//;
	    #$client->{auth}->from($from);
	    my @out = $client->{auth}->Command($from, $data);
	    $client->send_srv(@out);
	}

        if ($txt =~ qr/$trigger/) {
            my $code = $txt;
            $code =~ s/$trigger//;
            say "Got trigger: [$trigger] $code";

	    # f u vxp
	    return if $code =~ /foreach\s+proc/i;
	    return if $code =~ /irc\.arabs\./i;
	    return if $code =~ /foreach p \[info proc\]/i;
	    return if $code =~ /foreach.+info\s+proc/i;
	    return if $code =~ /foreach\s+var/i;
	    return if $code =~ /proc \w+ \{\} \{\}/i;
	    return if $code =~ /set \w+ \{\}/i;
	    return if $code =~ /lopl/i;
	    return if $from =~ /800A3C4E\.1B6ABF9\.8E35284E\.IP/;
	    return if $from =~ /org\.org/;
	    return if $from =~ /acidx.dj/;
	    return if $from =~ /anonine.com/;
	    return if $from =~ /maxchats\-afvhsk.ipv6.he.net/;
	    return if $from =~ /maxchats\-69a5t0.cust.bredbandsbolaget.se/;
	    return if $from =~ /dynamic.ip.windstream.net/;
	    return if $from =~ /pig.aids/;
	    return if $from =~ /2607:9800:c100/;
	    return if $from =~ /loller/;
	    return if $from =~ /blacktar/i;
	    return if $from =~ /chatbuffet.net/;
	    return if $from =~ /tptd/;
	    return if $from =~ /b0nk/;
	    return if $from =~ /fullsail.com/;
	    return if $from =~ /abrn/;
	    return if $from =~ /bsb/;
	    return if $from =~ /remembercaylee.org/;
	    return if $from =~ /andyskates/;
	    return if $from =~ /oaks/;
	    return if $from =~ /emad/;
	    return if $from =~ /arabs.ps/;
	    return if $from =~ /guest/i;
	    return if $from =~ /sf.gobanza.net/;
	    return if $from =~ /4C42D300.C6D0F7BD.4CA38DE1.IP/;
	    return if $from =~ /anal.beadgame.org/;
	    return if $from =~ /CFD23648.ED246337.302A69E4.IP/;
	    return if $from =~ /mc.videotron.ca/;
	    return if $from =~ /^v\@/;
	    return if $from =~ /xin\.lu/;
	    return if $from =~ /\.ps$/;
	    return if $from =~ /caresupply.info/;
	    return if $from =~ /sttlwa.fios.verizon.net/;
	    return if $from =~ /maxchats-m107ce.org/;
	    return if $from =~ /bofh.im/;
	    return if $from =~ /morb/;
	    return if $from =~ /push\[RAX\]/;
	    return if $from =~ /pushRAX/;
	    return if $from =~ /maxchats-u5t042.mc.videotron.ca/;
	    return if $from =~ /avas/i;
	    return if $from =~ /avaz/i;
	    return if $from =~ /sloth/i;
	    return if $from =~ /bzb/i;
	    return if $from =~ /^X\b/;
	    return if $from =~ /zenwhen/i;
	    return if $from =~ /noah/i;
	    return if $from =~ /maxchats\-87i1b6.com/i;
	    return if $from =~ /pynchon/i;
	    return if $from =~ /shaniqua/i;
	    return if $from =~ /145\.98\.IP/i;
	    return if $from =~ /devi/i;
	    return if $from =~ /devio.us/i;
	    return if $from =~ /silver/i;
	    return if $from =~ /jbs/i;
	    return if $from =~ /maxchats-m8r510.res.rr.com/i;
	    return if $from =~ /sw0de/i;
	    return if $from =~ /careking/i;
	    return if $from =~ /114.31.211./i;
	    return if $from =~ /rucas/i;
	    return if $from =~ /ucantc.me/i;
	    return if $from =~ /maxchats-ej6b15.2d1r.sjul.0470.2001\.IP/i;
	    return if $from =~ /maxchats-2gn1sk\.us/i;
	    return if $from =~ /maxchats-3p5evi.bgk.bellsouth.net/;

	    # add log info to interperter call
	    my $loglines = $client->slurp_chat_lines($chan);
            my $out = $client->{_tcl}->call($nick, $mask, '', $chan, $code, $loglines);
	    $client->send_to_channel($chan, $out);

	} else {
	    $txt = Encode::decode( 'utf8', $txt );
	    $client->append_chat_line( $chan, $client->log_line($nick, $mask, $txt) );
	}
    };

    $client->reg_cb(irc_privmsg => $parse_privmsg);

    $init = sub {
        $client->send_srv('PRIVMSG' => $nickserv, "identify $nickservpw") if defined $nickservpw;
        $client->connect (
            $botserver, $botport, { nick => $botnick, user => $botident, real => $botreal },
	    sub {
		my ($fh) = @_;

		if ($bindip) {
		    my $bind = AnyEvent::Socket::pack_sockaddr(undef, parse_address($bindip));
		    bind $fh, $bind;
		}

		return 30;
	    },
        );

        foreach my $chan (@$channels) {
	    next unless $chan;

            say "Joining $chan";

            $client->send_srv('JOIN', $chan);

            # ..You may have wanted to join #bla and the server
            # redirects that and sends you that you joined #blubb. You
            # may use clear_chan_queue to remove the queue after some
            # timeout after joining, so that you don't end up with a
            # memory leak.
            $client->clear_chan_queue($chan); 

            #$client->send_chan($chan, 'PRIVMSG', $chan, 'hy');
            #  $client->send_chan($botchan, 'NOTICE', $botchan, 'notice lol');
        }
    };

    $init->();
}

1;
