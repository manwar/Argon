package Argon::Manager;

use Moo;
use MooX::HandlesVia;
use Types::Standard qw(-types);
use Const::Fast;
use Coro;
use Coro::PrioChannel;
use Coro::Semaphore;
use Guard qw(scope_guard);
use Argon::Client;
use Argon::Tracker;
use Argon qw(K :logging :commands);

const our $ERR_NO_CAPACITY => 'Unable to process request. System is at max capacity.';
const our $ERR_PROC_FAIL   => 'An error occurred routing the request.';
const our $ERR_NOT_FOUND   => 'The message ID was not found.';

extends 'Argon::Dispatcher';

has queue_size => (
    is  => 'ro',
    isa => Maybe[Int],
);

has workers => (
    is          => 'ro',
    isa         => Map[Str,InstanceOf['Argon::Client']],
    init_arg    => undef,
    default     => sub {{}},
    handles_via => 'Hash',
    handles     => {
        set_worker  => 'set',
        get_worker  => 'get',
        del_worker  => 'delete',
        has_worker  => 'exists',
        all_workers => 'keys',
        num_workers => 'count',
    }
);

has tracking => (
    is          => 'ro',
    isa         => Map[Str,InstanceOf['Argon::Tracker']],
    init_arg    => undef,
    default     => sub {{}},
    handles_via => 'Hash',
    handles     => {
        set_tracking => 'set',
        get_tracking => 'get',
        del_tracking => 'delete',
    }
);

has sem_capacity => (
    is       => 'ro',
    isa      => InstanceOf['Coro::Semaphore'],
    init_arg => undef,
    default  => sub { Coro::Semaphore->new(0) },
    handles  => {
        current_capacity => 'count',
    }
);

has capacity => (
    is       => 'ro',
    isa      => Int,
    init_arg => undef,
    default  => 0,
);

has todo => (
    is       => 'lazy',
    isa      => InstanceOf['Coro::PrioChannel'],
    init_arg => undef,
    handles  => {
      todo_put => 'put',
      todo_get => 'get',
      todo_len => 'size',
    }
);

sub _build_todo {
    my $self = shift;
    return Coro::PrioChannel->new($self->queue_size);
}

has complete => (
    is          => 'ro',
    isa         => HashRef,
    init_arg    => undef,
    default     => sub {{}},
    handles_via => 'Hash',
    handles     => {
      complete_set => 'set',
      complete_get => 'get',
      complete_del => 'delete',
      is_pending   => 'exists',
    }
);

has watcher => (
    is       => 'lazy',
    isa      => InstanceOf['Coro'],
    init_arg => undef,
);

sub _build_watcher {
    my $self = shift;

    return async {
        while ($self->is_running) {
            # Get the next message
            my $msg = $self->todo_get;

            # Acquire capacity slot
            $self->sem_capacity->down;

            # Release capacity slot once complete
            scope_guard { $self->sem_capacity->up };

            # Get the next available worker
            my $cmp = sub { $self->get_tracking($_[0])->est_proc_time };
            my @workers =
                sort { $cmp->($a) <=> $cmp->($b) }
                grep { $self->get_tracking($_)->capacity > 0 }
                $self->all_workers;

            my $worker = $workers[0];

            # Execute with tracking
            $self->get_tracking($worker)->start_request($msg->id);

            scope_guard {
                # If the worker connection was lost while the request was
                # outstanding, the tracker may be missing, so completing
                # the request must account for this appropriately.
                $self->get_tracking($worker)->end_request($msg->id)
                    if $self->has_worker($worker);
            };

            # Assign the task
            $msg->{key} = $worker;

            # TODO this is hanging sometimes and causing delays in responses
            my $reply = eval { $self->get_worker($worker)->send($msg) };

            if ($@) {
                WARN 'Worker error (%s) - disconnecting: %s', $worker, $@;
                $self->deregister($worker);
                $reply = $msg->reply(cmd => $CMD_ERROR, payload => "$ERR_PROC_FAIL. Error message: $@");
            }

            $self->complete_get($msg->id)->put($reply);
        }
    };
}

has is_running => (
    is      => 'rw',
    isa     => Bool,
    default => 0,
);

sub inc_capacity {
    my ($self, $amount) = @_;
    $amount //= 1;
    $self->{capacity} += $amount;
}

sub dec_capacity {
    my ($self, $amount) = @_;
    $amount //= 1;
    $self->{capacity} -= $amount;
}

sub has_capacity {
    my $self = shift;
    return if $self->capacity == 0;
    return if $self->queue_size && $self->todo_len >= $self->queue_size;
    return 1;
}

sub init {
    my $self = shift;
    $self->respond_to($CMD_REGISTER, K('cmd_register', $self));
    $self->respond_to($CMD_QUEUE,    K('cmd_queue',    $self));
    $self->respond_to($CMD_COLLECT,  K('cmd_collect',  $self));
    $self->respond_to($CMD_STATUS,   K('cmd_status',   $self));
    $self->is_running(1);
    $self->watcher;
}

sub shutdown {
    my $self = shift;
    $self->is_running(0);
}

sub deregister {
    my ($self, $worker) = @_;
    if ($self->has_worker($worker)) {
        my $lost_capacity = $self->get_tracking($worker)->workers;
        $self->dec_capacity($lost_capacity);
        $self->sem_capacity->adjust(-$lost_capacity);
        $self->del_worker($worker);
        $self->del_tracking($worker);
        WARN 'Lost connection to worker "%s"', $worker;
        DEBUG 'Capacity at %d', $self->capacity;
    }
}

sub start_monitor {
    my ($self, $worker) = @_;
    my $client = $self->get_worker($worker);

    async_pool {
        scope_guard { $self->deregister($worker) };

        while (1) {
            DEBUG 'Sending ping';
            my $msg = Argon::Message->new(cmd => $CMD_PING);
            my $reply = $client->send($msg) or last;

            if ($reply->cmd == $CMD_ACK) {
                Coro::AnyEvent::sleep $Argon::POLL_INTERVAL;
            } else {
                WARN 'Worker monitor detected a problem: %s', $reply->payload;
                $self->deregister($worker);
            }
        }
    };
}

sub cmd_register {
    my ($self, $msg) = @_;
    my $key      = $msg->key;
    my $host     = $msg->payload->{host};
    my $port     = $msg->payload->{port};
    my $capacity = $msg->payload->{capacity};

    # Create client
    my $client = Argon::Client->new(host => $host, port => $port);

    INFO 'Connecting to worker "%s"', $key;
    $client->connect;
    INFO 'Connected to worker "%s"', $key;

    # Create tracker
    my $tracker = Argon::Tracker->new(
        tracking => $Argon::TRACK_MESSAGES,
        workers  => $capacity,
    );

    # Store worker and worker tracking
    $self->set_worker($key, $client);
    $self->set_tracking($key, $tracker);

    # Increment capacity and release up to $capacity slots
    $self->inc_capacity($capacity);
    $self->sem_capacity->adjust($capacity);

    # Start monitor
    $self->start_monitor($key);

    DEBUG 'Capacity at %d', $self->capacity;

    return $msg->reply(
        cmd     => $CMD_ACK,
        payload => { client_addr => $client->addr },
    );
}

sub cmd_queue {
    my ($self, $msg, $addr) = @_;

    # Reject tasks when there is no available capacity
    return $msg->reply(cmd => $CMD_REJECTED, payload => $ERR_NO_CAPACITY)
        unless $self->has_capacity;

    $self->complete_set($msg->id => Coro::Channel->new());
    $self->todo_put($msg);

    return $msg->reply(cmd => $CMD_ACK);
}

sub cmd_collect {
    my ($self, $msg, $addr) = @_;

    my $id = $msg->payload;

    return $msg->reply(cmd => $CMD_ERROR, payload => $ERR_NOT_FOUND)
        unless $self->is_pending($id);

    my $result = $self->complete_get($id)->get;;
    $self->complete_del($id);

    return $result->reply(id => $id);
}

sub cmd_status {
    my ($self, $msg, $addr) = @_;

    my $pending;
    foreach my $worker ($self->all_workers) {
        $pending->{$worker} = [$self->get_tracking($worker)->all_pending];
    }

    return $msg->reply(
        cmd     => $CMD_COMPLETE,
        payload => {
            workers          => $self->num_workers,
            total_capacity   => $self->capacity,
            current_capacity => $self->current_capacity,
            queue_length     => $self->todo_len,
            pending          => $pending,
        }
    );
}

1;
