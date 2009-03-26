package xPL::Dock::LCDproc;

=head1 NAME

xPL::Dock::Lcdproc - xPL::Dock plugin for an LCDproc client

=head1 SYNOPSIS

  use xPL::Dock qw/LCDproc/;
  my $xpl = xPL::Dock->new();
  $xpl->main_loop();

=head1 DESCRIPTION

This L<xPL::Dock> plugin adds lcdproc proximity reporting.

=head1 METHODS

=cut

use 5.006;
use strict;
use warnings;

use English qw/-no_match_vars/;
use xPL::Dock::Plug;
use xPL::Queue;
use IO::Socket::INET;

our @ISA = qw(xPL::Dock::Plug);
our %EXPORT_TAGS = ( 'all' => [ qw() ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw();
our $VERSION = qw/$Revision$/[1];

__PACKAGE__->make_readonly_accessor($_) foreach (qw/server delay/);

=head2 C<getopts( )>

This method returns the L<Getopt::Long> option definition for the
plugin.

=cut

sub getopts {
  my $self = shift;
  $self->{_delay} = 10;
  $self->{_server} = '127.0.0.1:13666';
  return
    (
     'lcdproc-verbose|lcdprocverbose+' => \$self->{_verbose},
     'lcdproc-server|lcdprocserver=s' => \$self->{_server},
     'lcdproc-delay|lcdprocdelay=i' => $self->{_delay},
    );
}

=head2 C<init(%params)>

=cut

sub init {
  my $self = shift;
  my $xpl = shift;
  my %p = @_;

  $self->SUPER::init($xpl, @_);

  my $lcdproc = $self->{_lcdproc} =
    IO::Socket::INET->new($self->{_server}) or
        die "Failed to connect to ", $self->{_server}, ": $!\n";
  $xpl->add_input(handle => $lcdproc,
                  callback => sub { $self->read_lcdproc(@_) });

  # Add a callback to receive all incoming xPL messages
  $xpl->add_xpl_callback(id => 'xpl', self_skip => 0,
                         callback => sub { $self->xpl_in(@_) },
                         filter => {
                                    message_type => 'xpl-cmnd',
                                    class => 'osd',
                                   });

  $self->{_protocol_expected} = '0.3';
  $self->{_buffer} = '';
  $self->{_q} = xPL::Queue->new;
  $self->{_waiting} = undef;
  $self->{_widget} = {};
  $self->{_visible} = undef;
  $self->queue_lcdproc('hello');

  return $self;
}

=head2 C<xpl_in( )>

This method is the callback to display the C<osd.basic> messages.

=cut

sub xpl_in {
  my $self = shift;
  my $xpl = $self->xpl;
  my %p = @_;
  my $msg = $p{message};
  my $peeraddr = $p{peeraddr};
  my $peerport = $p{peerport};

  my $row = $msg->row;
  unless ($row && $row >= 1 && $row <= $self->{_rows}) {
    $row = 1;
  }
  if ((lc $msg->command) eq 'clear') {
    $self->clear_screen();
  }
  unless ($msg->text) {
    return;
  }

  my $delay = $msg->delay;
  $delay = $self->{_delay} if (!defined $delay || $delay > $self->{_delay});
  $self->write_row($row, $msg->text);
  if ($xpl->exists_timer('row'.$row)) {
    $xpl->remove_timer('row'.$row);
  }
  $xpl->add_timer(id => 'row'.$row, timeout => $delay,
                  callback => sub { $self->clear_row($row); return });
  return 1;
}

=head2 C<read_lcdproc( )>

This callback handles responses the input from the lcdproc server.

=cut

sub read_lcdproc {
  my $self = shift;
  my $bytes = $self->{_lcdproc}->sysread($self->{_buffer}, 512,
                                         length $self->{_buffer});
  while ($self->{_buffer} =~ s/^(.*?)\r?\n//) {
    my $line = $LAST_PAREN_MATCH;
    if ($line =~ /^connect\b/) {
      $self->{_waiting} = undef;
      $self->{_columns} = $1 if ($line =~ /\bwid\s+(\d+)/);
      $self->{_rows} = $1 if ($line =~ /\bhgt\s+(\d+)/);
      $self->info('Connected to LCD (',
                  $self->{_columns}||'?', 'x', $self->{_rows}||'?', ")\n");
      if ($line =~ /\bprotocol\s+(\S+)/ && $1 ne $self->{_protocol_expected}) {
        warn "LCDproc daemon protocol $1 not ".$self->{_protocol_expected}.
          " as expected.\n";
      }
      $self->queue_lcdproc('screen_add xplosd');
      $self->queue_lcdproc('screen_set xplosd -name xplosd');
      $self->queue_lcdproc('screen_set xplosd -priority hidden');
      undef $self->{_visible};
    } elsif ($line eq 'success') {
      undef $self->{_waiting};
      $self->write_lcdproc();
    } elsif ($line =~ /^huh\?/) {
      warn "Failed sending ", $self->{_waiting}, "got: ", $line, "\n";
      undef $self->{_waiting};
      $self->write_lcdproc();
    }
  }
}

=head2 C<queue_lcdproc( $msg )>

This method queues messages to be sent to the lcdproc server.

=cut

sub queue_lcdproc {
  my ($self,$msg) = @_;
  $self->{_q}->enqueue($msg);
  $self->info('queued: ', $msg, "\n");
  return $self->write_lcdproc()  if (!defined $self->{_waiting});
  return 1;
}

=head2 C<write_lcdproc( )>

This method sends messages to the lcdproc server.

=cut

sub write_lcdproc {
  my $self = shift;
  my $msg = $self->{_q}->dequeue;
  return if (!defined $msg);
  $self->info('sending: ', $msg, "\n");
  $msg .= "\n";
  syswrite($self->{_lcdproc}, $msg, length $msg);
  $self->{_lcdproc}->flush();
  $self->{_waiting} = $msg;
}

=head2 C<clear_screen( )>

This method clears the entire lcdproc display.  It hides the xPL "screen"
and removes all "widgets" from it.

=cut

sub clear_screen {
  my $self = shift;
  $self->queue_lcdproc('screen_set xplosd -priority hidden')
    if ($self->{_visible});
  undef $self->{_visible};
  foreach (1..($self->{_rows}||1)) {
    $self->clear_row($_);
  }
}

=head2 C<clear_row( $row )>

This method clears a single row of the lcdproc display.  It removes any
widget defined for the row and if that was the last widget it also hides
the xPL "screen".

=cut

sub clear_row {
  my ($self, $row) = @_;
  if (exists $self->{_widget}->{$row}) {
    $self->queue_lcdproc('widget_del xplosd row'.$row);
  }
  delete $self->{_widget}->{$row};
  if ($self->{_visible} && !keys %{$self->{_widget}}) {
    $self->queue_lcdproc('screen_set xplosd -priority hidden');
    undef $self->{_visible};
  }
}

=head2 C<write_row( $row, $msg )>

This method writes text to a single row of the lcdproc display.  It uses
a string widget or if the text is longer than the number of columns a
scroller widget.

=cut

sub write_row {
  my ($self, $row, $msg) = @_;
  my $widget = ($self->{_columns} &&
                (length $msg) > $self->{_columns}) ? 'scroller' : 'string';
  if (exists $self->{_widget}->{$row} && $self->{_widget}->{$row} eq $widget) {
  } else {
    $self->queue_lcdproc('widget_del row'.$row)
      if (exists $self->{_widget}->{$row});
    $self->queue_lcdproc('widget_add xplosd row'.$row.' '.$widget);
  }
  my $cmd = 'widget_set xplosd row'.$row.' 1 '.$row.' ';
  if ($widget eq 'scroller') {
    $cmd .= $self->{_columns}.' '.$row.' h 2 ';
  }
  $msg =~ s/"/'/g;
  $cmd .= '"'.$msg.'"';
  $self->{_widget}->{$row} = $widget;
  $self->queue_lcdproc($cmd);
  $self->queue_lcdproc('screen_set xplosd -priority alert')
    unless ($self->{_visible});
  $self->{_visible} = 1;
}

1;
__END__

=head1 EXPORT

None by default.

=head1 SEE ALSO

xPL::Dock(3)

Project website: http://www.xpl-perl.org.uk/

LCDProc website: http://lcdproc.sourceforge.net/

=head1 AUTHOR

Mark Hindess, E<lt>soft-xpl-perl@temporalanomaly.comE<gt>

=head1 COPYRIGHT

Copyright (C) 2008, 2009 by Mark Hindess

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut