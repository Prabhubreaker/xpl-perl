#!/usr/bin/perl -w
use strict;
use Test::More tests => 114;
use t::Helpers qw/test_error test_warn/;
use Socket;
use Time::HiRes;
$|=1;

my $timeout = 0.25;
use_ok("xPL::Listener");

{ # normally only clients have an identity but we'll need one to test
  # the self_skip option on xPL callbacks
  package MY::Listener;
  use base 'xPL::Listener';
  sub id { "acme-clock.dingus" };
  1;
}

my $xpl = MY::Listener->new(ip => "127.0.0.1",
                            broadcast => "127.255.255.255",
                            verbose => 1,
                           );

my @methods =
  (
   [ 'ip', "127.0.0.1", ],
   [ 'broadcast', "127.255.255.255", ],
   [ 'port', 0, ],
  );
foreach my $rec (@methods) {
  my ($method, $value) = @$rec;
  is($xpl->$method, $value, "$method method");
}

ok($xpl->module_available('strict'), "module available already used");
ok(!$xpl->module_available('sloppy'), "module not available");
ok($xpl->module_available('strict'), "module available with cache");
ok($xpl->module_available('English'), "module available");

ok($xpl->add_input(handle => \*STDIN, arguments => []), "adding input");
my @h = $xpl->inputs();
is(scalar @h, 2, "inputs count");

like(test_error(sub { $xpl->add_input(handle => \*STDIN); }),
   qr/MY::Listener->add_item: input item '[^']+' already registered/,
   "adding existing input");

ok($xpl->remove_input(\*STDIN), "removing input");

is(test_error(sub { $xpl->add_input(); }),
   "MY::Listener->add_input: requires 'handle' argument",
   "adding input without handle argument");

@h = $xpl->inputs();
is(scalar @h, 1, "inputs count");

my @t = $xpl->timers();
is(scalar @t, 0, "timers count");
my $to = $xpl->timer_minimum_timeout;
is($to, undef, "timer minimum timeout - undef");

my $cb;
$xpl->add_timer(id => 'tick', callback => sub { my %p=@_; $cb=\%p; },
                arguments => ["grr argh"],
                timeout => $timeout);

$to = $xpl->timer_minimum_timeout;
ok(defined $to && $to > 0 && $to < $timeout, "timer minimum timeout - ".$to);

$xpl->main_loop(1) until ($cb);

ok(exists $cb->{id}, "timer ticked");
is($cb->{id}, 'tick', "correct timer argument");
ok($cb && exists $cb->{arguments}, "arguments passed");
is($cb->{arguments}->[0], "grr argh", "correct argument passed");
is($xpl->timer_callback_count('tick'), 1, "timer callback counter");

my $now = time;
is(&{$xpl->timer_attrib('tick', 'next_fn')}($now), $now+$timeout,
   "timer next_function with positive timeout");

my $nt = $xpl->timer_next_ticks();
$to = $nt->[0] - Time::HiRes::time();
ok(defined $to && $to > 0 && $to < $timeout, "timer minimum timeout - ".$to);
ok($xpl->remove_timer('tick'), "remove timer");

$timeout = .5;
$xpl->add_timer(id => 'null', timeout => -$timeout, count => 5);
my $st = Time::HiRes::time();
$xpl->main_loop(1);
ok(Time::HiRes::time()-$st < $timeout/2,
   "quick dispatch of negative timeout");
is($xpl->timer_callback_count('null'), 1, "timer callback counter");
is($xpl->timer_attrib('null', 'count'), 4, "timer repeat count");
@t = $xpl->timers();
is(scalar @t, 1, "timers count");

$now = time;
is(&{$xpl->timer_attrib('null', 'next_fn')}($now), $now+$timeout,
   "timer next_function with negative timeout");

is(test_error(sub { $xpl->add_timer(id => 'null', timeout => -1) }),
   ref($xpl)."->add_timer: timer 'null' already exists",
   "adding existing timer");

foreach my $c (3,2,1) {
  my $tn = $xpl->timer_next('null');
  $xpl->main_loop(1) while ($xpl->timer_next('null') == $tn);
  is($xpl->timer_attrib('null', 'count'), $c, "timer repeat count");
  is($xpl->timer_callback_count('null'), 5-$c, "timer callback counter");
  @t = $xpl->timers();
  is(scalar @t, 1, "timers count");
}

my $tn = $xpl->timer_next('null');
is(test_warn(sub {
     $xpl->main_loop(1) while ($xpl->timer_attrib('null', 'count'));
   }),
   "MY::Listener->item_attrib: timer item 'null' not registered",
   'timer removed when count reaches zero');
ok(!$xpl->exists_timer('null'), 'timer removed when count reaches zero');

$xpl->add_timer(id => "no-dec-count", timeout => -1, count => 1,
                callback => sub { -1; });
$xpl->main_loop(1);
ok($xpl->exists_timer("no-dec-count"), "timer count not decremented");
is($xpl->timer_callback_count("no-dec-count"), 1, "timer callback counter");
is($xpl->timer_attrib("no-dec-count", 'count'), 1, "timer repeat count");
ok($xpl->remove_timer("no-dec-count"), "removing timer");

$xpl->add_timer(id => 'null', timeout => -1, callback => sub { undef });
$xpl->main_loop(1);
ok(!$xpl->exists_timer('null'), "timer triggered and removed on undef");

$xpl->add_timer(id => 'null', timeout => -1, count => 1);
$xpl->main_loop(1);
ok(!$xpl->exists_timer('null'), "timer triggered and removed by counter");

is(test_error(sub { $xpl->add_timer(timeout => -1) }),
   ref($xpl)."->add_timer: requires 'id' parameter",
   "adding existing timer");

is(test_error(sub { $xpl->add_timer(id => 'null', timeout => 'tomorrow') }),
   q{xPL::Timer->new_from_string: unknown timeout, 'tomorrow'},
   "adding existing timer");

is(test_error(sub { $xpl->add_timer(id => 'null') }),
   ref($xpl)."->add_timer: requires 'timeout' parameter",
   "adding existing timer");

# hacking the send socket to send to ourselves
$xpl->{_send_sin} = sockaddr_in($xpl->listen_port, inet_aton($xpl->ip));

$xpl->send(head =>
            {
             source => "acme-clock.dingus",
            },
            class => "hbeat.app",
            body =>
            {
             interval => 5,
             port => $xpl->listen_port,
             remote_ip => $xpl->ip,
            },
           );

undef $cb;
$xpl->add_xpl_callback(id => 'hbeat',
                       callback => sub { my %p=@_; $cb=\%p },
                       arguments => ["my test"],
                       self_skip => 0);
$xpl->add_xpl_callback(id => 'null');

is(test_error(sub { $xpl->add_xpl_callback(id => 'null') }),
   ref($xpl)."->add_item: xpl_callback item 'null' already registered",
   "adding existing xpl callback");

$xpl->main_loop(1);

ok($cb && exists $cb->{message}, "message returned");
is(ref($cb->{message}), "xPL::Message::hbeat::app", "correct message type");
ok($cb && exists $cb->{arguments}, "arguments passed");
is($cb->{arguments}->[0], "my test", "correct argument passed");
is($xpl->xpl_callback_callback_count('hbeat'), 1, "callback counter non-zero");
is($xpl->xpl_callback_callback_count('null'), 0, "callback counter zero");
is($xpl->input_callback_count($xpl->{_listen_sock}), 1,
   "input callback count");

ok($xpl->add_input(handle => \*STDIN, arguments => []), "adding input");
ok($xpl->{_select}->exists(\*STDIN), "input added to select");
ok($xpl->remove_input(\*STDIN), "removing input");
ok(!$xpl->{_select}->exists(\*STDIN), "input removed from select");

use_ok("xPL::Message");
my $msg = xPL::Message->new(head =>
                            {
                             source => "acme-clock.livingroom",
                            },
                            class => "clock.update",
                            body =>
                            {
                             time => '20051113182650',
                            },
                           );
undef $cb;
$xpl->send($msg);

$xpl->main_loop(1);

is($xpl->xpl_callback_callback_count('hbeat'), 2, "callback counter");
is($xpl->xpl_callback_callback_count('null'), 1, "callback counter self-skip");
ok($cb && exists $cb->{message}, "message returned");
is(ref($cb->{message}), "xPL::Message::clock::update", "correct message type");

undef $cb;
$xpl->send($msg->string);
$xpl->main_loop(1);
is($xpl->xpl_callback_callback_count('hbeat'), 3, "callback counter");
is($xpl->xpl_callback_callback_count('null'), 2, "callback counter self-skip");
ok($cb && exists $cb->{message}, "message returned");
is(ref($cb->{message}), "xPL::Message::clock::update", "correct message type");

undef $cb;
$xpl->send(head =>
           {
            source => "acme-clock.livingroom",
           },
           class => "clock.update",
           body =>
           {
            time => '20051113182651',
           });
$xpl->main_loop(1);
is($xpl->xpl_callback_callback_count('hbeat'), 4, "callback counter");
is($xpl->xpl_callback_callback_count('null'), 3, "callback counter self-skip");
ok($cb && exists $cb->{message}, "message returned");
is(ref($cb->{message}), "xPL::Message::clock::update", "correct message type");
is($cb->{message}->time(), '20051113182651', "correct value");

undef $cb;
$xpl->send(head =>
            {
             source => "acme-clock.dingus",
            },
            class => "hbeat.end",
            body =>
            {
             interval => 5,
             port => $xpl->listen_port,
             remote_ip => $xpl->ip,
            },
           );
$xpl->main_loop(1);

is($xpl->xpl_callback_callback_count('hbeat'), 5, "callback counter");
is($xpl->xpl_callback_callback_count('null'), 3, "callback counter self-skip");
ok($cb && exists $cb->{message}, "message returned");
is(ref($cb->{message}), "xPL::Message::hbeat::end", "correct message type");

ok($xpl->remove_xpl_callback('hbeat'), "remove xpl callback");

@h = $xpl->inputs();
is(scalar @h, 1, "inputs count");
my $handle = $h[0];
ok($xpl->remove_input($handle), "remove input");
@h = $xpl->inputs();
is(scalar @h, 0, "inputs count");

ok($xpl->add_input(handle => $handle), "add input with null callback");
$xpl->send(head =>
            {
             source => "acme-clock.dingus",
            },
            class => "hbeat.end",
            body =>
            {
             interval => 5,
             port => $xpl->listen_port,
             remote_ip => $xpl->ip,
            },
           );
$xpl->main_loop(1);

is($xpl->input_callback_count($handle), 1, "input callback count");
ok($xpl->remove_input($handle), "remove input");

is(test_error(sub { $xpl->send(invalid => 'messagedata'); }),
   "MY::Listener->send_aux: message error: ".
     "xPL::Message->new: requires 'class' parameter",
   "send with invalid message data");

is(test_error(sub {
    my $xpl = xPL::Listener->new(vendor_id => 'acme',
                                 device_id => 'dingus',
                                 ip => "not-ip",
                                 broadcast => "127.255.255.255",
                                );
  }),
   "xPL::Listener->new: ip invalid",
   "xPL::Listener invalid ip");

is(test_error(sub {
    my $xpl = xPL::Listener->new(vendor_id => 'acme',
                                 device_id => 'dingus',
                                 port => "not-port",
                                 ip => "127.0.0.1",
                                 broadcast => "127.255.255.255",
                                );
  }),
   "xPL::Listener->new: port invalid",
   "xPL::Listener invalid port");

is(test_error(sub {
    my $xpl = xPL::Listener->new(vendor_id => 'acme',
                                 device_id => 'dingus',
                                 ip => "127.0.0.1",
                                 broadcast => "not-broadcast",
                                );
  }),
   "xPL::Listener->new: broadcast invalid",
   "xPL::Listener invalid broadcast");

is(test_error(sub { $xpl->add_xpl_callback(); }),
   ref($xpl)."->add_xpl_callback: requires 'id' argument",
   "adding callback without an id");

is(test_error(sub { $xpl->add_xpl_callback(id => 'test',
                                          filter => ['invalid']); }),
   ref($xpl).'->add_xpl_callback: filter not scalar or hash',
   "adding callback with invalid filter");

is(test_warn(sub { $xpl->remove_xpl_callback('none'); }),
   ref($xpl)."->remove_item: xpl_callback item 'none' not registered",
   "removing non-existent callback");

is(test_warn(sub { $xpl->xpl_callback_callback_count('none'); }),
   ref($xpl)."->item_attrib: xpl_callback item 'none' not registered",
   "checking count of non-existent callback");

is(test_warn(sub { $xpl->remove_timer('none'); }),
   ref($xpl)."->remove_item: timer item 'none' not registered",
   "removing non-existent timer");

is(test_warn(sub { $xpl->timer_next('none'); }),
   ref($xpl)."->item_attrib: timer item 'none' not registered",
   "querying non-existent timer");

is(test_warn(sub { $xpl->timer_callback_count('none'); }),
   ref($xpl)."->item_attrib: timer item 'none' not registered",
   "querying non-existent timer tick count");

is(test_warn(sub { $xpl->remove_input('none'); }),
   ref($xpl)."->remove_input: input 'none' is not registered",
   "removing non-existent input");

is(test_warn(sub { $xpl->dispatch_input('none'); }),
   ref($xpl)."->dispatch_input: input 'none' is not registered",
   "dispatching non-existent input");

is(test_warn(sub { $xpl->input_callback_count('none'); }),
   ref($xpl)."->item_attrib: input item 'none' not registered",
   "checking attribute of non-existent input");

is(test_warn(sub { $xpl->dispatch_timer('none'); }),
   ref($xpl)."->dispatch_timer: timer 'none' is not registered",
   "dispatching non-existent timer");

{
  package xPL::Test;
  use base 'xPL::Listener';
  sub port { $xpl->listen_port };
  1;
}

is(test_error(sub {
     my $test = xPL::Test->new(vendor_id => 'acme',
                               device_id => 'dingus',
                               ip => "127.0.0.1",
                               broadcast => "127.255.255.255");
  }),
   "xPL::Test->create_listen_socket: ".
     "Failed to bind listen socket: Address already in use",
   "bind failure");

SKIP: {
  skip "DateTime::Event::Cron", 5
    unless ($xpl->module_available("DateTime::Event::Cron"));
  ok($xpl->add_timer(id => 'every5m', timeout => 'cron crontab="*/5 * * * *"'),
     "cron based timer created");
  my $now = time;
  my $min = (localtime($now))[1];
  $min = ($min-($min%5)+5)%60;
  @t = $xpl->timers();
  is(scalar @t, 1, "timers count");
  my $tmin = (localtime($xpl->timer_next('every5m')))[1];
  is($tmin, $min, "cron based timer has correct minute value");
  $tmin = (localtime(&{$xpl->timer_attrib('every5m', 'next_fn')}($now)))[1];
  is($tmin, $min, "cron based timer next_fn has correct minute value");
  ok($xpl->remove_timer('every5m'), "remove timer 'every 5 minutes'");
}

# hack to ensure module isn't available to cause error
#$xpl->{_mod}->{"DateTime::Event::Cron"} = 0;
#is(test_warn(sub { $xpl->add_timer(id => 'every5m',
#                                   timeout => "C */5 * * * *"); }),
#   ref($xpl)."->add_timer: DateTime::Event::Cron modules is required
#in order to support crontab-like timer syntax",
#   "graceful crontab-like behaviour failure");

$xpl = $xpl->new(ip => "127.0.0.2",
                 broadcast => "127.255.255.255",
                );
ok($xpl, 'constructor from blessed reference - not recommended');

# mostly for coverage, these aren't used (yet)
like(test_warn(sub { xPL::Listener->ouch('ouch') }),
     qr/xPL::Listener->__ANON__(\[[^]]+\])?: ouch/,
     'warning message method on non-blessed reference');

like(test_error(sub { xPL::Listener->argh('argh'); }),
     qr/xPL::Listener->__ANON__(\[[^]]+\])?: argh/,
     'error message method on non-blessed reference');

is(test_warn(sub { xPL::Listener->ouch_named('eek', 'ouch') }),
   'xPL::Listener->eek: ouch',
   'warning message method on non-blessed reference');

is(test_error(sub { xPL::Listener->argh_named('ook', 'argh'); }),
   'xPL::Listener->ook: argh',
   'error message method on non-blessed reference');
