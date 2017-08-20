FROM centos:7

RUN yum update -y
RUN yum install -y tcl-devel tclx gcc
RUN yum install -y perl-App-cpanminus sudo perl-Try-Tiny perl-Module-Pluggable perl-LWP-Protocol-https perl-JSON \
  perl-YAML perl-WWW-Curl

ADD app/cpanfile /cpanfile
RUN cpanm -Svn --installdeps /

ADD app /app
WORKDIR /app

ENV PERL_DL_NONLAZY=1

CMD ["perl", "bot.pl"]
