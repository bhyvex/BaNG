package BaNG::Config;

use Cwd qw( abs_path );
use File::Basename;
use File::Find::Rule;
use POSIX qw( strftime );
use YAML::Tiny qw( LoadFile Dump );

use Exporter 'import';
our @EXPORT = qw(
    %globalconfig
    %hosts
    %groups
    %servers
    $prefix
    $config_path
    $config_global
    $servername
    get_global_config
    get_default_config
    get_host_config
    get_group_config
    get_server_config
    get_cronjob_config
    generated_crontab
    read_host_configfile
    split_configname
);

our %globalconfig;
our %defaultconfig;
our %hosts;
our %groups;
our %servers;
our $config_path;
our $config_global;
our $prefix     = dirname( abs_path($0) );
our $servername = `hostname -s`;
chomp $servername;

sub get_global_config {
    my ($prefix_arg) = @_;

    $prefix        = $prefix_arg if $prefix_arg;
    $config_path   = "$prefix/etc";
    $config_global = "$config_path/defaults_servers.yaml";

    # read bang global configs
    if ( sanityfilecheck($config_global) ) {
        my $global_settings = LoadFile($config_global);
        %globalconfig = %{ $global_settings };
    }

    # override with server-specific global configs
    my $server_defaults = "$config_path/$globalconfig{path_serverconfig}/${servername}_defaults.yaml";
    if ( sanityfilecheck($server_defaults) ) {
        my $server_settings = LoadFile($server_defaults);
        foreach my $key ( keys %{$server_settings} ) {
            $globalconfig{$key} = $server_settings->{$key};
        }
    }

    # preprend full path where needed
    foreach my $key (qw( config_defaults_hosts config_bangstat path_serverconfig path_groupconfig path_hostconfig path_excludes path_logs path_lockfiles )) {
        $globalconfig{$key} = "$config_path/$globalconfig{$key}";
    }

    $globalconfig{config_defaults_servers} = $config_global;

    return 1;
}

sub get_default_config {

    sanityfilecheck( $globalconfig{config_defaults_hosts} );
    my $defaultconfig = LoadFile( $globalconfig{config_defaults_hosts} );

    return $defaultconfig;
}

sub sanityfilecheck {
    my ($file) = @_;

    if ( !-f "$file" ) {
        # logit("localhost","INTERNAL", "$file NOT available");
        return 0;    # FIXME CLI should check return value
    } else {
        return 1;
    }
}

sub find_configs {
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

sub split_configname {
    my ($configfile) = @_;

    my ($hostname, $groupname) = $configfile =~ /^([\w\d-]+)_([\w\d-]+)\.yaml/;

    return ($hostname, $groupname);
}

sub split_group_configname {
    my ($configfile) = @_;

    my ($groupname) = $configfile =~ /^([\w\d-]+)\.yaml/;

    return ($groupname);
}

sub split_server_configname {
    my ($configfile) = @_;

    my ($server) = $configfile =~ /^([\w\d-]+)_defaults\.yaml/;

    return ($server);
}

sub split_cronconfigname {
    my ($cronconfigfile) = @_;

    my ($server, $jobtype) = $cronconfigfile =~ /^([\w\d-]+)_cronjobs_([\w\d-]+)\.yaml/;

    return ($server, $jobtype);
}

sub get_host_config {
    my ($host, $group) = @_;

    $host  ||= '*';
    $group ||= '*';
    undef %hosts;
    my @hostconfigs = find_configs( "$host\_$group\.yaml", "$globalconfig{path_hostconfig}" );

    foreach my $hostconfigfile (@hostconfigs) {
        my ($hostname, $group)          = split_configname($hostconfigfile);
        my ($hostconfig, $confighelper) = read_host_configfile( $hostname, $group );
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
    my @groupconfigs = find_configs( "$group\.yaml", "$globalconfig{path_groupconfig}" );

    foreach my $groupconfigfile (@groupconfigs) {
        my ($groupname)                  = split_group_configname($groupconfigfile);
        my ($groupconfig, $confighelper) = read_group_configfile($groupname);
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

sub get_server_config {
    my ($server) = @_;

    $server ||= '*';
    undef %servers;
    my @serverconfigs = find_configs( "${server}_defaults\.yaml", $globalconfig{path_serverconfig} );

    foreach my $serverconfigfile (@serverconfigs) {
        my ($servername) = split_server_configname($serverconfigfile);
        my ($serverconfig, $confighelper) = read_server_configfile($servername);

        $servers{"$servername"} = {
            'status'       => $status,
            'configfile'   => $serverconfigfile,
            'serverconfig' => $serverconfig,
            'confighelper' => $confighelper,
        };
    }

    return 1;
}

sub get_cronjob_config {
    my %unsortedcronjobs;
    my %sortedcronjobs;

    my @cronconfigs = find_configs( "*_cronjobs_*.yaml", "$globalconfig{path_serverconfig}" );

    foreach my $cronconfigfile (@cronconfigs) {
        my ($server, $jobtype) = split_cronconfigname($cronconfigfile);

        JOBTYPE: foreach my $jobtype (qw( backup wipe )) {
            my $cronjobsfile = "$globalconfig{path_serverconfig}/${server}_cronjobs_$jobtype.yaml";
            next JOBTYPE unless sanityfilecheck($cronjobsfile);
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

sub read_host_configfile {
    my ($host, $group) = @_;

    my %configfile;
    my $settingshelper;

    my $settings = LoadFile( $globalconfig{config_defaults_hosts} );
    $configfile{group} = "$globalconfig{path_groupconfig}/$group.yaml";
    $configfile{host}  = "$globalconfig{path_hostconfig}/$host\_$group.yaml";

    foreach my $config_override (qw( group host )) {
        if ( sanityfilecheck( $configfile{$config_override} ) ) {

            my $settings_override = LoadFile( $configfile{$config_override} );

            foreach my $key ( keys %{$settings_override} ) {
                $settings->{$key}       = $settings_override->{$key};
                $settingshelper->{$key} = $config_override;
            }
        }
    }

    return ($settings, $settingshelper);
}

sub read_group_configfile {
    my ($group) = @_;

    my %configfile;
    my $settingshelper;

    my $settings = LoadFile( $globalconfig{config_defaults_hosts} );
    $configfile{group} = "$globalconfig{path_groupconfig}/$group.yaml";

    foreach my $config_override (qw( group )) {
        if ( sanityfilecheck( $configfile{$config_override} ) ) {

            my $settings_override = LoadFile( $configfile{$config_override} );

            foreach my $key ( keys %{$settings_override} ) {
                $settings->{$key}       = $settings_override->{$key};
                $settingshelper->{$key} = $config_override;
            }
        }
    }

    return ($settings, $settingshelper);
}

sub read_server_configfile {
    my ($server) = @_;

    my %configfile;
    my $settingshelper;

    my $settings = LoadFile( $globalconfig{config_defaults_servers} );
    $configfile{server} = "$globalconfig{path_serverconfig}/${server}_defaults.yaml";

    foreach my $config_override (qw( server )) {
        if ( sanityfilecheck( $configfile{$config_override} ) ) {

            my $settings_override = LoadFile( $configfile{$config_override} );

            foreach my $key ( keys %{$settings_override} ) {
                $settings->{$key}       = $settings_override->{$key};
                $settingshelper->{$key} = $config_override;
            }
        }
    }

    return ($settings, $settingshelper);
}

1;
