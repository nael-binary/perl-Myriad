package Coffee::Manager::Coffee;

use Myriad::Service;

use JSON::MaybeUTF8 qw(:v1);
use Time::Moment;

has $fields;

BUILD (%args) {
    $fields = {
        user => {
            mandatory => 1,
            entity    => 1,
        },
        machine => {
            mandatory => 1,
            entity    => 1,
        },
        timestamp => {
            isa => 'Time::Moment', # some type casting can be implemented
        },
    };
}

async method startup () {

}

async method buy : RPC (%args) {
    $log->warnf('GOT Request: %s', \%args);

    my $storage = $api->storage;
    if ( $args{type} eq 'PUT' or $args{type} eq 'POST' or $args{type} eq 'GET' ) {
        # Parse arguments and parameters and accept them in various ways.
        my %input;

        my @param = $args{params}->%*;
        @input{qw(user machine)} = @param;

        try {
            $input{timestamp} = Time::Moment->from_string($args{body}->{timestamp}) if exists $args{body}->{timestamp};
        } catch ($e) {
            return {error => {text => 'Invalid timestamp format', code => 400 } };
        }
        # set timestamp if not supplied.
        $input{timestamp} = Time::Moment->now unless exists $input{timestamp};

        return {error => {text => 'Missing Argument. Must supply user, machine', code => 400 } }
            if grep { ! exists $input{$_} } keys $fields->%*;

        # Get entities details:
        # should be converted to fmap instead of for
        for my $entity (grep { exists $fields->{$_}{entity}} keys $fields->%*) {
            my $service_storage = $api->service_by_name(join('.', 'coffee.manager', $entity))->storage;
            my $raw_d = await $service_storage->hash_get($entity, $input{$entity});
            my $data = decode_json_utf8($raw_d);
            # Only if found
            delete $data->{id};
            if ( grep { defined } values %$data ) {
                $input{$entity.'_'.$_} = $data->{$_} for keys %$data;
                # since we have it all added
                $input{$entity.'_id'} = delete $input{$entity};
            } else {
                return {error => {text => 'Invalid User or Machine does not exist', code => 400 } };
            }
        }
        $input{timestamp} = $input{timestamp}->epoch;
        $log->debugf('ARGS: %s', \%input);

        my $id = await $storage->get('id');
        $id++;
        await $storage->set('id', $id);
        await $storage->hash_set('coffee', $id, encode_json_utf8(\%input));
        return {id => $id};


    }

}
1;