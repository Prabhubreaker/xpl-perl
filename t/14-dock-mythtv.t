#!/usr/bin/perl -w
#
# Copyright (C) 2009 by Mark Hindess

use strict;
use IO::Socket::INET;
use IO::Select;
use Socket;
use Test::More tests => 21;
use Time::HiRes;
use Cwd;
use t::Helpers qw/test_warn test_error test_output/;
$|=1;

use_ok('xPL::Dock','Mythtv');

my @msg;
sub xPL::Dock::send_aux {
  my $self = shift;
  my $sin = shift;
  push @msg, [@_];
}

$ENV{XPL_HOSTNAME} = 'mytestid';
my $device = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1:0');
ok($device, 'creating fake tcp mythtv client');
my $sel = IO::Select->new($device);
my $port = $device->sockport();
my $xpl;

{
  local $0 = 'dingus';
  local @ARGV = ('-v',
                 '--interface', 'lo',
                 '--define', 'hubless=1',
                 '--mythtv-verbose',
                 '--mythtv-server' => '127.0.0.1:'.$port);
  $xpl = xPL::Dock->new(port => 0);
}
ok($xpl, 'created dock mythtv client');
my $plugin = ($xpl->plugins)[0];
ok($plugin, 'plugin exists');
is(ref $plugin, 'xPL::Dock::Mythtv', 'plugin has correct type');

ok(!$sel->can_read(0.2), 'mythtv device not ready to accept');


$xpl->main_loop(1);

ok($sel->can_read(0.2), 'mythtv device ready to accept - 1');
my $client = $device->accept;
ok($client, 'client accepted - 1');
my $client_sel = IO::Select->new($client);

ok($client_sel->can_read(0.2), 'client can read');
my $cbuf;
is((sysread $client, $cbuf, 1024), 18, 'client content length');
is($cbuf, "GET / HTTP/1.0\r\n\r\n", 'client content');

$client->print(q{
  <div class="content">
    <h2>Encoder status</h2>
    Encoder 1 is local on backend1 and is recording: 'Lost' on C101.<br />
    Encoder 2 is local on backend1 and is recording: 'Found' on C102.<br />
    Encoder 3 is local on backend1 and is not recording.<br />
  </div>
});

$xpl->main_loop(1);

check_sent_msg({
                message_type => 'xpl-stat',
                class => 'sensor.basic',
                body =>
                {
                 device => 'mytestid-myth',
                 current => '66.66',
                 type => 'generic',
                 units => 'percent',
                },
               }, 'checking xPL message - 66.66 usage');

$client->close;

$xpl->dispatch_timer('mythtv');

ok($sel->can_read(0.2), 'mythtv device ready to accept - 2');
$client = $device->accept;
ok($client, 'client accepted - 2');
$client_sel = IO::Select->new($client);

ok($client_sel->can_read(0.2), 'client can read - 2');
is((sysread $client, $cbuf, 1024), 18, 'client content length - 2');
is($cbuf, "GET / HTTP/1.0\r\n\r\n", 'client content - 2');

$client->print(q{
  <div class="content">
    <h2>Encoder status</h2>
    Encoder invalid
  </div>
});

$xpl->main_loop(1);

check_sent_msg({
                message_type => 'xpl-stat',
                class => 'sensor.basic',
                body =>
                {
                 device => 'mytestid-myth',
                 current => '0',
                 type => 'generic',
                 units => 'percent',
                },
               }, 'checking xPL message - 0 usage');

$client->close;

$xpl->dispatch_timer('mythtv');
ok($sel->can_read(0.2), 'mythtv device ready to accept - 3');
$client = $device->accept;
ok($client, 'client accepted - 3');
$client->close;

$xpl->main_loop(1);

$device->close;

is(test_warn(sub { $xpl->dispatch_timer('mythtv'); }),
   ("Failed to contact mythtv daemon at 127.0.0.1:".$port.
    ": Connection refused\n"),
   'connection failed');

sub check_sent_msg {
  my ($expected, $desc) = @_;
  my $msg = shift @msg;
  while (ref $msg->[0]) {
    $msg = shift @msg; # skip hbeat.* message
  }
  my %m = @{$msg};
  is_deeply(\%m, $expected, $desc);
}