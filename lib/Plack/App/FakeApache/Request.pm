package Plack::App::FakeApache::Request;

use Moose;

use APR::Pool;
use APR::Table;

use HTTP::Status qw(:is);

use Plack::Request;
use Plack::Response;
use Plack::App::File;

use Plack::App::FakeApache::Request::Connection;
use Cwd qw(cwd);

my $NS = "plack.app.fakeapache";

# Plack related attributes:
has env => (
    is       => 'ro',
    isa      => 'HashRef[Any]',
    required => 1,
);

has plack_request => (
    is         => 'ro',
    isa        => 'Plack::Request',
    lazy_build => 1,
    handles    => {
        method       => 'method',
        unparsed_uri => 'request_uri',
        uri          => 'path',
        user         => 'user',
    },
);

has plack_response => (
    is         => 'ro',
    isa        => 'Plack::Response',
    lazy_build => 1,
    handles    => {
        set_content_length => 'content_length',
        content_type     => 'content_type',
        content_encoding => 'content_encoding',
        status           => 'status',
    },
);

# Apache related attributes
has _apr_pool => (
    is         => 'ro',
    isa        => 'APR::Pool',
    lazy_build => 1,
);

has headers_in => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has headers_out => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has err_headers_out => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has _subprocess_env => (
    is         => 'ro',
    isa        => 'APR::Table',
    lazy_build => 1,
);

has dir_config => (
    isa     => 'HashRef[Any]',
    traits  => ['Hash'],
    default => sub { {} },
    handles => {
        dir_config => 'accessor'
    }
);

has location => (
    is      => 'rw',
    isa     => "Str",
    default => '/',
);

has filename => (
    is         => 'rw',
    isa        => 'Str|Undef',
    lazy_build => 1,
);

has root => (
    is         => 'rw',
    isa        => 'Str',
    default    => cwd(),
);

has _notes => (
    is  => 'rw',
    isa => 'APR::Table',
    lazy_build => 1,
);

# builders
sub _build_plack_request  { return Plack::Request->new( shift->env ) }
sub _build_plack_response { return Plack::Response->new( 200, {}, [] ) }
sub _build__apr_pool      { return APR::Pool->new() }
sub _build_headers_out    { return APR::Table::make( shift->_apr_pool, 64 ) }
sub _build_err_headers_out{ return APR::Table::make( shift->_apr_pool, 64 ) }
sub _build__notes         { return APR::Table::make( shift->_apr_pool, 64 ) }

sub _build__subprocess_env { 
    my $self  = shift;
    my $env   = $self->env;
    my $table = APR::Table::make( $self->_apr_pool, 64 );

    $table->add( $_ => $env->{$_} ) for grep { /^[_A-Z]+$/ } keys %$env;

    return $table;
}

sub _build_headers_in { 
    my $self  = shift;
    my $table = APR::Table::make( $self->_apr_pool, 64 );

    $self->plack_request->headers->scan( sub {
        $table->add( @_ );
    } );

   return $table;
}

sub _build_filename {
    my $self = shift;

    # did something set us a filename?
    my $file = $self->env->{'plack.app.fakeapache.request.filename'};
    return $file if defined $file;

    # work out what the file should be ourselves
    my $paf = Plack::App::File->new(
        root => $self->root
    );
    ($file) = $paf->locate_file( $self->env );

    return undef if ref $file;  # some sort of error
    return $file;
}

# Plack methods
sub finalize { 
    my $self     = shift;
    my $response = $self->plack_response;

    $self->headers_out->do( sub { $response->header( @_ ); 1 } ) if is_success( $self->status() );
    $self->err_headers_out->do( sub { $response->header( @_ ); 1 } );

    return $response->finalize;
};

# Apache methods

sub args {
    my $self = shift;
    if (@_) {
        $self->plack_request->env->{QUERY_STRING} = shift;
    }
    return $self->plack_request->env->{QUERY_STRING};
}

sub log_reason { 1 } # TODO
sub hostname {
    my $self = shift;

    return $self->env->{HTTP_HOST};
}

sub subprocess_env {
    my $self = shift;

    if (@_ == 1) {
        return $self->_subporcess_env->get( @_ );
    }

    if (@_ == 2) {
        return $self->_subprocess_env->set( @_ );
    }

    if (defined wantarray) {
        return $self->_subprocess_env;
    }

    $self->_subprocess_env->do( sub { $ENV{ $_[0] } = $_[1]; 1 } );
    return;
}

sub document_root {
    my $self = shift;
    return $self->root;
}

sub pnotes {
    my $self = shift;
    my $key  = shift;
    my $old = $self->env->{$NS.'.pnotes'}->{$key};

    if (@_) {
        $self->env->{$NS.'.pnotes'}->{$key} = shift;
    }

    return $old;
}

sub notes {
    my $self = shift;
    $self->_notes(shift) if @_;
    return $self->_notes;
}

# this is strictly mocking Apache::Connection, and only partially
sub connection {
    my $self = shift;

    return Plack::App::FakeApache::Request::Connection->new(
        remote_ip => $self->plack_request->address,
    );
}

sub read {
    my $self = shift;
    my ($buffer, $length, $offset) = @_; # ... but use $_[0] for buffer

    my $request = $self->plack_request;

    # Is this needed? Intrudes on a Plack::Request private methodf...
    unless ($request->env->{'psgix.input.buffered'}) {
        $request->_parse_request_body;

        # Sets psgix.input.buffered and rewinds.
    }

    my $fh = $request->input
        or return 0;

    return $fh->read($_[0], $length, $offset);
}

sub print {
    my $self = shift;

    my $length = 0;
    for (@_) {
        $self->_add_content($_);
        $length += length;
    }

    return $length;
}

sub write {
    my ($self, $buffer, $length, $offset) = @_;

    if (defined $length && $length == -1) {
        $self->_add_content($buffer);
        return length $buffer;
    }

    my $output = substr $buffer, $offset // 0, $length // length $buffer;

    $self->_add_content($output);
    
    return length $output;
}

sub _add_content {
    my $self = shift;

    push @{ $self->plack_response->body }, @_;
}

sub rflush {
    1;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
