#!/usr/bin/perl

use strict;
use warnings;

use Carp::Always;
use Data::Dump qw/ddx dump/;

use 5.01;
use utf8;
use Data::Dumper;
use AnyEvent::IRC::Client;
use AnyEvent::Socket;
use AnyEvent::IRC::Util qw/prefix_nick prefix_user prefix_host/;

use lib 'lib';
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

    my $tcl = Shittybot::TCL->spawn($state_dir, $client);
    say "Spawned TCL interpreter for state $state_dir";

    return $tcl;
}

# log channel chat lines 
sub append_chat_line {
    my ( $heap, $channel, $line) = @_;
    my $log = $heap->{irc_logs}->{$channel} || [];
    push @$log, $line;
    $heap->{irc_logs}->{$channel} = $log;
    return $log;
}

# retrieve channel log chat lines (as an array ref)
sub get_chat_lines {
    my ( $heap, $channel ) = @_;
    my $log = $heap->{irc_logs}->{$channel} || [];
    return $log;
}

# clear channel chat lines
# mutation
sub clear_chat_lines {
    my ($heap, $channel) = @_;
    $heap->{irc_logs}->{$channel} = [];
}
# retrieve and clear channel chat lines (as an array ref)
# mutation
sub slurp_chat_lines {
    my ($heap, $channel) = @_;
    my $log = get_chat_lines( $heap, $channel );
    clear_chat_lines( $heap, $channel );
    return $log;
}
# This is a data structure that is a chat long message
sub log_line {
    my ($nick, $mask, $message) = @_;
    return [ time(), $nick, $mask, $message ];
}

sub irc_public {
  my ($kernel,$heap,$who,$channels,$message)  = @_[KERNEL,HEAP,ARG0 .. ARG2];

  my $nick  = ($who =~ /^([^!]+)/)[0];
  my $mask  = $who;
  $mask     =~ s/^[^!]+!//;
  my $channel = ${$channels}[0];

  my $trigger = $heap->{conf}->{trigger};
  print STDERR "got message: $message\n";
  if ($message  =~ qr/$trigger/) {
    print "Got trigger $message\n";
    my $code  = $message;
    $code     =~ s/$trigger//;

    #my $nick  = ($who =~ /^([^!]+)/)[0];
    #my $mask  = $who;
    #$mask     =~ s/^[^!]+!//;
    #my $channel = ${$channels}[0];
    my $loglines = slurp_chat_lines( $heap, $channel );
    my $out   = $heap->{tcl}->call($nick,$mask,'',$channel,$code, $loglines);
    
    $out =~ s/\001ACTION /\0777ACTION /g;
    $out =~ s/[\000-\001]/ /g;
    $out =~ s/\0777ACTION /\001ACTION /g;
    my @lines = split( /\n/, $out);
    my $limit = $heap->{conf}->{linelimit} || 20;
    # split lines if they are too long
    @lines = map { chunkby($_, 420) } @lines;
    if (@lines > $limit) {
        my $n = @lines; 
        @lines = @lines[0..($limit-1)];
        push @lines, "error: output truncated to ".($limit - 1)." of $n lines total"
    }
    $heap->{irc}->yield(privmsg  => ${$channels}[0]  => $_) for @lines;
    #$heap->{irc}->yield(privmsg  => ${$channels}[0]  => $_) for (split (/\n/,$out));
  } else {
    append_chat_line( $heap, $channel, log_line($nick, $mask, $message) );
  }
}

sub make_client {
    my ($conf) = @_;

    my $client = new AnyEvent::IRC::Client::Pre;
    $client->{_tcl} = spawn_tcl($client);

    # config
    my $botnick    = $conf->{nickname};
    my $bindip     = $conf->{bindip};
    my $channels   = $conf->{channels};
    my $botreal    = $conf->{realname};
    my $botident   = $conf->{username};
    my $botserver  = $conf->{address};
    my $botport    = $conf->{port} || 6667;
    my $operuser   = $conf->{operuser};
    my $operpass   = $conf->{operpass};
    my $nickserv   = $conf->{nickserv} || 'NickServ';
    my $nickservpw = $conf->{nickpass};

    $client->{auth} = new Shittybot::Auth
      ('ownernick' => $conf->{ownername},
       'ownerpass' => $conf->{ownerpass},
       'sessionttl' => $conf->{sessionttl},
#       'client' => $client,
      );


    # force array
    next unless $channels;
    $channels = [$channels] unless ref $channels;

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

    my $trigger = $conf->{trigger};

    my $parse_privmsg = sub {
        my ($self, $msg) = @_;

        my $chan = $msg->{params}->[0];
        my $from = $msg->{prefix};

	#return if (grep { $from =~ qr/^$_/ } @{$client->{auth}->ignorelist});
	return if (grep { $from =~ qr/$_/ } @{$client->{auth}->ignorelist});

        # if ($msg->{params}->[-1] =~ m/^!lol (.*)/) {
        #     $client->send_chan($chan, 'PRIVMSG', $chan, "\001ACTION lol @ $1"); # <--- action here
        # }
        # if ($msg->{params}->[-1] =~ m/^!whois$/) {
        #     say $client->send_msg('WHOIS', prefix_nick($from));
        # }
	if ($msg->{params}->[-1] =~ qr/^admin\s/) {
	  my $data = $msg->{params}->[-1];
	  $data =~ s/^admin\s//;
	  #$client->{auth}->from($from);
	  my @out = $client->{auth}->Command($from, $data);
	  $client->send_srv(@out);
	}

        if ($msg->{params}->[-1] =~ qr/$trigger/) {
            my $code = $msg->{params}->[-1];
            $code =~ s/$trigger//;
            my $nick = prefix_nick($from);
            my $mask = prefix_user($from)."@".prefix_host($from);
            say "Got trigger: [$trigger] $code";
            my $out =  $client->{_tcl}->call($nick, $mask, '', $chan, $code);
	    utf8::encode($out);

	    $out =~ s/\001ACTION /\0777ACTION /g;
	    $out =~ s/[\000-\001]/ /g;
	    $out =~ s/\0777ACTION /\001ACTION /g;

	    my @lines = split  "\n" => $out;
	    my $limit = $conf->{linelimit} || 20;
	    # split lines if they are too long
	    @lines = map { chunkby($_, 420) } @lines;
	    if (@lines > $limit) {
	      my $n = @lines;
	      @lines = @lines[0..($limit-1)];
	      push @lines, "error: output truncated to ".($limit - 1)." of $n lines total"
	    }
	    foreach(@lines) {
	      $client->send_chan($chan, 'PRIVMSG', $chan, $_);
	    }
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


sub chunkby {
        my ($a,$len) = @_;
        my @out = ();
        while (length($a) > $len) {
                push @out,substr($a, 0, $len);
                $a = substr($a,$len);
        }
        push @out, $a if (defined $a);
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
