#!/usr/bin/perl -w

use Sys::Hostname;
use Socket;
# use Data::Dumper;
use strict;

# This file is a part of tcsboot, the Fortian Inc. netbooting and deployment
# utility.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc., 51
# Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# $Id: netboot.pl,v 1.3 2009/02/27 16:38:02 bstern Exp $ 

my $DEV = 'sda'; # Which device are we stomping on?
my $NETBOOT_CONF = "/netboot.conf"; # From the NFS root POV, where is config?
my $PORT = 31678; # Where does tcsboot listen for successful boot indication?

## my $PARTED = "/sbin/parted -s";
#my $DD = "/bin/dd bs=512b if=/dev/zero";
my $DD = "/bin/dd if=/dev/zero";
my $RSYNC = "/usr/bin/rsync -rzlxHpogDtS --partial"; # -v --progress --stats --rsh=ssh";

# Side note: The 60GB hard drives we are using are 117210240 blocks large.
# 117210240 blocks = (2^7 * 3^4 * 5 * 7 * 17 * 19) blocks * 2^9 bytes/block

# Local variables.
my (%hwaddr, $wipedisk, %chgpart, %parts, @curparts, $rv, @fsli);
my %newpars = ();
my $nbh;

# Prettyprint some information.  This function arguments gets Yoda like.
# showmsg(LEVEL, "bar", "foo:") will print "foo: bar\n" in some manner.
# showmsg(LEVEL, "baz") will print "baz\n" in some manner.
sub showmsg($$;$) {
    my ($level, $msg, $prefix) = @_;

    print "$prefix " if defined $prefix;
    if ($level eq 'fail') { print "\033[1;31m"; }
    elsif ($level eq 'warn') { print "\033[1;33m"; }
    elsif ($level eq 'success') { print "\033[1;32m"; }
    print $msg;
    print "\033[0;39m\n";
    if ($level eq 'fail') { sleep 5; exit 1; }
    elsif ($level eq 'warn') { sleep 2; }
}

sub checkpoint($;$) {
    my ($name, $state) = @_;
    my @ipb = split /\./, $nbh, 4;
    my $binip = pack('CCCC', @ipb);
    my $paddr = sockaddr_in($PORT, $binip);

    showmsg('success', $nbh, 'Checking in with remote server');
    socket(NBH, PF_INET, SOCK_STREAM, 0) or
            showmsg('fail', $!, 'Could not open socket:');
    connect NBH, $paddr or showmsg('fail', $!, 'Could not connect:');
    # showmsg('success', length $name, "Packing $name as:");
    my $hid = pack('C', length $name);
    print NBH $hid;
    print NBH $name;
    $state = '' unless defined $state;
    $hid = pack('C', length $state);
    print NBH $hid;
    print NBH $state if $state ne '';
    close NBH;
}

sub fixfstab($) {
    my $i = shift;
    my $ft = lc $newpars{$i}{'fstype'};
    my $opt = $newpars{$i}{'fsopts'};
    my $fr = '/etc/fedora-release';
    my $dev = $DEV;

    if (-f "/mnt/dc$fr") {
        if (open FEDREL, "</mnt/dc$fr") {
            my $line = <FEDREL>;
            my @words = split ' ', $line;
            if (defined $words[2] and $words[2] eq 7) {
                showmsg('success', $fr, 'Found release 7 in');
                $dev =~ s/^h/s/; # FC7 thinks these disks are SCSI/SATA
                ## $DISTVER = 7;
            } elsif (defined $words[3] and $words[3] eq 3) {
                showmsg('success', $fr, 'Found release 3 in');
                # DNGN
            } else {
                showmsg('warn', 'assuming 3', "Could not understand $fr,");
            }
            close FEDREL;
        } else {
            showmsg('warn', $!, "Could not open (/mnt/dc)$fr:");
        }
    } else {
        showmsg('warn', 'assuming FC3', 'Unknown distribution,');
    }

    showmsg('success', '/etc/fstab', 'Fixing up');
    $opt =~ s/;/,/g; # fix the options line
    open FSTAB, ">/mnt/dc/etc/fstab" or
        showmsg('fail', $!, 'Could not open (/mnt/dc)/etc/fstab:');
    print FSTAB qq|LABEL=/\t/\text3\tdefaults\t1 1
none\t/dev/pts\tdevpts\tgid=5,mode=620\t0 0
none\t/dev/shm\ttmpfs\tdefaults\t0 0
none\t/proc\tproc\tdefaults\t0 0
none\t/sys\tsysfs\tdefaults\t0 0
|;
    print "Adding variable partitions...\n";
    foreach my $j (@fsli) {
        my $mp = $newpars{$j}{'mountpoint'};
        my $d = $newpars{$j}{'fsopts'};
        next unless defined $mp and $mp ne '' and $mp ne '/';
        my $jf = $newpars{$j}{'fstype'};
        next if $jf ne 'swap' and $jf ne 'ext2' and $jf ne 'ext3';
        if ($jf ne 'swap') {
            print FSTAB "/dev/$dev$j\t\t$mp\t\t$jf\t$d\t1 2\n";
        } else {
            print FSTAB "/dev/$dev$j\tnone\t\tswap\t" .
                "defaults\t0 0\n";
        }
        showmsg('success', $mp, 'Adding:');
    }
    close FSTAB;
}

sub fixsyscfg($) {
    my $n = shift;
    # my @hnp;
    my $i;
    my $type;

    ## $n =~ s/-ctrl//; # in case someone used a weird name
    ## @hnp = split(/-/, $n);
    ## $i = pop @hnp;
	if ($n =~ /([A-Za-z0-9]+)-(\d+)-ctrl/) {
        $type = $1;
        $i = $2;
    } else {
        showmsg('fail', $n, "Could not determine IP from name:");
    }

    # $i = 161 if $i eq 'alpha';
    # $i = 162 if $i eq 'bravo';
    # $i = 163 if $i eq 'charlie';
    # $i = 164 if $i eq 'delta';
    # $i = 165 if $i eq 'echo';
    # $i = 166 if $i eq 'foxtrot';
    # $i = 167 if $i eq 'golf';
    # $i = 168 if $i eq 'hotel';
    # $i = 169 if $i eq 'india';
    # $i = 170 if $i eq 'juliet';
    # $i = 171 if $i eq 'kilo';
    # $i = 172 if $i eq 'lima';
    # $i = 132 if $i eq 'BAE-1';
    # $i = 135 if $i eq 'BAE-5';
    # $i = 180 if $i eq 'utransfer';
    showmsg('fail', 'Invalid hostname', 'Could not determine IP from name:')
        unless defined $i and ($i =~ /\d+/);
    
    open NETW, '>/mnt/dc/etc/sysconfig/network' or
        showmsg('fail', $!, 'Could not open .../etc/sysconfig/network:');
    print NETW "NETWORKING=yes\nHOSTNAME=$type-$i\nNOZEROCONF=1\n" or
        showmsg('fail', $!, 'Could not write to .../etc/sysconfig/network:');
    close NETW or
        showmsg('fail', $!, 'Could not close .../etc/sysconfig/network:');

    foreach my $nic (sort keys %hwaddr) {
        open CFGE, ">/mnt/dc/etc/sysconfig/network-scripts/ifcfg-$nic"
            or showmsg('fail', $!, "Could not open ifcfg-$nic for writing:");
        print CFGE "DEVICE=$nic\nBOOTPROTO=static\n" or
            showmsg('fail', $!, "Could not write to ifcfg-$nic:");
        if ($type eq 'MANE') {
            my $nn = $nic;

            print CFGE "ONBOOT=yes\nGATEWAY=0.0.0.0\n" or
                showmsg('fail', $!, "Could not write ONBOOT to ifcfg-$nic:");
            $nn =~ s/^eth//;
	    my $ii = $i;
	    $ii =~ s/^0+//;
            if ($nn == 0) {
                $nn = "10.4.1.$ii";
                print CFGE "NETMASK=255.255.0.0\n" or showmsg('fail', $!,
                    "Could not write NETMASK to ifcfg-$nic:");
            } else {
                $nn = "10.4.20$nn.$ii";
                print CFGE "NETMASK=255.255.255.0\n" or showmsg('fail', $!, 
                    "Could not write NETMASK to ifcfg-$nic:");
            }
            print CFGE "IPADDR=$nn\n" or showmsg('fail', $!, 
                "Could not write IPADDR to ifcfg-$nic:");
        } else {
            if ($nic eq 'eth0') {
                print CFGE "ONBOOT=yes\nIPADDR=10.4.2." or
                    showmsg('fail', $!, "Couldn't write ONBOOT to ifcfg-$nic:");
                print CFGE
                    sprintf("%d\nNETMASK=255.255.0.0\nGATEWAY=0.0.0.0\n", $i)
                    or showmsg('fail', $!, "Could not write IP to ifcfg-$nic:");
            }
        }
        print CFGE "HWADDR=$hwaddr{$nic}\n" or
            showmsg('fail', $!, "Could not write MAC to ifcfg-$nic:");
        close CFGE or showmsg('fail', $!, "Could not close ifcfg-$nic:");
    }

    ## open HOSTSO, '</mnt/dc/etc/hosts' or
    ##     showmsg('fail', $!, 'Could not open .../etc/hosts for read:');
    ## open HOSTSN, ">/mnt/dc/etc/hosts.$$" or
    ##     showmsg('fail', $!, "Could not open .../etc/hosts.$$ for write:");
    ## while (my $l = <HOSTSO>) {
    ##     if ($l =~ /127\.0\.0\.1/) {
    ##         print HOSTSN "127.0.0.1\t$type-$i\t$type-$i.lab\tlocalhost.localdomain\t";
    ##         print HOSTSN "localhost\n";
    ##     } else {
    ##         print HOSTSN $l;
    ##     }
    ## }
    ## close HOSTSO or showmsg('fail', $!, 'Could not close hosts:');
    ## close HOSTSN or showmsg('fail', $!, "Could not close hosts.$$:");
    ## rename "/mnt/dc/etc/hosts.$$", '/mnt/dc/etc/hosts' or
    ##     showmsg('fail', $!, "Could not rename hosts.$$ to hosts:");
}

sub fixgrub($) {
    my $i = shift;

    $rv = shellwrap("/bin/mount /dev/$DEV$i /boot");
    # if ($rv) {
    #     $DEV =~ s/^s/h/;
    #     $rv = shellwrap("/bin/mount /dev/$DEV$i /boot");
    # }
    exit $rv if $rv;
    ## if ($DISTVER == 3) {
    ##     $rv = shellwrap("/sbin/grub-install hd0");
    ##     exit $rv if $rv;
    ## } else {
        print "About to issue grub commands...\n";
        open GRUB, "|/sbin/grub --batch" or
            showmsg('fail', $!, 'Could not run grub:');
        $i--;
        print GRUB "root (hd0,$i)\n" or
            showmsg('fail', $!, "Could not issue command root (hd0,$i):");
        print GRUB "setup (hd0)\n" or
            showmsg('fail', $!, 'Could not issue command setup (hd0):');
        print GRUB "quit\n" or
            showmsg('fail', $!, 'Could not quit grub:');
        close GRUB or showmsg('fail', $!, 'Could not end grub commands:');
    ## }
    $rv = shellwrap("umount /boot");
    exit $rv if $rv;
}

sub sleeper($$) {
    my ($len, $msg) = @_;

    print $msg . "You have $len seconds to stop me: ";
    foreach (1 .. $len) {
        print '.';
        sleep 1;
    }
    print " Starting.\n";
}

sub readparts() {
    @curparts = ();
    open PF, '</proc/partitions' or
       showmsg('fail', $!, 'Could not open /proc/partitions:');
    while (<PF>) {
        chomp;
        if ($_ =~ /$DEV(\d+)/) {
            push @curparts, $1;
        }
    }
    close PF;
}

sub shellwrap($) {
    my $cmd = shift;
    print "Running `$cmd'... ";
    my $rv = system($cmd);
    my @name = split(/ /, $cmd);
    $cmd = shift @name;
    @name = split(/\//, $cmd);
    $cmd = pop @name;
    if ($rv < 0) {
        showmsg('fail', $!, "\nCould not execute $cmd:");
    } elsif ($rv & 127) {
        ## $msg .= " (core dumped)" if $rv & 128;
        showmsg('warn', $rv & 127, "\n$cmd killed by signal");
    } elsif ($rv) {
        $rv >>= 8;
        showmsg('warn', $rv, "\n$cmd returned");
    } else {
        showmsg('success', 'done');
    }
    return $rv;
}

sub runfdisk(@) {
    my @cmds = @_;
    # my $bad;

    print "About to issue fdisk commands...\n";
    print join(' ', @cmds, "\n");

    # foreach $DEV (qw(sda hda)) {
        # $bad = 0;
    open FDISK, "|/sbin/fdisk /dev/$DEV" or showmsg('fail', $!,
        'Could not open fdisk commands:');
    foreach (@cmds) {
        if (print FDISK "$_\n") {
            # showmsg('success', $_, 'fdisk command:');
        } else {
            showmsg('fail', $!, "Could not run command $_:");
        }
    }
    print FDISK "w\n" or showmsg('fail', $!, 'Could not send write to fdisk:');
    close FDISK or showmsg('fail', $!, 'Could not close fdisk commands:');
    # if (not $bad) {
    showmsg('success', 'done');
            # return;
        # }
    # }
}


# main

print "*** I have just booted. ***\n";

my @nics = ();
open NETDEV, "</proc/net/dev" or
    showmsg('fail', $!, 'Could not open /proc/net/dev for reading:');
foreach my $line (<NETDEV>) {
    next unless $line =~ /(eth[0-9]):/;
    push @nics, $1;
}
foreach my $nic (@nics) {
    open FOO, "/sbin/ifconfig $nic|" or
        showmsg('fail', $!, 'Could not run /sbin/ifconfig:');
    my $elem = <FOO>;
    while (<FOO>) { } # consume the rest of the output
    close FOO;
    my @tmp = split(' ', $elem);
    $elem = pop @tmp;
    #$elem =~ s/://g;
    $hwaddr{$nic} = lc $elem;
}

my $hostname = hostname();

print "My hardware address is $hwaddr{'eth0'} and my hostname is $hostname.\n";
readparts;

my $cmds;

open CFG, "</netboot.conf" or
    showmsg('fail', $!, "Could not open $NETBOOT_CONF:");
my $scenario = <CFG>;
showmsg('fail', $! ne '' ? $! : 'syntax error',
    "Insufficient information in $NETBOOT_CONF:") unless
    defined $scenario and $scenario ne '';

chomp $scenario;
showmsg('success', $scenario, "Will look for scenario information in:\n");

while (<CFG>) {
    chomp;
    next unless /^$hostname:(.*)/;
    $cmds = $1;
}
close CFG;

showmsg('fail', 'Stop.', "Commands not found in $NETBOOT_CONF -") unless
    defined $cmds;

showmsg('success', $cmds, 'My command string is');

my @toks = split //, $cmds;
my $start = shift @toks;

showmsg('success', $start, 'Starting at state');

# Undocumented state, suitable for emergencies.
if ($start eq 'Z') {
    showmsg('fail', 'Bailing out.');
}

open DMESG, "</var/log/dmesg" or
    showmsg('fail', $!, 'Could not open /var/log/dmesg:');
while (<DMESG>) {
    if ($_ =~ /Got DHCP answer from (\d+\.\d+\.\d+\.\d+)/) {
        $nbh = $1;
        last;
    }
}
close DMESG;
showmsg('fail', 'Stop.', 'Could not find netboot server. ') unless
    defined $nbh;

print "Mounting server with disk.conf ...\n" if 0;
$rv = shellwrap("/bin/mount $scenario/$hostname /mnt/di");
exit $rv if $rv;

open DCONF, "</mnt/di/control/disk.conf" or
    showmsg('fail', $!, 'Could not open disk.conf:');
while (<DCONF>) {
    chomp;
    my @items = split /,/;
    my $idx = shift @items;
    my ($start, $end) = split /-/, shift @items;
    my %h;
    $h{'start'} = $start;
    $h{'end'} = $end if defined $end;
    $h{'fstype'} = shift @items;
    if ($h{'fstype'} ne 'EXTENDED') {
        $h{'mountpoint'} = shift @items;
        $h{'fsopts'} = shift @items;
        $h{'source'} = shift @items;
    }
    $newpars{$idx} = \%h;
}
close DCONF;
@fsli = (keys %newpars);

if ($start == 0) {
    my $step = shift @toks;

    if ($step eq 'D') { # delete all partitions
        print "Deleting all partitions.\n";
    } elsif ($step eq 'W' or $step eq 'X') { # wipe entire disk
        print "Wiping disk";
        print " and halting" if $step eq 'X';
        print ".\n";
        $rv = shellwrap("$DD bs=65536 count=915705 of=/dev/$DEV");
        exit $rv if $rv;
        # $rv = shellwrap("/bin/touch /tmp/dd.done");
        # exit $rv if $rv;
        checkpoint($hostname, '0D') if $step eq 'W'; # transition from 0W to 0D
    }

    runfdisk(qw(o)) if $step ne 'R' and $step ne 'C';

    if ($step eq 'X') {
        checkpoint($hostname); # take it out of netbooting
        exec "/sbin/shutdown -h now" or
            showmsg('fail', $!, 'Could not shut down:');
    }

    if ($step ne 'R' and $step ne 'C') {
        @curparts = ();

        my $i;
        my @fcm = ();
        foreach $i (sort keys %newpars) {
            my $ft = lc $newpars{$i}{'fstype'};
            my $s = $newpars{$i}{'start'};
            my $e = $newpars{$i}{'end'};

            # Assume that partitions are contiguous
            # Assume there are always 4 primary partitions
            push @fcm, 'n'; # new
                if ($i < 5) {
                    if ($ft eq 'extended') { push @fcm, 'e'; }
                    else { push @fcm, 'p'; }
                    push @fcm, $i if $i != 4; # fdisk chooses 4 automatically
                }
            push @fcm, ''; # select default start cylinder
            if (defined $e and $e ne '') {
                push @fcm, sprintf("+%dM", $e - $s); # size in megs
            } else {
                push @fcm, '';
            }
            if ($ft eq 'swap') {
                push @fcm, 't';
                push @fcm, $i if $i > 1;
                push @fcm, 82;
            }
        }
        push @fcm, 'p';

        runfdisk(@fcm);

        my @parlist = (sort keys %newpars);
        for (my $wait = 0; $wait < 50; $wait++) {
            my @npl = ();
            foreach (@parlist) {
                if (open NONSENSE, "</dev/sda$_") {
                    close NONSENSE;
                    next;
                # } elsif (open NONSENSE, "</dev/hda$_") {
                #     close NONSENSE;
                #     next;
                } else {
                    push @npl, $_;
                }
            }
            last unless scalar @npl > 0;
            sleep 1;
            print "Still waiting for partitions: " .
                join('/', @npl) . " [$wait]\n";
        }

        checkpoint($hostname, '0R');
    }

    if ($step ne 'C') {
        foreach my $i (sort keys %newpars) {
            my $ft = lc $newpars{$i}{'fstype'};

            if ($ft eq 'ext2' or $ft eq 'ext3') {
                my $mp = $newpars{$i}{'mountpoint'};
                $rv = shellwrap("/sbin/mkfs.$ft -L $mp /dev/$DEV$i");
                # if ($rv) {
                #     $DEV =~ s/^s/h/;
                #     $rv = shellwrap("/sbin/mkfs.$ft -L $mp /dev/$DEV$i");
                # }
                exit $rv if $rv;
            } elsif ($ft eq 'swap') {
                $rv = shellwrap("/sbin/mkswap /dev/$DEV$i");
                if ($rv) {
                    $DEV =~ s/^s/h/;
                    $rv = shellwrap("/sbin/mkswap /dev/$DEV$i");
                }
                exit $rv if $rv;
            } else {
                print "Not placing a new fs on partition $i of type $ft.\n";
            }
        }
        checkpoint($hostname, '0C');
    }

    my $sl = '1C';
    my @parl = ();
    foreach (sort keys %newpars) {
        my $src = $newpars{$_}{'source'};
        next unless defined $src and $src ne '';

        $sl .= $_;
        push @parl, $_;
    }
    checkpoint($hostname, $sl);

    foreach my $i (sort keys %newpars) {
        my $src = $newpars{$i}{'source'};

        # now we have to lay new data down, since we torched the last set
        next unless defined $src and $src ne '';
        showmsg('success', "$src -> $DEV$i", 'Copying data:');
        $rv = shellwrap("/bin/mount /dev/$DEV$i /mnt/dc");
        # if ($rv) {
        #     $DEV =~ s/^s/h/;
        #     $rv = shellwrap("/bin/mount /dev/$DEV$i /mnt/dc");
        # }
        exit $rv if $rv;
        $src =~ s/\//:/; # convert to rsync path
        $rv = shellwrap("$RSYNC $src/ /mnt/dc");
        exit $rv if $rv;
        $rv = shellwrap("/bin/umount /mnt/dc");
        exit $rv if $rv;
        shift @parl;
        checkpoint($hostname, '1C' . join('', @parl));
    }

} elsif ($start == 1) {
    my $step;
    my $mode;
    my %pars = ();
    my %modes = (
        'W' => 'wipe', # dd the partition
        'R' => 'reformat', # newfs the partition
        'S' => 'sync', # synchronize (deleting unneeded files)
        # 'D' => 'delete', # delete the partition and readd - not useful
        'O' => 'overwrite', # overwrite existing files, no deletion though
        'C' => 'copy', # copy only - no overwrite, no delete
    );
    my %revmodes = (
        'wipe' => 'W',
        'reformat' => 'R',
        'sync' => 'S',
        'overwrite' => 'O',
        'copy' => 'C',
    );

    foreach $step (@toks) {
        if (defined $modes{$step}) {
            showmsg('success', $modes{$step}, 'Identified mode:');
            $mode = $modes{$step};
        } elsif (defined $mode and ($step =~ /^\d$/)) {
            showmsg('success', $step, "Applying $mode to partition");
            $pars{$step} = $mode;
        } else {
            showmsg('fail', $step, 'Undefined mode in stage 1:');
        }
    }

    my @opl = sort keys %pars;
    foreach $step (@opl) {
        next unless $pars{$step} eq 'wipe';
        $rv = shellwrap("$DD bs=512 of=/dev/$DEV$step");
        exit $rv if $rv;
        $pars{$step} = 'reformat';
        my $sl = '1';
        my $last = '';
        foreach (sort keys %pars) {
            $sl .= $revmodes{$pars{$_}} unless $last eq $revmodes{$pars{$_}};
            $last = $revmodes{$pars{$_}};
            $sl .= $_;
        }
        checkpoint($hostname, $sl);
    }

    # we're done with wiping now
    # if (open DDDONE, ">/tmp/dd.done") {
    #     close DDDONE;
    # } else {
    #     warn "Could not create /tmp/dd.done: $!\n";
    # }

    foreach $step (@opl) {
        next unless $pars{$step} eq 'reformat';
        my $t = $newpars{$step}{'fstype'};
        if ($t eq 'ext2' or $t eq 'ext3') {
            my $mp = $newpars{$step}{'mountpoint'};
            $rv = shellwrap("/sbin/mkfs.$t -L $mp /dev/$DEV$step");
            exit $rv if $rv;
            $pars{$step} = 'copy'; # can't copy other partition types
        } elsif ($t eq 'swap') {
            $rv = shellwrap("/sbin/mkswap /dev/$DEV$step");
            exit $rv if $rv;
            delete $pars{$step};
        } else {
            showmsg('warn', $t, "Refusing to newfs partition $step of type:");
        }
        my $sl = '1';
        my $last = '';
        foreach (sort keys %pars) {
            $sl .= $revmodes{$pars{$_}} unless $last eq $revmodes{$pars{$_}};
            $last = $revmodes{$pars{$_}};
            $sl .= $_;
        }
        checkpoint($hostname, $sl);
    }

    foreach $step (sort keys %pars) {
        my $ft = lc $newpars{$step}{'fstype'};
        my $src = $newpars{$step}{'source'};
                                
        shift @opl;
        next unless defined $src and $src ne ''; # skips swap, raw, and extended

        my $cmd = $RSYNC;
        my $act;
        if ($pars{$step} eq 'copy') {
            $cmd .= ' -u';
            $act = 'Copying';
        } elsif ($pars{$step} eq 'sync') {
            $cmd .= ' --delete --delete-excluded --force';
            $act = 'Synchronizing';
        } elsif ($pars{$step} eq 'overwrite') {
            # nothing else needed
            $act = 'Overwriting changed';
        } else {
            showmsg('fail', $step, 'Cannot act on partition');
        }
        $src =~ s/\//:/; # convert to rsync path
        $cmd .= " $src/ /mnt/dc";

        showmsg('success', "$src -> $DEV$step", "$act data:");
        $rv = shellwrap("/bin/mount /dev/$DEV$step /mnt/dc");
        # if ($rv) {
        #     $DEV =~ s/^s/h/;
        #     $rv = shellwrap("/bin/mount /dev/$DEV$step /mnt/dc");
        # }
        exit $rv if $rv;
        $rv = shellwrap($cmd);
        exit $rv if $rv;
        $rv = shellwrap("/bin/umount /mnt/dc");
        exit $rv if $rv;

        my $sl = '1';
        my $last = '';
        foreach (@opl) {
            $sl .= $revmodes{$pars{$_}} unless $last eq $revmodes{$pars{$_}};
            $last = $revmodes{$pars{$_}};
            $sl .= $_;
        }
        checkpoint($hostname, $sl);
    }
}

checkpoint($hostname, '2'); # We've done all of the prep work.

# do rotation through mount points

foreach my $i (sort keys %newpars) {
    my $src = $newpars{$i}{'source'};
    next unless defined $newpars{$i}{'mountpoint'};
    if ($newpars{$i}{'mountpoint'} eq '/') { # assume /etc is on /
        $rv = shellwrap("/bin/mount /dev/$DEV$i /mnt/dc");
        # if ($rv) {
        #     $DEV =~ s/^s/h/;
        #     $rv = shellwrap("/bin/mount /dev/$DEV$i /mnt/dc");
        # }
        exit $rv if $rv;
        fixfstab($i);
        fixsyscfg($hostname);
        $rv = shellwrap("/bin/umount /mnt/dc");
        exit $rv if $rv;
    } elsif ($newpars{$i}{'mountpoint'} eq '/boot') {
        showmsg('success', "/dev/$DEV$i", 'Adding GRUB configuration for:');
        fixgrub($i);
    }
}

# Now sync with root_base_1
my @inter = ();
foreach (keys %newpars) {
    push @inter, $_ if defined $newpars{$_}{'mountpoint'} and
        $newpars{$_}{'mountpoint'} ne '' and
        $newpars{$_}{'mountpoint'} ne 'swap';
}
my @tree = sort {
    $newpars{$a}{'mountpoint'} cmp $newpars{$b}{'mountpoint'}
} @inter;
foreach (@tree) {
    $rv = shellwrap("/bin/mount /dev/$DEV$_ /mnt/dc" .
        $newpars{$_}{'mountpoint'});
    if ($rv) {
        $DEV =~ s/^s/h/;
        $rv = shellwrap("/bin/mount /dev/$DEV$_ /mnt/dc" .
            $newpars{$_}{'mountpoint'});
    }
    exit $rv if $rv;
}

showmsg('success', "$scenario/$hostname/root_base_1/",
    'Now synchronizing with:');
$rv = shellwrap("$RSYNC /mnt/di/root_base_1/ /mnt/dc");
exit $rv if $rv;

print "Activating SELinux system relabelling on next boot...\n";
$rv = shellwrap("/bin/touch /mnt/dc/.autorelabel");
exit $rv if $rv;

while (scalar @tree) {
    my $remove = pop @tree;
    $rv = shellwrap("/bin/umount /mnt/dc" . $newpars{$remove}{'mountpoint'});
    exit $rv if $rv;
}

print "Unmounting server with disk.conf ...\n";
$rv = shellwrap("/bin/umount /mnt/di");
exit $rv if $rv;

checkpoint($hostname); # take us out of netbooting

print "Getting ready to reboot...\n";

showmsg('success', '[Netbooting completed successfully.]');

exit 0;
