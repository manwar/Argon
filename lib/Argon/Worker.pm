package Argon::Worker;
# ABSTRACT: Argon worker node providing capacity to an Argon::Manager

use strict;
use warnings;
use Carp;
use Path::Tiny qw(path);
use AnyEvent;
use AnyEvent::Util qw(fork_call);
use Argon::Constants qw(:commands);
use Argon::Log;
use Argon::Util qw(K param token cipher interval);
require Argon::Client;
require Argon::Message;

use namespace::autoclean;

sub new {
  my ($class, %param) = @_;
  my $capacity = param 'capacity', %param;
  my $mgr_host = param 'mgr_host', %param;
  my $mgr_port = param 'mgr_port', %param;
  my $keyfile  = param 'keyfile',  %param, undef;

  my $key = defined $keyfile
    ? path($keyfile)->slurp_raw
    : param 'key', %param;

  $AnyEvent::Util::MAX_FORKS = $capacity;

  my $self = bless {
    key      => $key,
    capacity => $capacity,
    mgr_host => $mgr_host,
    mgr_port => $mgr_port,
    token    => token(cipher($key)),
    timer    => undef,
    tries    => 0,
    intvl    => interval(1),
  }, $class;

  $self->connect;

  return $self;
}

sub connect {
  my $self = shift;
  ++$self->{tries};
  $self->{mgr} = Argon::Client->new(
    key    => $self->{key},
    token  => $self->{token},
    host   => $self->{mgr_host},
    port   => $self->{mgr_port},
    opened => K('_connected', $self),
    closed => K('_disconnected', $self),
    notify => K('_queue', $self),
  );
}

sub _connected {
  my $self = shift;
  undef $self->{timer};
  $self->{intvl}->(1);
  $self->register;
}

sub _disconnected {
  my $self = shift;
  log_note 'Manager disconnected' unless $self->{timer};
  $self->reconnect;
}

sub reconnect {
  my $self = shift;
  my $intvl = $self->{intvl}->();
  log_debug 'Reconection attempt in %0.4fs', $intvl;
  $self->{timer} = AnyEvent->timer(after => $intvl, cb => K('connect', $self));
}

sub register {
  my $self = shift;
  log_trace 'Registering with manager';

  my $msg = Argon::Message->new(
    cmd  => $HIRE,
    info => { capacity => $self->{capacity} },
  );

  $self->{mgr}->send($msg);
  $self->{mgr}->reply_cb($msg, K('_mgr_registered', $self));
}

sub _mgr_registered {
  my ($self, $msg) = @_;
  if ($msg->cmd eq $ERROR) {
    log_error 'Failed to register with manager: %s', $msg->info;
  } else {
    log_info 'Accepting tasks';
  }
}

sub _queue {
  my ($self, $msg) = @_;
  my ($class, @args) = @{$msg->info};
  fork_call { _task($class, @args) } K('_result', $self, $msg);
}

sub _task {
  require Class::Load;
  my ($class, @args) = @_;
  Class::Load::load_class($class);
  $class->new(@args)->run;
}

sub _result {
  my $self = shift;
  my $msg  = shift;

  my $reply = @_ == 0
    ? $msg->reply(cmd => $ERROR, info => $@ || "errno: $!")
    : $msg->reply(cmd => $DONE,  info => shift);

  $self->{mgr}->send($reply);
}

1;
