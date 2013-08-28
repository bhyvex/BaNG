package BaNG::Reporting;

use 5.010;
use strict;
use warnings;
use BaNG::Common;
use BaNG::Config;
use DBI;
use Date::Parse;
use IO::Socket;
use MIME::Lite;
use POSIX qw( strftime );
use Template;
use YAML::Tiny;

use Exporter 'import';
our @EXPORT = qw(
    $bangstat_dbh
    bangstat_db_connect
    bangstat_set_jobstatus
    bangstat_recentbackups
    bangstat_recentbackups_all
    bangstat_recentbackups_last
    send_hobbit_report
    db_report
    mail_report
    hobbit_report
    logit
    read_log
    error404
);

our %serverconfig;
our $bangstat_dbh;

sub bangstat_db_connect {
    my ($ConfigBangstat) = @_;

    my $yaml = YAML::Tiny->read($ConfigBangstat);
    my $DBhostname = $yaml->[0]{DBhostname};
    my $DBusername = $yaml->[0]{DBusername};
    my $DBdatabase = $yaml->[0]{DBdatabase};
    my $DBpassword = $yaml->[0]{DBpassword};

    $bangstat_dbh = DBI->connect(
        "DBI:mysql:database=$DBdatabase:host=$DBhostname:port=3306", $DBusername, $DBpassword,
        { PrintError => 0 }
    );

    return 0 unless $bangstat_dbh;
    return 1;
}

sub bangstat_set_jobstatus {
    my ($taskid, $jobid, $host, $group, $lastbkp, $status) = @_;

    my $SQL = qq(
        UPDATE statistic
        SET JobStatus = '$status'
        WHERE BkpFromHost = '$host'
        AND BkpGroup = '$group'
        AND JobID = '$jobid';
    );

    my $conn = bangstat_db_connect( $serverconfig{config_bangstat} );
    if ( !$conn ) {
        logit( $taskid, $host, $group, "ERROR: Could not connect to DB to set jobstatus to $status for host $host group $group" );
        return 1;
    }

    my $sth = $bangstat_dbh->prepare($SQL);
    $sth->execute() unless $serverconfig{dryrun};
    $sth->finish();

    $SQL =~ s/;.*/;/sg;
    logit( $taskid, $host, $group, "Set jobstatus SQL command: $SQL" ) if ( $serverconfig{debug} && $serverconfig{debuglevel} >= 2 );
    logit( $taskid, $host, $group, "Set jobstatus to $status for host $host group $group" );

    return 1;
}

sub bangstat_recentbackups {
    my ($host, $lastXdays) = @_;

    $lastXdays ||= 5;
    my $BkpStartHour = 18;

    my $conn = bangstat_db_connect( $serverconfig{config_bangstat} );
    return () unless $conn;

    my $sth = $bangstat_dbh->prepare("
        SELECT *, TIMESTAMPDIFF(Minute, Start , Stop) as Runtime
        FROM recent_backups
        WHERE Start > date_sub(concat(curdate(),' $BkpStartHour:00:00'), interval $lastXdays day)
        AND BkpFromHost like '$host'
        ORDER BY BkpGroup, Start DESC;
    ");
    $sth->execute();

    my %RecentBackups;
    my %RecentBackupTimes;
    while ( my $dbrow = $sth->fetchrow_hashref() ) {
        my $BkpGroup = $dbrow->{'BkpGroup'} || 'NA';
        my $BkpFromPath = $dbrow->{'BkpFromPath'};
        $BkpFromPath =~ s/^:$/:\//g;
        push( @{$RecentBackups{"$host-$BkpGroup"}}, {
            TaskID      => $dbrow->{'TaskID'},
            JobID       => $dbrow->{'JobID'},
            Starttime   => $dbrow->{'Start'},
            Stoptime    => $dbrow->{'Stop'},
            Runtime     => &BaNG::Common::time2human($dbrow->{'Runtime'}),
            BkpFromPath => $BkpFromPath,
            BkpToPath   => $dbrow->{'BkpToPath'} ,
            isThread    => $dbrow->{'isThread'},
            LastBkp     => $dbrow->{'LastBkp'},
            ErrStatus   => $dbrow->{'ErrStatus'},
            JobStatus   => $dbrow->{'JobStatus'},
            BkpGroup    => $BkpGroup,
            BkpHost     => $dbrow->{'BkpFromHost'},
            FilesTrans  => &BaNG::Common::num2human($dbrow->{'NumOfFilesTrans'}),
            SizeTrans   => &BaNG::Common::num2human($dbrow->{'TotFileSizeTrans'},1024),
        });
        push( @{$RecentBackupTimes{"$host-$dbrow->{'BkpFromPath'}"}}, {
            TaskID      => $dbrow->{'TaskID'},
            JobID       => $dbrow->{'JobID'},
            Starttime   => $dbrow->{'Start'},
            BkpFromPath => $dbrow->{'BkpFromPath'},
            BkpToPath   => $dbrow->{'BkpToPath'},
            Host        => $host,
            BkpGroup    => $BkpGroup,
        });
    }
    $sth->finish();

    # scan for missing backups
    my $now     = time;
    my $today   = `$serverconfig{path_date} -d \@$now +"%Y-%m-%d"`;
    my $tonight = str2time("$today $BkpStartHour:00:00");
    foreach my $hostpath ( keys %RecentBackupTimes ) {
        my $thatnight = $tonight;
        my @bkp = @{$RecentBackupTimes{$hostpath}};
        my $missingBkpFromPath = $bkp[0]->{BkpFromPath} || 'NA';
        my $missingBkpToPath   = $bkp[0]->{BkpToPath}   || 'NA';
        my $missingBkpGroup    = $bkp[0]->{BkpGroup}    || 'NA';
        my $missingHost        = $bkp[0]->{Host}        || 'NA';

        foreach my $Xdays ( 1 .. $lastXdays ) {
            my $isMissing = 0;

            if ( !@bkp ) {
                # a backup is missing if list is already empty
                $isMissing = 1;
            } else {
                # or if no backup occured during that day
                my $latestbkp = str2time( $bkp[0]->{Starttime} );
                unless ( $latestbkp > $thatnight - 24*3600
                      && $latestbkp < $thatnight ) {
                    $isMissing = 1;
                }
            }

            if ( $isMissing ) {
                # add empty entry for missing backups
                my $missingepoch = $thatnight - 24 * 3600;
                my $missingday   = `$serverconfig{path_date} -d \@$missingepoch +"%Y-%m-%d"`;
                my $nobkp = {
                    Starttime   => $missingday,
                    Stoptime    => '',
                    Runtime     => '',
                    BkpFromPath => $missingBkpFromPath,
                    BkpToPath   => $missingBkpToPath,
                    isThread    => '',
                    LastBkp     => '',
                    ErrStatus   => 99,
                    BkpGroup    => $missingBkpGroup,
                };
                splice( @{$RecentBackups{"$missingHost-$missingBkpGroup"}}, $Xdays - 1, 0, $nobkp );
            } else {
                # remove successful backups of that day from list
                while ( @bkp && str2time( $bkp[0]->{Starttime} ) > $thatnight - 24 * 3600 ) {
                    shift @bkp;
                }
            }
            # then look at previous day
            $thatnight -= 24 * 3600;
        }
    }

    return %RecentBackups;
}

sub bangstat_recentbackups_all {
    my ($lastXhours) = @_;
    $lastXhours ||= 24;

    my $conn = bangstat_db_connect( $serverconfig{config_bangstat} );
    return '' unless $conn;

    my $sth = $bangstat_dbh->prepare("
        SELECT *, TIMESTAMPDIFF(Minute, Start , Stop) as Runtime
        FROM recent_backups
        WHERE Start > date_sub(NOW(), INTERVAL $lastXhours HOUR)
        AND BkpFromHost like '%'
        AND JobID IN (
            SELECT MAX(JobID)
            FROM recent_backups AS G
            WHERE G.bkpfromhost = recent_backups.bkpfromhost
            AND Start > DATE_SUB(NOW(), INTERVAL $lastXhours HOUR)
            GROUP BY G.bkpfromhost, G.bkpgroup)
        ORDER BY JobStatus, Start DESC;
    ");
    $sth->execute();

    my %RecentBackupsAll;
    while ( my $dbrow = $sth->fetchrow_hashref() ) {
        my $BkpFromPath = $dbrow->{'BkpFromPath'};
        $BkpFromPath =~ s/^:$/:\//g;
        push( @{$RecentBackupsAll{'Data'}}, {
            TaskID      => $dbrow->{'TaskID'},
            JobID       => $dbrow->{'JobID'},
            Starttime   => $dbrow->{'Start'},
            Stoptime    => $dbrow->{'Stop'},
            Runtime     => &BaNG::Common::time2human($dbrow->{'Runtime'}),
            BkpFromPath => $BkpFromPath ,
            BkpToPath   => $dbrow->{'BkpToPath'},
            isThread    => $dbrow->{'isThread'},
            LastBkp     => $dbrow->{'LastBkp'},
            ErrStatus   => $dbrow->{'ErrStatus'},
            JobStatus   => $dbrow->{'JobStatus'},
            BkpGroup    => $dbrow->{'BkpGroup'} || 'NA',
            BkpHost     => $dbrow->{'BkpFromHost'},
            BkpToHost   => $dbrow->{'BkpToHost'},
            FilesTrans  => &BaNG::Common::num2human($dbrow->{'NumOfFilesTrans'}),
            SizeTrans   => &BaNG::Common::num2human($dbrow->{'TotFileSizeTrans'},1024),
        });
    }
    $sth->finish();

    return \%RecentBackupsAll;
}

sub bangstat_recentbackups_last {
    my ($lastXhours) = @_;
    $lastXhours ||= 24;

    my $conn = bangstat_db_connect( $serverconfig{config_bangstat} );
    return '' unless $conn;

    my $sth = $bangstat_dbh->prepare("
        SELECT *, TIMESTAMPDIFF(Minute, Start , Stop) as Runtime
        FROM recent_backups
        WHERE Start > date_sub(NOW(), INTERVAL $lastXhours HOUR)
        AND BkpFromHost like '%'
        ORDER BY Start DESC;
    ");
    $sth->execute();

    my %RecentBackupsLast;
    while ( my $dbrow = $sth->fetchrow_hashref() ) {
        my $BkpFromPath = $dbrow->{'BkpFromPath'};
        $BkpFromPath =~ s/^:$/:\//g;
        push( @{$RecentBackupsLast{'Data'}}, {
            TaskID      => $dbrow->{'TaskID'},
            JobID       => $dbrow->{'JobID'},
            Starttime   => $dbrow->{'Start'},
            Stoptime    => $dbrow->{'Stop'},
            Runtime     => &BaNG::Common::time2human($dbrow->{'Runtime'}),
            BkpFromPath => $BkpFromPath ,
            BkpToPath   => $dbrow->{'BkpToPath'},
            isThread    => $dbrow->{'isThread'},
            LastBkp     => $dbrow->{'LastBkp'},
            ErrStatus   => $dbrow->{'ErrStatus'},
            JobStatus   => $dbrow->{'JobStatus'},
            BkpGroup    => $dbrow->{'BkpGroup'} || 'NA',
            BkpHost     => $dbrow->{'BkpFromHost'},
            BkpToHost   => $dbrow->{'BkpToHost'},
            FilesTrans  => &BaNG::Common::num2human($dbrow->{'NumOfFilesTrans'}),
            SizeTrans   => &BaNG::Common::num2human($dbrow->{'TotFileSizeTrans'},1024),
        });
    }
    $sth->finish();

    return \%RecentBackupsLast;
}

sub send_hobbit_report {
    my ($report) = @_;

    my $socket = IO::Socket::INET->new(
        PeerAddr => 'hobbit.phys.ethz.ch',
        PeerPort => '1984',
        Proto    => 'tcp',
    );

    if ( defined $socket and $socket != 0 ) {
        $socket->print("$report");
        $socket->close();
    }

    return 1;
}

sub db_report {
    my ($taskid, $jobid, $host, $group, $startstamp, $endstamp, $path, $targetpath, $lastbkp, $errcode, $jobstatus, @outlines) = @_;

    my %parse_log_keys = (
        'last backup'                 => 'LastBkp',
        'Number of files'             => 'NumOfFiles',
        'Number of files transferred' => 'NumOfFilesTrans',
        'Total file size'             => 'TotFileSize',
        'Total transferred file size' => 'TotFileSizeTrans',
        'Literal data'                => 'LitData',
        'Matched data'                => 'MatchData',
        'File list size'              => 'FileListSize',
        'File list generation time'   => 'FileListGenTime',
        'File list transfer time'     => 'FileListTransTime',
        'Total bytes sent'            => 'TotBytesSent',
        'Total bytes received'        => 'TotBytesRcv',
    );

    my %log_values;
    foreach my $logkey ( keys %parse_log_keys ) {
        $log_values{$parse_log_keys{$logkey}} = 'NULL';
    }

    foreach my $outline (@outlines) {
        next unless $outline =~ m/:/;
        chomp $outline;
        my ($key, $value) = split( ': ', $outline );
        foreach my $logkey ( keys %parse_log_keys ) {
            if ( $logkey eq $key ) {
                $value =~ s/^\D*([\d.]+).*?$/$1/;
                $log_values{$parse_log_keys{$logkey}} = $value;
            }
        }
    }

    $path =~ s/'//g;    # rm quotes to avoid errors in sql syntax
    my $isSubfolderThread = $hosts{"$host-$group"}->{hostconfig}->{BKP_THREAD_SUBFOLDERS} ? 'true' : 'NULL';

    my $sql;
    $sql .= "INSERT INTO statistic (";
    $sql .= " TaskID, JobID, BkpFromHost, BkpGroup, BkpFromPath, BkpToHost, BkpToPath, LastBkp, isThread, ErrStatus, JobStatus, Start, Stop, ";
    $sql .= " NumOfFiles, NumOfFilesTrans, TotFileSize, TotFileSizeTrans, LitData, MatchData, ";
    $sql .= " FileListSize, FileListGenTime, FileListTransTime, TotBytesSent, TotBytesRcv ";
    $sql .= ") VALUES (";
    $sql .= "'$taskid', '$jobid', '$host', '$group', '$path', '$servername', '$targetpath', '$lastbkp', ";
    $sql .= " $isSubfolderThread , '$errcode', '$jobstatus', FROM_UNIXTIME('$startstamp'), FROM_UNIXTIME('$endstamp'), ";
    $sql .= "'$log_values{NumOfFiles}'  , '$log_values{NumOfFilesTrans}', ";
    $sql .= "'$log_values{TotFileSize}' , '$log_values{TotFileSizeTrans}', ";
    $sql .= "'$log_values{LitData}'     , '$log_values{MatchData}', ";
    $sql .= "'$log_values{FileListSize}', '$log_values{FileListGenTime}', '$log_values{FileListTransTime}', ";
    $sql .= "'$log_values{TotBytesSent}', '$log_values{TotBytesRcv}' ";
    $sql .= ")";
    logit( $taskid, $host, $group, "DB Report SQL command: $sql" ) if ( $serverconfig{debuglevel} >= 2 );

    my $conn = bangstat_db_connect( $serverconfig{config_bangstat} );
    if ( !$conn ) {
        logit( $taskid, $host, $group, "ERROR: Could not connect to DB to send bangstat report." );
        return 1;
    }

    my $sth = $bangstat_dbh->prepare($sql);
    $sth->execute() unless $serverconfig{dryrun};
    $sth->finish();
    $bangstat_dbh->disconnect;

    logit( $taskid, $host, $group, "Bangstat report sent." );

    return 1;
}

sub mail_report {
    my ($taskid, $host, $group, %RecentBackups) = @_;

    my $status = $hosts{"$host-$group"}->{errormsg} ? 'warnings' : 'success';

    my $RecentBackups = {
        RecentBackups => \%RecentBackups,
        Group         => "$host-$group",
        Errormsg      => $hosts{"$host-$group"}->{errormsg},
    };

    my $tt = Template->new(
        START_TAG    => '<%',
        END_TAG      => '%>',
        INCLUDE_PATH => "$prefix/views",
    );

    my $mail_msg = MIME::Lite->new(
        From    => 'root@phys.ethz.ch',
        To      => $serverconfig{report_to},
        Type    => 'multipart/alternative',
        Subject => "Backup report of ($host-$group): $status",
    );

    foreach my $mailtype (qw(plain html)) {
        my $report;
        $tt->process( "report-mail_$mailtype.tt", $RecentBackups, \$report )
            or logit( $taskid, $host, $group, "ERROR generating mail report template: " . $tt->error() );

        my $mail_att = MIME::Lite->new(
            Type     => 'text',
            Data     => $report,
            Encoding => 'quoted-printable',
        );
        $mail_att->attr( 'content-type' => "text/$mailtype; charset=UTF-8" );
        $mail_msg->attach($mail_att);
    }

    unless ( $serverconfig{dryrun} ) {
        $mail_msg->send or logit( $taskid, $host, $group, "mail_report error" );
    }

    logit( $taskid, $host, $group, "Mail report sent." );

    return 1;
}

sub hobbit_report {
    my ($taskid, $host, $group, %RecentBackups)  = @_;

    my $topcolor = 'green';
    my $errcode;
    foreach my $key ( keys %RecentBackups ) {
        $errcode = $RecentBackups{$key}[0]{ErrStatus};
        my @errorcodes = split( ',', $errcode );
        foreach my $code (@errorcodes) {
            next if $code eq '0';     # no errors
            next if $code eq '24';    # vanished source files
            next if $code eq '99';    # no last_bkp
            if ( $code eq '23' ) {
                $topcolor = 'yellow'; # partial transfer
                next;
            }
            $topcolor = 'red';
        }
    }
    $topcolor = 'yellow' unless %RecentBackups;

    my $RecentBackups = {
        RecentBackups  => \%RecentBackups,
        Group          => "$host-$group",
        HobbitTopColor => $topcolor,
        Errormsg       => $hosts{"$host-$group"}->{errormsg},
    };

    my $STATUSTTL = 2160;     # (2160=>1.5d) Time in min until page becomes purple
    my $DATE      = `$serverconfig{path_date}`;
    chomp $DATE;

    my $hobbitreport = "status+$STATUSTTL $host.bkp $topcolor $DATE (TTL=$STATUSTTL min)\n";

    my $tt = Template->new(
        START_TAG    => '<%',
        END_TAG      => '%>',
        INCLUDE_PATH => "$prefix/views",
    );
    my $report;
    $tt->process( 'report-hobbit.tt', $RecentBackups, \$report )
        or logit( $taskid, $host, $group, "ERROR generating hobbit report template: " . $tt->error() );
    $hobbitreport .= $report;

    send_hobbit_report($hobbitreport) unless $serverconfig{dryrun};
    logit( $taskid, $host, $group, "Hobbit report sent." );

    return 1;
}

sub logit {
    my ($taskid, $host, $group, $msg) = @_;

    my $timestamp  = strftime "%b %d %H:%M:%S", localtime;
    my $logmonth   = strftime "%Y-%m", localtime;
    my $logdate    = strftime $serverconfig{global_log_date}, localtime;
    my $logfolder  = "$serverconfig{path_logs}/${host}_${group}";
    my $globallogfile = "$serverconfig{path_logs}/global_$logmonth.log";
    my $logfile    = "$logfolder/$logdate.log";
    my $logmessage = "$timestamp $host-$group($taskid) : $msg";
    $logmessage   .= "\n" unless ( $logmessage =~ m/\n$/ );

    print $logmessage if $serverconfig{debug};

    unless ( $serverconfig{dryrun} ) {
        # write into daily logfile per host_group
        mkdir($logfolder) unless -d $logfolder;
        open my $log, ">>", $logfile or print "ERROR opening logfile $logfile: $!\n";
        print {$log} $logmessage;
        close $log;

        # write selection of messages to global logfile
        my $selection = qr{
            Queueing \s backup \s for |
            Backup \s successful |
            ERROR |
            Wipe \s host |
            Wipe \s existing |
            Wipe \s successful |
            Delete \s btrfs \s subvolume
        }x;
        if ( $logmessage =~ /$selection/ ) {
            open my $log, ">>", $globallogfile or print "ERROR opening logfile $globallogfile: $!\n";
            print {$log} $logmessage;
            close $log;
        }
    }

    if ( $logmessage =~ /warn|error/i ) {
        $hosts{"$host-$group"}{errormsg} .= $logmessage;
    }

    return 1;
}

sub read_log {
    my ($host, $group, $show_logs_number) = @_;

    my %parsed_logdata;
    my $logfolder = "$serverconfig{path_logs}/${host}_${group}";
    my @logfiles  = glob("$logfolder/*.log");
    $show_logs_number = $#logfiles + 1 if ( $#logfiles < $show_logs_number );

    foreach my $logfile (@logfiles[-$show_logs_number..-1]) {
        open(LOGDATA, $logfile) or print "ERROR opening logfile $logfile: $!\n";
        my @logdata = <LOGDATA>;
        close LOGDATA;

        foreach my $logline (@logdata) {
            if ( $logline =~ qr{
                    (?<logdate> \w{3}\s\d{2} ) \s
                    (?<logtime> \d{2}:\d{2}:\d{2} ) \s
                    (?<hostgroup> [^:]* )\s:\s
                    (?<message> .* )
                }x )
            {
                push( @{ $parsed_logdata{$+{logdate}} }, {
                    date      => $+{logdate},
                    time      => $+{logtime},
                    hostgroup => $+{hostgroup},
                    message   => $+{message},
                });
            } else {
                $parsed_logdata{(sort keys %parsed_logdata)[-1]}[-1]->{message} .= "<br />$logline";
            }
        }
    }

    return \%parsed_logdata;
}

sub error404 {
    my ($title) = @_;
    $title ||= 'An error occured.';

    Dancer::Continuation::Route::ErrorSent->new(
        return_value => Dancer::Error->new(
            code  => 404,
            title => $title,
        )->render()
    )->throw;
}

1;
