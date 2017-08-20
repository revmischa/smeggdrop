FROM centos:7

RUN yum update -y
RUN yum install -y tcl-devel tclx gcc
RUN yum install -y perl-App-cpanminus sudo perl-Try-Tiny perl-Module-Pluggable perl-LWP-Protocol-https perl-JSON \
  perl-YAML perl-WWW-Curl

ADD app /app
WORKDIR /app

RUN cpanm -Svn --installdeps .

ADD state ./
ADD int80_slack-oauth2-token ./
ADD shittybot.yml ./

CMD ['./run-bot']
