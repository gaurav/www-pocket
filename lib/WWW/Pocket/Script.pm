package WWW::Pocket::Script;
use Moose;

use Getopt::Long 'GetOptionsFromArray';
use JSON::PP;
use List::Util 'sum';
use Path::Class;
use URI;
use Pod::Usage;

use WWW::Pocket;

has consumer_key => (
    is        => 'ro',
    isa       => 'Str',
    lazy      => 1,
    default   => sub { die "consumer_key is required to authenticate" },
    predicate => '_has_consumer_key',
);

has redirect_uri => (
    is      => 'ro',
    isa     => 'Str',
    default => 'https://getpocket.com/',
);

has credentials_file => (
    is      => 'ro',
    isa     => 'Str',
    default => "$ENV{HOME}/.pocket",
);

has pocket => (
    is      => 'ro',
    isa     => 'WWW::Pocket',
    lazy    => 1,
    default => sub {
        my $self = shift;

        my $credentials_file = file($self->credentials_file);
        if (-e $credentials_file) {
            return $self->_apply_credentials($credentials_file);
        }
        else {
            return $self->_authenticate;
        }
    },
);

sub run {
    my $self = shift;
    my @argv = @_;

    my $method = shift @argv;
    if ($self->_method_is_command($method)) {
        return $self->$method(@argv);
    }
    else {
        pod2usage(-verbose => 2);
    }
}

sub _method_is_command {
    my $self = shift;
    my ($name) = @_;

    return unless $name;
    return if $name eq 'run' || $name eq 'meta';
    return if $name =~ /^_/;
    my $method = $self->meta->find_method_by_name($name);
    return unless $method;
    return if $method->isa('Class::MOP::Method::Accessor');

    return 1;
}

# Display quick usage help on this script.
sub help {
    my $self = shift;
    pod2usage(-verbose => 1);
}

# Display comprehensive help about this script.
sub man {
    my $self = shift;
    pod2usage(-verbose => 2);
}



sub authenticate {
    my $self = shift;
    $self->pocket;
}

sub _apply_credentials {
    my $self = shift;
    my ($file) = @_;

    my ($consumer_key, $access_token, $username) = $file->slurp(chomp => 1);
    return WWW::Pocket->new(
        consumer_key => $consumer_key,
        access_token => $access_token,
        username     => $username,
    );
}

sub _authenticate {
    my $self = shift;

    my $consumer_key = $self->_has_consumer_key
        ? $self->consumer_key
        : $self->_prompt_for_consumer_key;

    my $pocket = WWW::Pocket->new(consumer_key => $consumer_key);

    my $redirect_uri = $self->redirect_uri;
    my ($url, $code) = $pocket->start_authentication($redirect_uri);

    print "Visit $url and log in. When you're done, press enter to continue.\n";
    <STDIN>;

    $pocket->finish_authentication($code);

    my $fh = file($self->credentials_file)->openw;
    $fh->write($pocket->consumer_key . "\n");
    $fh->write($pocket->access_token . "\n");
    $fh->write($pocket->username . "\n");
    $fh->close;

    return $pocket;
}

sub _prompt_for_consumer_key {
    my $self = shift;

    print "Consumer key required. You can sign up for a consumer key as a\n" .
        "Pocket developer at https://getpocket.com/developer/apps/new.\n";

    print "Enter your consumer key: ";
    my $key = <STDIN>;

    # Trim start and end.
    $key =~ s/^\s*(.*)\s*$/$1/;
    # print "Key entered: '$key'\n";

    return $key;
}

sub list {
    my $self = shift;
    my @argv = @_;

    my ($params) = $self->_parse_retrieve_options(@argv);
    my %params = (
        $self->_default_search_params,
        %$params,
    );

    print "$_\n" for $self->_retrieve_urls(%params);
}

sub words {
    my $self = shift;
    my @argv = @_;

    my ($params) = $self->_parse_retrieve_options(@argv);
    my %params = (
        $self->_default_search_params,
        %$params,
    );

    my $word_count = sum($self->_retrieve_field('word_count', %params)) || 0;
    print "$word_count\n";
}

sub search {
    my $self = shift;
    my @argv = @_;

    my ($params, $extra_argv) = $self->_parse_retrieve_options(@argv);
    my ($search) = @$extra_argv;
    my %params = (
        $self->_default_search_params,
        %$params,
        search => $search,
    );

    print "$_\n" for $self->_retrieve_urls(%params);
}

sub favorites {
    my $self = shift;
    my @argv = @_;

    my ($params) = $self->_parse_retrieve_options(@argv);
    my %params = (
        $self->_default_search_params,
        state => 'all',
        %$params,
        favorite => 1,
    );

    print "$_\n" for $self->_retrieve_urls(%params);
}

# Download a local copy of all the URLs on Pocket.
sub local {
    my $self = shift;
    my @argv = @_;

    # Local path provided?
    my $output_path = shift @argv;
    unless (-d $output_path and -w $output_path) {
        print STDERR "Could not write to '$output_path', not a writeable directory.\n";
        $output_path = undef;
    }
    print STDERR "Writing output to '$output_path'.\n" if $output_path;

    my ($params) = $self->_parse_retrieve_options(@argv);
    my %params = (
        $self->_default_search_params,
        # detailType => 'complete', -- only if you need tags!
        %$params,
    );

    my %item_counts;
    foreach my $item ($self->_retrieve_data(%params)) {
        my $item_id = $item->{'item_id'};

        # For each item, figure out which folders it should go into.
        my @subfolders = ('all');

        # Status: 'list', 'archive', 'to_be_deleted'
        push @subfolders, {
            '0' => 'list',
            '1' => 'archived',
            '2' => 'to_be_deleted'
        }->{$item->{'status'}};

        if($item->{'time_read'} eq '0') {
            push @subfolders, 'unread';
        } else {
            push @subfolders, 'read';
        }

        # Video: 'has_video', 'is_video'
        if($item->{'has_video'} eq '1') {
            push @subfolders, 'has_video';
        } elsif($item->{'has_video'} eq '2') {
            push @subfolders, 'is_video';
        }

        # Group by size.
        my $word_count = $item->{'word_count'};
        if($word_count < 500) {
            push @subfolders, 'tiny';
        } elsif($word_count < 2000) {
            push @subfolders, 'small';
        } elsif($word_count < 5000) {
            push @subfolders, 'short';
        } elsif($word_count < 10_000) {
            push @subfolders, 'normal';
        } elsif($word_count < 15_000) {
            push @subfolders, 'large';    
        } else {
            push @subfolders, 'huge';
        }

        # Sort by date.
        my $time_added = $item->{'time_added'};
        my $time_path = 'by_date';
        {
            my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($time_added);
            $year += 1900;
            my @months = qw(january february march april may june july august september october november december);
            my $month = $months[$mon];
            $time_path .= "/$year/$month";

            # We need to make the folder here, because mkdir isn't recursive.
            mkdir "$output_path/by_date" unless -d "$output_path/by_date";
            mkdir "$output_path/by_date/$year" unless -d "$output_path/by_date/$year";
        }
        push @subfolders, $time_path;

        foreach my $subfolder (@subfolders) {
            $item_counts{$subfolder} = 0 if not exists $item_counts{$subfolder};
            $item_counts{$subfolder}++;

            if ($output_path) {
                my $title = $item->{'resolved_title'};
                $title =~ s/[^a-zA-Z]/_/g;
                $title =~ s/^\_*(.*)\_*$/$1/;
                # Truncate to 231 characters (leaving 17 letters for the item ID + 3 letters for ' - ' + 4 letters for '.url')
                $title = substr($title, 0, 231);

                unless (-d "$output_path/$subfolder") {
                    mkdir("$output_path/$subfolder") or die "Could not create '$output_path/$subfolder': $!";
                }
                open(my $fh, ">:utf8", "$output_path/$subfolder/$item_id - $title.url") 
                    or die "Could not open '$output_path/$subfolder/$item_id - $title.url': $!";
                print $fh "[InternetShortcut]\nURL=http://getpocket.com/a/read/$item_id\n";
                close($fh);
            }
        }

        print "https://getpocket.com/a/read/$item_id to be saved to folders: " . join(', ', @subfolders) . "\n"
            unless $output_path;
    }
    # print "https://getpocket.com/a/read/$_\n" for $self->_retrieve_field('item_id', %params);

    print "\nNumber of items in each category:\n";
    foreach my $category (sort { $item_counts{$b} <=> $item_counts{$a} } keys %item_counts) {
        print sprintf " - %s: %d (%.2f%%)\n", (
            $category,
            $item_counts{$category},
            $item_counts{$category}/$item_counts{'all'} * 100
        );
    }
    print "\n";
}

sub retrieve_raw {
    my $self = shift;
    my @argv = @_;

    my ($state, $favorite, $tag, $contentType, $sort, $detailType);
    my ($search, $domain, $since, $count, $offset);
    GetOptionsFromArray(
        \@argv,
        "state=s"       => \$state,
        "favorite!"     => sub { $favorite = $_[1] ? '1' : '0' },
        "tag=s"         => \$tag,
        "contentType=s" => \$contentType,
        "sort=s"        => \$sort,
        "detailType=s"  => \$detailType,
        "search=s"      => \$search,
        "domain=s"      => \$domain,
        "since=i"       => \$since,
        "count=i"       => \$count,
        "offset=i"      => \$offset,
    ) or die "???";

    my %params = (
        (defined($state)       ? (state       => $state)       : ()),
        (defined($favorite)    ? (favorite    => $favorite)    : ()),
        (defined($tag)         ? (tag         => $tag)         : ()),
        (defined($contentType) ? (contentType => $contentType) : ()),
        (defined($sort)        ? (sort        => $sort)        : ()),
        (defined($detailType)  ? (detailType  => $detailType)  : ()),
        (defined($search)      ? (search      => $search)      : ()),
        (defined($domain)      ? (domain      => $domain)      : ()),
        (defined($since)       ? (since       => $since)       : ()),
        (defined($count)       ? (count       => $count)       : ()),
        (defined($offset)      ? (offset      => $offset)      : ()),
    );

    $self->_pretty_print($self->pocket->retrieve(%params));
}

sub _parse_retrieve_options {
    my $self = shift;
    my @argv = @_;

    my ($unread, $archive, $all, @tags);
    GetOptionsFromArray(
        \@argv,
        "unread"  => \$unread,
        "archive" => \$archive,
        "all"     => \$all,
        "tag=s"   => \@tags,
    ) or die "???";

    return (
        {
            ($unread  ? (state => 'unread')         : ()),
            ($archive ? (state => 'archive')        : ()),
            ($all     ? (state => 'all')            : ()),
            (@tags    ? (tag   => join(',', @tags)) : ()),
        },
        [ @argv ],
    );
}

sub _default_search_params {
    my $self = shift;

    return (
        sort       => 'oldest',
        detailType => 'simple',
    );
}

sub _retrieve_urls {
    my $self = shift;
    my %params = @_;

    $self->_retrieve_field('resolved_url', %params);
}

sub _retrieve_field {
    my $self = shift;
    my ($field, %params) = @_;

    my $response = $self->pocket->retrieve(%params);
    my $list = $response->{list};
    return unless ref($list) && ref($list) eq 'HASH';

    return map {
        $_->{$field}
    } sort {
        $a->{sort_id} <=> $b->{sort_id}
    } values %$list;
}

# Retrieve all the data (identical to _retrieve_field, but without the mapping).
sub _retrieve_data {
    my $self = shift;
    my (%params) = @_;

    my $response = $self->pocket->retrieve(%params);
    my $list = $response->{list};
    return unless ref($list) && ref($list) eq 'HASH';

    return values %$list;
}



sub _pretty_print {
    my $self = shift;
    my ($data) = @_;

    print JSON::PP->new->utf8->pretty->canonical->encode($data), "\n";
}

sub add {
    my $self = shift;
    my ($url, $title) = @_;

    $self->pocket->add(
        url   => $url,
        title => $title,
    );
    print "Page Saved!\n";
}

sub archive {
    my $self = shift;
    my ($url) = @_;

    $self->_modify('archive', $url);
    print "Page archived!\n";
}

sub readd {
    my $self = shift;
    my ($url) = @_;

    $self->_modify('readd', $url);
    print "Page added!\n";
}

sub favorite {
    my $self = shift;
    my ($url) = @_;

    $self->_modify('favorite', $url);
    print "Page favorited!\n";
}

sub unfavorite {
    my $self = shift;
    my ($url) = @_;

    $self->_modify('unfavorite', $url);
    print "Page unfavorited!\n";
}

sub delete {
    my $self = shift;
    my ($url) = @_;

    $self->_modify('delete', $url);
    print "Page deleted!\n";
}

sub _modify {
    my $self = shift;
    my ($action, $url) = @_;

    $self->pocket->modify(
        actions => [
            {
                action  => $action,
                item_id => $self->_get_id_for_url($url),
            },
        ],
    );
}

sub _get_id_for_url {
    my $self = shift;
    my ($url) = @_;

    my $response = $self->pocket->retrieve(
        domain => URI->new($url)->host,
        state  => 'all',
    );
    my $list = $response->{list};
    return unless ref($list) && ref($list) eq 'HASH';

    for my $item (values %$list) {
        return $item->{item_id}
            if $item->{resolved_url} eq $url
            || $item->{given_url} eq $url;
    }

    return;
}

__PACKAGE__->meta->make_immutable;
no Moose;

=begin Pod::Coverage

  add
  archive
  authenticate
  delete
  favorite
  favorites
  list
  readd
  retrieve_raw
  run
  search
  unfavorite
  words

=end Pod::Coverage

=cut

1;
