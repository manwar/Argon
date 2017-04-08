package Argon::Message;
# ABSTRACT: Encodable message structure used for cross-system coordination

use strict;
use warnings;
use Carp;
use Data::UUID;
use JSON::XS;
use Argon::Constants qw(:priorities :commands);
use Argon::Util qw(param);

sub new {
  my ($class, %param) = @_;
  my $id    = param 'id',    %param, sub { Data::UUID->new->create_str };
  my $token = param 'token', %param, undef;
  my $pri   = param 'pri',   %param, $PRI_NO;
  my $cmd   = param 'cmd',   %param;
  my $info  = param 'info',  %param, undef;

  bless {
    id    => $id,
    token => $token,
    pri   => $pri,
    cmd   => $cmd,
    info  => $info,
  }, $class;
}

sub id    { $_[0]->{id} }
sub token { $_[0]->{token} }
sub pri   { $_[0]->{pri} }
sub cmd   { $_[0]->{cmd} }
sub info  { $_[0]->{info} }

sub failed { $_[0]->cmd eq $ERROR }

sub reply {
  my ($self, %param) = @_;
  Argon::Message->new(
    %$self,         # copy $self
    token => undef, # remove token (unless in %param)
    %param,         # add caller's parameters
  );
}

sub error {
  my ($self, $error, %param) = @_;
  $self->reply(%param, cmd => $ERROR, info => $error);
}

sub result {
  my $self = shift;
  return $self->cmd eq $ERROR ? croak($self->info)
       : $self->cmd eq $DONE  ? $self->info
       : $self->cmd eq $ACK   ? 1
       : $self->cmd;
}

sub explain {
  my $self = shift;
  my $info = ref $self->info ? $self->info : [$self->info];
  sprintf 'Message<%s %s: %s>',
    $self->cmd,
    $self->id,
    encode_json($info);
}

1;
