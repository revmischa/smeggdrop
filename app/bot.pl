#!/usr/bin/perl

# NOTE: This may segfault unless run with PERL_DL_NONLAZY=1

# must be loaded first
use Tcl;

use Moose;
use feature 'say';

use lib 'lib';

use Shittybot;
use Config::JFDI;

# disable stdout buffering
$| = 1;

my $datadir = $ENV{SMEGGDROP_DATA} || '.';

## anyevent main CV
my $cond = AnyEvent->condvar;

run();

$cond->wait;

sub run {
    # load shittybot.yml/conf/ini/etc
    my $config_raw = Config::JFDI->new(path => "./$datadir", name => 'shittybot');
    my $config = $config_raw->get;

    my $networks = $config->{networks}
        or die "Unable to find network configuration";

    # spawn client for each network
    my @clients;
    while (my ($net, $net_conf) = each %$networks) {
        next unless $net_conf->{slack}; # temp

        my $client = Shittybot->new(
            network => $net,
            config => $config,
            network_config => $net_conf,
        );

        $client->init;

        push @clients, $client;
    }   
}


