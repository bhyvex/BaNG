package BaNG::Config;

use Cwd qw( abs_path );
use File::Basename;
use File::Find::Rule;
use POSIX qw( strftime );
use YAML::Tiny qw( LoadFile Dump );

use Exporter 'import';
our @EXPORT = qw(
    %hosts
    %groups
    %servers
    %serverconfig
    $prefix
    $servername
    get_serverconfig
    get_host_config
    get_group_config
    get_cronjob_config
    generated_crontab
);

our %hosts;
our %groups;
our %servers;
our %serverconfig;
our $prefix     = dirname( abs_path($0) );
our $servername = `hostname -s`;
chomp $servername;

sub get_serverconfig {
    my ($prefix_arg) = @_;

    undef %servers;
    undef %serverconfig;
    $prefix        = $prefix_arg if $prefix_arg;
    $serverconfig{path_configs}            = "$prefix/etc";
    $serverconfig{config_defaults_servers} = "$serverconfig{path_configs}/defaults_servers.yaml";
    $serverconfig{path_serverconfig}       = "$serverconfig{path_configs}/servers";

    # get info about all backup servers
    my @serverconfigs = _find_configs( "*_defaults\.yaml", $serverconfig{path_serverconfig} );

    foreach my $serverconfigfile (@serverconfigs) {
        my ($server) = _split_server_configname($serverconfigfile);
        my ($serverconfig, $confighelper) = _read_server_configfile($server);

        $servers{"$server"} = {
            'configfile'   => $serverconfigfile,
            'serverconfig' => $serverconfig,
            'confighelper' => $confighelper,
        };
    }

    # copy info about localhost to separate hash for easier retrieval
    foreach my $key ( keys %{ $servers{$servername}{serverconfig} } ) {
        $serverconfig{$key} = $servers{$servername}{serverconfig}->{$key};
    }

    # preprend full path where needed
    foreach my $key (qw( config_defaults_hosts config_bangstat path_serverconfig path_groupconfig path_hostconfig path_excludes path_logs path_lockfiles )) {
        $serverconfig{$key} = "$serverconfig{path_configs}/$serverconfig{$key}";
    }

    # add defaults_hosts config
    my $defaults_hosts_file = $serverconfig{config_defaults_hosts};
    if ( _sanityfilecheck($defaults_hosts_file) ) {
        $serverconfig{defaults_hosts} = LoadFile( $defaults_hosts_file );
    }

    return 1;
}

sub get_host_config {
    my ($host, $group) = @_;

    $host  ||= '*';
    $group ||= '*';
    undef %hosts;
    my @hostconfigs = _find_configs( "$host\_$group\.yaml", "$serverconfig{path_hostconfig}" );

    foreach my $hostconfigfile (@hostconfigs) {
        my ($hostname, $group)          = _split_configname($hostconfigfile);
        my ($hostconfig, $confighelper) = _read_host_configfile( $hostname, $group );
        my $isEnabled        = $hostconfig->{BKP_ENABLED};
        my $isBulkbkp        = $hostconfig->{BKP_BULK_ALLOW};
        my $isBulkwipe       = $hostconfig->{WIPE_BULK_ALLOW};
        my $status           = $isEnabled ? "enabled" : "disabled";
        my $css_class        = $isEnabled ? "active " : "";
        my $nobulk_css_class = ( $isBulkbkp == 0 && $isBulkwipe == 0 ) ? "nobulk " : "";

        $hosts{"$hostname-$group"} = {
            'hostname'         => $hostname,
            'group'            => $group,
            'status'           => $status,
            'configfile'       => $hostconfigfile,
            'css_class'        => $css_class,
            'nobulk_css_class' => $nobulk_css_class,
            'hostconfig'       => $hostconfig,
            'confighelper'     => $confighelper,
        };
    }

    return 1;
}

sub get_group_config {
    my ($group) = @_;

    $group ||= '*';
    undef %groups;
    my @groupconfigs = _find_configs( "$group\.yaml", "$serverconfig{path_groupconfig}" );

    foreach my $groupconfigfile (@groupconfigs) {
        my ($groupname)                  = _split_group_configname($groupconfigfile);
        my ($groupconfig, $confighelper) = _read_group_configfile($groupname);
        my $isEnabled        = $groupconfig->{BKP_ENABLED};
        my $isBulkbkp        = $groupconfig->{BKP_BULK_ALLOW};
        my $isBulkwipe       = $groupconfig->{WIPE_BULK_ALLOW};
        my $status           = $isEnabled ? "enabled" : "disabled";
        my $css_class        = $isEnabled ? "active " : "";
        my $nobulk_css_class = ( $isBulkbkp == 0 && $isBulkwipe == 0 ) ? "nobulk " : "";

        $groups{"$groupname"} = {
            'status'           => $status,
            'configfile'       => $groupconfigfile,
            'css_class'        => $css_class,
            'nobulk_css_class' => $nobulk_css_class,
            'groupconfig'      => $groupconfig,
            'confighelper'     => $confighelper,
        };
    }

    return 1;
}

sub get_cronjob_config {
    my %unsortedcronjobs;
    my %sortedcronjobs;

    my @cronconfigs = _find_configs( "*_cronjobs_*.yaml", "$serverconfig{path_serverconfig}" );

    foreach my $cronconfigfile (@cronconfigs) {
        my ($server, $jobtype) = _split_cronconfigname($cronconfigfile);

        JOBTYPE: foreach my $jobtype (qw( backup wipe )) {
            my $cronjobsfile = "$serverconfig{path_serverconfig}/${server}_cronjobs_$jobtype.yaml";
            next JOBTYPE unless _sanityfilecheck($cronjobsfile);
            my $cronjobslist = LoadFile($cronjobsfile);

            foreach my $cronjob ( keys %{$cronjobslist} ) {
                my ($host, $group) = split( /_/, $cronjob );

                $unsortedcronjobs{$server}{$jobtype}{$cronjob} = {
                    'host'  => $host,
                    'group' => $group,
                    'ident' => "$host-$group",
                    'cron'  => $cronjobslist->{$cronjob},
                };
            }

            my $id = 1;
            foreach my $cronjob ( sort {
                sprintf("%02d%02d", $unsortedcronjobs{$server}{$jobtype}{$a}{cron}->{HOUR}, $unsortedcronjobs{$server}{$jobtype}{$a}{cron}->{MIN})
                <=>
                sprintf("%02d%02d", $unsortedcronjobs{$server}{$jobtype}{$b}{cron}->{HOUR}, $unsortedcronjobs{$server}{$jobtype}{$b}{cron}->{MIN})
                } keys %{ $unsortedcronjobs{$server}{$jobtype} } ) {
                my $PastMidnight = ( $unsortedcronjobs{$server}{$jobtype}{$cronjob}{cron}->{HOUR} >= 18 ) ? 0 : 1;

                $sortedcronjobs{$server}{$jobtype}{sprintf( "$jobtype$PastMidnight%05d", $id )} = $unsortedcronjobs{$server}{$jobtype}{$cronjob};
                $id++;
            }
        }
    }

    return \%sortedcronjobs;
}

sub generated_crontab {
    my $cronjobs = get_cronjob_config();
    my $crontab  = "# Automatically generated by BaNG; do not edit locally\n";

    foreach my $jobtype ( sort keys %{ $cronjobs->{$servername} } ) {
        $crontab .= "#--- $jobtype ---\n";
        foreach my $cronjob ( sort keys %{ $cronjobs->{$servername}->{$jobtype} } ) {
            my %cron;
            foreach my $key (qw( MIN HOUR DOM MONTH DOW )) {
                $cron{$key} = $cronjobs->{$servername}->{$jobtype}->{$cronjob}->{cron}->{$key};
                $crontab .= sprintf( '%3s', $cron{$key} );
            }
            $crontab .= "    root    $prefix/BaNG";

            $crontab .= " --wipe" if ( $jobtype eq 'wipe' );

            my $host  = "$cronjobs->{$servername}->{$jobtype}->{$cronjob}->{host}";
            $crontab .= " -h $host" unless $host eq 'BULK';

            my $group = "$cronjobs->{$servername}->{$jobtype}->{$cronjob}->{group}";
            $crontab .= " -g $group" unless $group eq 'BULK';

            my $threads = $cronjobs->{$servername}->{$jobtype}->{$cronjob}->{cron}->{THREADS};
            $crontab .= " -t $threads" if $threads;

            $crontab .= "\n";
        }
    }

    return $crontab;
}

sub _read_host_configfile {
    my ($host, $group) = @_;

    my %configfile;
    my $settingshelper;

    my $settings       = $serverconfig{defaults_hosts};
    $configfile{group} = "$serverconfig{path_groupconfig}/$group.yaml";
    $configfile{host}  = "$serverconfig{path_hostconfig}/$host\_$group.yaml";

    foreach my $config_override (qw( group host )) {
        if ( _sanityfilecheck( $configfile{$config_override} ) ) {

            my $settings_override = LoadFile( $configfile{$config_override} );

            foreach my $key ( keys %{$settings_override} ) {
                $settings->{$key}       = $settings_override->{$key};
                $settingshelper->{$key} = $config_override;
            }
        }
    }

    return ($settings, $settingshelper);
}

sub _read_group_configfile {
    my ($group) = @_;

    my %configfile;
    my $settingshelper;

    my $settings       = $serverconfig{defaults_hosts};
    $configfile{group} = "$serverconfig{path_groupconfig}/$group.yaml";

    foreach my $config_override (qw( group )) {
        if ( _sanityfilecheck( $configfile{$config_override} ) ) {

            my $settings_override = LoadFile( $configfile{$config_override} );

            foreach my $key ( keys %{$settings_override} ) {
                $settings->{$key}       = $settings_override->{$key};
                $settingshelper->{$key} = $config_override;
            }
        }
    }

    return ($settings, $settingshelper);
}

sub _read_server_configfile {
    my ($server) = @_;

    my %configfile;
    my $settingshelper;

    my $settings = LoadFile( $serverconfig{config_defaults_servers} );
    $configfile{server} = "$serverconfig{path_serverconfig}/${server}_defaults.yaml";

    foreach my $config_override (qw( server )) {
        if ( _sanityfilecheck( $configfile{$config_override} ) ) {

            my $settings_override = LoadFile( $configfile{$config_override} );

            foreach my $key ( keys %{$settings_override} ) {
                $settings->{$key}       = $settings_override->{$key};
                $settingshelper->{$key} = $config_override;
            }
        }
    }

    return ($settings, $settingshelper);
}

sub _sanityfilecheck {
    my ($file) = @_;

    if ( !-f "$file" ) {
        # logit("localhost","INTERNAL", "$file NOT available");
        return 0;    # FIXME CLI should check return value
    } else {
        return 1;
    }
}

sub _find_configs {
    my ($query, $searchpath) = @_;

    my @files;
    my $ffr_obj = File::Find::Rule->file()
                                  ->name($query)
                                  ->relative
                                  ->maxdepth(1)
                                  ->start($searchpath);

    while ( my $file = $ffr_obj->match() ) {
        push( @files, $file );
    }

    return @files;
}

sub _split_configname {
    my ($configfile) = @_;

    my ($hostname, $groupname) = $configfile =~ /^([\w\d-]+)_([\w\d-]+)\.yaml/;

    return ($hostname, $groupname);
}

sub _split_group_configname {
    my ($configfile) = @_;

    my ($groupname) = $configfile =~ /^([\w\d-]+)\.yaml/;

    return ($groupname);
}

sub _split_server_configname {
    my ($configfile) = @_;

    my ($server) = $configfile =~ /^([\w\d-]+)_defaults\.yaml/;

    return ($server);
}

sub _split_cronconfigname {
    my ($cronconfigfile) = @_;

    my ($server, $jobtype) = $cronconfigfile =~ /^([\w\d-]+)_cronjobs_([\w\d-]+)\.yaml/;

    return ($server, $jobtype);
}

1;
