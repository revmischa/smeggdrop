# Shittybot
* A fork of Sam Stephenson's excellent smeggdrop.
* Evalutes Tcl in IRC and Slack chat rooms.
* No longer requires eggdrop.
* This fork uses AnyEvent, POE is on the outs.

# Requirements:
* Install required CPAN modules:
`cpanm --sudo -v -n --installdeps .`

# Quickstart:
* `cp shittybot.yml.default shittybot.yml`
* Edit `shittybot.yml`
* `./run-bot`
