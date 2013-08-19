#!/usr/bin/perl

use strict;

use Config::Simple; # make sure this is installed...
use File::Path;
use File::Copy;
use Cwd;
use Data::Dumper;
use UNIVERSAL 'isa';
 
use subs qw(mydie);

my $config_file = 'spd_install.cfg';
my $instance_map;
my $branch_map;
my $copy_dirs;
my $continue = 1;
my $branch;
my $tag;
my $verbose;
my $testmode;
my $do_backup;
my $backup_dir;
my $cfg;
my $args;
my $cwd;
my $local_repo;
my $remote_repo;
my $instance;

print "spd_install.pl starting\n";
my $datetime = &getDateTime();
&getArgs();
&readConfig();
&dumpRunSettings();
&getSpdInstanceToBeUpdated();
&getBranch();
&createLocalGitRepo();
&doFileCopy();
&cleanup();
if($do_backup) {
    print "Remember that backups are in '$backup_dir'.  Probably copy them to your home directory ASAP.\n";
}
if ($continue) {
    print "OK\n";
} else {
    print "FAIL\n";
}    

#
# Get command line args
#   -c specifies a non-standard config file (for whatever reason)
#   -h/--help shows help
#   -v turns on verbose mode    
#   -t turns on test mode (no files get copied).
#
sub getArgs {

    my $getConfig;

    foreach my $arg (@ARGV) {
	if($arg =~ /^-c$/) {
	    $getConfig = 1;
	    next;
	} elsif($arg =~ /^-v$/) {
	    $verbose = 1; 
	    $args->{'verbose'} = {'val' => '1', 'show' => $arg};
	} elsif($arg =~ /^-t$/) {
	    $testmode= 1; 
	    $args->{'test mode'} = {'val' => '1', 'show' => $arg};
	} elsif($arg =~ /^--?h(elp)?$/) {
	    &showUsage();
	} else {
	    if($getConfig == 1) {
		$config_file = $arg;
		print "Using config file '$config_file'\n";
		$getConfig = 0;
		next;
	    } else {
		print "Unknown arg '$arg'.\n";
		&showUsage();
	    }
	}
    }
}

#
# Read the config file
#
sub readConfig {
    
    my $cs = new Config::Simple($config_file);
    my %cfg_hash = $cs->vars();
    foreach my $key (keys %cfg_hash) {
	my($val) = $cfg_hash{$key};
	if($key =~ /spd_instances\..*/) {
	    $key =~ s/spd_instances\.(.*)/$1/;
	    $instance_map->{$key} = $val;
	} elsif($key =~ /git_branches\..*/) {
	    $key =~ s/git_branches\.(.*)/$1/;
	    $branch_map->{$key} = $val;
	} elsif($key =~ /copy_dirs\..*/) {
	    $key =~ s/copy_dirs\.(.*)/$1/;
	    if(isa($val, 'ARRAY')) {
		foreach my $v (@$val) {
		   push(@{$copy_dirs->{$key}}, $v);
		}
	    } else {
		push(@{$copy_dirs->{$key}}, $val);
	    }
	} else {
	    $key =~ s/.*\.(.*)/$1/;
	    $key =~ s/\ /\_/g;
	    $cfg->{$key} = $val;
	}
    }
    print "\$cfg = " . Dumper($cfg) . "\n" if $testmode;
}

#
# Show the user what we have config plus command line
#
sub dumpRunSettings {

    my $prompt = "Using the following settings in config file $config_file:\n";
    foreach my $key (keys %$cfg) {
	my $val = $cfg->{$key};
	my $val_out;
	if ($val eq '1') {
	    $val_out = "on";
	} elsif ($val eq '0') {
	    $val_out = "off";
	} else {
	    $val_out = $val;
	}
	$key =~ s/_/\ /g;
	unless ($val eq '0' && defined $args->{$key}) {    
	    $prompt .= sprintf ("    %-24s = %-18s\n", $key, $val_out);
	}
    }	

    if(scalar(keys %$args) > 0) {
	my($do_header) = 1;
	foreach my $key (keys %$args) {
	    if($args->{$key}->{'val'} eq '1' && 
		    (! defined $cfg->{$key} || $cfg->{$key} eq '' or $cfg->{$key} eq '0')) {
		if($do_header) {
		    $prompt .= "Using the following settings from the command line:\n";
		    $do_header = 0;    
		}
		my $val = $args->{$key}->{'val'};
		my $display = $args->{$key}->{'show'};
		if ($val eq '1') {
		    $val = "on ($display)";
		} elsif ($val eq '0') {
		    $val = "off";
		}
		$key =~ s/_/\ /g;
		$prompt .= sprintf ("    %-24s = %-18s\n", $key, $val);
	    }
	}
    } 
    $prompt .=  "Proceed? [y/n]";
    my $allowed = ['y','n', 'yes', 'no'];
    my($yesno) = &getUserInput($prompt, $allowed); 
    die unless $yesno =~ /^y(es)?$/i; 
}

#
# All of the stuff necessary to set up a local git repo
#
sub createLocalGitRepo {

    # have to have a remote (github) repo
    $remote_repo = $cfg->{'github_repo'};
    mydie "No remote repo defined.  Check for value of 'github repo' in $config_file and add it if it doesn't exist already.\n" unless $remote_repo;

    my($do_full_repo_create) = &doFullRepoCreate();
    
    if($do_full_repo_create) {
	# have to have a local repo
	$local_repo = $cfg->{'local_repo_alternate'};
	mydie "No local repo defined.  Check for value of 'local repo' in $config_file and add it if it doesn't exist already.\n" unless $local_repo;

	# create a temporary directory to use as a local repo
	&createDirectory() if $continue;

	# initialize it as a git repo
	&doGit_Init() if $continue;

	# clone the remote (github) repo 
	&doGit_Clone() if $continue;

	# change to the 'root' directory within the repo.  should be 'spd'.
	if($continue) {
	    my($root) = $cfg->{'local_repo_root'};
	    if(-d $root) {
		chdir $root;
	    } else {
		mydie "Unable to change to $root: $!\n";
	    }
	}

    } else {
	print "Post-deploy cleanup is automatically disabled since the deployment is using an existing repository.\n"; 
	$cfg->{'do_cleanup'} == 0;
	$local_repo = $cfg->{'local_repo_default'};
	mydie "No local repo defined.  Check for value of 'local repo' in $config_file and add it if it doesn't exist already.\n" unless $local_repo;

	# change to the 'root' directory within the repo.  should be 'spd'.
	if($continue) {
	    my($root) = $local_repo . "/" . $cfg->{'local_repo_root'};
	    if(-d $root) {
		chdir $root;
	    } else {
		mydie "Unable to change to $root: $!\n";
	    }
	}
    }

    # if we are using 'master' branch this is probably not necessary
    # but if it is 'devel' we might need to create the branch
    my($branch_exists, $is_current_branch) = &doGit_Branch() if $continue;

    # ...and checkout to the branch
    &doGit_Checkout($branch_exists, $is_current_branch) if $continue;

    # fetching...
    &doGit_Fetch() if $continue;
   
    # might not be necessary but it doesn't hur to do an update 
    &doGit_Pull() if $continue;

    # find out if there is a tag other than the current tag and if so, reset to that tag
    my($resetToTag) = &resetToTagYesNo() if $continue;
    &getTag() if ($resetToTag && $continue);

}

#
# Ask the user if we are updating spd, spd2 or both
# 
sub getSpdInstanceToBeUpdated {
    my $allowed = [];
    my($prompt) =  "Which SPD instance is being updated?\n";
    foreach my $key (sort (keys %$instance_map)) {
	push(@$allowed, $key);
	$prompt .= "\t$key\t=\t$instance_map->{$key}\n";
    }
    $prompt =~ s/(.*)\n$/$1/s;
    my($num) = &getUserInput($prompt, $allowed); 
    $instance = $instance_map->{$num};
    print "updating " . $instance_map->{$num} . "\n";
}

#
# Ask the user whether the update should be done out of the 'devel' or 'master' branch
#
sub getBranch {
    my $allowed = [];
    my($prompt) =  "Which branch should the update use?\n";
    foreach my $key (sort (keys %$branch_map)) {
	push(@$allowed, $key);
	$prompt .= "\t$key\t=\t$branch_map->{$key}\n";
    }
    $prompt =~ s/(.*)\n$/$1/s;
    my($num) = &getUserInput($prompt, $allowed); 
    print "using branch " . $branch_map->{$num} . "\n";
    $branch = $branch_map->{$num};
}

#
# Ask the user if they want to do a full repo create and cleanup or just do the default
# git pull to the existing default repo.
# 
sub doFullRepoCreate {
    my $allowed = ['y','n', 'yes', 'no'];
    my($prompt) =  "Do you want to do a full repo create (default is 'no')? [y/n]";
    my($yesno) = &getUserInput($prompt, $allowed); 
    return 1 if $yesno =~ /^y(es)?$/i; 
}

#
# Ask the user if the update needs to be done from a point earlier than the current code.
# 
sub resetToTagYesNo {
    my $allowed = ['y','n', 'yes', 'no'];
    my($prompt) =  "Does the repo need to be reset to an earlier tag? [y/n]";
    my($yesno) = &getUserInput($prompt, $allowed); 
    return 1 if $yesno =~ /^y(es)?$/i; 
}

#
# Give the user a list of recent tags to choose from if they answered yes to the above question.
#
sub getTag {
    my $allowed = [];
    my($tags) = &doGit_Tag();
    my($prompt) =  "Which tag should the update use?\n";
    
    foreach my $key (sort (keys %$tags)) {
	push(@$allowed, $key);
	$prompt .= "\t$key\t=\t$tags->{$key}";
	$prompt .= " (current release)" if $key == 1;
	$prompt .= "\n";
    }
    $prompt =~ s/(.*)\n$/$1/s;
    my($num) = &getUserInput($prompt, $allowed); 
    my $tag = $tags->{$num};
    if($tag != 1) {
	print "resetting repo to tag " . $tags->{$num} . "\n" if $tag == 1;
	&doGit_Reset($tag);
    }
}

#
# Ask the user if they want to do a full repo create and cleanup or just do the default
# git pull to the existing default repo.
# 
sub doBackupYesNo {
    my $allowed = ['y','n', 'yes', 'no'];
    my($prompt) =  "Should we backup working files that will be overwritten by the code update? [y/n]";
    my($yesno) = &getUserInput($prompt, $allowed); 
    return 1 if $yesno =~ /^y(es)?$/i; 
}

#
# Create the temporary directory we will use to do the code update and then change to that directory.
#
sub createDirectory {

    # create the parent directory
    $local_repo .= "_$datetime";
    print "creating local_repo in '$local_repo'\n";
    my $args = {verbose => $verbose} if $verbose;
    mkpath($local_repo, $args);

    $cwd = cwd();
    chdir $local_repo or mydie "Unable to change to local repo '$local_repo': $!\n";
}

#
# Initialize a local git repo.
#
sub doGit_Init {

    my $cmd = "git init"; 
    print "$cmd\n";
    my $init = `$cmd`;
    print "$init\n" if $verbose;
}

#
# Clone the remote github repo to local 
#
sub doGit_Clone {

    my $cmd = "git clone git\@$remote_repo";
    print "$cmd\n";
    my $clone = `$cmd`;
    print "$clone\n" if $verbose;
}

#
# We might need to use one of several branches.  Find out here if the brnach we want to
# use exists and if it is the branch we are currently on. 
#
sub doGit_Branch {

    my $cmd = "git branch";
    my $br = `$cmd`;

    chomp($br);
    $br =~ s/\*/\\\*/g;
    my(@branches) = split /\n/, $br;

    my $branch_exists = 0;
    my $is_current_branch = 0;
    foreach my $brx (@branches) {  
	$brx =~ s/^\s+//;		   
	if($brx =~ /$branch/) {
	    $branch_exists = 1;
	    if($brx =~ /\*\s*$branch/){
		$is_current_branch = 1;
	    } 
	    last;
	}
    }

    return ($branch_exists, $is_current_branch);
}

#
# Checkout the branch that we want to use.  If the branch we want to use already
# exists and it is the current branch, do nothing.  If it exists but isn't out current
# branch, a simple 'git checkout' will do it.  But if it doesn't exist yet the '-b'
# switch is required to create the branch before we switch to it.
#
sub doGit_Checkout {
    my($branch_exists) = shift;
    my($is_current_branch) = shift;

    my $cmd;

    if($branch_exists && $is_current_branch) {
    } else {
	if(! $is_current_branch) {
	    $cmd = "git checkout ";
	}
	if(! $branch_exists) {
	    $cmd .= "-b ";
	}
	$cmd .= $branch; 
	print "Running [$cmd]\n";
	my($co) = `$cmd`;
	print "$co\n" if $verbose;
    }
}

#
# Might not be necessary but it doesn't hurt to ensure we get the latest stuff
# from the branch we want to use.
# 
sub doGit_Fetch {

    #my $cmd = "git fetch origin $branch";
    my $cmd = "git fetch --all"; # need to fetch all to bring all remote tags 
    print "$cmd\n";
    my($fetch) = `$cmd`;
    print "$fetch\n" if $verbose;
}

#
# Might not be necessary but it doesn't hurt to ensure we get the latest stuff
# from the branch we want to use.
# 
sub doGit_Pull {

    my $cmd = "git pull origin $branch";
    print "$cmd\n";
    my($pull) = `$cmd`;
    print "$pull\n" if $verbose;
}
 
#
# Get a list of recent tags for the user to pick from.  List size is configurable.
#   
sub doGit_Tag {
    
    #my $cmd = "git tag -l";
    my $cmd = "git for-each-ref --sort='*authordate' --format='%(tag)' refs/tags";
    my(@tags) = `$cmd`;
    #@tags = sort {$b cmp $a} @tags;
    @tags = reverse @tags;
    if($cfg->{'tags_limit'} && $cfg->{'tags_limit'} ne '') {
	my $limit = $cfg->{'tags_limit'};
	@tags = @tags[0..$limit-1];
    }

    my($tagref) = {};
    my($count) = 1;
    foreach my $t (@tags) {
	chomp($t);    
	$tagref->{$count} = $t;
	$count++;
    }
    return $tagref;
}

#
# If the user wants to reset to an earlier tag, do it here.
# 
sub doGit_Reset {

    my($tag) = shift;
    my $cmd = "git reset --hard $tag";
    my $reset = `$cmd`;
    print "$reset\n" if $verbose;
}

#
# Generic, show prompt and get user response.  Check to make sure the
# response is valid.
#
sub getUserInput {
    my($string) = shift;
    my($allowed_responses) = shift;

    print "$string\n>>";
    my $resp = <STDIN>;
    chomp($resp);
    foreach my $ar (@$allowed_responses) {
	if($resp eq $ar) {
	    return $resp;
	}    
    }
    mydie "Unknown response '$resp'\n";
}

#
# Copy files from our temp directory to the working code
#
sub doFileCopy {

    if($continue) {
	$do_backup = $cfg->{'do_backup'};
	$do_backup = &doBackupYesNo() unless $do_backup;
	if($do_backup) {
	    $backup_dir = &getBackupDir();
	    print "backups will be in $backup_dir\n";
	}

	my($destination_dir) = $cfg->{'working_code_path'} . $instance;
	print "copying files from $local_repo to $destination_dir\n";

	my $cwd = cwd();
	opendir TMP, $cwd or mydie "Unable to open $cwd: $!";
	my(@contents) = grep !/^\..*/, readdir TMP;
	closedir TMP;
	foreach my $c (@contents) {
	    if(-d "$cwd/$c" && exists $copy_dirs->{$c}) {
		&copyDirs("$cwd/$c", $c, $cwd, "$destination_dir/$c");
	    }
	}
    }
}

# 
# This is the recursive stuff we need to handle when we deal with a directory
#
sub copyDirs {
    my($dir) = shift;
    my($parent) = shift;
    my($repo_root) = shift;
    my($destination) = shift;

    opendir TMP, "$dir" or mydie "Unable to open $dir: $!";
    my(@contents) = grep !/^\..*/, readdir TMP;
    close TMP;
    foreach my $c (@contents) {
	my($path) = "$dir/$c";
	if(-d $path) {
	    &copyDirs($path, $parent, $repo_root, "$destination/$c");
	} elsif (-f $path) {
	    &copyFiles($path, $parent, $repo_root, "$destination/$c");
	}    
    }
}

#
# Logic to handle filtering on file names when copying.
# Filters are regex and fall into two categories: include (either by
# default or with an "include:" in the config file) or exclude 
# ("exclude:" in the config file).  With an include filter a file has to match
# in order to have the 'ok' flag set to 1 (any match will make the file OK for
# copying.  With an exclude filter a file that matches fails and can't be copied
# (any match fails the file).  
#
sub copyFiles {
    my($file) = shift;
    my($parent) = shift;
    my($repo_root) = shift;
    my($destination) = shift;

    my $filters = $copy_dirs->{$parent};
    if(scalar(@$filters) > 0) {
	my($ok_incl) = 0;
	my($ok_excl) = 1;

	# anything that doesn't explicitly include things includes everything
	my $has_explicit_include;
	foreach my $filter (@$filters) {
	    if($filter =~ /\.\*/ || $filter =~ /include:.*/) {
		$has_explicit_include = 1;
	    }
	}
	$ok_incl = 1 unless $has_explicit_include;

	foreach my $filter (@$filters) {
	    my($action, $fltr);
	    if($filter =~ /.*:.*/) {
		($action, $fltr) = $filter =~ /(.*):(.*)/;
	    } else {
		$action = 'include';
		$fltr = $filter;
	    }
		
	    if($action eq 'include' && $file =~ /.*$fltr.*/i) {
		$ok_incl = 1;
	    } elsif($action eq 'exclude' && $file =~ /.*$fltr.*/i) {
		$ok_excl = 0;
	    }
	}
	if($ok_incl && $ok_excl) {
	    &copyFile($file, $destination);
	} else {
	    &skipFile($file);
	}
    } else {
	&copyFile($file, $destination);
    }
}

#
# Creating destination directories and doing the actual file copy.
#
sub copyFile {
    my($src) = shift;
    my($dest) = shift;

    my($dest_path) = $dest =~ /(.*\/).*$/;
    unless (-d $dest_path) {
	my $args = {verbose => $verbose} if $verbose;
	print "$dest_path does not exist. creating...\n";
	mkpath($dest_path, $args) unless $testmode;
    }
    print "copying $src to $dest \n";
    print "(TEST MODE)" if $testmode;
    if($do_backup) {
	&doBackup($dest);
    }	
    unless($testmode) {
        unless (copy($src, $dest)) {
	    print "file copy failed: $!\n";
	}
    }
}
    
#
# Overkill.
#
sub skipFile {
    my($src) = shift;
	
    print "skipping file $src\n";
}

#
# File-by-file basis.  Figure out where this file should get copied to and copy it.
#
sub doBackup {
    my($dest) = shift;

    my $working_code_path = $cfg->{'working_code_path'};
    $dest =~ s/$working_code_path.*?\///;
    my($bkp_path) = $backup_dir . "/" . $dest;
    $bkp_path =~ s/(.*\/).*/$1/;
    unless(-d $bkp_path) {
	my $args = {verbose => $verbose} if $verbose;
	mkpath($bkp_path, $args) unless $testmode;
    }
    unless($testmode) {
	print "backing up $dest to $bkp_path\n" if $verbose;
        unless (copy($dest, $bkp_path)) {
	    print "file copy failed: $!\n";
	}
    }
}

sub getBackupDir {

    return $cfg->{'default_backup'} . "_$datetime";

}

#
# Probably not necessary since we are doing this out of /tmp but it doesn't
# hurt to clean up after ourselves. This can be turned on/off in the config.
#
sub cleanup {

    if ($cfg->{'do_cleanup'} == 1) {
	print "cleaning up...\n";
	chdir $cwd or mydie "Unable to change back to our original directory '$cwd': $!\n";
	if(-d $local_repo) {
	    my $args = {verbose => $verbose} if $verbose;
	    rmtree($local_repo, $args);
	}
    }
}

#
# We don't really want to die since that would prevent us from doing cleanup.
# Instead print a message and set a flag.
# 
sub mydie {
    my($msg) = shift;
    print $msg;
    $continue = 0;
}

#
# Used for naming our temporary working directory.
# 
sub getDateTime {

    my(@time) = localtime(time);
    return sprintf("%04d%02d%02d_%02d%02d%02d", $time[5]+1900, $time[4]+1, $time[3], $time[2], $time[1], $time[0]);
}

#
# Help message.
#
sub showUsage {

    die "USAGE: spd_install.pl [-c config file]
		-c	    : specify a config file to use (default is $config_file)
		-h, --help  : show this help info
		-v	    : verbose mode
		-t	    : test mode (create the repo but don't copy files)\n";
}
