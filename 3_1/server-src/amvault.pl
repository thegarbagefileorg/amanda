#! @PERL@
# Copyright (c) 2008, 2009, 2010 Zmanda, Inc.  All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 2 as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
#
# Contact information: Zmanda Inc., 465 S. Mathilda Ave., Suite 300
# Sunnyvale, CA 94086, USA, or: http://www.zmanda.com

use lib '@amperldir@';
use strict;

package Amvault;

use Amanda::Config qw( :getconf config_dir_relative );
use Amanda::Debug qw( :logging );
use Amanda::Device qw( :constants );
use Amanda::Xfer qw( :constants );
use Amanda::Header qw( :constants );
use Amanda::MainLoop;
use Amanda::DB::Catalog;
use Amanda::Changer;

my $quiet = 0;

sub fail($) {
    print STDERR @_, "\n";
    exit 1;
}

sub vlog($) {
    if (!$quiet) {
	print @_, "\n";
    }
}

sub new {
    my ($class, $src_write_timestamp, $dst_changer, $dst_label_template) = @_;

    # check that the label template is valid
    fail "Invalid label template '$dst_label_template'"
	if ($dst_label_template =~ /%[^%]+%/
	    or $dst_label_template =~ /^[^%]+$/);

    # translate "latest" into the most recent timestamp
    if ($src_write_timestamp eq "latest") {
	$src_write_timestamp = Amanda::DB::Catalog::get_latest_write_timestamp();
    }

    fail "No dumps found"
	unless (defined $src_write_timestamp);

    bless {
	'src_write_timestamp' => $src_write_timestamp,
	'dst_changer' => $dst_changer,
	'dst_label_template' => $dst_label_template,
	'first_dst_slot' => undef,
    }, $class;
}

# Start a copy of a single file from src_dev to dest_dev.  If there are
# no more files, call the callback.
sub run {
    my $self = shift;

    $self->{'remaining_files'} = [
	Amanda::DB::Catalog::sort_dumps([ "label", "filenum" ],
	    Amanda::DB::Catalog::get_parts(
		write_timestamp => $self->{'src_write_timestamp'},
		ok => 1,
	)) ];

    $self->{'src_chg'} = Amanda::Changer->new();
    $self->{'src_res'} = undef;
    $self->{'src_dev'} = undef;
    $self->{'src_label'} = undef;

    $self->{'dst_chg'} = Amanda::Changer->new($self->{'dst_changer'});
    $self->{'dst_res'} = undef;
    $self->{'dst_dev'} = undef;
    $self->{'dst_label'} = undef;

    $self->{'dst_timestamp'} = Amanda::Util::generate_timestamp();

    Amanda::MainLoop::call_later(sub { $self->start_next_file(); });
    Amanda::MainLoop::run();
}

sub generate_new_dst_label {
    my $self = shift;

    # count the number of percents in there
    (my $npercents =
	$self->{'dst_label_template'}) =~ s/[^%]*(%+)[^%]*/length($1)/e;
    my $nlabels = 10 ** $npercents;

    # make up a sprintf pattern
    (my $sprintf_pat =
	$self->{'dst_label_template'}) =~ s/(%+)/"%0" . length($1) . "d"/e;

    my $tl = Amanda::Tapelist::read_tapelist(
	config_dir_relative(getconf($CNF_TAPELIST)));
    my %existing_labels =
	map { $_->{'label'} => 1 } @$tl;

    for (my $i = 0; $i < $nlabels; $i++) {
	my $label = sprintf($sprintf_pat, $i);
	next if (exists $existing_labels{$label});
	return $label;
    }

    fail "No unused labels matching '$self->{dst_label_template}' are available";
}

# add $next_file to the catalog db.  This assumes that the corresponding label
# is already in the DB.

sub add_part_to_db {
    my $self = shift;
    my ($next_file, $filenum) = @_;

    my $dump = {
	'label' => $self->{'dst_label'},
	'filenum' => $filenum,
	'dump_timestamp' => $next_file->{'dump'}->{'dump_timestamp'},
	'write_timestamp' => $self->{'dst_timestamp'},
	'hostname' => $next_file->{'dump'}->{'hostname'},
	'diskname' => $next_file->{'dump'}->{'diskname'},
	'level' => $next_file->{'dump'}->{'level'},
	'status' => 'OK',
	'partnum' => $next_file->{'partnum'},
	'nparts' => $next_file->{'dump'}->{'nparts'},
	'kb' => 0, # unknown
	'sec' => 0, # unknown
    };

    Amanda::DB::Catalog::add_part($dump);
}

# This function is called to copy the next file in $self->{remaining_files}
sub start_next_file {
    my $self = shift;
    my $next_file = shift @{$self->{'remaining_files'}};

    # bail if we're finished
    if (!defined $next_file) {
	vlog("all files copied");
	$self->release_reservations(sub {
	    Amanda::MainLoop::quit();
	});
	return;
    }

    # make sure we're on the right device.  Note that we always change
    # both volumes at the same time.
    if (defined $self->{'src_label'} &&
		$self->{'src_label'} eq $next_file->{'label'}) {
	$self->seek_and_copy($next_file);
    } else {
	$self->load_next_volumes($next_file);
    }
}

# Start both the source and destination changers seeking to the next volume
sub load_next_volumes {
    my $self = shift;
    my ($next_file) = @_;
    my ($src_loaded, $dst_loaded) = (0,0);
    my ($release_src, $load_src, $got_src, $set_labeled_src,
        $release_dst, $load_dst, $got_dst,
	$maybe_done);

    # For the source changer, we release the previous device, load the next
    # volume by its label, and open the device.

    $release_src = make_cb('release_src' => sub {
	if ($self->{'src_dev'}) {
	    $self->{'src_dev'}->finish()
		or fail $self->{'src_dev'}->error_or_status();
	    $self->{'src_dev'} = undef;
	    $self->{'src_label'} = undef;

	    $self->{'src_res'}->release(
		finished_cb => $load_src);
	} else {
	    $load_src->(undef);
	}
    });

    $load_src = make_cb('load_src' => sub {
	my ($err) = @_;
	fail $err if $err;
	vlog("Loading source volume $next_file->{label}");

	$self->{'src_chg'}->load(
	    label => $next_file->{'label'},
	    res_cb => $got_src);
    });

    $got_src = make_cb(got_src => sub {
	my ($err, $res) = @_;
	fail $err if $err;

	debug("Opened source device");

	$self->{'src_res'} = $res;
	my $dev = $self->{'src_dev'} = $res->{'device'};
	my $device_name = $dev->device_name;

	if ($dev->volume_label ne $next_file->{'label'}) {
	    fail ("Volume in $device_name has unexpected label " .
		 $dev->volume_label);
	}

	$dev->start($ACCESS_READ, undef, undef)
	    or fail ("Could not start device $device_name: " .
		$dev->error_or_status());

	# OK, it all matches up now..
	$self->{'src_label'} = $next_file->{'label'};
	$src_loaded = 1;

	$maybe_done->();
    });

    # For the destination, we release the reservation after noting the 'next'
    # slot, and either load that slot or "current".  When the slot is loaded,
    # check that there is no label, invent a label, and write it to the volume.

    $release_dst = make_cb('release_dst' => sub {
	if ($self->{'dst_dev'}) {
	    $self->{'dst_dev'}->finish()
		or fail $self->{'dst_dev'}->error_or_status();
	    $self->{'dst_dev'} = undef;

	    $self->{'dst_res'}->release(
		finished_cb => $load_dst);
	} else {
	    $load_dst->(undef);
	}
    });

    $load_dst = make_cb('load_dst' => sub {
	my ($err) = @_;
	fail $err if $err;
	vlog("Loading next destination slot");

	if (defined $self->{'dst_res'}) {
	    $self->{'dst_chg'}->load(
		relative_slot => 'next',
		slot => $self->{'dst_res'}->{'this_slot'},
		set_current => 1,
		res_cb => $got_dst);
	} else {
	    $self->{'dst_chg'}->load(
		relative_slot => "current",
		set_current => 1,
		res_cb => $got_dst);
	}
    });

    $got_dst = make_cb('got_dst' => sub {
	my ($err, $res) = @_;
	fail $err if $err;

	debug("Opened destination device");

	# if we've tried this slot before, we're out of destination slots
	if (defined $self->{'first_dst_slot'}) {
	    if ($res->{'this_slot'} eq $self->{'first_dst_slot'}) {
		fail("No more unused destination slots");
	    }
	} else {
	    $self->{'first_dst_slot'} = $res->{'this_slot'};
	}

	$self->{'dst_res'} = $res;
	my $dev = $self->{'dst_dev'} = $res->{'device'};
	my $device_name = $dev->device_name;

	# for now, we only overwrite absolutely empty volumes.  This will need
	# to change when we introduce use of a taperscan algorithm.

	my $status = $dev->status;
	if (!($status & $DEVICE_STATUS_VOLUME_UNLABELED)) {
	    # if UNLABELED is only one possibility, give a device error msg
	    if ($status & ~$DEVICE_STATUS_VOLUME_UNLABELED) {
		fail ("Could not read label from $device_name: " .
		     $dev->error_or_status());
	    } else {
		vlog("Volume in destination slot $res->{this_slot} is already labeled; going to next slot");
		$release_dst->();
		return;
	    }
	}

	if (defined($dev->volume_header)) {
	    vlog("Volume in destination slot $res->{this_slot} is not empty; going to next slot");
	    $release_dst->();
	    return;
	}

	my $new_label = $self->generate_new_dst_label();

	$dev->start($ACCESS_WRITE, $new_label, $self->{'dst_timestamp'})
	    or fail ("Could not start device $device_name: " .
		$dev->error_or_status());

	# OK, it all matches up now..
	$self->{'dst_label'} = $new_label;
	$dst_loaded = 1;

	$res->set_label($dev->volume_label(),
			finished_cb => $maybe_done);
    });

    # and finally, when both src and dst are finished, we move on to
    # the next step.
    $maybe_done = make_cb('maybe_done' => sub {
	return if (!$src_loaded or !$dst_loaded);

	vlog("Volumes loaded; starting copy");
	$self->seek_and_copy($next_file);
    });

    # kick it off
    $release_src->();
    $release_dst->();
}

sub seek_and_copy {
    my $self = shift;
    my ($next_file) = @_;
    my $dst_filenum;

    vlog("Copying file #$next_file->{filenum}");

    # seek the source device
    my $hdr = $self->{'src_dev'}->seek_file($next_file->{'filenum'});
    if (!defined $hdr) {
	fail "Error seeking to read next file: " .
		    $self->{'src_dev'}->error_or_status()
    }
    if ($hdr->{'type'} == $F_TAPEEND
	    or $self->{'src_dev'}->file() != $next_file->{'filenum'}) {
	fail "Attempt to seek to a non-existent file.";
    }

    if ($hdr->{'type'} != $F_DUMPFILE && $hdr->{'type'} != $F_SPLIT_DUMPFILE) {
	fail "Unexpected header type $hdr->{type}";
    }

    # start the destination device with the same header
    if (!$self->{'dst_dev'}->start_file($hdr)) {
	fail "Error starting new file: " . $self->{'dst_dev'}->error_or_status();
    }

    # and track the destination filenum correctly
    $dst_filenum = $self->{'dst_dev'}->file();

    # now put together a transfer to copy that data.
    my $xfer;
    my $xfer_cb = sub {
	my ($src, $msg, $elt) = @_;
	if ($msg->{type} == $XMSG_INFO) {
	    vlog("while transferring: $msg->{message}\n");
	}
	if ($msg->{type} == $XMSG_ERROR) {
	    fail $msg->{elt} . " failed: " . $msg->{message};
	} elsif ($msg->{'type'} == $XMSG_DONE) {
	    debug("transfer completed");

	    # add this dump to the logfile
	    $self->add_part_to_db($next_file, $dst_filenum);

	    # start up the next copy
	    $self->start_next_file();
	}
    };

    $xfer = Amanda::Xfer->new([
	Amanda::Xfer::Source::Device->new($self->{'src_dev'}),
	Amanda::Xfer::Dest::Device->new($self->{'dst_dev'},
				        getconf($CNF_DEVICE_OUTPUT_BUFFER_SIZE)),
    ]);

    debug("starting transfer");
    $xfer->start($xfer_cb);
}

sub release_reservations {
    my $self = shift;
    my ($finished_cb) = @_;
    my $steps = define_steps
	cb_ref => \$finished_cb;

    step release_src => sub {
	if ($self->{'src_res'}) {
	    $self->{'src_res'}->release(
		finished_cb => $steps->{'release_dst'});
	} else {
	    $steps->{'release_dst'}->(undef);
	}
    };

    step release_dst => sub {
	my ($err) = @_;
	vlog("$err") if $err;

	if ($self->{'dst_res'}) {
	    $self->{'dst_res'}->release(
		finished_cb => $steps->{'done'});
	} else {
	    $steps->{'done'}->(undef);
	}
    };

    step done => sub {
	my ($err) = @_;
	vlog("$err") if $err;
	$finished_cb->();
    };
}

## Application initialization
package Main;
use Amanda::Config qw( :init :getconf );
use Amanda::Debug qw( :logging );
use Amanda::Util qw( :constants );
use Getopt::Long;

sub usage {
    print <<EOF;
**NOTE** this interface is under development and will change in future releases!

Usage: amvault [-o configoption]* [-q|--quiet]
	<conf> <src-run-timestamp> <dst-changer> <label-template>

    -o: configuration overwrite (see amanda(8))
    -q: quiet progress messages

Copies data from the run with timestamp <src-run-timestamp> onto volumes using
the changer <dst-changer>, labeling new volumes with <label-template>.  If
<src-run-timestamp> is "latest", then the most recent amdump or amflush run
will be used.

Each source volume will be copied to a new destination volume; no re-assembly
or splitting will be performed.  Destination volumes must be at least as large
as the source volumes.

EOF
    exit(1);
}

Amanda::Util::setup_application("amvault", "server", $CONTEXT_CMDLINE);

my $config_overrides = new_config_overrides($#ARGV+1);
Getopt::Long::Configure(qw{ bundling });
GetOptions(
    'o=s' => sub { add_config_override_opt($config_overrides, $_[1]); },
    'q|quiet' => \$quiet,
) or usage();

usage unless (@ARGV == 4);

my ($config_name, $src_write_timestamp, $dst_changer, $label_template) = @ARGV;

set_config_overrides($config_overrides);
config_init($CONFIG_INIT_EXPLICIT_NAME, $config_name);
my ($cfgerr_level, @cfgerr_errors) = config_errors();
if ($cfgerr_level >= $CFGERR_WARNINGS) {
    config_print_errors();
    if ($cfgerr_level >= $CFGERR_ERRORS) {
	fail("errors processing config file");
    }
}

Amanda::Util::finish_setup($RUNNING_AS_ANY);

# start the copy
my $vault = Amvault->new($src_write_timestamp, $dst_changer, $label_template);
$vault->run();
Amanda::Util::finish_application();