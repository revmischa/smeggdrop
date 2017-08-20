#!/usr/bin/perl

use strict;
use warnings;
use 5.01;
use Net::SCP::Expect;

my $host = $ENV{"PUBLISH_HOSTNAME"};
my $user = $ENV{"PUBLISH_USERNAME"};
my $pass = $ENV{"PUBLISH_PASSWORD"};
my $file = $ENV{"PUBLISH_FILENAME"};

open TMP, ">", "publish";
while(<STDIN>) {
  print TMP
}
close TMP;

my $scpe = Net::SCP::Expect->new;
$scpe->login($user, $pass);
$scpe->scp("publish", "$host:$file");

