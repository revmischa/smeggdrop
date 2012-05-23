package ForkRing;
# ForkRing attempts to provide a constant interface
# to a revolving door of potentially failing processes
use Moose;

our $DEBUG = 0;

# code is the code that get passed to forkbabies
has code        => ( is=>'rw', isa => 'CodeRef' );
has currentBaby => ( is=>'rw', isa => 'ForkBaby' );

sub runTests {
    TestForkRing::run();
}

sub getNewBaby {
    my ($self) = @_;
    dwarn("getNewBaby");
    my $baby = ForkBaby->new(code => $self->code);
    dwarn("forking...");
    $baby->forkit; #start the baby!
    $self->currentBaby($baby);
    return $baby;
}

#this will make a new baby is necessary
sub get_baby {
    my ($self) = @_;
    my $baby = $self->currentBaby();
    if ($baby) {
        return $baby;
    } else {
        return $self->getNewBaby()
    }
}

sub send {
    my ($self,$msg) = @_;
    dwarn("Getting Baby");
    my $baby = $self->get_baby();
    dwarn("Sending baby");
    dwarn("[$$] Sending baby: [$msg] ".$baby->hasForked());
    return $baby->send($msg);
}
sub dwarn { return unless $DEBUG; print join("\n", @_) . "\n"}
1;
package ForkBaby;
#Fork Baby wraps underlying perl code
#The perl code will just read and write
use Moose;
use Data::Dumper;
$| = 1;
use IO::Pipe;
use Time::Out qw(timeout) ;
$SIG{PIPE} = 'IGNORE';
use POSIX qw(sys_wait_h _exit);
sub REAPER {
    my $waitedpid = wait;
    # loathe sysV: it makes us not only reinstate
    # the handler, but place it after the wait
    $SIG{CHLD} = \&REAPER;
}
$SIG{CHLD} = \&REAPER;

sub install_handlers {
    $SIG{PIPE} = 'IGNORE';
    $SIG{CHLD} = \&REAPER;
}


has isParent          => ( is => 'rw', isa => 'Int', default => 0); #Pid
has hasForked         => ( is => 'rw', isa => 'Int', default => 0); #Pid
has fromParentToChild => ( is => 'rw', isa => 'IO::Pipe');
has fromChildToParent => ( is => 'rw', isa => 'IO::Pipe');
has code              => ( is => 'rw', isa => 'CodeRef' );
has timeoutSeconds    => ( is => 'rw', isa => 'Int', default => 30); #timeout time

sub iopipe {
    my $pipe = IO::Pipe->new();
    return $pipe;
}


sub send {
    my ($self,$msg) = @_;
    dwarn("Checking baby");
    my $hasForked = $self->hasForked();
    my $isParent = $self->isParent();
    die "[$$] [send] Not a parent, not forked [$msg] [$hasForked] [$isParent]" unless ($hasForked && $isParent);
    die "Not a parent, not forked [$msg]" unless (my $child_pid = $self->isParent());
    #die "Command has a newline in it!" if ($msg =~ m#$/#); 
    dwarn("Getting parent to child writer");
    my $writer = $self->fromParentToChild();
    dwarn("Writing to baby!");
    _writeMsg($writer, { type => "COMMAND", results => $msg });
    #print $writer ($msg.$/);
    # assume writer is flushed..
    return $self->readResponse();
}

sub childPid {
    my ($self) = @_;
    $self->isParent();
}

sub forkit {
    my ($self) = @_;
    dwarn("forkit");
    my $p2c = iopipe();
    my $c2p = iopipe();
    $self->fromChildToParent($c2p);
    $self->fromParentToChild($p2c);
    my $pid;
    if ($pid = fork()) {
        dwarn("[$$] Has parent now");
        $self->isParent($pid);
        $self->hasForked(1);
        $p2c->writer();
        $p2c->autoflush(1);
        $c2p->reader();
        $c2p->autoflush(1);
        utf8ify($c2p);
        utf8ify($p2c);
    } else {
        install_handlers();
        $self->isParent(0); # child
        $p2c->reader();
        $c2p->writer();
        $c2p->autoflush(1);
        $p2c->autoflush(1);
        utf8ify($c2p);
        utf8ify($p2c);
        return $self->childLoop();
    }    
}
sub utf8ify {
    my ($a) = @_;
    binmode $a, ":utf8";
}

sub readMsgFromParent {
    my ($self) = @_;
    my $read_pipe = $self->fromParentToChild();
    my $msg = _readMsg($read_pipe);
    return $msg;
}

sub childLoop {
    my ($self) = @_;
    dwarn("Child reading from parent!");
    while (my $command = $self->readMsgFromParent()) {
        dwarn("Have command! $command");
        my ($msg) = $self->parseCommand($command);
        my $res = $self->evalMsg($msg);
        # chances are we're a different process now! isn't that neat ;)
    }
    #die "We're done yeah!";
    _exit(0);
    #exit(0); #we're done yeah!
}

sub evalMsg {
    my ($self, $msg) = @_;
    my $result_pipe = iopipe();
    my $pid;
    my $results = undef;
    if ($pid = fork()) {
        # parent
        $result_pipe->reader();
        utf8ify( $result_pipe );
        $result_pipe->autoflush(1);
        my $time = $self->timeoutSeconds();
        my $SUCCESS = undef;
        timeout $time => sub {
            my $msg = _readMsg($result_pipe);
            if (defined($msg)) {
                $SUCCESS = $msg->{type};
                $results = $msg->{results};
            } else {
                $SUCCESS="failure";
                $results = "The underlying process likely died";
            }

            close($result_pipe);
            $result_pipe = undef;
        };
        if ($@ || $SUCCESS ne "SUCCESS"){
            # timeout occurred :(
            # kill the child
            # send error up
            # stay alive
            if (kill 0 => $pid) {
                kill 9 => $pid;
            }
            dwarn("A timeout occurred or the child died [".((defined($SUCCESS))?$SUCCESS:"undef")."]");
            if ($@) {
                $self->sendFailure( results => $@ );
            } else {
                $self->sendFailure( results => $results );
            }
        } else {
            # send info to parent
            $self->sendSuccess(pid => $pid, results => $results);
            # kill self
            #kill 1 => $$;
            #die "Kill self";
            _exit(0);
        }
    } else {
        # in the child
        install_handlers();
        $result_pipe->writer();
        utf8ify( $result_pipe );
        $result_pipe->autoflush(1);
        # we're a child lets run this command
        my $res = $self->runMsg($msg);
        # haha! we're still alive right!
        _writeMsg($result_pipe, { type=> "SUCCESS", results => $res });
        close($result_pipe);
        $result_pipe = undef;
    }
}
sub cleanUpChildren {
    my ($self) = @_;
    my $pid = $self->isParent();
    if (kill 0 => $pid) {
        kill 9 => $pid;
    }
}
sub parseCommand {
    my ($self,$command) = @_;
    return $command->{results} if $command;
    die "Invalid command to parse!";
}


sub runMsg {
    my ($self,$msg) = @_;
    my $sub = $self->code();
    my $res = &$sub($self,$msg);
    return $res;
}


sub _writeMsg {
    my ($write_fd, $hash) = @_;
    my $type = uc($hash->{type}) or die "No type for writeMsg!";
    dwarn("Sending type: $type");
    print $write_fd "$type$/";
    while (my ($key,$val) = each %$hash) {
        if ($key ne "CHARS" && lc($key) ne "type" && lc($key)  ne "results") {
            unless ($val =~ m#$/#) {
                dwarn("Sending $key: $val");
                print $write_fd "$key: $val$/";
            }
        }
    }
    print $write_fd "CHARS: ".length($hash->{results}).$/;
    print $write_fd $hash->{results};
    print $write_fd $/;
}


sub sendSuccess {
    my ($self,%hash) = @_;
    my $pid = $hash{pid};
    my $str = $hash{results};
    my $len = length($str)||0;
    my $write_fd = $self->fromChildToParent();
    _writeMsg($write_fd, { type => "SUCCESS", "new pid" => $pid, "pid" => $pid, results => $str});
}
sub sendFailure {
    my ($self,%hash) = @_;
    my $str = $hash{results};
    my $len = length($str)||0;
    my $write_fd = $self->fromChildToParent();
   _writeMsg($write_fd, { type => "FAILURE", results => $str});
}

# The format here is
# name\n
# metadata 1: value\n
# metadata 2: value\n
# ...
# metadata n: value\n
# CHARS: #ofchars\n#ascii integer
# c1...cn\n
#
# Don't send the same metadata again

sub _readMsg {
    my ($reader) = @_;
    dwarn("Starting _readMsg");
    my $name = <$reader>;
    dwarn("Finished _readMsg");
    return undef unless defined $name;
    chomp($name);
    dwarn("Got name $name");
    my $lname = lc($name);
    my $out = {
               type => $name,
               $lname => 1,
              };
    my $chars = 0;
    my $done = 0;
    while(my $line = <$reader>) {
        chomp($line);
        dwarn("Read line: $line");
        if ($line =~ /^CHARS:/) {
            $chars = _how_many_chars($line);
            last;
        } elsif ($line =~ /^([ a-zA-Z0-9]+):\s(.*)$/) {
            my ($key,$val) = ($1,$2);
            $out->{$key} = $val unless exists $out->{$key};
        } else {
            die "I'm not sure how to parse [$line]";
        }
    }
    dwarn("Expecting $chars");
    my $results = "";
    my $n = $reader->read($results, $chars);
    dwarn("Read: $results");
    die "Read $n not $chars chars!" unless $n == $chars;
    my $nl = <$reader>;
    die "[_readMsg] Not a newline: [$nl] [$results]" unless $nl eq $/;
    $out->{len} = $n;
    $out->{results} = $results;
    return $out;
}

sub readResponse {
    my ($self) = @_;
    dwarn("Reading response");
    my $hasForked = $self->hasForked();
    my $isParent = $self->isParent();
    die "Not a parent, not forked [$hasForked] [$isParent]" unless ($hasForked && $isParent);
    my $reader = $self->fromChildToParent();
    #dwarn("Result: $success_or_failure") if defined($success_or_failure);
    my $msg = _readMsg($reader);
    
    if (!defined($msg)) {
        warn "unexplained failure [probably death] [undefined \$msg]";
        $self->cleanUpChildren();
        $self->forkit();
        return {type => "FAILURE",
                failure => 1,
                results => "Not sure",
               };
    } elsif ($msg->{type} eq 'SUCCESS') {
        return $msg;
    } elsif ($msg->{type} eq 'FAILURE') {
        return $msg;
    } else { #like an undef
        die "Unexplained input ".Dumper($msg);
    }
}
sub _how_many_chars {
    my ($str) = @_;
    chomp($str);
    my ($chars) = ($str =~ /CHARS:\s+(\d+)$/);
    return $chars || 0;
}
sub _parse_pid {
    my ($str) = @_;
    chomp($str);
    my ($chars) = ($str =~ /NEW PID:\s+(\d+)$/);
    return $chars || 0;
}
sub dwarn { return unless $DEBUG; print join("\n", @_) . "\n"}
1;
package TestForkRing;
use strict;
use Data::Dumper;
sub proof_of_death {
    open(my $pod ,">>","proof_of_death.log");
    print $pod (@_,$/);
    close($pod);
    warn @_;
    die @_;
}

sub run {
    my $run = sub {
        my ($self,$data) = @_;
        srand();
        if (int(rand(10))==0) {
            proof_of_death "Random Death [$data]";
        } else {
            return localtime();
        }
    };
    my $fr = ForkRing->new( code => $run );
    for my $i (1..100) {
        #warn("Test $_");
        my $res = undef;
        do {
            $res = $fr->send("Test $i");
            warn "Not successful $i".Dumper($res) if !$res->{success};
        } until ($res->{success})
    }
    warn "We finally go to 100!";
    my $response = sub {
        my ($self,$data) = @_;
        srand();

        if (int(rand(10))==0) {
            proof_of_death "Response Random Death [$data]";
        } else {
            return lc($data);
        }
    };
    $fr = undef;
    $fr = ForkRing->new( code => $response );
    for my $c ('A'..'Z') {
        my $res;
        do {
            $res = $fr->send($c);
            warn "Not successful $c" if !$res->{success};
        } until ($res->{success});
        my $resc = $res->{results};
        chomp($resc);
        lc($c) eq $resc or  die "not LC'd? ".Dumper($res);
    }
    warn "We got from A..Z";

    my $state = 0;
    my $state_test = sub {
        my ($self,$data) = @_;
        warn "ST: $data $state";
        srand();

        if (int(rand(10))==0) {
            proof_of_death "State Test Random Death [$data]";
        } else {
            warn "Didn't die $data $state";
            $state += $data;
            return $state;
        }
    };
    my $cmpstate = 0;
    $fr = ForkRing->new( code => $state_test );
    for my $c (1..100) {
        $cmpstate += $c;
        my $res;
        do {
            $res = $fr->send($c);
            warn "Not successful $c" if !$res->{success};
        } until ($res->{success});
        my $resc = $res->{results};
        #warn "$cmpstate $resc";
        $cmpstate == $resc or  die "not State != State [$cmpstate] [$resc] ".Dumper($res);

    }
    warn "We got from 1..100 for state";

    my $newline_test = sub {
        my ($self,$data) = @_;
        srand();
        if (int(rand(10))==0) {
            proof_of_death("Newline Random Death [".length($data)."]");
        } else {
            my @nls = ($data =~ m#($/)#g);
            return scalar(@nls);
        }
    };
    $cmpstate = 0;
    $fr = ForkRing->new( code => $newline_test );
    for my $c (1..100) {
        #warn $c;
        my $s = "$/"x$c;
        my $res;
        do {
            $res = $fr->send($s);
            warn "Not successful $c" if !$res->{success};
        } until ($res->{success});
        my $resc = $res->{results};
        $c == $resc or die "Newlines didn't go through!";
    }
    warn "We got from 1..100 newline stuff";
    warn "Good everything worked!";
}
