# overload the IRC::Client connect method to let us define a prebinding callback
package Shittybot;

use 5.014;

use Shittybot::TCL;
use Shittybot::Auth;

use Moose;
use Encode;
use utf8;
use AnyEvent::IRC::Connection;
use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw/prefix_nick prefix_user prefix_host/;
use AnyEvent::Socket;
use AnyEvent::WebSocket::Client;
use Twiggy::Server;
use Plack::Request;
use LWP::Authen::OAuth2;
use AnyEvent::HTTP;
use JSON qw/decode_json encode_json/;
use Try::Tiny;
use Carp qw/carp croak/;

use Data::Dump qw/ddx dump/;
use Data::Dumper;

BEGIN { extends 'AnyEvent::IRC::Client'; }

binmode STDOUT, ":utf8";

# hash of channel => \@logs
has 'logs' => (
    is => 'rw',
    isa => 'HashRef',
    lazy => 1,
    default => sub { {} },
);

# has 'ua' => (
#     is => 'rw',
#     isa => 'LWP::UserAgent',
#     lazy => 1,
#     default => sub { LWP::UserAgent->new },
# );

has 'config' => (
    is => 'ro',
    isa => 'HashRef',
    required => 1,
);

has 'network' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'network_config' => (
    is => 'ro',
    isa => 'HashRef',
    required => 1,
);

has 'should_reconnect' => ( is => 'rw', isa => 'Bool', default => 0 );

# websocket client
has 'ws' => (
    is => 'rw',
    isa => 'AnyEvent::WebSocket::Connection',
);

# Twigger HTTP server for OAuth2 redirect
has 'httpd' => (
    is => 'rw',
    isa => 'Twiggy::Server',
    predicate => 'has_httpd',
    clearer => 'clear_httpd',
);

# oauth2 client
has 'oauth2' => (
    is => 'rw',
    isa => 'LWP::Authen::OAuth2',
);

has 'oauth2_access_token' => (
    is => 'rw',
    isa => 'Str|Undef',
);

# slack realtime messaging state
# see: https://api.slack.com/methods/rtm.start
has 'rtm_state' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} },
);

has 'tcl' => (
    is => 'ro',
    # isa => 'Shittybot::TCL',
    lazy_build => 1,
    handles => [qw/ safe_eval versioned_eval /],
);

sub is_slack { $_[0]->network_config->{slack} }

sub _build_tcl {
    my ($self) = @_;

    my $config = $self->config;
    
    my $state_dir = $config->{state_directory};
    my $traits = $config->{traits} || [];

    my @traits = map { "Shittybot::TCL::Trait::$_" } @$traits;

    my $tcl = Shittybot::TCL->new_with_traits(
        state_path => $state_dir,
        config => $config,
        traits => \@traits,
        irc => $self,
    );

    return $tcl;
}

sub init {
    my ($self) = @_;

    $self->init_tcl;

    if ($self->is_slack) {
        $self->init_slackbot;
    } else {
        $self->init_irc;
    }
}

sub init_tcl { shift->tcl }

# send a generic message
sub channel_msg {
    my ($self, $channel, $msg) = @_;

    unless ($channel) {
        carp "Attempted to send message to no channel";
        return;
    }

    if ($self->is_slack) {
        $self->slack_msg_chan($channel, $msg);
    } else {
        $self->irc->send_to_channel($channel, $msg);
    }
}

# register websocket client for slack
sub init_slackbot {
    my ($self) = @_;

    my $conf = $self->network_config;
    my $trigger = $conf->{trigger};

    my $api_token = $conf->{api_token} or die "Slack API token not configured";

    my $ws = AnyEvent::WebSocket::Client->new;

    $self->refresh_slack_oauth2 or return;

    # RTM.start
    my $res = $self->oauth2->post(
        "https://slack.com/api/rtm.start", 
        { token => $self->oauth2_access_token },
    );

    my $content = $res->content;
    if (index($content, 'You') != -1) {
        # you are sending messages too fast...
        $self->should_reconnect(1);
        return;
    }
    my $data = decode_json($res->content);
    $self->rtm_state($data);
    my $ws_url = $data->{url};
    unless ($ws_url) {
        ddx($data);
        die "Didn't get websocket URL";
    }

    $ws->connect($ws_url)->cb(sub {
        my $conn = eval { shift->recv };

        if ($@) {
            # handle error...
            warn $@;
            return;
        }

        $self->should_reconnect(0);
        $self->ws($conn);

        $conn->on(each_message => sub {
            # $message isa AnyEvent::WebSocket::Message
            my ($connection, $message) = @_;

            $self->refresh_slack_oauth2;

            return unless $message->is_text;

            my $data = decode_json($message->body);
        # dump messages here:
        #ddx($data);
            if ($data->{type} eq 'message') {
        my $channel_raw = $data->{channel};
                my $channel = $data->{channel};

                # edited message?
                if ($data->{subtype} && $data->{subtype} eq 'message_changed') {
                    $data = $data->{message};
                    $data->{channel} = $channel_raw = $channel;
                }

                $channel = $self->slack_channel_name($channel);
                my $nick = $self->slack_user_name($data->{user}) || $data->{username};
                my $text = $data->{text};

                # skip if from self
                return if $nick && $nick eq $conf->{nickname};

                # is this in a watched channel
                my $chans = $conf->{channels} || [];
                # ddx($chans);
                # warn "chan: $channel";
                unless ($chans && @$chans) {
                    warn "Got a message on slack but not watching any channels";
                    return;
                }
                my $is_watched_chan = grep { $_ eq $channel or $_ eq $channel_raw } @$chans;

                if ($text && $is_watched_chan && $text =~ /$trigger/) {
                    my $code = $text;
                    $code =~ s/$trigger//;
                    #say "Got trigger: [$trigger] $code";
                    $self->handle_slack_eval($connection, $data, $code);
                } else {
                    $text = Encode::decode('utf8', $text);
                    $self->append_chat_line($channel, $self->log_line($nick, undef, $text) );
                }
            }
        });

        $conn->on(finish => sub {
            my ($connection) = @_;
            warn "DISCONNECTED";

            $self->should_reconnect(1);
        });
    });
}

sub slack_user_name {
    my ($self, $userid) = @_;
    return unless $userid;
    my $users = $self->rtm_state->{users};
    foreach my $u (@$users) {
        next unless $u->{id} eq $userid;
        return $u->{name};
    }
}

sub slack_channel_name {
    my ($self, $chanid) = @_;
    return unless $chanid;
    my $channels = $self->rtm_state->{channels};
    foreach my $c (@$channels) {
        next unless $c->{id} eq $chanid;
        return '#' . $c->{name};
    }
}

sub handle_slack_eval {
    my ($self, $connection, $msg, $tcl) = @_;

    my $channel_id = $msg->{channel};
    my $channel = $self->slack_channel_name($channel_id);
    my $user = $self->slack_user_name($msg->{user});
    my $text = $msg->{text};

    my $conf = $self->network_config;
    my $icon_url = $conf->{icon_url};

    # maybe we shouldn't execute this?
    if ($self->looks_shady(undef, $tcl)) {
        warn "looks shady: $tcl";
        return;
    }

    # add log info to interperter call
    my $loglines = $self->slurp_chat_lines($channel);
    my $cmd_ctx = Shittybot::Command::Context->new(
        nick => $user,
        mask => undef,
        channel => $channel,
        command => $tcl,
        loglines => $loglines,
    );

    my ($cmd_res, $ok) = $self->versioned_eval($cmd_ctx);

    # reply
    $cmd_res =~ s/```/'''/smg;
    my @attachments;
    my %reply_msg = (
        channel => $channel_id,
        username => 'TclBot',
        icon_url => $icon_url,
        unfurl_media => 0,
        unfurl_links => 0,
        parse => 'none',
    );

    if ($ok) {
        # eval success
        $cmd_res ||= '(No output)' if defined $cmd_res;
        push @attachments, {
            title => "Eval: '$msg->{text}'",
            text => "```$cmd_res```",
            fallback => $cmd_res . '',
            color => 'good',
            parse => 'none',

            mrkdwn_in => [qw/ text /],
        };
    } else {
        # eval error?
        unless ($cmd_res) {
            warn "No eval response for $msg->{text}";
            return;
        }
        push @attachments, {
            title => "Eval error: '$msg->{text}'",
            text => "Error: $cmd_res",
            color => 'danger',
            parse => 'none',
        };
    }

    $reply_msg{attachments} = encode_json(\@attachments) if @attachments;
    $self->send_slack_msg(\%reply_msg);

    # $self->safe_eval($cmd_ctx, sub {
    #     my ($ctx, $res) = @_;
    #     warn "res: $res";
    #     $self->send_slack_message($msg, $res);
    # });
}

my $guard;
sub slack_api {
    my ($self, $method, $args, $cb) = @_;

    $self->refresh_slack_oauth2 unless $method =~ /^auth/;

    $args ||= {};
    $args->{token} ||= $self->oauth2_access_token;

    $cb ||= sub {};
    my $url = "https://slack.com/api/$method";

    my $res = $self->oauth2->post($url, $args);
    my $hdr = $res->headers;
    my $res_decoded;
    try {
        $res_decoded = decode_json($res->content);
    } catch {
        my ($err) = @_;
        warn "Failed to decode slack API response: " .
            $res->content . ": [$err]"; 
    };
    $cb->($res_decoded, $hdr);

    return;

    $guard = http_request
        POST => $url, 
        %$args,
        $cb;
}

# send a message to a channel
sub slack_msg_chan {
    my ($self, $channel_id, $text, $opts) = @_;

    $opts ||= {};

    my %msg = (
    channel => $channel_id,
    text => $text,
    %$opts,
    );
    $self->send_slack_msg(\%msg);
}

# send a generic slack message
# msg is a hashref of params to chat.postMessage
sub send_slack_msg {
    my ($self, $msg) = @_;

    # don't do anything if we're in the middle of an OAuth2 session thing
    return if $self->has_httpd;

    try {
        my $res = $self->slack_api(
            "/chat.postMessage",
        $msg,
            sub {
                my ($data, $hdr) = @_;
                unless ($data->{ok}) {
                    warn "Posting failed: \n";
                    ddx($hdr);
                    ddx($data);                    
                }
            }
        );
    } catch {
        my $err = shift;
        warn "Error posting message: $err";
    };
}

sub save_oauth2_token_string {
    my ($self, $tok_str) = @_;
    my $netname = $self->network;
    my $fh; open $fh, ">${netname}-oauth2-token" or die "Couldn't save token $!";
    print $fh $tok_str;
    close $fh;
}

sub load_oauth2_token_string {
    my ($self) = @_;
    my $netname = $self->network;
    my $fh; open $fh, "${netname}-oauth2-token" or return;
    local $/;
    my $tok_str = <$fh>;
    close $fh;
    $self->got_oauth2_token_string($tok_str);
    return $tok_str;
}

sub got_oauth2_token_string {
    my ($self, $tok_str) = @_;
    return unless $tok_str;

    my $data = eval {decode_json($tok_str)};
    my $parse_error = $@;
    die "JSON parse error: $parse_error" if $parse_error;
    #my $access_token = $data->{access_token};  # if using "client" scope
    my $access_token = $data->{bot}{bot_access_token};  # if using "bot" scope
    $self->oauth2_access_token($access_token);
    $self->save_oauth2_token_string($tok_str);
}

sub slack_oauth2 {
    my ($self) = @_;

    # are we already waiting?
    return if $self->has_httpd;

    my $conf = $self->network_config;
    my $client_id = $conf->{client_id} or die "OAuth client ID not configured";
    my $client_secret = $conf->{client_secret} or die "OAuth client secret not configured";

    my $token_string = $self->load_oauth2_token_string;

    my $oauth_wait_cv = AnyEvent->condvar;

    my $save_tokens = sub {
        my ($new_token_string) = @_;
        $self->got_oauth2_token_string($new_token_string);
    say "OAuth2 completed successfully.";
        $oauth_wait_cv->send;
    };

    my $oc = $self->config->{oauth2} || {};
    my $hostname = $oc->{hostname};
    $hostname ||= $self->config->{hostname};
    $hostname ||= 'localhost';
    my $port = $oc->{port} || 1488;
    my $redir = "http://$hostname:$port";
#    warn $redir;

    my $oauth2 = LWP::Authen::OAuth2->new(
        client_id => $client_id,
        client_secret => $client_secret,
        redirect_uri => $redir,

        service_provider => 'Slack',
        scope => "channels:read chat:write:bot identify bot",

        save_tokens => $save_tokens,
        token_string => $token_string,

        error_handler => sub {
            my ($err) = @_;
            warn "Got OAuth2 client error: $err";
        },
    );
    $self->oauth2($oauth2);

    if ($token_string) {
        #warn "okay. should_refresh: " . $oauth2->should_refresh;
        return 1 unless $oauth2->should_refresh;
    }

    my $auth_url = $oauth2->authorization_url;
    say "Complete OAuth2: $auth_url";

    $self->stop_httpd;
    my $server = Twiggy::Server->new(
        host => '0.0.0.0',
        port => $port,
    );
    $self->httpd($server);

    $server->register_service(sub {
        my $env = shift; # PSGI env
     
        my $req = Plack::Request->new($env);
     
        my $path_info = $req->path_info;
        my $query     = $req->parameters;

        my $code = $query->get('code');
        if ($code) {
            # get oauth tokens now
            $oauth2->request_tokens(code => $code);
            my $token_string = $oauth2->token_string;
        }
     
        my $res = $req->new_response(200); # new Plack::Response
        $res->content("Auth success!") if $code;
        $res->finalize;
    });

    $oauth_wait_cv->recv;
    $self->stop_httpd;
    return 1;
}

sub stop_httpd {
    my ($self) = @_;

    return unless $self->has_httpd;
    $self->httpd->{exit_guard}->end;
    $self->clear_httpd;
}

sub refresh_slack_oauth2 {
    my ($self) = @_;

    $self->slack_oauth2 unless $self->oauth2;

    if ($self->oauth2->should_refresh) {
        $self->slack_api("auth.test", {}, sub {
            my ($data) = @_;

            unless ($data->{ok}) {
                # need reauth
                $self->slack_oauth2;
            }
        });
    }

    return 1;
}

sub init_irc {
    my ($self) = @_;

    my $network_conf = $self->network_config;

    # config
    my $botnick    = $network_conf->{nickname};
    my $bindip     = $network_conf->{bindip};
    my $channels   = $network_conf->{channels};
    my $botreal    = $network_conf->{realname};
    my $botident   = $network_conf->{username};
    my $botserver  = $network_conf->{address};
    my $botssl     = $network_conf->{ssl};
    my $botpass    = $network_conf->{password};
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

    if ($ownername && $ownerpass && $sessionttl) {
        $self->{auth} = new Shittybot::Auth(
            'ownernick' => $network_conf->{ownername},
            'ownerpass' => $network_conf->{ownerpass},
            'sessionttl' => $network_conf->{sessionttl} || 0,
        );
    }

    # save channel list for the interpreter
    $self->{config_channel_list} = $channels;

    # closures to be defined
    my $init;
    my $getNick;

    ## getting its nick back
    $getNick = sub {
        my $nick = shift;
        # change your nick here
        $self->send_srv('PRIVMSG' => $nickserv, "ghost $nick $nickservpw") if defined $nickservpw;
        $self->send_srv('NICK', $nick);
    };

    ## callbacks
    my $conn = sub {
        my ($self, $err) = @_;
        return unless $err;
        say "Can't connect: $err";
        #keep reconecting
        $self->{reconnects}{$botserver} = AnyEvent->timer(
            after => 1,
            interval => 10,
            cb => sub {
                $init->();
            },
        );
    };

    $self->reg_cb(connect => $conn);
    $self->reg_cb(
        registered => sub {
            my $self = shift;
            say "Registered on IRC server";
            delete $self->{reconnects}{$botserver};
            $self->enable_ping(60);

            # oper up
            if ($operuser && $operpass) {
                $self->send_srv(OPER => $operuser, $operpass);
            }

            # save timer
            $self->{_nickTimer} = AnyEvent->timer(
                after => 10,
                interval => 30, # NICK RECOVERY INTERVAL
                cb => sub {
                    $getNick->($botnick) unless $self->is_my_nick($botnick);
                },
            );
        },
        ctcp => sub {
            my ($self, $src, $target, $tag, $msg, $type) = @_;
            say "$type $tag from $src to $target: $msg";
        },
        error => sub {
            my ($self, $code, $msg, $ircmsg) = @_;
            print STDERR "ERROR: $msg " . ddx($ircmsg) . "\n";
        },
        disconnect => sub {
            my ($self, $reason) = @_;
            delete $self->{_nickTimer};
            delete $self->{rejoins};
            say "disconnected: $reason. trying to reconnect...";
 
            #keep reconecting
            $self->{reconnects}{$botserver} = AnyEvent->timer(
                after => 10,
                interval => 10,
                cb => sub {
                    $init->();
                },
            );
        },
        part => sub {
            my ($self, $nick, $channel, $is_myself, $msg) = @_;
            return unless $nick eq $self->nick;
            say "SAPart from $channel, rejoining";
            $self->send_srv('JOIN', $channel);
        },
        kick => sub {
            my ($self, $nick, $channel, $msg, $nick2) = @_;
            return unless $nick eq $self->nick;
            say "Kicked from $channel; rejoining";
            $self->send_srv('JOIN', $channel);

            # keep trying to rejoin
            $self->{rejoins}{$channel} = AnyEvent->timer(
                after => 10,
                interval => 60,
                cb => sub {
                    $self->send_srv('JOIN', $channel);
                },
            );
        },
        join => sub {
            my ($self, $nick, $channel, $is_myself) = @_;
            return unless $is_myself;

            delete $self->{rejoins}{$channel};
        },
        nick_change => sub {
            my ($self, $old_nick, $new_nick, $is_myself) = @_;
            return unless $is_myself;
            return if $new_nick eq $botnick;
            $getNick->($botnick);
        },
    );

    $self->ctcp_auto_reply ('VERSION', ['VERSION', 'Shittybot']);

    # default crap
    $self->reg_cb
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
        my $mask = prefix_user($from);
        $mask .= "@".prefix_host($from) if prefix_host($from);

        if ($self->{auth}) {
            return if grep { $from =~ qr/$_/ } @{$self->{auth}->ignorelist};
        }

        my $txt = $msg->{params}->[-1];

        if ($txt =~ qr/^admin\s/ && $self->{auth}) {
            my $data = $txt;
            $data =~ s/^admin\s//;
            #$self->{auth}->from($from);
            my @out = $self->{auth}->Command($from, $data);
            $self->send_srv(@out);
        }

        if ($txt =~ qr/$trigger/) {
            my $code = $txt;
            $code =~ s/$trigger//;
            say "Got trigger: [$trigger] $code";

            # maybe we shouldn't execute this?
            return if $self->looks_shady($from, $code);

            # add log info to interperter call
            my $loglines = $self->slurp_chat_lines($chan);
            my $cmd_ctx = Shittybot::Command::Context->new(
                nick => $nick,
                mask => $mask,
                channel => $chan,
                command => $code,
                loglines => $loglines,
            );

            my ($cmd_res, $ok) = $self->versioned_eval($cmd_ctx);
            $self->send_to_channel($chan, $cmd_res);
        } else {
            $txt = Encode::decode( 'utf8', $txt );
            $self->append_chat_line( $chan, $self->log_line($nick, $mask, $txt) );
        }
    };

    $self->reg_cb(irc_privmsg => $parse_privmsg);

    $init = sub {
        $self->send_srv('PRIVMSG' => $nickserv, "identify $nickservpw") if defined $nickservpw;
        $self->enable_ssl if $botssl;
        $self->connect(
            $botserver, $botport, { nick => $botnick, user => $botident, real => $botreal, password => $botpass },
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

            # allow password
            my ($chan_, $pass) = split(':', $chan);
            $chan = $chan_ if $chan_;

            say "Joining $chan on " . $self->network;

            if ($chan && $pass) {
                $self->send_srv('JOIN', $chan, $pass);
            } else {
                $self->send_srv('JOIN', $chan);
            }

            # ..You may have wanted to join #bla and the server
            # redirects that and sends you that you joined #blubb. You
            # may use clear_chan_queue to remove the queue after some
            # timeout after joining, so that you don't end up with a
            # memory leak.
            $self->clear_chan_queue($chan);
        }
    };

    $init->();
}

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

# log channel chat lines 
sub append_chat_line {
    my ($self, $channel, $line) = @_;
    my $log = $self->logs->{$channel} || [];
    push @$log, $line;
    $self->logs->{$channel} = $log;
    return $log;
}

# retrieve channel log chat lines (as an array ref)
sub get_chat_lines {
    my ($self, $channel) = @_;
    return [] unless $channel;
    my $log = $self->logs->{$channel} || [];
    return $log;
}

# clear channel chat lines
# mutation
sub clear_chat_lines {
    my ($self, $channel) = @_;
    $self->logs->{$channel} = [];
}
# retrieve and clear channel chat lines (as an array ref)
# mutation
sub slurp_chat_lines {
    my ($self, $channel) = @_;
    my $log = $self->get_chat_lines( $channel );
    $self->clear_chat_lines( $channel );
    return $log;
}
# This is a data structure that is a chat long message
sub log_line {
    my ($self, $nick, $mask, $message) = @_;
    return [ time(), $nick, $mask, $message ];
}

sub send_to_channel {
    my ($self, $chan, $msg) = @_;

    return unless $msg;
    utf8::encode($msg);

    $msg =~ s/\001ACTION /\0777ACTION /g;
    $msg =~ s/[\000-\001]/ /g;
    $msg =~ s/\0777ACTION /\001ACTION /g;

    my @lines = split "\n" => $msg;
    my $limit = $self->network_config->{linelimit} || 20;

    # split lines if they are too long
    @lines = map { chunkby($_, 420) } @lines;

    if (@lines > $limit) {
        my $n = @lines;
        @lines = @lines[0..($limit-1)];
        push @lines, "error: output truncated to ".($limit - 1)." of $n lines total"
    }

    if ($self->is_slack) {
        foreach my $line (@lines) {
            $line =~ s/`/'/g;  # need to quote the line for monospace
            $self->send_chan($chan, 'PRIVMSG', $chan, "`${line}`");
        }
    } else {
        $self->send_chan($chan, 'PRIVMSG', $chan, $_) for @lines;
    }
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

sub looks_shady {
    my ($self, $from, $code) = @_;

    return 1 if $code =~ /foreach\s+proc/i;
    return 1 if $code =~ /irc\.arabs\./i;
    return 1 if $code =~ /foreach p \[info proc\]/i;
    return 1 if $code =~ /foreach.+info\s+proc/i;
    return 1 if $code =~ /foreach\s+var/i;
    return 1 if $code =~ /proc \w+ \{\} \{\}/i;
    return 1 if $code =~ /set \w+ \{\}/i;
    return 1 if $code =~ /lopl/i;

    return 0 unless $from;

    return 1 if $from =~ /800A3C4E\.1B6ABF9\.8E35284E\.IP/;
    return 1 if $from =~ /org\.org/;
    return 1 if $from =~ /acidx.dj/;
    return 1 if $from =~ /anonine.com/;
    return 1 if $from =~ /maxchats\-afvhsk.ipv6.he.net/;
    return 1 if $from =~ /maxchats\-69a5t0.cust.bredbandsbolaget.se/;
    return 1 if $from =~ /dynamic.ip.windstream.net/;
    return 1 if $from =~ /pig.aids/;
    return 1 if $from =~ /2607:9800:c100/;
    return 1 if $from =~ /loller/;
    return 1 if $from =~ /blacktar/i;
    return 1 if $from =~ /chatbuffet.net/;
    return 1 if $from =~ /tptd/;
    return 1 if $from =~ /b0nk/;
    return 1 if $from =~ /fullsail.com/;
    return 1 if $from =~ /abrn/;
    return 1 if $from =~ /bsb/;
    return 1 if $from =~ /remembercaylee.org/;
    return 1 if $from =~ /andyskates/;
    return 1 if $from =~ /oaks/;
    return 1 if $from =~ /emad/;
    return 1 if $from =~ /arabs.ps/;
    return 1 if $from =~ /guest/i;
    return 1 if $from =~ /sf.gobanza.net/;
    return 1 if $from =~ /4C42D300.C6D0F7BD.4CA38DE1.IP/;
    return 1 if $from =~ /anal.beadgame.org/;
    return 1 if $from =~ /CFD23648.ED246337.302A69E4.IP/;
    return 1 if $from =~ /mc.videotron.ca/;
    return 1 if $from =~ /^v\@/;
    return 1 if $from =~ /xin\.lu/;
    return 1 if $from =~ /\.ps$/;
    return 1 if $from =~ /caresupply.info/;
    return 1 if $from =~ /sttlwa.fios.verizon.net/;
    return 1 if $from =~ /maxchats-m107ce.org/;
    return 1 if $from =~ /bofh.im/;
    return 1 if $from =~ /morb/;
    return 1 if $from =~ /push\[RAX\]/;
    return 1 if $from =~ /pushRAX/;
    return 1 if $from =~ /maxchats-u5t042.mc.videotron.ca/;
    return 1 if $from =~ /avas/i;
    return 1 if $from =~ /avaz/i;
    return 1 if $from =~ /sloth/i;
    return 1 if $from =~ /bzb/i;
    return 1 if $from =~ /^X\b/;
    return 1 if $from =~ /zenwhen/i;
    return 1 if $from =~ /noah/i;
    return 1 if $from =~ /maxchats\-87i1b6.com/i;
    return 1 if $from =~ /pynchon/i;
    return 1 if $from =~ /shaniqua/i;
    return 1 if $from =~ /145\.98\.IP/i;
    return 1 if $from =~ /devi/i;
    return 1 if $from =~ /devio.us/i;
    return 1 if $from =~ /silver/i;
    return 1 if $from =~ /jbs/i;
    return 1 if $from =~ /maxchats-m8r510.res.rr.com/i;
    return 1 if $from =~ /sw0de/i;
    return 1 if $from =~ /careking/i;
    return 1 if $from =~ /114.31.211./i;
    return 1 if $from =~ /rucas/i;
    return 1 if $from =~ /ucantc.me/i;
    return 1 if $from =~ /maxchats-ej6b15.2d1r.sjul.0470.2001\.IP/i;
    return 1 if $from =~ /maxchats-2gn1sk\.us/i;
    return 1 if $from =~ /maxchats-3p5evi.bgk.bellsouth.net/;

    return 0;
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);
