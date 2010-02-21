#!/usr/bin/perl 

use strict;
use warnings;
use Config::General;
use Carp::Always;
use Data::Dump  qw/ddx/;
use POE         qw/Component::IRC::State Component::IRC::Plugin::Connector/;

sub parse_config {
  my $configfile  = $ENV{'SMEGGDROP_CONFIG'} && (-r $ENV{'SMEGGDROP_CONFIG'}) ? 
                      $ENV{'SMEGGDROP_CONFIG'} : 'bot.conf';
  die "Config file does not exist" unless (-r $configfile);
  my $config      = Config::General->new($configfile) or die "Failed to read config file";

  my %configuration = $config->getall or die "Failed to parse configuration file";
  return \%configuration;
}

my $config  = parse_config;

for my $server (keys %{$config->{Server}}) {
  my $conf  = $config->{Server}->{$server};

  my $nick      = $conf->{nickname} || 'dickbot',
  my $username  = $conf->{username} || 'urmom',
  my $ircname   = $conf->{realname} || 'loves dis bot',
  
  my $server    = $conf->{address} || warn "Unable to parse address for network $server" && next;
  my $port      = $conf->{port} || 6667;

  my $irc = POE::Component::IRC::State->spawn(
    nick      => $nick,
    username  => $username,
    ircname   => $ircname,

    server    => $server,
    port      => $port,
  ) or warn "Failed to spawn IRC component" && next;

  POE::Session->create(
    package_states  => [
      main  => [qw/_default _start irc_001/],
    ],
    heap  => {
      irc   => $irc,
      conf  => $conf,
    },
  );
}

sub _start {
  my ($kernel, $heap) = @_[KERNEL,HEAP];

  $heap->{irc}->yield(register  => 'all');
  $heap->{irc}->yield('connect');
}

sub irc_001 {
  my ($kernel, $heap) = @_[KERNEL,HEAP];

  print "Connected to ", $heap->{irc}->server_name, "\n";

  $heap->{irc}->yield(join => "#$_") for (@{$heap->{conf}->{Channels}->{default}});
}

sub _default {
  my ($kernel,$heap,$event,@args) = @_[KERNEL,HEAP,ARG0,ARG1 .. $#_];

  ddx($event);
  ddx(@args);
}

POE::Kernel->run();
