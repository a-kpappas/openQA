#!/usr/bin/env perl
# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -base, -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';

use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::Case;
use OpenQA::Test::Utils 'wait_for';
use OpenQA::Client;

use OpenQA::SeleniumTest;

my $schema = OpenQA::Test::Case->new->init_data;
driver_missing unless my $driver = call_driver;

sub wait_for_data_table_entries ($table, $expected_entry_count) {
    my @entries;
    wait_for_ajax msg => 'DataTable query';
    wait_for {
        @entries = $driver->find_child_elements($table, 'tbody/tr', 'xpath');
        scalar @entries == $expected_entry_count;
    }
    "$expected_entry_count entries present", {timeout => OpenQA::Test::TimeLimit::scale_timeout 10};
    return \@entries;
}

sub check_data_table_entries ($table, $expected_entry_count, $test_name) {
    my $entries = wait_for_data_table_entries $table, $expected_entry_count;
    is scalar @$entries, $expected_entry_count, $test_name;
    return $entries;
}

my $t = Test::Mojo->new('OpenQA::WebAPI');
# we need to talk to the phantom instance or else we're using wrong database
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

# Scheduled isos are only available to operators and admins
$t->get_ok($url . '/admin/auditlog')->status_is(302);
$t->get_ok($url . '/login')->status_is(302);
$t->get_ok($url . '/admin/auditlog')->status_is(200);

# Log in as Demo
$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");
is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");

$driver->find_element('#user-action a')->click();
$driver->find_element_by_link_text('Audit log')->click();
like($driver->get_title(), qr/Audit log/, 'on audit log');
my $table = $driver->find_element_by_id('audit_log_table');
ok $table, 'audit table found' or BAIL_OUT 'unable to find DataTable';

subtest 'audit log entries' => sub {
    # search for name, event, date and combination
    my $search = $driver->find_element('#audit_log_table_filter input.form-control');
    ok($search, 'search box found');

    check_data_table_entries $table, 4, 'four rows without filter';

    $search->send_keys('QA restart');
    my $entries = check_data_table_entries $table, 2, 'less rows when filtered for event data';
    like $entries->[0]->get_text(), qr/openQA restarted/, 'correct element displayed';
    $search->clear;

    $search->send_keys('user:system');
    check_data_table_entries $table, 2, 'less rows when filtered by user';
    $search->clear;

    $search->send_keys('event:user_login');
    check_data_table_entries $table, 2, 'less rows when filtered by event';
    $search->clear;

    $search->send_keys('newer:today');
    check_data_table_entries $table, 4, 'again 4 rows when filtering for only newer than today';
    $search->clear;

    $search->send_keys('older:today');
    $entries = check_data_table_entries $table, 1, 'one row for empty table when filtering for only older than today';
    is $driver->find_child_element($entries->[0], 'td')->get_attribute('class'), 'dataTables_empty',
      'but DataTable is empty';
    $search->clear;

    $search->send_keys('user:system event:startup date:today');
    check_data_table_entries $table, 2, 'two rows when filtered by combination';
};

subtest 'clickable events' => sub {
    # Populate database via the API to add events without hard-coding the format here
    my $auth = {'X-CSRF-Token' => $t->ua->get($url . '/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
    $t->post_ok($url . '/api/v1/machines', $auth => form => {name => 'foo', backend => 'qemu'})->status_is(200);
    $t->post_ok($url . '/api/v1/test_suites', $auth => form => {name => 'testsuite'})->status_is(200);
    $t->post_ok(
        $url . '/api/v1/products',
        $auth => form => {
            arch => 'x86_64',
            distri => 'opensuse',
            flavor => 'DVD',
            version => '13.2',
        })->status_is(200);
    ok OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'table_create'), 'event emitted';

    $driver->refresh;
    wait_for_ajax msg => 'DataTable ready';
    my $table = $driver->find_element_by_id('audit_log_table');
    check_data_table_entries $table, 7, 'seven rows without filter and before posting job/comment';
    my $search = $driver->find_element('#audit_log_table_filter input.form-control');
    $search->send_keys('event:table_create');
    my $entries = check_data_table_entries $table, 3, 'three rows for table create events';
    ok($entries->[0]->child('.audit_event_details'), 'event detail link present');

    $t->post_ok("$url/api/v1/jobs" => $auth => form => {TEST => 'foo'})->status_is(200)->json_is({id => 1});
    $t->post_ok("$url/api/v1/jobs/1/comments" => $auth => form => {text => 'Just a job test'})->status_is(200)
      ->json_is({id => 1});

    $driver->refresh;
    wait_for_ajax msg => 'DataTable ready';
    $table = $driver->find_element_by_id('audit_log_table');
    check_data_table_entries $table, 9, 'nine rows without filter and after posting job/comment';
    $search = $driver->find_element('#audit_log_table_filter input.form-control');
    $search->send_keys('event:comment_create');
    $entries = check_data_table_entries $table, 1, 'one row for comment create events';
    ok $entries->[0]->child('.audit_event_details'), 'event detail link present';

    $entries->[0]->child('.audit_event_details')->click;
    wait_for_ajax msg => 'details loaded';
    my @comments = $driver->find_elements('div.media-comment p', 'css');
    is(scalar @comments, 1, 'one comment');
    is($comments[0]->get_text(), 'Just a job test', 'right comment');
};

kill_driver();
done_testing();
