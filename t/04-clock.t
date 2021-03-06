#!/usr/bin/perl -w
#
# Copyright (C) 2005, 2007 by Mark Hindess

use strict;
use Test::More tests => 3;
use POSIX qw/strftime/;

use_ok("xPL::Message");
my $t=strftime("%Y%m%d%H%M%S", localtime(time));
my $msg = xPL::Message->new(message_type => 'xpl-stat',
                            schema => "clock.update",
                            head => { source => "acme-clock.hall", },
                            body => [ time => $t ]);
ok($msg, "created clock update message");
is($msg->field('time'), $t, "clock update time");
