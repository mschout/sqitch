#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use Test::MockModule;
use Path::Class;
use Try::Tiny;
use Test::Exception;
use DBI;
use Locale::TextDomain qw(App-Sqitch);

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::sqlite';
    require_ok $CLASS or die;
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.conf';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.conf';
}

is_deeply [$CLASS->config_vars], [
    client    => 'any',
    db_name   => 'any',
    sqitch_db => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new;
isa_ok my $sqlite = $CLASS->new(sqitch => $sqitch, db_name => file 'foo'), $CLASS;

is $sqlite->client, 'sqlite3' . ($^O eq 'MSWin32' ? '.exe' : ''),
    'client should default to sqlite3';
is $sqlite->db_name, 'foo', 'db_name should be required';
is $sqlite->destination, $sqlite->db_name->stringify,
    'Destination should be db_name strintified';
is $sqlite->sqitch_db, file('foo')->dir->file('sqitch.db'),
    'sqitch_db should default to "sqitch.db" in the same diretory as db_name';

my @std_opts = (
    '-noheader',
    '-bail',
    '-csv',
);

is_deeply [$sqlite->sqlite3], [$sqlite->client, @std_opts, $sqlite->db_name],
    'sqlite3 command should have the proper opts';

##############################################################################
# Make sure we get an error for no database name.
isa_ok $sqlite = $CLASS->new(sqitch => $sqitch), $CLASS;
throws_ok { $sqlite->_dbh } 'App::Sqitch::X', 'Should get an error for no db name';
is $@->ident, 'sqlite', 'Missing db name error ident should be "sqlite"';
is $@->message, __ 'No database specified; use --db-name set "ore.sqlite.db_name" via sqitch config',
    'Missing db name error message should be correct';

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.sqlite.client'    => '/path/to/sqlite3',
    'core.sqlite.db_name'   => '/path/to/sqlite.db',
    'core.sqlite.sqitch_db' => 'meta.db',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create another sqlite';
is $sqlite->client, '/path/to/sqlite3',
    'client should fall back on config';
is $sqlite->db_name, '/path/to/sqlite.db',
    'db_name should fall back on config';
is $sqlite->destination, $sqlite->db_name->stringify,
    'Destination should be configured db_name strintified';
is $sqlite->sqitch_db, file('meta.db'),
    'sqitch_db should fall back on config';
is_deeply [$sqlite->sqlite3], [$sqlite->client, @std_opts, $sqlite->db_name],
    'sqlite3 command should have config values';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(db_client => 'foo/bar', db_name => 'my.db');
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create sqlite with sqitch with --client and --db-name';
is $sqlite->client, 'foo/bar', 'The client should be grabbed from sqitch';
is $sqlite->db_name, 'my.db', 'The db_name should be grabbed from sqitch';
is $sqlite->destination, $sqlite->db_name->stringify,
    'Destination should be optioned db_name strintified';
is_deeply [$sqlite->sqlite3], [$sqlite->client, @std_opts, $sqlite->db_name],
    'sqlite3 command should have option values';

##############################################################################
# Test _run(), _capture(), and _spool().
my $tmp_dir = Path::Class::tempdir( CLEANUP => 1 );
my $db_name = $tmp_dir->file('sqitch.db');
ok $sqlite = $CLASS->new(sqitch => $sqitch, db_name => $db_name),
    'Instantiate with a temporary database file';

can_ok $sqlite, qw(_run _capture _spool);

my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, @capture, @spool);
$mock_sqitch->mock(run     => sub { shift; @run = @_ });
$mock_sqitch->mock(capture => sub { shift; @capture = @_ });
$mock_sqitch->mock(spool   => sub { shift; @spool = @_ });

ok $sqlite->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$sqlite->sqlite3, qw(foo bar baz)],
    'Command should be passed to run()';

ok $sqlite->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $sqlite->sqlite3],
    'Command should be passed to spool()';

ok $sqlite->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$sqlite->sqlite3, qw(foo bar baz)],
    'Command should be passed to capture()';

# Test file and handle running.
ok $sqlite->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$sqlite->sqlite3, ".read 'foo/bar.sql'"],
    'File should be passed to run()';

ok $sqlite->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $sqlite->sqlite3],
    'Handle should be passed to spool()';

QUOTE: {
    try {
        require DBD::SQLite;
    } catch {
        skip 'DBD::SQLite not installed', 2;
    };

    # Verify should go to capture unless verosity is > 1.
    ok $sqlite->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
    is_deeply \@capture, [$sqlite->sqlite3, ".read 'foo/bar.sql'"],
        'Verify file should be passed to capture()';

    $mock_sqitch->mock(verbosity => 2);
    ok $sqlite->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
    is_deeply \@run, [$sqlite->sqlite3, ".read 'foo/bar.sql'"],
        'Verifile file should be passed to run() for high verbosity';
}

$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
can_ok $CLASS, '_ts2char';
is $CLASS->_ts2char('foo'),
    q{strftime('year:%Y:month:%m:day:%d:hour:%H:minute:%M:second:%S:time_zone:UTC', foo)},
    '_ts2char should work';

ok my $dtfunc = $CLASS->can('_dt'), "$CLASS->can('_dt')";
isa_ok my $dt = $dtfunc->(
    'year:2012:month:07:day:05:hour:15:minute:07:second:01:time_zone:UTC'
), 'App::Sqitch::DateTime', 'Return value of _dt()';
is $dt->year, 2012, 'DateTime year should be set';
is $dt->month,   7, 'DateTime month should be set';
is $dt->day,     5, 'DateTime day should be set';
is $dt->hour,   15, 'DateTime hour should be set';
is $dt->minute,  7, 'DateTime minute should be set';
is $dt->second,  1, 'DateTime second should be set';
is $dt->time_zone->name, 'UTC', 'DateTime TZ should be set';

##############################################################################
# Can we do live tests?
can_ok $CLASS, qw(
    initialized
    initialize
    run_file
    run_handle
    log_deploy_change
    log_fail_change
    log_revert_change
    earliest_change_id
    latest_change_id
    is_deployed_tag
    is_deployed_change
    change_id_for
    change_id_for_depend
    name_for_change_id
    change_offset_from_id
    load_change
);

subtest 'live database' => sub {
    my @sqitch_params = (
        top_dir     => Path::Class::dir(qw(t pg)),
        plan_file   => Path::Class::file(qw(t pg sqitch.plan)),
    );
    my $user1_name = 'Marge Simpson';
    my $user1_email = 'marge@example.com';
    $sqitch = App::Sqitch->new(
        @sqitch_params,
        user_name  => $user1_name,
        user_email => $user1_email,
    );
    $sqlite = $CLASS->new(sqitch => $sqitch, db_name => $db_name);
    try {
        $sqlite->_dbh;
    } catch {
        plan skip_all => "Unable to connect to a database for testing: "
            . eval { $_->message } || $_;
    };

    isa_ok $sqlite, $CLASS, 'The live DB engine';

    ok !$sqlite->initialized, 'Database should not yet be initialized';
    ok $sqlite->initialize, 'Initialize the database';
    ok $sqlite->initialized, 'Database should now be initialized';

    # Try it with a different Sqitch DB.
    ok $sqlite = $CLASS->new(
        sqitch    => $sqitch,
        db_name   => $db_name,
        sqitch_db => $db_name->dir->file('sqitchtest.db')
    ), 'Create a sqlite with sqitchtest.db sqitch_db';

    is $sqlite->earliest_change_id, undef, 'No init, earliest change';
    is $sqlite->latest_change_id, undef, 'No init, no latest change';

    ok !$sqlite->initialized, 'Database should no longer seem initialized';
    ok $sqlite->initialize, 'Initialize the database again';
    ok $sqlite->initialized, 'Database should be initialized again';

    is $sqlite->earliest_change_id, undef, 'Still no earlist change';
    is $sqlite->latest_change_id, undef, 'Still no latest changes';

    # Make sure a second attempt to initialize dies.
    throws_ok { $sqlite->initialize } 'App::Sqitch::X',
        'Should die on existing schema';
    is $@->ident, 'sqlite', 'Mode should be "sqlite"';
    is $@->message, __x(
        'Sqitch database {database} already initialized',
        database => $sqlite->sqitch_db,
    ), 'And it should show the proper schema in the error message';

    throws_ok { $sqlite->_dbh->do('INSERT blah INTO __bar_____') } 'App::Sqitch::X',
        'Database error should be converted to Sqitch exception';
    is $@->ident, $DBI::state, 'Ident should be SQL error state';
    is $@->message, 'near "blah": syntax error', 'The message should be the SQLite error';
    like $@->previous_exception, qr/\QDBD::SQLite::db do failed: /,
        'The DBI error should be in preview_exception';

    is $sqlite->current_state, undef, 'Current state should be undef';
    is_deeply all( $sqlite->current_changes ), [], 'Should have no current changes';
    is_deeply all( $sqlite->current_tags ), [], 'Should have no current tags';
    is_deeply all( $sqlite->search_events ), [], 'Should have no events';

    ##############################################################################
    # Test register_project().
    can_ok $sqlite, 'register_project';
    can_ok $sqlite, 'registered_projects';

    is_deeply [ $sqlite->registered_projects ], [],
        'Should have no registered projects';

    ok $sqlite->register_project, 'Register the project';
    is_deeply [ $sqlite->registered_projects ], ['pg'],
        'Should have one registered project, "sql"';
    is_deeply $sqlite->_dbh->selectall_arrayref(
        'SELECT project, uri, creator_name, creator_email FROM projects'
    ), [['pg', undef, $sqitch->user_name, $sqitch->user_email]],
        'The project should be registered';

    # Try to register it again.
    ok $sqlite->register_project, 'Register the project again';
    is_deeply [ $sqlite->registered_projects ], ['pg'],
        'Should still have one registered project, "sql"';
    is_deeply $sqlite->_dbh->selectall_arrayref(
        'SELECT project, uri, creator_name, creator_email FROM projects'
    ), [['pg', undef, $sqitch->user_name, $sqitch->user_email]],
        'The project should still be registered only once';

    # Register a different project name.
    MOCKPROJECT: {
        my $plan_mocker = Test::MockModule->new(ref $sqitch->plan );
        $plan_mocker->mock(project => 'groovy');
        $plan_mocker->mock(uri     => 'http://example.com/');
        ok $sqlite->register_project, 'Register a second project';
    }

    is_deeply [ $sqlite->registered_projects ], ['groovy', 'pg'],
        'Should have both registered projects';
    is_deeply $sqlite->_dbh->selectall_arrayref(
        'SELECT project, uri, creator_name, creator_email FROM projects ORDER BY created_at'
    ), [
        ['pg', undef, $sqitch->user_name, $sqitch->user_email],
        ['groovy', 'http://example.com/', $sqitch->user_name, $sqitch->user_email],
    ], 'Both projects should now be registered';

    # Try to register with a different URI.
    MOCKURI: {
        my $plan_mocker = Test::MockModule->new(ref $sqitch->plan );
        my $plan_proj = 'pg';
        my $plan_uri = 'http://example.net/';
        $plan_mocker->mock(project => sub { $plan_proj });
        $plan_mocker->mock(uri => sub { $plan_uri });
        throws_ok { $sqlite->register_project } 'App::Sqitch::X',
            'Should get an error for defined URI vs NULL registered URI';
        is $@->ident, 'engine', 'Defined URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" with URI {uri}: already exists with NULL URI',
            project => 'pg',
            uri     => $plan_uri,
        ), 'Defined URI error message should be correct';

        # Try it when the registered URI is NULL.
        $plan_proj = 'groovy';
        throws_ok { $sqlite->register_project } 'App::Sqitch::X',
            'Should get an error for different URIs';
        is $@->ident, 'engine', 'Different URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" with URI {uri}: already exists with URI {reg_uri}',
            project => 'groovy',
            uri     => $plan_uri,
            reg_uri => 'http://example.com/',
        ), 'Different URI error message should be correct';

        # Try with a NULL project URI.
        $plan_uri  = undef;
        throws_ok { $sqlite->register_project } 'App::Sqitch::X',
            'Should get an error for NULL plan URI';
        is $@->ident, 'engine', 'NULL plan URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" without URI: already exists with URI {uri}',
            project => 'groovy',
            uri     => 'http://example.com/',
        ), 'NULL plan uri error message should be correct';

        # It should succeed when the name and URI are the same.
        $plan_uri = 'http://example.com/';
        ok $sqlite->register_project, 'Register "groovy" again';
        is_deeply [ $sqlite->registered_projects ], ['groovy', 'pg'],
            'Should still have two registered projects';
        is_deeply $sqlite->_dbh->selectall_arrayref(
            'SELECT project, uri, creator_name, creator_email FROM projects ORDER BY created_at'
        ), [
            ['pg', undef, $sqitch->user_name, $sqitch->user_email],
            ['groovy', 'http://example.com/', $sqitch->user_name, $sqitch->user_email],
        ], 'Both projects should still be registered';

        # Now try the same URI but a different name.
        $plan_proj = 'bob';
        throws_ok { $sqlite->register_project } 'App::Sqitch::X',
            'Should get error for an project with the URI';
        is $@->ident, 'engine', 'Existing URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" with URI {uri}: project "{reg_prog}" already using that URI',
            project => $plan_proj,
            uri     => $plan_uri,
            reg_proj => 'groovy',
        ), 'Exising URI error message should be correct';
    }

    ##########################################################################
    # Test log_deploy_change().

    # Will use this fo fake clock ticks.
    my $set_event_timestamp = sub {
        my $ts = shift;
        $sqlite->_dbh->do($_, undef, $ts) for (
            'UPDATE events  SET committed_at = ? WHERE committed_at = CURRENT_TIMESTAMP',
            'UPDATE changes SET committed_at = ? WHERE committed_at = CURRENT_TIMESTAMP',
            'UPDATE tags    SET committed_at = ? WHERE committed_at = CURRENT_TIMESTAMP',
        );
    };

    my $plan = $sqitch->plan;
    my $change = $plan->change_at(0);
    my ($tag) = $change->tags;
    is $change->name, 'users', 'Should have "users" change';
    ok !$sqlite->is_deployed_change($change), 'The change should not be deployed';
    is_deeply [$sqlite->are_deployed_changes($change)], [],
        'The change should not be deployed';
    ok $sqlite->log_deploy_change($change), 'Deploy "users" change';
    $set_event_timestamp->('2013-03-30 00:44:47');
    ok $sqlite->is_deployed_change($change), 'The change should now be deployed';
    is_deeply [$sqlite->are_deployed_changes($change)], [$change->id],
        'The change should now be deployed';

    is $sqlite->earliest_change_id, $change->id, 'Should get users ID for earliest change ID';
    is $sqlite->earliest_change_id(1), undef, 'Should get no change offset 1 from earliest';
    is $sqlite->latest_change_id, $change->id, 'Should get users ID for latest change ID';
    is $sqlite->latest_change_id(1), undef, 'Should get no change offset 1 from latest';

    is_deeply all_changes(), [[
        $change->id, 'users', 'pg', '', $sqitch->user_name, $sqitch->user_email,
        $change->planner_name, $change->planner_email,
    ]],'A record should have been inserted into the changes table';
    is_deeply get_dependencies($change->id), [], 'Should have no dependencies';
    is_deeply [ $sqlite->changes_requiring_change($change) ], [],
        'Change should not be required';


    my @event_data = ([
        'deploy',
        $change->id,
        'users',
        'pg',
        '',
        $sqlite->_log_requires_param($change),
        $sqlite->_log_conflicts_param($change),
        $sqlite->_log_tags_param($change),
        $sqitch->user_name,
        $sqitch->user_email,
        $change->planner_name,
        $change->planner_email
    ]);

    is_deeply all_events(), \@event_data,
        'A record should have been inserted into the events table';

    is_deeply all_tags(), [[
        $tag->id,
        '@alpha',
        $change->id,
        'pg',
        'Good to go!',
        $sqitch->user_name,
        $sqitch->user_email,
        $tag->planner_name,
        $tag->planner_email,
    ]], 'The tag should have been logged';

    is $sqlite->name_for_change_id($change->id), 'users@alpha',
        'name_for_change_id() should return the change name with tag';

    ok my $state = $sqlite->current_state, 'Get the current state';
    isa_ok my $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
        'committed_at value';
    is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
    is_deeply $state, {
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        tags            => ['@alpha'],
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
        planned_at      => $change->timestamp,
    }, 'The rest of the state should look right';
    is_deeply all( $sqlite->current_changes ), [{
        change_id       => $change->id,
        change          => 'users',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => $dt,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
        planned_at      => $change->timestamp,
    }], 'Should have one current change';
    is_deeply all( $sqlite->current_tags('nonesuch') ), [],
        'Should have no current chnages for nonexistent project';
    is_deeply all( $sqlite->current_tags ), [{
        tag_id          => $tag->id,
        tag             => '@alpha',
        committed_at    => dt_for_tag( $tag->id ),
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        planner_name    => $tag->planner_name,
        planner_email   => $tag->planner_email,
        planned_at      => $tag->timestamp,
    }], 'Should have one current tags';
    is_deeply all( $sqlite->current_tags('nonesuch') ), [],
        'Should have no current tags for nonexistent project';
    my @events = ({
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => $sqlite->_log_requires_param($change),
        conflicts       => $sqlite->_log_conflicts_param($change),
        tags            => $sqlite->_log_tags_param($change),
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_event(0),
        planned_at      => $change->timestamp,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
    });
    is_deeply all( $sqlite->search_events ), \@events, 'Should have one event';

    ##########################################################################
    # Test log_new_tags().
    ok $sqlite->log_new_tags($change), 'Log new tags for "users" change';
    is_deeply all_tags(), [[
        $tag->id,
        '@alpha',
        $change->id,
        'pg',
        'Good to go!',
        $sqitch->user_name,
        $sqitch->user_email,
        $tag->planner_name,
        $tag->planner_email,
    ]], 'The tag should be the same';

    # Delete that tag.
    $sqlite->_dbh->do('DELETE FROM tags');
    is_deeply all_tags(), [], 'Should now have no tags';

    # Put it back.
    ok $sqlite->log_new_tags($change), 'Log new tags for "users" change again';
    is_deeply all_tags(), [[
        $tag->id,
        '@alpha',
        $change->id,
        'pg',
        'Good to go!',
        $sqitch->user_name,
        $sqitch->user_email,
        $tag->planner_name,
        $tag->planner_email,
    ]], 'The tag should be back';

    ##########################################################################
    # Test log_revert_change(). First shift existing event dates.
    ok $sqlite->log_revert_change($change), 'Revert "users" change';
    $set_event_timestamp->('2013-03-30 00:45:47');
    ok !$sqlite->is_deployed_change($change), 'The change should no longer be deployed';
    is_deeply [$sqlite->are_deployed_changes($change)], [],
        'The change should no longer be deployed';

    is $sqlite->earliest_change_id, undef, 'Should get undef for earliest change';
    is $sqlite->latest_change_id, undef, 'Should get undef for latest change';

    is_deeply all_changes(), [],
        'The record should have been deleted from the changes table';
    is_deeply all_tags(), [], 'And the tag record should have been removed';
    is_deeply get_dependencies($change->id), [], 'Should still have no dependencies';
    is_deeply [ $sqlite->changes_requiring_change($change) ], [],
        'Change should not be required';

    push @event_data, [
        'revert',
        $change->id,
        'users',
        'pg',
        '',
        $sqlite->_log_requires_param($change),
        $sqlite->_log_conflicts_param($change),
        $sqlite->_log_tags_param($change),
        $sqitch->user_name,
        $sqitch->user_email,
        $change->planner_name,
        $change->planner_email
    ];

    is_deeply all_events(), \@event_data,
        'The revert event should have been logged';

    is $sqlite->name_for_change_id($change->id), undef,
        'name_for_change_id() should no longer return the change name';
    is $sqlite->current_state, undef, 'Current state should be undef again';
    is_deeply all( $sqlite->current_changes ), [],
        'Should again have no current changes';
    is_deeply all( $sqlite->current_tags ), [], 'Should again have no current tags';

    unshift @events => {
        event           => 'revert',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => $sqlite->_log_requires_param($change),
        conflicts       => $sqlite->_log_conflicts_param($change),
        tags            => $sqlite->_log_tags_param($change),
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_event(1),
        planned_at      => $change->timestamp,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
    };
    is_deeply all( $sqlite->search_events ), \@events, 'Should have two events';

    ##########################################################################
    # Test log_fail_change().
    ok $sqlite->log_fail_change($change), 'Fail "users" change';
    $set_event_timestamp->('2013-03-30 00:46:47');
    ok !$sqlite->is_deployed_change($change), 'The change still should not be deployed';
    is_deeply [$sqlite->are_deployed_changes($change)], [],
        'The change still should not be deployed';
    is $sqlite->earliest_change_id, undef, 'Should still get undef for earliest change';
    is $sqlite->latest_change_id, undef, 'Should still get undef for latest change';
    is_deeply all_changes(), [], 'Still should have not changes table record';
    is_deeply all_tags(), [], 'Should still have no tag records';
    is_deeply get_dependencies($change->id), [], 'Should still have no dependencies';
    is_deeply [ $sqlite->changes_requiring_change($change) ], [],
        'Change should not be required';

    push @event_data, [
        'fail',
        $change->id,
        'users',
        'pg',
        '',
        $sqlite->_log_requires_param($change),
        $sqlite->_log_conflicts_param($change),
        $sqlite->_log_tags_param($change),
        $sqitch->user_name,
        $sqitch->user_email,
        $change->planner_name,
        $change->planner_email
    ];

    is_deeply all_events(), \@event_data, 'The fail event should have been logged';
    is $sqlite->current_state, undef, 'Current state should still be undef';
    is_deeply all( $sqlite->current_changes ), [], 'Should still have no current changes';
    is_deeply all( $sqlite->current_tags ), [], 'Should still have no current tags';

    unshift @events => {
        event           => 'fail',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => $sqlite->_log_requires_param($change),
        conflicts       => $sqlite->_log_conflicts_param($change),
        tags            => $sqlite->_log_tags_param($change),
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_event(2),
        planned_at      => $change->timestamp,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
    };
    is_deeply all( $sqlite->search_events ), \@events, 'Should have 3 events';

    # From here on in, use a different committer.
    my $user2_name  = 'Homer Simpson';
    my $user2_email = 'homer@example.com';
    $mock_sqitch->mock( user_name => $user2_name );
    $mock_sqitch->mock( user_email => $user2_email );

    ##########################################################################
    # Test a change with dependencies.
    ok $sqlite->log_deploy_change($change),    'Deploy the change again';
    $set_event_timestamp->('2013-03-30 00:47:47');
    ok $sqlite->is_deployed_tag($tag),     'The tag again should be deployed';
    is $sqlite->earliest_change_id, $change->id, 'Should again get users ID for earliest change ID';
    is $sqlite->earliest_change_id(1), undef, 'Should still get no change offset 1 from earliest';
    is $sqlite->latest_change_id, $change->id, 'Should again get users ID for latest change ID';
    is $sqlite->latest_change_id(1), undef, 'Should still get no change offset 1 from latest';

    ok my $change2 = $plan->change_at(1),   'Get the second change';
    is_deeply [sort $sqlite->are_deployed_changes($change, $change2)], [$change->id],
        'Only the first change should be deployed';
    my ($req) = $change2->requires;
    ok $req->resolved_id($change->id),      'Set resolved ID in required depend';
    # Send this change back in time.
    $sqlite->_dbh->do(
        'UPDATE changes SET committed_at = ?',
            undef, '2013-03-30 00:47:47',
    );
    ok $sqlite->log_deploy_change($change2),    'Deploy second change';
    $set_event_timestamp->('2013-03-30 00:48:47');
    is $sqlite->earliest_change_id, $change->id, 'Should still get users ID for earliest change ID';
    is $sqlite->earliest_change_id(1), $change2->id,
        'Should get "widgets" offset 1 from earliest';
    is $sqlite->earliest_change_id(2), undef, 'Should get no change offset 2 from earliest';
    is $sqlite->latest_change_id, $change2->id, 'Should get "widgets" ID for latest change ID';
    is $sqlite->latest_change_id(1), $change->id,
        'Should get "user" offset 1 from earliest';
    is $sqlite->latest_change_id(2), undef, 'Should get no change offset 2 from latest';

    is_deeply all_changes(), [
        [
            $change->id,
            'users',
            'pg',
            '',
            $user2_name,
            $user2_email,
            $change->planner_name,
            $change->planner_email,
        ],
        [
            $change2->id,
            'widgets',
            'pg',
            'All in',
            $user2_name,
            $user2_email,
            $change2->planner_name,
            $change2->planner_email,
        ],
    ], 'Should have both changes and requires/conflcits deployed';
    is_deeply [sort $sqlite->are_deployed_changes($change, $change2)],
        [sort $change->id, $change2->id],
        'Both changes should be deployed';
    is_deeply get_dependencies($change->id), [],
        'Should still have no dependencies for "users"';
    is_deeply get_dependencies($change2->id), [
        [
            $change2->id,
            'conflict',
            'dr_evil',
            undef,
        ],
        [
            $change2->id,
            'require',
            'users',
            $change->id,
        ],
    ], 'Should have both dependencies for "widgets"';
    is_deeply [ $sqlite->changes_requiring_change($change) ], [{
        project   => 'pg',
        change_id => $change2->id,
        change    => 'widgets',
        asof_tag  => undef,
    }], 'Change "users" should be required by "widgets"';
    is_deeply [ $sqlite->changes_requiring_change($change2) ], [],
        'Change "widgets" should not be required';

    push @event_data, [
        'deploy',
        $change->id,
        'users',
        'pg',
        '',
        $sqlite->_log_requires_param($change),
        $sqlite->_log_conflicts_param($change),
        $sqlite->_log_tags_param($change),
        $user2_name,
        $user2_email,
        $change->planner_name,
        $change->planner_email,
    ], [
        'deploy',
        $change2->id,
        'widgets',
        'pg',
        'All in',
        $sqlite->_log_requires_param($change2),
        $sqlite->_log_conflicts_param($change2),
        $sqlite->_log_tags_param($change2),
        $user2_name,
        $user2_email,
        $change2->planner_name,
        $change2->planner_email,
    ];
    is_deeply all_events(), \@event_data,
        'The new change deploy should have been logged';

    is $sqlite->name_for_change_id($change2->id), 'widgets',
        'name_for_change_id() should return just the change name';

    ok $state = $sqlite->current_state, 'Get the current state again';
    isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
        'committed_at value';
    is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
    is_deeply $state, {
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
        tags            => [],
    }, 'The state should reference new change';

    my @current_changes = (
        {
            change_id       => $change2->id,
            change          => 'widgets',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $change2->id ),
            planner_name    => $change2->planner_name,
            planner_email   => $change2->planner_email,
            planned_at      => $change2->timestamp,
        },
        {
            change_id       => $change->id,
            change          => 'users',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $change->id ),
            planner_name    => $change->planner_name,
            planner_email   => $change->planner_email,
            planned_at      => $change->timestamp,
        },
    );

    is_deeply all( $sqlite->current_changes ), \@current_changes,
        'Should have two current changes in reverse chronological order';

    my @current_tags = (
        {
            tag_id     => $tag->id,
            tag        => '@alpha',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_tag( $tag->id ),
            planner_name    => $tag->planner_name,
            planner_email   => $tag->planner_email,
            planned_at      => $tag->timestamp,
        },
    );
    is_deeply all( $sqlite->current_tags ), \@current_tags,
        'Should again have one current tags';

    unshift @events => {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        requires        => $sqlite->_log_requires_param($change2),
        conflicts       => $sqlite->_log_conflicts_param($change2),
        tags            => $sqlite->_log_tags_param($change2),
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(4),
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
    }, {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => $sqlite->_log_requires_param($change),
        conflicts       => $sqlite->_log_conflicts_param($change),
        tags            => $sqlite->_log_tags_param($change),
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(3),
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
        planned_at      => $change->timestamp,
    };
    is_deeply all( $sqlite->search_events ), \@events, 'Should have 5 events';

    ##########################################################################
    # Test deployed_changes(), deployed_changes_since(), load_change, and
    # change_offset_from_id().
    can_ok $sqlite, qw(
        deployed_changes
        deployed_changes_since
        load_change
        change_offset_from_id
    );
    my $change_hash = {
        id            => $change->id,
        name          => $change->name,
        project       => $change->project,
        note          => $change->note,
        timestamp     => $change->timestamp,
        planner_name  => $change->planner_name,
        planner_email => $change->planner_email,
        tags          => ['@alpha'],
    };
    my $change2_hash = {
        id            => $change2->id,
        name          => $change2->name,
        project       => $change2->project,
        note          => $change2->note,
        timestamp     => $change2->timestamp,
        planner_name  => $change2->planner_name,
        planner_email => $change2->planner_email,
        tags          => [],
    };
    is_deeply [$sqlite->deployed_changes], [$change_hash, $change2_hash],
        'Should have two deployed changes';
    is_deeply [$sqlite->deployed_changes_since($change)], [$change2_hash],
        'Should find one deployed since the first one';
    is_deeply [$sqlite->deployed_changes_since($change2)], [],
        'Should find none deployed since the second one';

    is_deeply $sqlite->load_change($change->id), $change_hash,
        'Should load change 1';
    is_deeply $sqlite->load_change($change2->id), $change2_hash,
        'Should load change 2';
    is_deeply $sqlite->load_change('whatever'), undef,
        'load() should return undef for uknown change ID';

    is_deeply $sqlite->change_offset_from_id($change->id, undef), $change_hash,
        'Should load change with no offset';
    is_deeply $sqlite->change_offset_from_id($change2->id, 0), $change2_hash,
        'Should load change with offset 0';

    # Now try some offsets.
    is_deeply $sqlite->change_offset_from_id($change->id, 1), $change2_hash,
        'Should find change with offset 1';
    is_deeply $sqlite->change_offset_from_id($change2->id, -1), $change_hash,
        'Should find change with offset -1';
    is_deeply $sqlite->change_offset_from_id($change->id, 2), undef,
        'Should find undef change with offset 2';

    # Revert change 2.
    ok $sqlite->log_revert_change($change2), 'Revert "widgets"';
    $set_event_timestamp->('2013-03-30 00:49:47');
    is_deeply [$sqlite->deployed_changes], [$change_hash],
        'Should now have one deployed change ID';
    is_deeply [$sqlite->deployed_changes_since($change)], [],
        'Should find none deployed since that one';

    # Add another one.
    ok $sqlite->log_deploy_change($change2), 'Log another change';
    $set_event_timestamp->('2013-03-30 00:50:47');
    is_deeply [$sqlite->deployed_changes], [$change_hash, $change2_hash],
        'Should have both deployed change IDs';
    is_deeply [$sqlite->deployed_changes_since($change)], [$change2_hash],
        'Should find only the second after the first';
    is_deeply [$sqlite->deployed_changes_since($change2)], [],
        'Should find none after the second';

    ok $state = $sqlite->current_state, 'Get the current state once more';
    isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
        'committed_at value';
    is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
    is_deeply $state, {
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        tags            => [],
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
    }, 'The new state should reference latest change';

    # These were reverted and re-deployed, so might have new timestamps.
    $current_changes[0]->{committed_at} = dt_for_change( $change2->id );
    $current_changes[1]->{committed_at} = dt_for_change( $change->id );
    is_deeply all( $sqlite->current_changes ), \@current_changes,
        'Should still have two current changes in reverse chronological order';
    is_deeply all( $sqlite->current_tags ), \@current_tags,
        'Should still have one current tags';

    unshift @events => {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        requires        => $sqlite->_log_requires_param($change2),
        conflicts       => $sqlite->_log_conflicts_param($change2),
        tags            => $sqlite->_log_tags_param($change2),
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(6),
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
    }, {
        event           => 'revert',
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        requires        => $sqlite->_log_requires_param($change2),
        conflicts       => $sqlite->_log_conflicts_param($change2),
        tags            => $sqlite->_log_tags_param($change2),
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(5),
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
    };
    is_deeply all( $sqlite->search_events ), \@events, 'Should have 7 events';

    ##########################################################################
    # Deploy the new changes with two tags.
    $plan->add( name => 'fred' );
    $plan->add( name => 'barney' );
    $plan->tag( name => 'beta' );
    $plan->tag( name => 'gamma' );
    ok my $fred = $plan->get('fred'),     'Get the "fred" change';
    ok $sqlite->log_deploy_change($fred),     'Deploy "fred"';
    $set_event_timestamp->('2013-03-30 00:51:47');
    ok my $barney = $plan->get('barney'), 'Get the "barney" change';
    ok $sqlite->log_deploy_change($barney),   'Deploy "barney"';
    $set_event_timestamp->('2013-03-30 00:52:47');

    is $sqlite->earliest_change_id, $change->id, 'Earliest change should sill be "users"';
    is $sqlite->earliest_change_id(1), $change2->id,
        'Should still get "widgets" offset 1 from earliest';
    is $sqlite->earliest_change_id(2), $fred->id,
        'Should get "fred" offset 2 from earliest';
    is $sqlite->earliest_change_id(3), $barney->id,
        'Should get "barney" offset 3 from earliest';

    is $sqlite->latest_change_id, $barney->id, 'Latest change should be "barney"';
    is $sqlite->latest_change_id(1), $fred->id, 'Should get "fred" offset 1 from latest';
    is $sqlite->latest_change_id(2), $change2->id, 'Should get "widgets" offset 2 from latest';
    is $sqlite->latest_change_id(3), $change->id, 'Should get "users" offset 3 from latest';

    is_deeply $sqlite->current_state, {
        project         => 'pg',
        change_id       => $barney->id,
        change          => 'barney',
        note            => '',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_change($barney->id),
        tags            => [qw(@beta @gamma)],
        planner_name    => $barney->planner_name,
        planner_email   => $barney->planner_email,
        planned_at      => $barney->timestamp,
    }, 'Barney should be in the current state';

    unshift @current_changes => {
        change_id       => $barney->id,
        change          => 'barney',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_change( $barney->id ),
        planner_name    => $barney->planner_name,
        planner_email   => $barney->planner_email,
        planned_at      => $barney->timestamp,
    }, {
        change_id       => $fred->id,
        change          => 'fred',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_change( $fred->id ),
        planner_name    => $fred->planner_name,
        planner_email   => $fred->planner_email,
        planned_at      => $fred->timestamp,
    };

    is_deeply all( $sqlite->current_changes ), \@current_changes,
        'Should have all four current changes in reverse chron order';

    my ($beta, $gamma) = $barney->tags;

    # Make sure the two tags have different timestamps.
    $sqlite->_dbh->do($_) for (
        q{UPDATE tags SET committed_at = '2013-03-30 00:53:47' WHERE tag = '@gamma'}
    );
    unshift @current_tags => {
        tag_id          => $gamma->id,
        tag             => '@gamma',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_tag( $gamma->id ),
        planner_name    => $gamma->planner_name,
        planner_email   => $gamma->planner_email,
        planned_at      => $gamma->timestamp,
    }, {
        tag_id          => $beta->id,
        tag             => '@beta',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_tag( $beta->id ),
        planner_name    => $beta->planner_name,
        planner_email   => $beta->planner_email,
        planned_at      => $beta->timestamp,
    };

    is_deeply all( $sqlite->current_tags ), \@current_tags,
        'Should now have three current tags in reverse chron order';

    unshift @events => {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $barney->id,
        change          => 'barney',
        note            => '',
        requires        => $sqlite->_log_requires_param($barney),
        conflicts       => $sqlite->_log_conflicts_param($barney),
        tags            => $sqlite->_log_tags_param($barney),
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(8),
        planner_name    => $barney->planner_name,
        planner_email   => $barney->planner_email,
        planned_at      => $barney->timestamp,
    }, {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $fred->id,
        change          => 'fred',
        note            => '',
        requires        => $sqlite->_log_requires_param($fred),
        conflicts       => $sqlite->_log_conflicts_param($fred),
        tags            => $sqlite->_log_tags_param($fred),
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(7),
        planner_name    => $fred->planner_name,
        planner_email   => $fred->planner_email,
        planned_at      => $fred->timestamp,
    };
    is_deeply all( $sqlite->search_events ), \@events, 'Should have 9 events';

    ##########################################################################
    # Test search_events() parameters.
    is_deeply all( $sqlite->search_events(limit => 2) ), [ @events[0..1] ],
        'The limit param to search_events should work';

    is_deeply all( $sqlite->search_events(offset => 4) ), [ @events[4..$#events] ],
        'The offset param to search_events should work';

    is_deeply all( $sqlite->search_events(limit => 3, offset => 4) ), [ @events[4..6] ],
        'The limit and offset params to search_events should work together';

    is_deeply all( $sqlite->search_events( direction => 'DESC' ) ), \@events,
        'Should work to set direction "DESC" in search_events';
    is_deeply all( $sqlite->search_events( direction => 'desc' ) ), \@events,
        'Should work to set direction "desc" in search_events';
    is_deeply all( $sqlite->search_events( direction => 'descending' ) ), \@events,
        'Should work to set direction "descending" in search_events';

    is_deeply all( $sqlite->search_events( direction => 'ASC' ) ),
        [ reverse @events ],
        'Should work to set direction "ASC" in search_events';
    is_deeply all( $sqlite->search_events( direction => 'asc' ) ),
        [ reverse @events ],
        'Should work to set direction "asc" in search_events';
    is_deeply all( $sqlite->search_events( direction => 'ascending' ) ),
        [ reverse @events ],
        'Should work to set direction "ascending" in search_events';
    throws_ok { $sqlite->search_events( direction => 'foo' ) } 'App::Sqitch::X',
        'Should catch exception for invalid search direction';
    is $@->ident, 'DEV', 'Search direction error ident should be "DEV"';
    is $@->message, 'Search direction must be either "ASC" or "DESC"',
        'Search direction error message should be correct';

    is_deeply all( $sqlite->search_events( committer => 'Simpson$' ) ), \@events,
        'The committer param to search_events should work';
    is_deeply all( $sqlite->search_events( committer => "^Homer" ) ),
        [ @events[0..5] ],
        'The committer param to search_events should work as a regex';
    is_deeply all( $sqlite->search_events( committer => 'Simpsonized$' ) ), [],
        qq{Committer regex should fail to match with "Simpsonized\$"};

    is_deeply all( $sqlite->search_events( change => 'users' ) ),
        [ @events[5..$#events] ],
        'The change param to search_events should work with "users"';
    is_deeply all( $sqlite->search_events( change => 'widgets' ) ),
        [ @events[2..4] ],
        'The change param to search_events should work with "widgets"';
    is_deeply all( $sqlite->search_events( change => 'fred' ) ),
        [ $events[1] ],
        'The change param to search_events should work with "fred"';
    is_deeply all( $sqlite->search_events( change => 'fre$' ) ), [],
        'The change param to search_events should return nothing for "fre$"';
    is_deeply all( $sqlite->search_events( change => '(er|re)' ) ),
        [@events[1, 5..8]],
        'The change param to search_events should return match "(er|re)"';

    is_deeply all( $sqlite->search_events( event => [qw(deploy)] ) ),
        [ grep { $_->{event} eq 'deploy' } @events ],
        'The event param should work with "deploy"';
    is_deeply all( $sqlite->search_events( event => [qw(revert)] ) ),
        [ grep { $_->{event} eq 'revert' } @events ],
        'The event param should work with "revert"';
    is_deeply all( $sqlite->search_events( event => [qw(fail)] ) ),
        [ grep { $_->{event} eq 'fail' } @events ],
        'The event param should work with "fail"';
    is_deeply all( $sqlite->search_events( event => [qw(revert fail)] ) ),
        [ grep { $_->{event} ne 'deploy' } @events ],
        'The event param should work with "revert" and "fail"';
    is_deeply all( $sqlite->search_events( event => [qw(deploy revert fail)] ) ),
        \@events,
        'The event param should work with "deploy", "revert", and "fail"';
    is_deeply all( $sqlite->search_events( event => ['foo'] ) ), [],
        'The event param should return nothing for "foo"';

    # Add an external project event.
    ok my $ext_plan = App::Sqitch::Plan->new(
        sqitch => $sqitch,
        project => 'groovy',
    ), 'Create external plan';
    ok my $ext_change = $ext_plan->add(
        plan => $ext_plan,
        name => 'crazyman',
    ), "Create external change";
    ok $sqlite->log_deploy_change($ext_change), 'Log the external change';
    $set_event_timestamp->('2013-03-30 00:53:47');
    my $ext_event = {
        event           => 'deploy',
        project         => 'groovy',
        change_id       => $ext_change->id,
        change          => $ext_change->name,
        note            => '',
        requires        => $sqlite->_log_requires_param($ext_change),
        conflicts       => $sqlite->_log_conflicts_param($ext_change),
        tags            => $sqlite->_log_tags_param($ext_change),
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(9),
        planner_name    => $user2_name,
        planner_email   => $user2_email,
        planned_at      => $ext_change->timestamp,
    };
    is_deeply all( $sqlite->search_events( project => '^pg$' ) ), \@events,
        'The project param to search_events should work';
    is_deeply all( $sqlite->search_events( project => '^groovy$' ) ), [$ext_event],
        'The project param to search_events should work with external project';
    is_deeply all( $sqlite->search_events( project => 'g' ) ), [$ext_event, @events],
        'The project param to search_events should match across projects';
    is_deeply all( $sqlite->search_events( project => 'nonexistent' ) ), [],
        qq{Project regex should fail to match with "nonexistent"};

    # Make sure we do not see these changes where we should not.
    ok !grep( { $_ eq $ext_change->id } $sqlite->deployed_changes),
        'deployed_changes should not include external change';
    ok !grep( { $_ eq $ext_change->id } $sqlite->deployed_changes_since($change)),
        'deployed_changes_since should not include external change';

    is $sqlite->earliest_change_id, $change->id,
        'Earliest change should sill be "users"';
    isnt $sqlite->latest_change_id, $ext_change->id,
        'Latest change ID should not be from external project';

    throws_ok { $sqlite->search_events(foo => 1) } 'App::Sqitch::X',
        'Should catch exception for invalid search param';
    is $@->ident, 'DEV', 'Invalid search param error ident should be "DEV"';
    is $@->message, 'Invalid parameters passed to search_events(): foo',
        'Invalid search param error message should be correct';

    throws_ok { $sqlite->search_events(foo => 1, bar => 2) } 'App::Sqitch::X',
        'Should catch exception for invalid search params';
    is $@->ident, 'DEV', 'Invalid search params error ident should be "DEV"';
    is $@->message, 'Invalid parameters passed to search_events(): bar, foo',
        'Invalid search params error message should be correct';

    ##########################################################################
    # Now that we have a change from an externa project, get its state.
    ok $state = $sqlite->current_state('groovy'), 'Get the "groovy" state';
    isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
        'groofy committed_at value';
    is $dt->time_zone->name, 'UTC', 'groovy committed_at TZ should be UTC';
    is_deeply $state, {
        project         => 'groovy',
        change_id       => $ext_change->id,
        change          => $ext_change->name,
        note            => '',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        tags            => [],
        planner_name    => $ext_change->planner_name,
        planner_email   => $ext_change->planner_email,
        planned_at      => $ext_change->timestamp,
    }, 'The rest of the state should look right';

    ##########################################################################
    # Test change_id_for().
    for my $spec (
        [
            'change_id only',
            { change_id => $change->id },
            $change->id,
        ],
        [
            'change only',
            { change => $change->name },
            $change->id,
        ],
        [
            'change + tag',
            { change => $change->name, tag => 'alpha' },
            $change->id,
        ],
        [
            'change@HEAD',
            { change => $change->name, tag => 'HEAD' },
            $change->id,
        ],
        [
            'tag only',
            { tag => 'alpha' },
            $change->id,
        ],
        [
            'ROOT',
            { tag => 'ROOT' },
            $change->id,
        ],
        [
            'FIRST',
            { tag => 'FIRST' },
            $change->id,
        ],
        [
            'HEAD',
            { tag => 'HEAD' },
            $barney->id,
        ],
        [
            'LAST',
            { tag => 'LAST' },
            $barney->id,
        ],
        [
            'project:ROOT',
            { tag => 'ROOT', project => 'groovy' },
            $ext_change->id,
        ],
        [
            'project:HEAD',
            { tag => 'HEAD', project => 'groovy' },
            $ext_change->id,
        ],
    ) {
        my ( $desc, $params, $exp_id ) = @{ $spec };
        is $sqlite->change_id_for(%{ $params }), $exp_id, "Should find id for $desc";
    }

    for my $spec (
        [
            'unkonwn id',
            { change_id => 'whatever' },
        ],
        [
            'unkonwn change',
            { change => 'whatever' },
        ],
        [
            'unkonwn tag',
            { tag => 'whatever' },
        ],
        [
            'change + unkonwn tag',
            { change => $change->name, tag => 'whatever' },
        ],
        [
            'change@ROOT',
            { change => $change->name, tag => 'ROOT' },
        ],
        [
            'change + different project',
            { change => $change->name, project => 'whatever' },
        ],
        [
            'tag + different project',
            { tag => 'alpha', project => 'whatever' },
        ],
    ) {
        my ( $desc, $params ) = @{ $spec };
        is $sqlite->change_id_for(%{ $params }), undef, "Should find nothing for $desc";
    }

    ##########################################################################
    # Test change_id_for_depend().
    my $id = '4f1e83f409f5f533eeef9d16b8a59e2c0aa91cc1';
    my $i;

    for my $spec (
        [
            'id only',
            { id => $id },
            { id => $id },
        ],
        [
            'change + tag',
            { change => 'bart', tag => 'epsilon' },
            { name   => 'bart' }
        ],
        [
            'change only',
            { change => 'lisa' },
            { name   => 'lisa' },
        ],
        [
            'tag only',
            { tag  => 'sigma' },
            { name => 'maggie' },
        ],
    ) {
        my ( $desc, $dep_params, $chg_params ) = @{ $spec };

        # Test as an internal dependency.
        INTERNAL: {
            ok my $change = $plan->add(
                name    => 'foo' . ++$i,
                %{$chg_params},
            ), "Create internal $desc change";

            # Tag it if necessary.
            if (my $tag = $dep_params->{tag}) {
                ok $plan->tag(name => $tag), "Add tag internal \@$tag";
            }

            # Should start with unsatisfied dependency.
            ok my $dep = App::Sqitch::Plan::Depend->new(
                plan    => $plan,
                project => $plan->project,
                %{ $dep_params },
            ), "Create internal $desc dependency";
            is $sqlite->change_id_for_depend($dep), undef,
                "Internal $desc depencency should not be satisfied";

            # Once deployed, dependency should be satisfied.
            ok $sqlite->log_deploy_change($change),
                "Log internal $desc change deployment";
            $set_event_timestamp->('2013-03-30 00:54:47');
            is $sqlite->change_id_for_depend($dep), $change->id,
                "Internal $desc depencency should now be satisfied";

            # Revert it and try again.
            ok $sqlite->log_revert_change($change),
                "Log internal $desc change reversion";
            $set_event_timestamp->('2013-03-30 00:55:47');
            is $sqlite->change_id_for_depend($dep), undef,
                "Internal $desc depencency should again be unsatisfied";
        }

        # Now test as an external dependency.
        EXTERNAL: {
            # Make Change and Tag return registered external project "groovy".
            $dep_params->{project} = 'groovy';
            my $line_mocker = Test::MockModule->new('App::Sqitch::Plan::Line');
            $line_mocker->mock(project => $dep_params->{project});

            ok my $change = App::Sqitch::Plan::Change->new(
                plan    => $plan,
                name    => 'foo' . ++$i,
                %{$chg_params},
            ), "Create external $desc change";

            # Tag it if necessary.
            if (my $tag = $dep_params->{tag}) {
                ok $change->add_tag(App::Sqitch::Plan::Tag->new(
                    plan    => $plan,
                    change  => $change,
                    name    => $tag,
                ) ), "Add tag external \@$tag";
            }

            # Should start with unsatisfied dependency.
            ok my $dep = App::Sqitch::Plan::Depend->new(
                plan    => $plan,
                project => $plan->project,
                %{ $dep_params },
            ), "Create external $desc dependency";
            is $sqlite->change_id_for_depend($dep), undef,
                "External $desc depencency should not be satisfied";

            # Once deployed, dependency should be satisfied.
            ok $sqlite->log_deploy_change($change),
                "Log external $desc change deployment";
            $set_event_timestamp->('2013-03-30 00:56:47');

            is $sqlite->change_id_for_depend($dep), $change->id,
                "External $desc depencency should now be satisfied";

            # Revert it and try again.
            ok $sqlite->log_revert_change($change),
                "Log external $desc change reversion";
            $set_event_timestamp->('2013-03-30 00:57:47');
            is $sqlite->change_id_for_depend($dep), undef,
                "External $desc depencency should again be unsatisfied";
        }
    }

    ok my $ext_change2 = App::Sqitch::Plan::Change->new(
        plan => $ext_plan,
        name => 'outside_in',
    ), "Create another external change";
    ok $ext_change2->add_tag( my $ext_tag = App::Sqitch::Plan::Tag->new(
        plan    => $plan,
        change  => $ext_change2,
        name    => 'meta',
    ) ), 'Add tag external "meta"';

    ok $sqlite->log_deploy_change($ext_change2), 'Log the external change with tag';
    $set_event_timestamp->('2013-03-30 00:58:47');

    # Make sure name_for_change_id() works properly.
    ok $sqlite->_dbh->do(q{DELETE FROM tags WHERE project = 'pg'}),
        'Delete the pg project tags';
    is $sqlite->name_for_change_id($change2->id), 'widgets',
        'name_for_change_id() should return "widgets" for its ID';
    is $sqlite->name_for_change_id($ext_change2->id), 'outside_in@meta',
        'name_for_change_id() should return "outside_in@meta" for its ID';

    # Make sure current_changes and current_tags are project-scoped.
    is_deeply all( $sqlite->current_changes ), \@current_changes,
        'Should have only the "pg" changes from current_changes';
    is_deeply all( $sqlite->current_changes('groovy') ), [
        {
            change_id       => $ext_change2->id,
            change          => $ext_change2->name,
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $ext_change2->id ),
            planner_name    => $ext_change2->planner_name,
            planner_email   => $ext_change2->planner_email,
            planned_at      => $ext_change2->timestamp,
        }, {
            change_id       => $ext_change->id,
            change          => $ext_change->name,
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $ext_change->id ),
            planner_name    => $ext_change->planner_name,
            planner_email   => $ext_change->planner_email,
            planned_at      => $ext_change->timestamp,
        }
    ], 'Should get only requestd project changes from current_changes';
    is_deeply all( $sqlite->current_tags ), [],
        'Should no longer have "pg" project tags';
    is_deeply all( $sqlite->current_tags('groovy') ), [{
        tag_id          => $ext_tag->id,
        tag             => '@meta',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_tag( $ext_tag->id ),
        planner_name    => $ext_tag->planner_name,
        planner_email   => $ext_tag->planner_email,
        planned_at      => $ext_tag->timestamp,
    }], 'Should get groovy tags from current_chages()';

    ##########################################################################
    # Test changes with multiple and cross-project dependencies.
    ok my $hyper = $plan->add(
        name     => 'hypercritical',
        requires => ['pg:fred', 'groovy:crazyman'],
    ), 'Create change "hypercritial" in current plan';
    $_->resolved_id( $sqlite->change_id_for_depend($_) ) for $hyper->requires;
    ok $sqlite->log_deploy_change($hyper), 'Log change "hyper"';
    $set_event_timestamp->('2013-03-30 00:59:47');

    is_deeply [ $sqlite->changes_requiring_change($hyper) ], [],
        'No changes should require "hypercritical"';
    is_deeply [ $sqlite->changes_requiring_change($fred) ], [{
        project   => 'pg',
        change_id => $hyper->id,
        change    => $hyper->name,
        asof_tag  => undef,
    }], 'Change "hypercritical" should require "fred"';

    is_deeply [ $sqlite->changes_requiring_change($ext_change) ], [{
        project   => 'pg',
        change_id => $hyper->id,
        change    => $hyper->name,
        asof_tag  => undef,
    }], 'Change "hypercritical" should require "groovy:crazyman"';

    # Add another change with more depencencies.
    ok my $ext_change3 = App::Sqitch::Plan::Change->new(
        plan => $ext_plan,
        name => 'elsewise',
        requires => [
            App::Sqitch::Plan::Depend->new(
                plan    => $ext_plan,
                project => 'pg',
                change  => 'fred',
            ),
            App::Sqitch::Plan::Depend->new(
                plan    => $ext_plan,
                change  => 'crazyman',
            ),
        ]
    ), "Create a third external change";
    $_->resolved_id( $sqlite->change_id_for_depend($_) ) for $ext_change3->requires;
    ok $sqlite->log_deploy_change($ext_change3), 'Log change "elsewise"';
    $set_event_timestamp->('2013-03-30 01:00:47');

    # Check the dependencies again.
    is_deeply [ $sqlite->changes_requiring_change($fred) ], [
        {
            project   => 'pg',
            change_id => $hyper->id,
            change    => $hyper->name,
            asof_tag  => undef,
        },
        {
            project   => 'groovy',
            change_id => $ext_change3->id,
            change    => $ext_change3->name,
            asof_tag  => undef,
        },
    ], 'Change "fred" should be required by changes in two projects';

    is_deeply [ $sqlite->changes_requiring_change($ext_change) ], [
        {
            project   => 'pg',
            change_id => $hyper->id,
            change    => $hyper->name,
            asof_tag  => undef,
        },
        {
            project   => 'groovy',
            change_id => $ext_change3->id,
            change    => $ext_change3->name,
            asof_tag  => undef,
        },
    ], 'Change "groovy:crazyman" should be required by changes in two projects';

    ##########################################################################
    # Test begin_work() and finish_work().
    can_ok $sqlite, qw(begin_work finish_work);
    my $mock_dbh = Test::MockModule->new(ref $sqlite->_dbh, no_auto => 1);
    my $txn;
    $mock_dbh->mock(commit     => sub { $txn = 0  });
    $mock_dbh->mock(rollback   => sub { $txn = -1 });
    my @do;
    $mock_dbh->mock(do => sub {
        shift;
        @do = @_;
        $txn = 1 if $do[0] eq 'BEGIN EXCLUSIVE TRANSACTION'
    });
    ok $sqlite->begin_work, 'Begin work';
    is $txn, 1, 'Should have started a transaction';
    ok $sqlite->finish_work, 'Finish work';
    is $txn, 0, 'Should have committed a transaction';
    ok $sqlite->begin_work, 'Begin work again';
    is $txn, 1, 'Should have started another transaction';
    ok $sqlite->rollback_work, 'Rollback work';
    is $txn, -1, 'Should have rolled back a transaction';
    $mock_dbh->unmock('do');

    # Unmock everything and call it a day.
    $mock_dbh->unmock_all;
    $mock_sqitch->unmock_all;
    done_testing;
};

done_testing;

sub dt_for_change {
    my $col = $sqlite->_ts2char('committed_at');
    $dtfunc->($sqlite->_dbh->selectcol_arrayref(
        "SELECT $col FROM changes WHERE change_id = ?",
        undef, shift
    )->[0]);
}

sub dt_for_tag {
    my $col = $sqlite->_ts2char('committed_at');
    $dtfunc->($sqlite->_dbh->selectcol_arrayref(
        "SELECT $col FROM tags WHERE tag_id = ?",
        undef, shift
    )->[0]);
}

sub all {
    my $iter = shift;
    my @res;
    while (my $row = $iter->()) {
        push @res => $row;
    }
    return \@res;
}

sub dt_for_event {
    my $col = $sqlite->_ts2char('committed_at');
    $dtfunc->($sqlite->_dbh->selectcol_arrayref(
        "SELECT $col FROM events ORDER BY committed_at ASC LIMIT 1 OFFSET ?",
        undef, shift
    )->[0]);
}

sub all_changes {
    $sqlite->_dbh->selectall_arrayref(q{
        SELECT change_id, change, project, note, committer_name, committer_email,
               planner_name, planner_email
          FROM changes
         ORDER BY committed_at
    });
}

sub all_tags {
    $sqlite->_dbh->selectall_arrayref(q{
        SELECT tag_id, tag, change_id, project, note,
               committer_name, committer_email, planner_name, planner_email
          FROM tags
         ORDER BY committed_at
    });
}

sub all_events {
    $sqlite->_dbh->selectall_arrayref(q{
        SELECT event, change_id, change, project, note, requires, conflicts, tags,
               committer_name, committer_email, planner_name, planner_email
          FROM events
         ORDER BY committed_at
    });
}

sub get_dependencies {
    $sqlite->_dbh->selectall_arrayref(q{
        SELECT change_id, type, dependency, dependency_id
          FROM dependencies
         WHERE change_id = ?
         ORDER BY dependency
    }, undef, shift);
}

