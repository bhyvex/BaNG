package BaNG::BackupServer;

use 5.010;
use strict;
use warnings;
use BaNG::Config;
use BaNG::Converter;
use BaNG::RemoteCommand;
use BaNG::Reporting;
use BaNG::BTRFS;
use Date::Parse;
use POSIX qw( floor );
use Net::Ping;
use YAML::Tiny qw( LoadFile );

use Exporter 'import';
our @EXPORT = qw(
    get_fsinfo
    get_lockfiles
    get_backup_folders
    check_client_connection
    get_automount_paths
    check_target_exists
    create_lockfile
    remove_lockfile
    check_lockfile
    writeto_lockfile
);

sub get_fsinfo {
    my %fsinfo;
    foreach my $server ( keys %servers ) {
        my @mounts = remote_command( $server, 'BaNG/bang_df' );

        foreach my $mount (@mounts) {
            $mount =~ qr{
                ^(?<filesystem> [\/\w\d-]+)
                \s+(?<fstyp> [\w\d]+)
                \s+(?<blocks> [\d]+)
                \s+(?<used> [\d]+)
                \s+(?<available>[\d]+)
                \s+(?<usedper> [\d]+)
                .\s+(?<mountpt> [\/\w\d-]+)
            }x;

            $fsinfo{$server}{$+{mountpt}} = {
                filesystem => $+{filesystem},
                mount      => $+{mountpt},
                fstyp      => $+{fstyp},
                blocks     => num2human( $+{blocks} ),
                used       => num2human( $+{used} * 1024, 1024 ),
                available  => num2human( $+{available} * 1024, 1024 ),
                freediff   => '',
                rwstatus   => '',
                used_per   => $+{usedper},
                css_class  => _check_fill_level( $+{usedper} ),
            };
        }

        @mounts = remote_command( $server, 'BaNG/procmounts' );
        foreach my $mount (@mounts) {
            $mount =~ qr{
                ^(?<device>[\/\w\d-]+)
                \s+(?<mountpt>[\/\w\d-]+)
                \s+(?<fstyp>[\w\d]+)
                \s+(?<mountopt>[\w\d\,\=\/]+)
                \s+(?<dump>[\d]+)
                \s+(?<pass>[\d]+)$
            }x;

            my $mountpt  = $+{mountpt};
            my $mountopt = $+{mountopt};

            $fsinfo{$server}{$mountpt}{rwstatus} = 'check_red' if $mountopt =~ /ro/;
        }

        if ( $server eq $servername ) {
            @mounts = remote_command( $server, 'BaNG/bang_di' );
            foreach my $mount (@mounts) {
                $mount =~ qr{
                    ^(?<filesystem> [\/\w\d-]+)
                    \s+(?<fstyp>[\w\d]+)
                    \s+(?<blocks>[\d]+)
                    \s+(?<used>[\d]+)
                    \s+(?<available>[\d]+)
                    \s+(?<free>[\d]+)
                    \s+(?<usedper>[\d]+)
                    .\s+(?<mountpt>[\/\w\d-]+)
                }x;

                my $freediff    = $+{free} - $+{available};
                my $freediffper = 100 / $+{free} * $freediff;

                $fsinfo{$server}{$+{mountpt}}{freediff} = ( $freediffper > 10 ) ? num2human( $freediff * 1024, 1024 ) : '';
            }
        }
    }

    return \%fsinfo;
}

sub _check_fill_level {
    my ($level) = @_;
    my $css_class = '';

    if ( $level > 98 ) {
        $css_class = 'alert_red';
    } elsif ( $level > 90 ) {
        $css_class = 'alert_orange';
    } elsif ( $level > 80 ) {
        $css_class = 'alert_yellow';
    }

    return $css_class;
}

sub check_client_connection {
    my ( $host, $gwhost ) = @_;

    my $state = 0;
    my $msg   = 'Host offline';
    my $p     = Net::Ping->new( 'tcp', 2 );

    if ( $p->ping($host) ) {
        $state = 1;
        $msg   = 'Host online';
    } elsif ($gwhost) {
        $state = 1;
        $msg   = 'Host not pingable because behind a Gateway-Host';
    }
    $p->close();

    return $state, $msg;
}

sub get_backup_folders {
    my ( $host, $group, $folder_type ) = @_;
    $folder_type ||= 0;
    my $bkpdir = targetpath( $host, $group );
    my $server = $hosts{"$host-$group"}{hostconfig}{BKP_TARGET_HOST};
    my @backup_folders;

    my $REGEX = "[0-9\./_]*";                                           # default, show all good folders
    $REGEX    = ".*_failed" if $folder_type == 1;                       # show all *_failed folders
    $REGEX    = "\\([0-9\./_]*\\|.*_failed\$\\)" if $folder_type == 2;  # show all folders, except "current" folder

    if ( $server eq $servername ) {
        @backup_folders = `find $bkpdir -mindepth 1 -maxdepth 1 -type d -regex '${bkpdir}/$REGEX' 2>/dev/null`;
    } else {
        @backup_folders = remote_command( $server, 'BaNG/bang_getBackupFolders', $bkpdir );
    }
    return @backup_folders;
}

sub check_target_exists {
    my ( $host, $group, $taskid, $create ) = @_;
    my $return_code = 0;
    $taskid ||= 0;
    $create ||= 0;

    my $rsync_target = targetpath( $host, $group );

    print "DEBUG: Check if target $rsync_target available...\n" if $serverconfig{verboselevel} == 3;
    if ( !-d $rsync_target ) {
        $return_code = 1;
        print "DEBUG: Target folder $rsync_target does not exists!\n" if $serverconfig{verboselevel} == 3;
        if ( $create ) {
            print "DEBUG: Creating target folder $rsync_target!\n" if $serverconfig{verboselevel} == 3;
            system("mkdir -p $rsync_target") unless $serverconfig{dryrun};
            $return_code = 0;
        }
    }
    if ( $hosts{"$host-$group"}->{hostconfig}->{BKP_STORE_MODUS} eq 'snapshots' ) {
        $rsync_target .= '/current';

        if ( !-d $rsync_target ) {
            print "DEBUG: Target subvolume $rsync_target does not exists!\n" if $serverconfig{verboselevel} == 3;
            $return_code = 1;
            if ( $create ) {
                print "DEBUG: Creating target subvolume $rsync_target!\n" if $serverconfig{verboselevel} == 3;
                create_btrfs_subvolume( $host, $group, $rsync_target, $taskid );
                $return_code = 0;
            }
        }
    }

    print "DEBUG: Target $rsync_target available!\n" if $serverconfig{verboselevel} == 3 and $return_code == 0;
    return $return_code;
}

sub get_automount_paths {
    my ($ypfile) = @_;
    $ypfile ||= 'auto.backup';

    my %automnt;

    if ( $serverconfig{path_ypcat} && -e $serverconfig{path_ypcat} ) {

        my @autfstbl = `$serverconfig{path_ypcat} -k $ypfile`;

        foreach my $line (@autfstbl) {
            if (
                $line =~ qr{
                (?<parentfolder>[^\s]*) \s*
                \-fstype\=autofs \s*
                yp\:(?<ypfile>.*)
                }x
                )
            {
                # recursively read included yp files
                my $parentfolder = $+{parentfolder};
                my $submounts    = get_automount_paths( $+{ypfile} );
                foreach my $mountpt ( keys %{$submounts} ) {
                    $automnt{$mountpt} = {
                        server => $submounts->{$mountpt}->{server},
                        path   => "$parentfolder/$submounts->{$mountpt}->{path}",
                    };
                }
            } elsif (
                $line =~ qr{
                (?<mountpt>[^\s]*) \s
                (?<server>[^\:]*) :
                (?<mountpath>.*)
                }x
                )
            {
                $automnt{$+{mountpath}} = {
                    server => $+{server},
                    path   => $+{mountpt},
                };
            }
        }
    }

    return \%automnt;
}

#################################
# Lockfile
#
sub lockfile {
    my ( $host, $group, $path ) = @_;

    $path =~ s/^://g;
    $path =~ s/\s:/\+/g;
    $path =~ s/\//%/g;
    my $lockfilename = "${host}_${group}_${path}";
    my $lockfile     = "$serverconfig{path_lockfiles}/$lockfilename.lock";

    return $lockfile;
}

sub create_lockfile {
    my ( $taskid, $host, $group, $path ) = @_;

    my $lockfile = lockfile( $host, $group, $path );

    if ( -e $lockfile ) {
        my @processes = `ps aux | grep -v grep | grep '$host' | grep '$path' | awk '{print \$2}'`;
        if ( @processes ) {
            logit( $taskid, $host, $group, "ERROR: lockfile $lockfile still exists" );
            logit( $taskid, $host, $group, 'ERROR: Backup canceled, still running backup!' );
            exit 0;
        }
    }

    logit( $taskid, $host, $group, "Created lockfile $lockfile" );
    writeto_lockfile( $taskid, $host, $group, $path, "taskid", $taskid);

    return 1;
}

sub remove_lockfile {
    my ( $taskid, $host, $group, $path ) = @_;

    my $lockfile = lockfile( $host, $group, $path );
    unlink $lockfile unless $serverconfig{dryrun};
    logit( $taskid, $host, $group, "Removed lockfile $lockfile" );

    return 1;
}

sub split_lockfile_name {
    my ($lockfile) = @_;
    my ( $host, $group, $path, $timestamp ) = $lockfile =~ /^([\w\d\.-]+)_([\w\d-]+)_(.*)\.lock (.*)/;
    my $file = "${host}_${group}_${path}.lock";

    $path =~ s/%/\//g;
    $path =~ s/\'//g;
    $path =~ s/\+/ :/g;
    $path =~ s/^\//:\//g;

    return $host, $group, $path, $timestamp, $file;
}

sub check_lockfile {
    my ( $taskid, $host, $group ) = @_;

    my @lockfiles;
    my $ffr_obj = File::Find::Rule->file()
                                  ->name("${host}_${group}_*.lock")
                                  ->relative
                                  ->maxdepth(1)
                                  ->start($serverconfig{path_lockfiles});

    while ( my $lockfile = $ffr_obj->match() ) {
        push( @lockfiles, $lockfile );
    }

    logit( $taskid, $host, $group, "Check for running backup tasks" );

    if ( $#lockfiles > -1 ) {
        logit( $taskid, $host, $group, 'ERROR: Wipe canceled, still ' . ( $#lockfiles + 1 ) . ' running backup!' );
        return 0;
    }

    return 1;
}

sub get_lockfiles {
    my %lockfiles;

    foreach my $server ( keys %servers ) {
        my @lockfiles = remote_command( $server, 'BaNG/bang_getLockFile', $serverconfig{path_lockfiles} );

        foreach my $lockfile (@lockfiles) {
            my ( $host, $group, $path, $timestamp, $file ) = split_lockfile_name($lockfile);
            my $ids    = LoadFile( "$serverconfig{path_lockfiles}/$file" );
            my $taskid = $ids->{taskid} || '';
            my $shpid  = $ids->{shpid} || '';

            $lockfiles{$server}{"$host-$group-$path"} = {
                taskid    => $taskid,
                host      => $host,
                group     => $group,
                path      => $path,
                shpid     => $shpid,
                timestamp => $timestamp,
            };
        }
    }

    return \%lockfiles;
}

sub writeto_lockfile {
    my ( $taskid, $host, $group, $path, $key, $value ) = @_;
    my $lockfile = lockfile( $host, $group, $path );

    unless ( $serverconfig{dryrun} ) {
        system("echo \"$key: $value\" >> \"$lockfile\"");
    }
    logit( $taskid, $host, $group, "Write to lockfile $lockfile -- $key: $value" ) if $serverconfig{verbose};
}

1;