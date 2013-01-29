#-------------------------------------------------------------------------------
# Logic governing a unit that may be managed by another process (e.g. a node
# in a cluster or cluster in a super-cluster).
#-------------------------------------------------------------------------------
package Argon::Role::ManagedServer;

use Moose::Role;
use Carp;
use namespace::autoclean;
use Argon qw/LOG :commands/;

requires 'port';
requires 'host';

has 'managers' => (
    is       => 'rw',
    isa      => 'HashRef[ArrayRef]',
    init_arg => undef,
    default  => sub {{}},
);

has 'manager' => (
    is       => 'rw',
    isa      => 'HashRef[Argon::Client]',
    init_arg => undef,
    default  => sub {{}},
);

#-------------------------------------------------------------------------------
# Selects a remote host to notify as a manager.
#-------------------------------------------------------------------------------
sub add_manager {
    my ($self, $host, $port) = @_;
    $self->managers->{"$host:$port"} = [$host, $port];
}

#-------------------------------------------------------------------------------
# Registers with configured upstream managers.
#-------------------------------------------------------------------------------
sub notify {
    my $self = shift;
    my $port = $self->port;
    my $host = $self->host || 'localhost';
    my $node = [$host, $port];

    foreach my $manager (keys %{$self->managers}) {
        my ($host, $port) = @{$self->managers->{$manager}};
        my $client  = Argon::Client->new(host => $host, port => $port);
        my $msg     = Argon::Message->new(command => CMD_ADD_NODE);
        my $respond = Argon::Respond->new();

        $msg->set_payload($node);

        $respond->to(CMD_ACK, sub {
            LOG("Registration complete with manager %s:%d", $host, $port);
            $self->manager->{$manager} = $client;
        });

        $respond->to(CMD_ERROR, sub {
            LOG("Unable to register with manager %s:%d - %s", $host, $port, shift);
            $client->close;
            del $self->managers->{$manager};
        });

        $client->on_connection(sub {
            LOG("Notification sent to manager %s", $manager);
            $client->send($msg, $respond);
        });

        LOG("Connecting to manager %s", $manager);
        $client->connect;
    }
}

no Moose;

1;