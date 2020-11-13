package Myriad::Transport::Redis;

use Myriad::Class extends => qw(IO::Async::Notifier);

# VERSION
# AUTHORITY

=pod

We expect to expose:

- stream handling functionality, including claiming/pending
- get/set and observables
- sorted sets
- hyperloglog existence
- simple queues via lists
- pub/sub

This module is responsible for namespacing, connection handling and clustering.
It should also cover retry for stateless calls.

=cut

use Myriad::Redis::Pending;

use Net::Async::Redis;

use List::Util qw(pairmap);

has $redis_uri;
has $redis;
has $redis_pool = [ ];
has $waiting_redis_pool = [];
has $pending_redis_count = 0;
has $wait_time = 15_000;
has $batch_count = 50;
has $max_pool_count;

has $ryu;

method configure (%args) {
    $redis_uri = delete $args{redis_uri} if exists $args{redis_uri};
    $max_pool_count = exists $args{max_pool_count} ? delete $args{max_pool_count} : 10;

    return $self->next::method(%args);
}

method ryu {$ryu}

=head2 wait_time

Time to wait for items, in milliseconds.

=cut

method wait_time () { $wait_time }

=head2 batch_count

Number of items to allow per batch (pending / readgroup calls).

=cut

method batch_count () { $batch_count }

async method oldest_processed_id($stream) {
    my $v = await $self->consumer_group_info(GROUPS => $stream);
    my $oldest;
    for my $group (@$v) {

        my $group_name = $group->{name};
        my $f = await $self->consumer_group_info(CONSUMERS => $stream, $group_name);
        $log->tracef('Consumer info: %s', $f);
        $log->tracef('Pending check where oldest was %s and last delivered %s', $oldest, $group->{last_delivered_id});
        $oldest //= $group->{last_delivered_id};
        $oldest = $group->{last_delivered_id} if $group->{last_delivered_id} and $self->compare_id($oldest, $group->{last_delivered_id}) > 0;
        {
            my ($v) = await $self->pending_messages_info($stream, $group_name);
            my ($count, $first_id, $last_id, $consumers) = @$v;
            $log->tracef('Pending info %s', $v);
            $log->tracef('Pending from %s', $first_id);
            $log->tracef('Pending check where oldest was %s and first %s', $oldest, $first_id);
            $oldest //= $first_id;
            $oldest = $first_id if defined($first_id) and $self->compare_id($oldest, $first_id) > 0;
        }
    }
    return $oldest;
}

=head2 compare_id

Given two IDs, compare them as if doing a C<< <=> >> numeric
comparison.

=cut

method compare_id($x, $y) {
    $x //= '0-0';
    $y //= '0-0';
    # Do they match?
    return 0 if $x eq $y;
    my @first = split /-/, $x, 2;
    my @second = split /-/, $y, 2;
    return $first[0] <=> $second[0]
        || $first[1] <=> $second[1];
}

=head2 next_id

Given a stream ID, returns the next ID after it.
This is managed by the simple expedient of incrementing
the right-hand part of the identifier.

=cut

method next_id($id) {
    my ($left, $right) = split /-/, $id, 2;
    ++$right;
    $left . '-' . $right
}

method _add_to_loop(@) {
    $self->add_child(
        $redis = Net::Async::Redis->new(uri => $redis_uri),
    );

    $self->add_child(
        $ryu = Ryu::Async->new
    )
}

method source(@args) {
    $self->ryu->source(@args)
}

=head2 iterate

Deal with incoming requests via a stream.

Returns a L<Ryu::Source> which emits L<Myriad::Redis::Pending> items.

=cut

method iterate(%args) {
    my $src = $self->source;
    my $stream = $args{stream};
    my $group = $args{group};
    my $client = $args{client};
    Future->wait_any(
        $src->completed->without_cancel,
        (async sub {
            while (1) {
                await $src->unblocked;
                my ($batch) = await $self->xreadgroup(
                    BLOCK   => $self->wait_time,
                    GROUP   => $group, $client,
                    COUNT   => $self->batch_count,
                    STREAMS => (
                        $stream, '>'
                    )
                );
                $log->tracef('Read group %s', $batch);
                for my $stream (sort keys $batch->%*) {
                    my  $data = $batch->{$stream};
                    for my $item ($data->@*) {
                        my ($id, $args) = $item->@*;
                        $log->tracef(
                            'Item from stream %s is ID %s and args %s',
                            $stream,
                            $id,
                            $args
                        );
                        if($args) {
                            push @$args, ("message_id", $id);
                            $src->emit($args);
                        }
                    }
                }
            }
        })->()->without_cancel
    )->on_fail(sub {
        my $error = shift;
        $log->errorf("Failed while iterating on messages due: %s", $error);
    })->retain;
    $src;
}

async method xinfo(@args) {
    return await $redis->xinfo(@args);
}

async method stream_info($stream) {
    my $v = await $self->xinfo(
        STREAM => $stream
    );
    my %info = pairmap {
        (
            ($a =~ tr/-/_/r),
            $b
        )
    } @$v;
    $log->tracef('Currently %d groups, %d total length', $info{groups}, $info{length});
    return \%info;
}

async method consumer_group_info(@args) {
    my $v = await $self->xinfo(@args);
    my @info;
    for my $s ($v->@*) {
        push @info, {pairmap { ( ($a =~ tr/-/_/r), $b ) } $s->@*};
    }
    $log->tracef('Full info %s', \@info);
    return \@info;
}

=head2 cleanup

Clear up old entries from a stream when it grows too large.

=cut

async method cleanup(%args) {
    my $stream = $args{stream};
    # Check on our status - can we clean up any old queue items?
    my %info = await $self->stream_info($stream)->%*;
    return unless $info{length} > $args{limit};

    # Track how far back our active stream list goes - anything older than this is fair game
    my $oldest = await $self->oldest_processed_id($stream);
    $log->debugf('Earliest ID to care about: %s', $oldest);

    if ($oldest and $oldest ne '0-0' and compare_id($oldest, $info{first_entry}[0]) > 0) {
        # At this point we know we have some older items that can go. We'll need to finesse
        # the direction to search: for now, take the naïve but workable assumption that we
        # have an even distribution of values. This means we go forwards from the start if
        # $oldest is closer to the first_delivery_id, or backwards from the end if it's
        # nearer to the end. We can use the timestamp (first half) rather than the full ID
        # for this comparison. If we get this wrong, we'll still end up with the right
        # count - it'll just be a bit less efficient.
        # This could likely be enhanced by taking a binary search (setting count to 1), although for the common case
        # of consistent/predictable stream population, having a few points that can be used for a good derivative
        # estimate means we could apply Newton-Raphson, Runge-Kutta or similar methods to converge faster.
        my $direction = do {
            no warnings 'numeric';
            ($oldest - $info{first_entry}[0]) > ($info{last_entry}[0] - $oldest)
                ? 'xrevrange'
                : 'xrange'
        };
        my $limit = 200;
        my $endpoint = $direction eq 'xrevrange' ? '+' : '-';
        my $total = 0;
        while (1) {
            # XRANGE / XREVRANGE conveniently have switched start/end parameters, so we don't need to swap $endpoint
            # and $oldest depending on type here.
            my ($v) = await $redis->$direction($stream, $endpoint, $oldest, COUNT => $limit);
            $log->tracef('%s returns %d/%d items between %s and %s', uc($direction), 0 + @$v, $limit, $endpoint, $oldest);
            $total += 0 + @$v;
            last unless 0 + @$v >= $limit;
            # Overlapping ranges, so the next ID will be included twice
            --$total;
            $endpoint = $v->[-1][0];
        }
        $total = $info{length} - $total if $direction eq 'xrange';

        $log->tracef('Would trim to %d items', $total);
        my ($before) = await $redis->memory_usage($stream);
        # my ($trim) = await $redis->xtrim($stream, MAXLEN => '~', $total);
        my ($trim) = await $redis->xtrim($stream, MAXLEN => $total);
        my ($after) = await $redis->memory_usage($stream);
        $log->tracef('Size changed from %d to %d after trim which removed %d items', $before, $after, $trim);
    }
    else {
        $log->tracef('No point in trimming: oldest is %s and this compares to %s', $oldest, $info{first_entry}[0]);
    }
}

=head2 pending

Check for any pending items, claiming them for reprocessing as required.

Takes the following named parameters:

=over 4

=item * C<stream> - the stream name

=item * C<group> - which consumer group to check

=item * C<client> - the name of the client to check

=back

Returns a L<Ryu::Source> for the pending items in this stream.

=cut

method pending(%args) {
    my $src = $self->source;
    my $stream = $args{stream};
    my $group = $args{group};
    my $client = $args{client};
    my $instance;
    Future->wait_any(
        $src->completed->without_cancel,
        (async sub {
            my $start = '-';
            while (1) {
                await $src->unblocked;
                my ($pending) = await $self->xpending(
                    $stream,
                    $group,
                    $start, '+',
                    $self->batch_count,
                    $client,
                );
                for my $item ($pending->@*) {
                    my ($id, $consumer, $age, $delivery_count) = $item->@*;
                    $log->tracef('Claiming pending message %s from %s, age %s, %d prior deliveries', $id, $consumer, $age, $delivery_count);
                    my $claim = await $redis->xclaim($stream, $group, $client, 10, $id);
                    $log->tracef('Claim is %s', $claim);
                    my $args = $claim->[0]->[1];
                    if($args) {
                        push @$args, ("message_id", $id);
                        $src->emit($args);
                    }
                }
                last unless @$pending >= $self->batch_count;
            }
        })->(),
    )->on_fail(sub  {
        my $error = shift;
        $log->errorf("Failed while looking for pending messages due: %s", $error);
    })->retain;
    $src;
}

=head2 publish

Publish a message through a Redis channel (pub/sub system)

=over 4

=item * C<channel> - The channel name.

=item * C<message> - The message we want to publish (string).

=back

=cut

async method publish($channel, $message) {
    await $redis->publish($channel, "$message");
}


=head2 ack

Acknowledge a message from a Redis stream.

=over 4

=item * C<stream> - The stream name.

=item * C<group> - The group name.

=item * C<message_id> - The id of the message we want to acknowledge.

=back

=cut

async method ack ($stream, $group, $message_id) {
    await $redis->xack($stream, $group, $message_id);
}


=head2 create_group

Create a Redis consumer group if it does NOT exist.

It'll also send the MKSTREAM option to create the stream if it doesn't exist.

=over 4

=item * C<stream> - The name of the stream we want to attach the group to.

=item * C<group> - The group name.

=item * C<start_from> - The id of the message that is going to be considered the start of the stream for this group's point of view
by default it's `$` which means the last message.

=back

=cut


async method create_group($stream, $group, $start_from = '$') {
    try {
        await $self->xgroup('CREATE', $stream, $group, $start_from, 'MKSTREAM');
    }
    catch ($e) {
        if($e =~ /BUSYGROUP/){
            return;
        } else {
            die $e;
        }
    }
}

=head2 pending_messages_info

Return information about the pending messages for a stream and a consumer group.

This currently just execute C<XPENDING> without any filtering.

=over 4

=item * C<stream> - The name of the stream we want to check.

=item * C<group> - The consumers group name that we want to check.

=back

=cut

async method pending_messages_info($stream, $group) {
    return await $self->xpending($stream, $group);
}

async method xpending(@args) {
    await $redis->xpending(@args);
}

async method xadd (@args) {
    return await $redis->xadd(@args);
}

=head2 redis_from_pool

Returns a Redis connection either from a pool of connection or a new one.
With the possibility of waiting to get one, if all connection were busy and we maxed out our limit.

=cut

async method redis_from_pool {
    $log->tracef('Available Redis pool count: %d', 0 + $redis_pool->@*);
    if (my $available_redis = shift $redis_pool->@*) {
        $pending_redis_count++;
        return await $self->loop->new_future->done($available_redis);
    } elsif ($pending_redis_count < $max_pool_count) {
        ++$pending_redis_count;
        $self->add_child(
            my $instance = Net::Async::Redis->new(uri => $redis_uri),
        );
        await $instance->connected;
        return await $self->loop->new_future->done($instance);
    }
    push @$waiting_redis_pool, my $f = $self->loop->new_future;
    $log->warnf('All Redis instances are pending, added to waiting list. Current Redis count: %d/%d | Waiting count: %d', $pending_redis_count, $max_pool_count, 0 + $waiting_redis_pool->@*);
    return await $f;

}

=head2 return_redis_to_pool

This puts back a redis connection into Redis pool, so it can be used by other called.
It should be called at the end of every usage, as on_ready.

It should also be possible with a try/finally combination..
but that's currently failing with the $redis_pool slot not being defined.

=over 4

=item * C<$instance> - Redis connection, to be returned.

=back

=cut

method return_redis_to_pool ($instance) {
    if( my $waiting_redis = shift $waiting_redis_pool->@*) {
        $waiting_redis->done($instance)
    } else {
        push $redis_pool->@*, $instance;
        $log->tracef('Returning instance to pool, Redis used/available now %d/%d', $pending_redis_count, 0 + $redis_pool->@*);
        $pending_redis_count--;
    }
}

async method xreadgroup (@args) {
    my $instance = await $self->redis_from_pool;
    my ($batch) =  await $instance->xreadgroup(@args)->on_ready(sub {
        $self->return_redis_to_pool($instance);
    });
        my %info = pairmap {
            (
                ($a =~ tr/-/_/r),
                $b
            )
        } @$batch;
        return (\%info);
}

async method xgroup (@args) {
    return await $redis->xgroup(@args);
}

1;

=head1 AUTHOR

Deriv Group Services Ltd. C<< DERIV@cpan.org >>

=head1 LICENSE

Copyright Deriv Group Services Ltd 2020. Licensed under the same terms as Perl itself.

