#-------------------------------------------------------------------------------
# Nodes manage a pool of Worker processes. Like a Cluster, they route tasks to
# Workers (without worrying about each processes' speed, since they are local),
# and store the results.
#-------------------------------------------------------------------------------
package Argon::Node;

use Moose;
use Carp;
use namespace::autoclean;
use Sys::Hostname;
use Argon qw/LOG :commands/;

require Argon::WorkerProcess;
require Argon::Client;

extends 'Argon::MessageProcessor';
with    'Argon::Role::MessageServer';
with    'Argon::Role::QueueManager';

has 'concurrency' => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

has 'worker_pool' => (
	traits   => ['Array'],
    is       => 'ro',
    isa      => 'ArrayRef[Argon::WorkerProcess]',
    init_arg => undef,
    default  => sub { [] },
    handles  => {
        'workers'    => 'elements',
        'checkout'   => 'shift',
        'checkin'    => 'push',
        'idle'       => 'count',
        'clear_pool' => 'clear',
    },
);

has 'managers' => (
    is       => 'rw',
    isa      => 'ArrayRef[ArrayRef]',
    init_arg => undef,
    default  => sub { [] },
);

has 'int_handler'  => ( is => 'rw', init_arg => undef );
has 'term_handler' => ( is => 'rw', init_arg => undef );

#-------------------------------------------------------------------------------
# Spawns a single worker process and returns the Argon::WorkerProcess instance.
# Passes parameters unchanged to Argon::WorkerProcess->spawn.
#-------------------------------------------------------------------------------
sub spawn_worker {
    my $self   = shift;
    my $worker = Argon::WorkerProcess->new(endline => $self->endline);
    $worker->spawn(@_);
    return $worker;
}

#-------------------------------------------------------------------------------
# Initializes by starting workers processes.
# TODO Determine and implement correct behavior when spawning initial processes
#      is unsuccessful. Is this behavior different from an error spawning a
#      worker process when already running?
#-------------------------------------------------------------------------------
sub initialize {
    my $self = shift;
    for (1 .. $self->concurrency) {
        LOG("Spawning worker #%d", $_);
		$self->checkin($self->spawn_worker());
    }

    $self->notify;

    # Add signal handlers
    $self->int_handler(AnyEvent->signal(signal => 'INT',  cb => sub { $self->shutdown }));
    $self->term_handler(AnyEvent->signal(signal => 'INT', cb => sub { $self->shutdown }));
}

sub shutdown {
    LOG('Shutting down.');
    exit 0;
}

#-------------------------------------------------------------------------------
# Selects a remote host to use as the manager for this node.
#-------------------------------------------------------------------------------
sub add_manager {
    my ($self, $host, $port) = @_;
    push @{$self->managers}, [$host, $port];
}

#-------------------------------------------------------------------------------
# Registers node with configured upstream managers.
#-------------------------------------------------------------------------------
sub notify {
    my $self = shift;
    my $port = $self->server->port;
    my $host = $self->server->host || hostname;
    my $node = [$host, $port];

    foreach my $manager (@{$self->managers}) {
        my ($host, $port) = @$manager;
        my $client = Argon::Client->new(host => $host, port => $port);
        my $msg    = Argon::Message->new(command => CMD_ADD_NODE);
        $msg->set_payload($node);

        LOG("Connecting to manager %s:%d", $host, $port);
        $client->connect(sub {
            LOG("Sent notification to manager %s:%d", $host, $port);
            $client->send($msg, sub {
                LOG("Registration complete with manager %s:%d", $host, $port);
                $client->close;
            });
        });
    }
}

#-------------------------------------------------------------------------------
# Attempts to assign the message to the next free worker process. If no
# processes are free, returns false.
#-------------------------------------------------------------------------------
sub assign_message {
    my ($self, $message) = @_;
	return if $self->idle == 0;

	my $worker = $self->checkout;
    $worker->send($message, sub {
		$self->msg_complete(shift);
		$self->checkin($worker);
	});

    return 1;
}

__PACKAGE__->meta->make_immutable;

1;