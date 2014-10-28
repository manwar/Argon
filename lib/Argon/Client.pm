package Argon::Client;

use Moo;
use MooX::HandlesVia;
use Types::Standard qw(-types);
use Carp;
use AnyEvent;
use AnyEvent::Socket;
use Coro;
use Coro::AnyEvent;
use Coro::Handle;
use List::Util qw(max);
use Guard qw(scope_guard);
use Argon qw(:commands :priorities :logging);
use Argon::Message;
use Argon::Stream;

has host => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);

has port => (
    is       => 'ro',
    isa      => Int,
    required => 1,
);

has stream => (
    is       => 'lazy',
    isa      => InstanceOf['Argon::Stream'],
    init_arg => undef,
    handles  => {
        addr => 'addr',
    },
);

sub _build_stream {
    my $self = shift;
    return Argon::Stream->connect($self->host, $self->port);
}

after _build_stream => sub {
    my $self = shift;
    $self->read_loop;
};

has pending => (
    is          => 'ro',
    isa         => HashRef,
    init_arg    => undef,
    default     => sub {{}},
    handles_via => 'Hash',
    handles  => {
        set_pending => 'set',
        get_pending => 'get',
        del_pending => 'delete',
        has_pending => 'exists',
        all_pending => 'keys',
    }
);

has inbox => (
    is       => 'ro',
    isa      => InstanceOf['Coro::Channel'],
    init_arg => undef,
    default  => sub { Coro::Channel->new() },
);

has read_loop => (
    is       => 'lazy',
    isa      => InstanceOf['Coro'],
    init_arg => undef,
);

sub _build_read_loop {
    my $self = shift;

    return async {
        scope_guard { $self->shutdown };

        while (1) {
            my $msg = $self->stream->read or last;

            if ($self->has_pending($msg->id)) {
                $self->get_pending($msg->id)->put($msg);
            } else {
                $self->inbox->put($msg);
            }
        }
    };
}

sub shutdown {
    my $self = shift;

    $self->stream->close;
    $self->inbox->shutdown;

    my $error = 'Lost connection to worker while processing request';
    foreach my $msgid ($self->all_pending) {
        my $msg = Argon::Message->new(cmd => $CMD_ERROR, id => $msgid, payload => $error);
        $self->get_pending($msgid)->put($msg);
    }
}

sub connect {
    my $self = shift;
    $self->stream;
}

sub _wait_msgid {
    my ($self, $msgid) = @_;
    my $reply = $self->get_pending($msgid)->get();
    $self->del_pending($msgid);
    return $reply;
}

sub send {
    my ($self, $msg) = @_;
    $self->set_pending($msg->id, Coro::Channel->new());
    $self->stream->write($msg);
    return $self->_wait_msgid($msg->id);
}

sub queue {
    my ($self, $f, $args, $pri, $max_tries) = @_;
    $f && ref $f eq 'CODE' || croak 'expected CODE ref';

    $args ||= [];
    ref $args eq 'ARRAY' || croak 'expected ARRAY ref of args';

    $pri       ||= $PRI_NORMAL;
    $max_tries ||= 10;

    my $msg = Argon::Message->new(
        cmd     => $CMD_QUEUE,
        pri     => $pri,
        payload => [$f, $args],
    );

    my $next_try  = 0.1;
    my $reply;

    for (my $tries = 1; $tries <= $max_tries; ++$tries) {
        $reply = $self->send($msg);

        if ($reply->cmd == $CMD_REJECTED) {
            $next_try = log(max($tries, 1.1)) / log(10);
            Coro::AnyEvent::sleep $next_try;
            next;
        }
    }

    if ($reply->cmd == $CMD_COMPLETE) {
        return $reply->payload;
    }
    elsif ($reply->cmd == $CMD_REJECTED) {
        croak sprintf('Request failed after %d attempts. %s', $max_tries, $reply->payload);
    }
    else {
        croak $reply->payload;
    }
}

sub defer {
    my $arr = wantarray;
    my $cv  = AnyEvent->condvar;

    my $thread = async_pool {
        if ($arr) {
            my @result = eval { queue(@_) };
            $cv->croak($@) if $@;
            $cv->send(@result);
        } else {
            my $result = eval { queue(@_) };
            $cv->croak($@) if $@;
            $cv->send($result);
        }
    } @_;

    return sub { $cv->recv };
}

1;
__DATA__

=head1 NAME

Argon::Client

=head1 SYNOPSIS

    use Argon::Client;

    # Connect
    my $client = Argon::Client->new(host => '...', port => XXXX);

    # Send task and wait for result
    my $the_answer = $client->queue(sub {
        my ($x, $y) = @_;
        return $x * $y;
    }, [6, 7]);

    # Send task and get a deferred result that can be synchronized later
    my $deferred = $client->defer(sub {
        my ($x, $y) = @_;
        return $x * $y;
    }, [6, 7]);

    my $result = $deferred->();

    # Close the client connection
    $client->shutdown;

=head1 DESCRIPTION

Establishes a connection to an Argon network and provides methods for executing
tasks and collecting the results.

=head1 METHODS

=head2 new(host => $host, port => $port)

Creates a new C<Argon::Client>. The connection is made lazily when the first
call to L</queue> or L</connect> is performed. The connection can be forced by
calling L</connect>.

=head2 connect

Connects to the remote host.

=head2 queue($f, $args, $pri, $max_tries)

Sends a task to the Argon network to evaluate C<$f->(@$args)> and returns the
result. Since Argon uses L<Coro>, this method does not actually block until the
result is received. Instead, it yields execution priority to other threads
until the result is available. If specified, $pri (an $Argon::PRI_* constant)
is the priority of the task, affecting the priority queueing of the task with
the manager. $max_tries specifies the maximum number of attempts that will be
made to queue the task in the event that the server is at maximum capacity and
rejects the request.

If an error occurs in the execution of C<$f>, an error is thrown.

=head2 defer($f, $args)

Similar to L</queue>, but instead of waiting for the result, returns an
anonymous function that, when called, waits and returns the result. If an error
occurs when calling <$f>, it is re-thrown from the anonymous function.

=head2 shutdown

Disconnects from the Argon network.

=head1 A NOTE ABOUT SCOPE

L<Storable> is used to serialize code that is sent to the Argon network. This
means that the code sent I<will not have access to variables and modules outside
of itself> when executed. Therefore, the following I<will not work>:

    my $x = 0;
    $client->queue(sub { return $x + 1 }); # $x not found!

The right way is to pass it to the function as part of the task's arguments:

    my $x = 0;

    $client->queue(sub {
        my $x = shift;
        return $x + 1;
    }, [$x]);

Similarly, module imports are not available to the function:

    use Data::Dumper;

    my $data = [1,2,3];
    my $string = $client->queue(sub {
        my $data = shift;
        return Dumper($data); # Dumper not found
    }, [$data]);

The right way is to import the module inside the task:

    my $data = [1,2,3];
    my $string = $client->queue(sub {
        require Data::Dumper;
        my $data = shift;
        return Data::Dumper::Dumper($data);
    }, [$data]);

Note the use of C<require> instead of C<use>. This is because C<use> is
performed at compilation time, causing it to be triggered when the calling code
is compiled, rather than from within the worker process. C<require>, on the
other hand, is triggered at runtime and will behave as expected.

=head1 AUTHOR

Jeff Ober <jeffober@gmail.com>
