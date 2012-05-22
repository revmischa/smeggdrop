Shittybot
=========
A fork of Sam Stephenson's excellent smeggdrop.
No longer requires eggdrop
This fork uses AnyEvent, POE is on the outs.

Requirements:
------------
- Perl
  - AnyEvent::IRC::Client
  - Tcl
  - Moose
  - MooseX::Callbacks
  - MooseX::Traits
  - Time::Out
  - Carp::Always
  - Data::Dump
  - Config::Any
  - Config::General
  - YAML::XS (preferable)
  - parent
  - Try::Tiny
  - Net::SCP::Expect
  - Digest::SHA1
- Tcl 8.5
  - -dev package
  - tcllib
  - tclcurl
  - tclx
- Git

Quickstart:
----------
- Edit shittybot.yml
- Run './run-bot'
