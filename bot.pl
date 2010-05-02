#!/usr/bin/perl

use strict;
use warnings;

use Config::Any;
use Carp::Always;
use Data::Dump qw/ddx/;

use 5.01;
use utf8;
use Data::Dumper;
use AnyEvent::IRC::Client;
use AnyEvent::Socket;
use AnyEvent::IRC::Util qw/prefix_nick prefix_user prefix_host/;

use lib 'lib';
use Shittybot::TCL;

my $config_stem = 'shittybot';

## anyevent stuff
my $cond = AnyEvent->condvar;

## config
my $config = Config::Any->load_stems({
    use_ext => 1,
    stems => [ $config_stem ],
})->[0] or die "Failed to read config file";

foreach my $config_file (values %{$config}) {
    my $networks = $config_file->{networks};
    die "Unable to find network configuration" unless $networks;

    while (my ($net, $net_conf) = each %$networks) {
        make_client($net_conf);
    }
}

$cond->wait;


###########


sub make_client {
    my ($conf) = @_;

    my $client = new AnyEvent::IRC::Client::Pre;

    # config
    my $botnick    = $conf->{nickname};
    my $bindip     = $conf->{bindip};
    my $channels   = $conf->{channels};
    my $botreal    = $conf->{realname};
    my $botident   = $conf->{username};
    my $botserver  = $conf->{address};
    my $operuser   = $conf->{operuser};
    my $operpass   = $conf->{operpass};
    my $nickserv   = $conf->{nickserv} || 'NickServ';
    my $nickservpw = $conf->{nickpass};
    my $state_directory = $conf->{state_directory};

    # force array
    $channels      = [$channels] unless ref $channels;

    # closures to be defined
    my $init;
    my $getNick;

    my %states;

    if (!$states{$state_directory}) {
        my $tcl = Shittybot::TCL->spawn($state_directory, $client);
        $states{$state_directory} = $tcl;
        ddx($state_directory . " has a tcl set!");
        print "Spawned TCL master for state $state_directory\n";
    }

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
        my $init_timer = AnyEvent->timer(after => 5, cb => sub { $init->() })
    };

    $client->reg_cb(connect => $conn);
    $client->reg_cb(
        registered => sub {
            my $self = shift;
            say "Registered on IRC server";
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
         disconnect => sub {
             delete $client->{_nickTimer};
             say "disconnected: $_[1]! trying to reconnect...";
             $init->();
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
             #say dump($ircmsg);
             if ($ircmsg->{command} eq '307') { # is a registred nick reply
                 # do something
             }
         });

    ## example of parsing
    my $trigger = $conf->{trigger};

    my $parse_privmsg = sub {
        my ($self, $msg) = @_;

        my $chan = $msg->{params}->[0];
        my $from = $msg->{prefix};

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
            my $out =  $states{$state_directory}->call($nick, $mask, '', $chan, $code);

	    foreach my $l (split "\n", $out) {
		utf8::encode($l);
		$client->send_chan($chan, 'PRIVMSG', $chan, $l);
	    }
        }
    };

    $client->reg_cb(irc_privmsg => $parse_privmsg);

    $init = sub {
        $client->send_srv('PRIVMSG' => $nickserv, "identify $nickservpw") if defined $nickservpw;
        $client->connect (
            $botserver, 6667, { nick => $botnick, user => $botident, real => $botreal },
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


# overload the IRC::Client connect method to let us defined a prebinding callback
package AnyEvent::IRC::Client::Pre;

use strict;
use warnings;
use AnyEvent::IRC::Connection;

use parent 'AnyEvent::IRC::Client';

sub connect {
    my ($self, $host, $port, $info, $pre) = @_;

    if (defined $info) {
	$self->{register_cb_guard} = $self->reg_cb (
	    ext_before_connect => sub {
		my ($self, $err) = @_;

		unless ($err) {
              $self->register(
		  $info->{nick}, $info->{user}, $info->{real}, $info->{password}
		  );
		}

		delete $self->{register_cb_guard};
	    }
	    );
    }
  
    AnyEvent::IRC::Connection::connect($self, $host, $port, $pre);
}

1;
