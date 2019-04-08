#!/usr/bin/env perl
# EPN, Mon Aug 10 10:39:33 2015 [development began on dnaorg_annotate_genomes.pl]
# EPN, Thu Feb 18 12:48:16 2016 [dnaorg_annotate.pl split off from dnaorg_annotate_genomes.pl]
#
use strict;
use warnings;
use Getopt::Long;
use Time::HiRes qw(gettimeofday);
use Bio::Easel::MSA;
use Bio::Easel::SqFile;

require "dnaorg.pm"; 
require "epn-options.pm";
require "epn-ofile.pm";
require "epn-seq.pm";
require "epn-seqfile.pm";
require "epn-utils.pm";

#######################################################################################
# What this script does: 
#
# Given a single full length homology model (CM) built for a reference
# accession created by a previous run of dnaorg_build.pl, this script
# aligns each input sequence to that homologoy model and uses that
# alignment to annotate the features (CDS and mature peptides) in
# those incoming sequences. This script outputs a tabular file and d
# feature table summarizing the annotations, as well as information on
# alerts found.
#
# A list of subroutines can be found after the main script before
# the subroutines.
# 
# Immediately below are a list of the steps performed by this
# script. Each has a corresponding code block in the main script.
#
# Preliminaries: 
#   - process options
#   - output program banner and open output files
#   - parse the optional input files, if necessary
#   - make sure the required executables are executable
#
# Step 1.  Gather and process information on reference genome using Edirect.
# Step 2.  Fetch and process the reference genome sequence.
# Step 3.  Verify we have the model file that we need to run cmalign.
#
#    Steps 1-2 are very similar to those done in dnaorg_build.pl, but
#    dnaorg_build.pl and dnaorg_annotate,pl are run separately, perhaps
#    with a big time lag. Therefore, this script, in step 3, verifies 
#    that the models built by dnaorg_build.pl are still up-to-date with 
#    respect to the reference used in running this script.
#
# Step 4.  Align sequences to the homology model (CM).
# Step 5.  Parse cmalign alignments.
# Step 6.  Fetch features and detect most nucleotide-annotation based alerts.
# Step 7.  Run BLASTX: all full length sequences and all fetched CDS features 
#          versus all proteins
# Step 8.  Add b_zft alerts for sequences with zero annotated features
# Step 9.  Output annotations and alerts.
#
#######################################################################################
#
# Alert identification:
#
# This script identifies and outputs a list of all alerts in each of
# the sequences it annotates. Each type of alert has an associated
# five letter alert 'code'. The list of alert codes is in the
# dnaorg.pm perl module file. It can also be found here:
#
#  /panfs/pan1/dnaorg/virseqannot/error_code_documentation/errorcodes.v6a.documentation.txt
#
# List of subroutines in which errors are detected and added:
# 1. add_classification_alerts()
#    c_noa, c_vls, c_los, c_vld, c_lod, c_ugr, c_usg, c_mst, c_loc, c_hbi (10)
#
# 2. alert_add_n_div()
#    n_div (1)
#
# 3. cmalign_parse_stk_and_add_alignment_alerts()
#    n_gp5, n_lp5, n_gp3, n_lp3 (4)
#
# 4. fetch_features_and_add_cds_and_mp_alerts()
#    n_str, n_nm3, n_stp, n_ext, n_nst, n_trc, b_per* (7)
#
# 5. add_blastx_alerts()
#    b_nop, b_cst, b_p5l, b_p5s, b_p3l, b_p3s, p_lin, p_lde, p_trc, b_non, b_per* (11)
#
# 6. alert_add_b_zft()
#    b_zft (1)
# 
# * b_per errors can be added in two places, and are only added in add_blastx_alerts for
#   features for which they weren't already added in fetch_features_and_add_cds_and_mp_alerts()
#
#######################################################################################
# make sure DNAORGDIR and DNAORGBLASTDIR environment variable is set
my $env_dnaorgdir      = utl_DirEnvVarValid("DNAORGDIR");
my $env_dnaorgblastdir = utl_DirEnvVarValid("DNAORGBLASTDIR");

my $inf_exec_dir      = $env_dnaorgdir . "/infernal-dev/src";
my $esl_exec_dir      = $env_dnaorgdir . "/infernal-dev/easel/miniapps";
my $esl_ssplit        = $env_dnaorgdir . "/Bio-Easel/scripts/esl-ssplit.pl";
my $blast_exec_dir    = $env_dnaorgblastdir;
 
#########################################################
# Command line and option processing using epn-options.pm
#
# opt_HH: 2D hash:
#         1D key: option name (e.g. "-h")
#         2D key: string denoting type of information 
#                 (one of "type", "default", "group", "requires", "incompatible", "preamble", "help")
#         value:  string explaining 2D key:
#                 "type":         "boolean", "string", "integer" or "real"
#                 "default":      default value for option
#                 "group":        integer denoting group number this option belongs to
#                 "requires":     string of 0 or more other options this option requires to work, each separated by a ','
#                 "incompatible": string of 0 or more other options this option is incompatible with, each separated by a ','
#                 "preamble":     string describing option for preamble section (beginning of output from script)
#                 "help":         string describing option for help section (printed if -h used)
#                 "setby":        '1' if option set by user, else 'undef'
#                 "value":        value for option, can be undef if default is undef
#
# opt_order_A: array of options in the order they should be processed
# 
# opt_group_desc_H: key: group number (integer), value: description of group for help output
my %opt_HH = ();      
my @opt_order_A = (); 
my %opt_group_desc_H = ();
my $g = 0; # option group

# Add all options to %opt_HH and @opt_order_A.
# This section needs to be kept in sync (manually) with the &GetOptions call below
#     option            type       default               group   requires incompat    preamble-output                                   help-output    
opt_Add("-h",           "boolean", 0,                        0,    undef, undef,      undef,                                            "display this help",                                  \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "basic options";
opt_Add("-f",           "boolean", 0,                       $g,    undef,undef,       "force directory overwrite",                      "force; if output dir exists, overwrite it",   \%opt_HH, \@opt_order_A);
opt_Add("-v",           "boolean", 0,                       $g,    undef, undef,      "be verbose",                                     "be verbose; output commands to stdout as they're run", \%opt_HH, \@opt_order_A);
opt_Add("-s",           "integer", 181,                     $g,    undef,  undef,     "seed for random number generator is <n>",        "seed for random number generator is <n>", \%opt_HH, \@opt_order_A);
opt_Add("-m",           "string",  undef,                   $g,    undef, undef,      "use CM file <s> instead of default",             "use CM file <s> instead of default", \%opt_HH, \@opt_order_A);
opt_Add("-i",           "string",  undef,                   $g,    undef, undef,      "use model info file <s> instead of default",     "use model info file <s> instead of default", \%opt_HH, \@opt_order_A);
opt_Add("-b",           "string",  undef,                   $g,    undef, undef,      "BLAST dbs are in dir <s>, instead of default",   "specify BLAST dbs are in dir <s>, instead of default", \%opt_HH, \@opt_order_A);
opt_Add("-n",           "integer", 0,                       $g,    undef, "-p",       "use <n> CPUs",                                   "use <n> CPUs", \%opt_HH, \@opt_order_A);
opt_Add("--keep",       "boolean", 0,                       $g,    undef, undef,      "leaving intermediate files on disk",             "do not remove intermediate files, keep them all on disk", \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "options related to expected classification";
#        option               type   default                group  requires incompat    preamble-output                                                     help-output    
opt_Add("--group",         "string",  undef,                  $g,     undef, undef,     "set expected classification of all seqs to group <s>",             "set expected classification of all seqs to group <s>",            \%opt_HH, \@opt_order_A);
opt_Add("--subgroup",      "string",  undef,                  $g, "--group", undef,     "set expected classification of all seqs to subgroup <s>",          "set expected classification of all seqs to subgroup <s>",         \%opt_HH, \@opt_order_A);
opt_Add("--cthresh",         "real",  "0.3",                  $g,     undef, undef,     "expected classification must be within <x> bits/nt of top match",  "expected classification must be within <x> bits/nt of top match", \%opt_HH, \@opt_order_A);
opt_Add("--ctoponly",     "boolean",  0,                      $g,     undef, undef,     "top match must be expected classification",                        "top match must be expected classification",                       \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "options for controlling which alerts cause a sequence to FAIL";
#        option               type   default                group  requires incompat    preamble-output                                                     help-output    
opt_Add("--alt_list",     "boolean",  0,                     $g,     undef, undef,     "output summary of all alerts and exit",                            "output summary of all alerts and exit",                                \%opt_HH, \@opt_order_A);
opt_Add("--alt_pass",      "string",  undef,                 $g,     undef, undef,     "specify that alert codes in <s> DO     cause FAILure",             "specify that alert codes in comma-separated <s> DO NOT cause FAILure", \%opt_HH, \@opt_order_A);
opt_Add("--alt_fail",      "string",  undef,                 $g,     undef, undef,     "specify that alert codes in <s> DO NOT cause FAILure",             "specify that alert codes in comma-separated <s> DO     cause FAILure", \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "options for tuning classification alerts";
#     option                type         default            group   requires incompat     preamble-output                                                   help-output    
opt_Add("--lowcovthresh",   "real",    0.9,                  $g,   undef,   undef,        "fractional coverage threshold for 'low coverage' is <x>",        "fractional coverage threshold for 'low coverage' alert is <x>",       \%opt_HH, \@opt_order_A);
opt_Add("--lowscthresh",    "real",    0.3,                  $g,   undef,   undef,        "bits per nucleotide threshold for 'low score' is <x>",           "bits per nucleotide threshold for 'low score' alert is <x>",          \%opt_HH, \@opt_order_A);
opt_Add("--vlowscthresh",   "real",    0.2,                  $g,   undef,   undef,        "bits per nucleotide threshold for 'very low score' is <x>",      "bits per nucleotide threshold for 'very low score' alert is <x>",     \%opt_HH, \@opt_order_A);
opt_Add("--lowdiffthresh",  "real",    0.06,                 $g,   undef,   undef,        "bits per nucleotide diff threshold for 'low diff' is <x>",       "bits per nucleotide diff threshold for 'low diff' alert is <x>",      \%opt_HH, \@opt_order_A);
opt_Add("--vlowdiffthresh", "real",    0.006,                $g,   undef,   undef,        "bits per nucleotide diff threshold for 'very low diff' is <x>",  "bits per nucleotide diff threshold for 'very low diff' alert is <x>", \%opt_HH, \@opt_order_A);
opt_Add("--biasfract",      "real",    0.25,                 $g,   undef,   undef,        "fractional threshold for 'high bias' is <x>",                    "fractional threshold for 'high bias' alert is <x>",                   \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "options for tuning nucleotide-based annotation errors:";
#        option               type   default                group  requires incompat   preamble-output                                                             help-output    
opt_Add("--ppmin",          "real",  0.8,                    $g,     undef, undef,     "set minimum allowed posterior probability at feature segment ends to <x>", "set minimum allowed posterior probability at feature segment ends to <x>", \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "options for tuning protein validation with blastx";
#        option               type   default                group  requires incompat   preamble-output                                                                                 help-output    
opt_Add("--xminntlen",   "integer",  30,                     $g,     undef, undef,     "min CDS/mat_peptide/gene length for feature table output and blastx analysis is <n>",           "min CDS/mat_peptide/gene length for feature table output and blastx analysis is <n>", \%opt_HH, \@opt_order_A);
opt_Add("--xalntol",     "integer",  5,                      $g,     undef, undef,     "max allowed difference in nucleotides b/t nucleotide and blastx start/end predictions is <n>",  "max allowed difference in nucleotides b/t nucleotide and blastx start/end postions is <n>", \%opt_HH, \@opt_order_A);
opt_Add("--xmaxins",     "integer",  27,                     $g,     undef, undef,     "max allowed nucleotide insertion length in blastx validation is <n>",                           "max allowed nucleotide insertion length in blastx validation is <n>", \%opt_HH, \@opt_order_A);
opt_Add("--xmaxdel",     "integer",  27,                     $g,     undef, undef,     "max allowed nucleotide deletion length in blastx validation is <n>",                            "max allowed nucleotide deletion length in blastx validation is <n>", \%opt_HH, \@opt_order_A);
opt_Add("--xlonescore",  "integer",  80,                     $g,     undef, undef,     "minimum score for a lone blastx hit (not supported by a CM hit) to cause an error ",            "minimum score for a lone blastx (not supported by a CM hit) to cause an error is <n>", \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "options for modifying cmalign runs";
#        option               type   default                group  requires incompat   preamble-output                                                                help-output    
opt_Add("--mxsize",     "integer", 8000,                    $g,    undef, undef,      "set max allowed dp matrix size --mxsize value for cmalign calls to <n> Mb",    "set max allowed dp matrix size --mxsize value for cmalign calls to <n> Mb", \%opt_HH, \@opt_order_A);
opt_Add("--tau",        "real",    1E-3,                    $g,    undef, undef,      "set the initial tau value for cmalign to <x>",                                 "set the initial tau value for cmalign to <x>", \%opt_HH, \@opt_order_A);
opt_Add("--nofixedtau", "boolean", 0,                       $g,    undef, undef,      "fix the tau value when running cmalign, allow it to increase if nec",          "do not fix the tau value when running cmalign, allow it to decrease if nec", \%opt_HH, \@opt_order_A);
opt_Add("--nosub",      "boolean", 0,                       $g,    undef, undef,      "use alternative alignment strategy for truncated sequences",                   "use alternative alignment strategy for truncated sequences", \%opt_HH, \@opt_order_A);
opt_Add("--noglocal",   "boolean", 0,                       $g,"--nosub", undef,      "do not run cmalign in glocal mode (run in local mode)",                        "do not run cmalign in glocal mode (run in local mode)", \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "options related to parallelization on compute farm";
#     option            type       default                group   requires incompat    preamble-output                                                help-output    
opt_Add("-p",           "boolean", 0,                       $g,    undef,  undef,      "parallelize cmsearch/cmalign on a compute farm",              "parallelize cmsearch/cmalign on a compute farm", \%opt_HH, \@opt_order_A);
opt_Add("-q",           "string",  undef,                   $g,     "-p",  undef,      "use qsub info file <s> instead of default",                   "use qsub info file <s> instead of default", \%opt_HH, \@opt_order_A);
opt_Add("--nkb",        "integer", 10,                      $g,     "-p",  undef,      "number of KB of seq for each cmsearch farm job is <n>",       "number of KB of sequence for each cmsearch farm job is <n>", \%opt_HH, \@opt_order_A);
opt_Add("--wait",       "integer", 500,                     $g,     "-p",  undef,      "allow <n> minutes for cmsearch jobs on farm",                 "allow <n> wall-clock minutes for cmsearch jobs on farm to finish, including queueing time", \%opt_HH, \@opt_order_A);
opt_Add("--errcheck",   "boolean", 0,                       $g,     "-p",  undef,      "consider any farm stderr output as indicating a job failure", "consider any farm stderr output as indicating a job failure", \%opt_HH, \@opt_order_A);
opt_Add("--maxnjobs",   "integer", 2500,                    $g,     "-p",  undef,      "maximum allowed number of jobs for compute farm",             "set max number of jobs to submit to compute farm to <n>", \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "optional output files";
#       option       type       default                  group  requires incompat  preamble-output                         help-output    
opt_Add("--ftrinfo",    "boolean", 0,                       $g,    undef, undef, "output internal feature information",   "create file with internal feature information", \%opt_HH, \@opt_order_A);
opt_Add("--sgminfo",    "boolean", 0,                       $g,    undef, undef, "output internal segment information",   "create file with internal segment information", \%opt_HH, \@opt_order_A);
opt_Add("--altinfo",    "boolean", 0,                       $g,    undef, undef, "output internal error information",     "create file with internal error information", \%opt_HH, \@opt_order_A);

$opt_group_desc_H{++$g} = "options for skipping stages and using files from earlier, identical runs, primarily useful for debugging";
#     option               type       default            group   requires    incompat                    preamble-output                                            help-output    
opt_Add("--skipalign",     "boolean", 0,                    $g,   undef,      "-f,--nkb,--maxnjobs,--wait",         "skip the cmalign step, use existing results",             "skip the cmscan step, use results from an earlier run of the script", \%opt_HH, \@opt_order_A);

# This section needs to be kept in sync (manually) with the opt_Add() section above
my %GetOptions_H = ();
my $usage    = "Usage: dnaorg_annotate.pl [-options] <fasta file to annotate> <output directory to create>\n";
$usage      .= "\n";
my $synopsis = "dnaorg_annotate.pl :: classify and annotate sequences using a CM library";
my $options_okay = 
    &GetOptions('h'            => \$GetOptions_H{"-h"}, 
# basic options
                'f'            => \$GetOptions_H{"-f"},
                'v'            => \$GetOptions_H{"-v"},
                's'            => \$GetOptions_H{"-s"}, 
                'm=s'          => \$GetOptions_H{"-m"}, 
                'i=s'          => \$GetOptions_H{"-i"}, 
                'b=s'          => \$GetOptions_H{"-b"}, 
                'n=s'          => \$GetOptions_H{"-n"}, 
                'keep'         => \$GetOptions_H{"--keep"},
# options related to expected classification
                'group=s'     => \$GetOptions_H{"--group"},
                'subgroup=s'  => \$GetOptions_H{"--subgroup"},
                'cthresh=s'   => \$GetOptions_H{"--cthresh"},
                'ctoponly'    => \$GetOptions_H{"--ctoponly"},
# options for controlling which alerts cause failure
                "alt_list"    => \$GetOptions_H{"--alt_list"},
                "alt_pass=s"  => \$GetOptions_H{"--alt_pass"},
                "alt_fail=s"  => \$GetOptions_H{"--alt_fail"},
# options for tuning classification alerts
                "lowcovthresh=s"   => \$GetOptions_H{"--lowcovthresh"},
                "lowscthresh=s"    => \$GetOptions_H{"--lowscthresh"},
                "vlowscthresh=s"   => \$GetOptions_H{"--vlowscthresh"},
                "lowdiffthresh=s"  => \$GetOptions_H{"--lowdiffthresh"},
                "vlowdiffthresh=s" => \$GetOptions_H{"--vlowdiffthresh"},
                'biasfract=s'      => \$GetOptions_H{"--biasfract"},  
# options for tuning nucleotide-based annotation errors
                'ppmin=s'      => \$GetOptions_H{"--ppmin"},
# options for tuning protein validation with blastx
                'xminntlen=s'  => \$GetOptions_H{"--xminntlen"},
                'xalntol=s'    => \$GetOptions_H{"--xalntol"},
                'xmaxins=s'    => \$GetOptions_H{"--xmaxins"},
                'xmaxdel=s'    => \$GetOptions_H{"--xmaxdel"},
                'xlonescore=s' => \$GetOptions_H{"--xlonescore"},
# options for changing search sensitivity modes
                'mxsize=s'     => \$GetOptions_H{"--mxsize"},
                'tau=s'        => \$GetOptions_H{"--tau"},
                'nofixedtau'   => \$GetOptions_H{"--nofixedtau"},
                'nosub'        => \$GetOptions_H{"--nosub"},
                'noglocal'     => \$GetOptions_H{"--noglocal"},
# options related to parallelization
                'p'            => \$GetOptions_H{"-p"},
                'q=s'          => \$GetOptions_H{"-q"},
                'nkb=s'        => \$GetOptions_H{"--nkb"}, 
                'wait=s'       => \$GetOptions_H{"--wait"},
                'errcheck'     => \$GetOptions_H{"--errcheck"},
                'maxnjobs=s'   => \$GetOptions_H{"--maxnjobs"},
# optional output files
                'ftrinfo'      => \$GetOptions_H{"--ftrinfo"}, 
                'sgminfo'      => \$GetOptions_H{"--sgminfo"},
                'seqinfo'      => \$GetOptions_H{"--seqinfo"}, 
                'altinfo'      => \$GetOptions_H{"--altinfo"},
# options for skipping stages, using earlier results
                'skipalign'     => \$GetOptions_H{"--skipalign"});

my $total_seconds     = -1 * ofile_SecondsSinceEpoch(); # by multiplying by -1, we can just add another secondsSinceEpoch call at end to get total time
my $executable        = $0;
my $date              = scalar localtime();
my $version           = "0.45x";
my $model_version_str = "1p0"; 
my $qsub_version_str  = "1p0"; 
my $releasedate       = "Mar 2019";
my $pkgname           = "dnaorg";

# make *STDOUT file handle 'hot' so it automatically flushes whenever we print to it
# it is printed to
select *STDOUT;
$| = 1;

# print help and exit if necessary
if((! $options_okay) || ($GetOptions_H{"-h"})) { 
  ofile_OutputBanner(*STDOUT, $pkgname, $version, $releasedate, $synopsis, $date, undef);
  opt_OutputHelp(*STDOUT, $usage, \%opt_HH, \@opt_order_A, \%opt_group_desc_H);
  if(! $options_okay) { die "ERROR, unrecognized option;"; }
  else                { exit 0; } # -h, exit with 0 status
}

# set options in opt_HH
opt_SetFromUserHash(\%GetOptions_H, \%opt_HH);

# validate options (check for conflicts)
opt_ValidateSet(\%opt_HH, \@opt_order_A);

#######################################
# deal with --alt_list option, if used
#######################################
# initialize error related data structures, we have to do this early, so we can deal with --alt_list opition
my %alt_info_HH = (); 
dng_AlertInfoInitialize(\%alt_info_HH, undef);
if(opt_IsUsed("--alt_list",\%opt_HH)) { 
  alert_list_option(\%alt_info_HH);
  exit 0;
}

# check that number of command line args is correct
if(scalar(@ARGV) != 2) {   
  print "Incorrect number of command line arguments.\n";
  print $usage;
  print "\nTo see more help on available options, do dnaorg_annotate.pl -h\n\n";
  exit(1);
}

my ($fa_file, $dir) = (@ARGV);

############################################################
# option checks that are too sophisticated for epn-options
############################################################
# enforce that lowscthresh >= vlowscthresh
if(opt_IsUsed("--lowscthresh",\%opt_HH) || opt_IsUsed("--vlowscthresh",\%opt_HH)) { 
  if(opt_Get("--lowscthresh",\%opt_HH) < opt_Get("--vlowscthresh",\%opt_HH)) { 
    die sprintf("ERROR, with --lowscthresh <x> and --vlowscthresh <y>, <x> must be less than <y> (got <x>: %f, <y>: %f)\n", 
                opt_Get("--lowscthresh",\%opt_HH), opt_Get("--vlowscthresh",\%opt_HH)); 
  }
}
# enforce that lowdiffthresh >= vlowdiffthresh
if(opt_IsUsed("--lowdiffthresh",\%opt_HH) || opt_IsUsed("--vlowdiffthresh",\%opt_HH)) { 
  if(opt_Get("--lowdiffthresh",\%opt_HH) < opt_Get("--vlowdiffthresh",\%opt_HH)) { 
    die sprintf("ERROR, with --lowdiffthresh <x> and --vlowdiffthresh <y>, <x> must be less than <y> (got <x>: %f, <y>: %f)\n", 
                opt_Get("--lowdiffthresh",\%opt_HH), opt_Get("--vlowdiffthresh",\%opt_HH)); 
  }
}

# enforce that --alt_pass and --alt_fail options are valid
if((opt_IsUsed("--alt_pass", \%opt_HH)) || (opt_IsUsed("--alt_fail", \%opt_HH))) { 
  alert_pass_fail_options(\%alt_info_HH, \%opt_HH);
}

#############################
# create the output directory
#############################
my $cmd;               # a command to run with utl_RunCommand()
my @early_cmd_A = ();  # array of commands we run before our log file is opened

if($dir !~ m/\/$/) { $dir =~ s/\/$//; } # remove final '/' if it exists
if(-d $dir) { 
  $cmd = "rm -rf $dir";
  if(opt_Get("-f", \%opt_HH)) { utl_RunCommand($cmd, opt_Get("-v", \%opt_HH), 0, undef); push(@early_cmd_A, $cmd); }
  else                        { die "ERROR directory named $dir already exists. Remove it, or use -f to overwrite it."; }
}
if(-e $dir) { 
  $cmd = "rm $dir";
 if(opt_Get("-f", \%opt_HH)) { utl_RunCommand($cmd, opt_Get("-v", \%opt_HH), 0, undef); push(@early_cmd_A, $cmd); }
  else                        { die "ERROR a file named $dir already exists. Remove it, or use -f to overwrite it."; }
}

# create the dir
$cmd = "mkdir $dir";
utl_RunCommand($cmd, opt_Get("-v", \%opt_HH), 0, undef);
push(@early_cmd_A, $cmd);

my $dir_tail = $dir;
$dir_tail =~ s/^.+\///; # remove all but last dir
my $out_root = $dir . "/" . $dir_tail . ".dnaorg_annotate";

#############################################
# output program banner and open output files
#############################################
# output preamble
my @arg_desc_A = ();
my @arg_A      = ();
my %extra_H    = ();
$extra_H{"\$DNAORGDIR"}       = $env_dnaorgdir;
$extra_H{"\$DNAORGBLASTDIR"}  = $env_dnaorgblastdir;
ofile_OutputBanner(*STDOUT, $pkgname, $version, $releasedate, $synopsis, $date, \%extra_H);
opt_OutputPreamble(*STDOUT, \@arg_desc_A, \@arg_A, \%opt_HH, \@opt_order_A);

# open the log and command files:
# set output file names and file handles, and open those file handles
my %ofile_info_HH = ();  # hash of information on output files we created,
                         # 1D keys: 
                         #  "fullpath":  full path to the file
                         #  "nodirpath": file name, full path minus all directories
                         #  "desc":      short description of the file
                         #  "FH":        file handle to output to for this file, maybe undef
                         # 2D keys (at least initially)
                         #  "log":  log file of what's output to stdout
                         #  "cmd":  command file with list of all commands executed
                         #  "list": file with list of all output files created

# open the log and command files 
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "log",  $out_root . ".log",  1, "Output printed to screen");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "cmd",  $out_root . ".cmd",  1, "List of executed commands");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "list", $out_root . ".list", 1, "List and description of all output files");
my $log_FH = $ofile_info_HH{"FH"}{"log"};
my $cmd_FH = $ofile_info_HH{"FH"}{"cmd"};
my $FH_HR  = $ofile_info_HH{"FH"};
# output files are all open, if we exit after this point, we'll need
# to close these first.

# open optional output files
if(opt_Get("--ftrinfo", \%opt_HH)) { 
  ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "ftrinfo", $out_root . ".ftrinfo", 1, "Feature information (created due to --ftrinfo)");
}
if(opt_Get("--sgminfo", \%opt_HH)) { 
  ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "sgminfo", $out_root . ".sgminfo", 1, "Segment information (created due to --sgminfo)");
}
if(opt_Get("--altinfo", \%opt_HH)) { 
  ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "altinfo", $out_root . ".altinfo", 1, "Alert information (created due to --altinfo)");
}

# now we have the log file open, output the banner there too
ofile_OutputBanner($log_FH, $pkgname, $version, $releasedate, $synopsis, $date, \%extra_H);
opt_OutputPreamble($log_FH, \@arg_desc_A, \@arg_A, \%opt_HH, \@opt_order_A);

# output any commands we already executed to $log_FH
foreach $cmd (@early_cmd_A) { 
  print $cmd_FH $cmd . "\n";
}

my $progress_w = 60; # the width of the left hand column in our progress output, hard-coded
my $start_secs = ofile_OutputProgressPrior("Validating input", $progress_w, $log_FH, *STDOUT);

# make sure the sequence, CM, modelinfo, qsubinfo files exist
utl_FileValidateExistsAndNonEmpty($fa_file, "input fasta sequence file", undef, 1, \%{$ofile_info_HH{"FH"}}); # '1' says: die if it doesn't exist or is empty

my $df_model_dir = "/panfs/pan1/infernal/notebook/19_0307_virus_dnaorg_classify_annotate_merge/norovirus-testing-20190318/models";

my $df_cm_file   = $df_model_dir . "/" . "dnaorg." . $model_version_str . ".cm";
my $cm_file      = undef;
if(! opt_IsUsed("-m", \%opt_HH)) { $cm_file = $df_cm_file; }
else                             { $cm_file = opt_Get("-m", \%opt_HH); }
if(! opt_IsUsed("-m", \%opt_HH)) {
  utl_FileValidateExistsAndNonEmpty($cm_file, "default CM file", undef, 1, \%{$ofile_info_HH{"FH"}}); # '1' says: die if it doesn't exist or is empty
}
else { # -m used on the command line
  utl_FileValidateExistsAndNonEmpty($cm_file, "CM file specified with -i", undef, 1, \%{$ofile_info_HH{"FH"}}); # '1' says: die if it doesn't exist or is empty
}

my $df_modelinfo_file = $df_model_dir . "/" . "dnaorg." . $model_version_str . ".modelinfo";
my $modelinfo_file = undef;
if(! opt_IsUsed("-i", \%opt_HH)) { $modelinfo_file = $df_modelinfo_file; }
else                             { $modelinfo_file = opt_Get("-i", \%opt_HH); }
if(! opt_IsUsed("-i", \%opt_HH)) {
  utl_FileValidateExistsAndNonEmpty($modelinfo_file, "default model info file", undef, 1, \%{$ofile_info_HH{"FH"}}); # '1' says: die if it doesn't exist or is empty
}
else { # -i used on the command line
  utl_FileValidateExistsAndNonEmpty($modelinfo_file, "model info file specified with -i", undef, 1, \%{$ofile_info_HH{"FH"}}); # '1' says: die if it doesn't exist or is empty
}

my $qsubinfo_file    = undef;
my $df_qsubinfo_file = $df_model_dir . "/" . "dnaorg." . $qsub_version_str . ".qsubinfo";
if(! opt_IsUsed("-q", \%opt_HH)) { $qsubinfo_file = $df_qsubinfo_file; }
else                             { $qsubinfo_file = opt_Get("-q", \%opt_HH); }

if(opt_IsUsed("-p", \%opt_HH)) { 
  # check for existence of qsub info file
  if(! opt_IsUsed("-q", \%opt_HH)) {
    utl_FileValidateExistsAndNonEmpty($qsubinfo_file, "default qsub info file", undef, 1, \%{$ofile_info_HH{"FH"}}); # '1' says: die if it doesn't exist or is empty
  }
  else { # -q used on the command line
    utl_FileValidateExistsAndNonEmpty($qsubinfo_file, "qsub info file specified with -q", undef, 1, \%{$ofile_info_HH{"FH"}}); # 1 says: die if it doesn't exist or is empty
  }
}
# make sure the blastdb directory exists
my $blastdb_dir = (opt_IsUsed("-b", \%opt_HH)) ? opt_Get("-b", \%opt_HH) : $df_model_dir;
$blastdb_dir =~ s/\/$//; # remove trailing '/'
if(! -d $blastdb_dir) { 
  ofile_FAIL(sprintf("ERROR, %sblast DB directory $blastdb_dir%s does not exist", 
                     opt_IsUsed("-b", \%opt_HH) ? "" : "default", 
                     opt_IsUsed("-b", \%opt_HH) ? "specified with -b" : ""), "dnaorg", 1, $FH_HR);
}
# we check for existence of blast DB files after we parse the model info file

###################################################
# make sure the required executables are executable
###################################################
my %execs_H = (); # hash with paths to all required executables
$execs_H{"cmalign"}           = $inf_exec_dir   . "/cmalign";
$execs_H{"cmfetch"}           = $inf_exec_dir   . "/cmfetch";
$execs_H{"cmsearch"}          = $inf_exec_dir   . "/cmsearch";
$execs_H{"esl-seqstat"}       = $esl_exec_dir   . "/esl-seqstat";
$execs_H{"esl-ssplit"}        = $esl_ssplit;
$execs_H{"blastx"}            = $blast_exec_dir . "/blastx";
$execs_H{"parse_blastx"}      = $env_dnaorgdir  . "/dnaorg_scripts/parse_blastx.pl";
utl_ExecHValidate(\%execs_H, \%{$ofile_info_HH{"FH"}});

###########################
# Parse the model info file
###########################
my @mdl_info_AH  = (); # array of hashes with model info
my %ftr_info_HAH = (); # hash of array of hashes with feature info 
my %sgm_info_HAH = (); # hash of array of hashes with segment info 

utl_FileValidateExistsAndNonEmpty($modelinfo_file, "model info file", undef, 1, $FH_HR);
dng_ModelInfoFileParse($modelinfo_file, \@mdl_info_AH, \%ftr_info_HAH, $FH_HR);

# validate %mdl_info_AH
my @mdl_reqd_keys_A = ("name", "cmfile", "length");
my $nmdl = utl_AHValidate(\@mdl_info_AH, \@mdl_reqd_keys_A, "ERROR reading model info from $modelinfo_file", $FH_HR);
my $mdl_idx;

# if --group or --subgroup used, make sure at least one model has that group/subgroup
my $exp_group    = opt_Get("--group", \%opt_HH);
my $exp_subgroup = opt_Get("--subgroup", \%opt_HH);
if(opt_IsUsed("--group", \%opt_HH)) { 
  if(utl_AHCountKeyValue(\@mdl_info_AH, "group", $exp_group) == 0) { 
    ofile_FAIL("ERROR with --group $exp_group, did not read any models with group defined as $exp_group in model info file:\n$modelinfo_file", "dnaorg", 1, $FH_HR);
  }
}
if(opt_IsUsed("--subgroup", \%opt_HH)) { 
  if(! defined $exp_group) {
    # opt_ValidateSet() will have enforced --subgroup requires --group, but we check again 
    ofile_FAIL("ERROR with --subgroup, the --group option must also be used", "dnaorg", 1, $FH_HR);
  }
  if(utl_AHCountKeyValue(\@mdl_info_AH, "subgroup", $exp_subgroup) == 0) { 
    ofile_FAIL("ERROR with --group $exp_group and --subgroup $exp_subgroup,\ndid not read any models with group defined as $exp_group and subgroup defined as $exp_subgroup in model info file:\n$modelinfo_file", "dnaorg", 1, $FH_HR);
  }
}

my @ftr_reqd_keys_A = ("type", "coords");
for(my $mdl_idx = 0; $mdl_idx < $nmdl; $mdl_idx++) { 
  my $mdl_name = $mdl_info_AH[$mdl_idx]{"name"};
  utl_AHValidate(\@{$ftr_info_HAH{$mdl_name}}, \@ftr_reqd_keys_A, "ERROR reading feature info for model $mdl_name from $modelinfo_file", $FH_HR);
  dng_FeatureInfoImputeLength(\@{$ftr_info_HAH{$mdl_name}}, $FH_HR);
  dng_FeatureInfoImputeSourceIdx(\@{$ftr_info_HAH{$mdl_name}}, $FH_HR);
  dng_FeatureInfoImputeParentIdx(\@{$ftr_info_HAH{$mdl_name}}, $FH_HR);
  dng_FeatureInfoImpute3paFtrIdx(\@{$ftr_info_HAH{$mdl_name}}, $FH_HR);
  dng_FeatureInfoImputeOutname(\@{$ftr_info_HAH{$mdl_name}});
  dng_SegmentInfoPopulate(\@{$sgm_info_HAH{$mdl_name}}, \@{$ftr_info_HAH{$mdl_name}}, $FH_HR);
}

# if there are any CDS features, validate that the BLAST db files we need exist
for(my $mdl_idx = 0; $mdl_idx < $nmdl; $mdl_idx++) { 
  my $mdl_name = $mdl_info_AH[$mdl_idx]{"name"};
  my $ncds = dng_FeatureInfoCountType(\@{$ftr_info_HAH{$mdl_name}}, "CDS"); 
  if($ncds > 0) { 
    if(! defined $mdl_info_AH[$mdl_idx]{"blastdb"}) { 
      ofile_FAIL("ERROR, model $mdl_name has $ncds CDS features, but \"blastdb\" is not defined in model info file:\n$modelinfo_file\n", "dnaorg", 1, $FH_HR);
    }
    my $blastdb = $blastdb_dir . "/" . $mdl_info_AH[$mdl_idx]{"blastdb"};
    foreach my $sfx ("", ".phr", ".pin", ".psq") { 
      if(! -s ($blastdb . $sfx)) { 
        ofile_FAIL("ERROR, required blastdb file $blastdb.$sfx for model $mdl_name does not exist in directory $blastdb_dir.\nUse -b to specify a different directory.\n", "dnaorg", 1, $FH_HR);
      }
    }
    $mdl_info_AH[$mdl_idx]{"blastdbpath"} = $blastdb;
  }
}

##################################
# Validate the input sequence file
##################################
my $seqstat_file = $out_root . ".seqstat";
my @seq_name_A = (); # [0..$i..$nseq-1]: name of sequence $i in input file
my %seq_len_H = ();  # key: sequence name (guaranteed to be unique), value: seq length
utl_RunCommand($execs_H{"esl-seqstat"} . " --dna -a $fa_file > $seqstat_file", opt_Get("-v", \%opt_HH), 0, $FH_HR);
if(-e $fa_file . ".ssi") { unlink $fa_file . ".ssi"}; # remove SSI file if it exists, it may be out of date
ofile_AddClosedFileToOutputInfo(\%ofile_info_HH, undef, "seqstat", $seqstat_file, 0, "esl-seqstat -a output for input fasta file");
my $tot_len_nt = sqf_EslSeqstatOptAParse($seqstat_file, \@seq_name_A, \%seq_len_H, $FH_HR);
my $nseq = scalar(@seq_name_A);
#my %seq_idx_H = ();  # key: sequence name <sqname>, value index [0..$nseq-1] of <sqname> in @seq_name_A
#utl_IdxHFromA(\%seq_idx_H, \@seq_name_A, undef, $FH_HR);

ofile_OutputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

####################################
# Classification: cmsearch round 1
####################################
my $r1_cmsearch_opts = " --cpu 0 --trmF3 --noali --hmmonly"; 
cmsearch_wrapper(\%execs_H, $cm_file, undef, $fa_file, $r1_cmsearch_opts, $out_root, 1, $nseq, $tot_len_nt, $progress_w, \%opt_HH, \%ofile_info_HH);

# sort into a new file by score
my $r1_tblout_key  = "search.r1.tblout"; # set in cmsearch_wrapper()
my $r1_tblout_file = $ofile_info_HH{"fullpath"}{$r1_tblout_key};
my $r1_sort_tblout_file = $r1_tblout_file . ".sort";
my $r1_sort_tblout_key  = $r1_tblout_key . ".sort";
utl_FileValidateExistsAndNonEmpty($r1_tblout_file, "round 1 search tblout output", undef, 1, \%{$ofile_info_HH{"FH"}}); # '1' says: die if it doesn't exist or is empty

my $sort_cmd = "grep -v ^\# $r1_tblout_file | sort -k 1,1 -k 3,3rn > $r1_sort_tblout_file"; 
utl_RunCommand($sort_cmd, opt_Get("-v", \%opt_HH), 0, $FH_HR);
ofile_AddClosedFileToOutputInfo(\%ofile_info_HH, "dnaorg", $r1_sort_tblout_key, $r1_sort_tblout_file, 0, "sorted round 1 search tblout file");

# parse the round 1 sorted tblout file
my %cls_results_HHH = (); # key 1: sequence name, 
                          # key 2: ("r1.1","r1.2","r1.eg","r2")
                          # key 3: ("model", "coords", "bstrand", "score", "bias")
cmsearch_parse_sorted_tblout($r1_sort_tblout_file, 1, # 1: round 1
                             \@mdl_info_AH, \%cls_results_HHH, \%opt_HH, $FH_HR);

###########################################
# Coverage determination: cmsearch round 2
###########################################
my $mdl_name;               # a model name
my $seq_name;               # a sequence name
my @r2_tblout_key_A  = ();  # array of round 2 search tblout keys in %ofile_info_HH
my @r2_tblout_file_A = ();  # array of round 2 search tblout files 
my $r2_cmsearch_opts = " --cpu 0 --hmmonly --noali"; # cmsearch options for round 2 searches to determine coverage

# fill per-model data structures based on classification reesults
my %mdl_cls_ct_H     = ();  # key is model name $mdl_name, value is number of sequences classified to this model
my %mdl_seq_name_HA  = ();  # key is model name $mdl_name, array is of seq names that r1 search assigned to model $mdl_name 
my %mdl_seq_len_H    = ();  # key is model name $mdl_name, value is summed length of all seqs in @{$mdl_seq_HA{$mdl_name}
populate_per_model_data_structures_given_classification_results(\@seq_name_A, \%seq_len_H, \%cls_results_HHH, undef, undef, undef, 
                                                                \%mdl_seq_name_HA, \%mdl_seq_len_H, \%mdl_cls_ct_H, $FH_HR);

# for each model, fetch the sequences classified to it and perform the round 2 search to get sequence coverage
my $sqfile = Bio::Easel::SqFile->new({ fileLocation => $fa_file }); # the sequence file object
for($mdl_idx = 0; $mdl_idx < $nmdl; $mdl_idx++) { 
  $mdl_name = $mdl_info_AH[$mdl_idx]{"name"};
  if(defined $mdl_seq_name_HA{$mdl_name}) { 
    my $mdl_fa_file = $out_root . "." . $mdl_name . ".fa";
    $sqfile->fetch_seqs_given_names(\@{$mdl_seq_name_HA{$mdl_name}}, 60, $mdl_fa_file);

    # now run cmsearch against this file
    cmsearch_wrapper(\%execs_H, $cm_file, $mdl_name, $mdl_fa_file, $r2_cmsearch_opts, $out_root, 2, scalar(@{$mdl_seq_name_HA{$mdl_name}}), 
                     $mdl_seq_len_H{$mdl_name}, $progress_w, \%opt_HH, \%ofile_info_HH);
    my $r2_tblout_key = "search.r2.$mdl_name.tblout"; # set in cmsearch_wrapper()
    push(@r2_tblout_key_A,  $r2_tblout_key);
    push(@r2_tblout_file_A, $ofile_info_HH{"fullpath"}{$r2_tblout_key});
  }
}

# sort the round 2 search results, we concatenate all model's tblout files and sort them
my $r2_sort_tblout_key  = "search.r2.tblout.sort";
my $r2_sort_tblout_file = $out_root . "." . $r2_sort_tblout_key;
$sort_cmd = "cat " . join(" ", @r2_tblout_file_A) . " | grep -v ^\# | sort -k 1,1 -k 15,15rn -k 16,16g > $r2_sort_tblout_file"; 
utl_RunCommand($sort_cmd, opt_Get("-v", \%opt_HH), 0, $FH_HR);
ofile_AddClosedFileToOutputInfo(\%ofile_info_HH, "dnaorg", $r2_sort_tblout_key, $r2_sort_tblout_file, 0, "sorted round 2 search tblout file");

# parse cmsearch round 2 tblout data
cmsearch_parse_sorted_tblout($r2_sort_tblout_file, 2, # 2: round 2
                             \@mdl_info_AH, \%cls_results_HHH, \%opt_HH, $FH_HR);

############################
# Add classification alerts
############################
# add classification errors based on cls_results_HHH
# keep track of seqs to annotate per model
my %alt_seq_instances_HH = (); # 2D key with info on all instances of per-sequence alerts 
                               # key1: sequence name, key2 alert code, value: alert message
my %cls_output_HH = (); # 2D key with info to output derived from the classification stage
                        # key1: sequence name, key2 one of: "score", "scpnt", "scdiff", "bstrand", "scov", "mcov", "model1", "model2"
add_classification_alerts(\%alt_seq_instances_HH, \%seq_len_H, \@mdl_info_AH, \%alt_info_HH, \%cls_results_HHH, \%cls_output_HH, \%opt_HH, \%ofile_info_HH);

##################
# Align sequences
##################
# create per-model files again, because some classification alerts can cause sequences not to be annotated 
# (e.g. c_mst (minus strand))
# zero out %mdl_seq_name_HA and %mdl_seq_len_H, we'll refill them 
%mdl_seq_name_HA = ();
%mdl_seq_len_H = ();
my %mdl_ant_ct_H = ();  # key is model name, value is number of sequences annotated with that model

populate_per_model_data_structures_given_classification_results(\@seq_name_A, \%seq_len_H, \%cls_results_HHH, \%cls_output_HH, \%alt_info_HH, \%alt_seq_instances_HH,
                                                                \%mdl_seq_name_HA, \%mdl_seq_len_H, \%mdl_ant_ct_H, $FH_HR);

# file names and data structures necessary for the alignment stage
my %stk_file_HA       = ();     # hash of arrays of all stk output files created in cmalignOrNhmmscanWrapper()
                                # 1D key is $mdl_name
my @overflow_seq_A    = ();     # array of sequences that fail cmalign b/c required matrix was too big
my @overflow_mxsize_A = ();     # array of required matrix sizes for each sequence in @overflow_seq_A
my %ftr_results_HHAH  = ();     # 1st dim: hash, keys are model names
                                # 2nd dim: hash, keys are sequence names
                                # 3rd dim: array, 0..$nsgm-1, one per segment
                                # 4th dim: hash of feature results, keys are:
                                # keys include "n_start", "n_stop", "n_stop_c", "n_strand", "n_5trunc", "n_3trunc"
                                # "p_start", "p_stop", "p_strand", "p_query", "p_ins", p_del", "p_trcstop", "p_score"
my %sgm_results_HHAH  = ();     # 1st dim: hash, keys are model names
                                # 2nd dim: hash, keys are sequence names
                                # 3rd dim: array, 0..$nsgm-1, one per segment
                                # 4th dim: hash, keys are "sstart", "sstop", "mstart", "mstop", "strand", "5seqflush", "3seqflush", "5trunc", "3trunc"
my %alt_ftr_instances_HHH = (); # hash of arrays of hashes
                                # key1: sequence name, key2: feature index, key3: alert code, value: alert message
my %mdl_n_div_H = ();           # key is model name, value is number of n_div alerts thrown for that model in alignment stage

# for each model with seqs to align to, create the sequence file and run cmalign
for($mdl_idx = 0; $mdl_idx < $nmdl; $mdl_idx++) { 
  $mdl_name = $mdl_info_AH[$mdl_idx]{"name"};
  if(defined $mdl_seq_name_HA{$mdl_name}) { 

    # fetch seqs
    my $mdl_nseq = scalar(@{$mdl_seq_name_HA{$mdl_name}});
    my $mdl_fa_file = $out_root . "." . $mdl_name . ".a.fa";
    $sqfile->fetch_seqs_given_names(\@{$mdl_seq_name_HA{$mdl_name}}, 60, $mdl_fa_file);

    # run cmalign
    @{$stk_file_HA{$mdl_name}} = ();
    cmalign_wrapper(\%execs_H, $cm_file, $mdl_name, $mdl_fa_file, $out_root, scalar(@{$mdl_seq_name_HA{$mdl_name}}), 
                    $mdl_seq_len_H{$mdl_name}, $progress_w, \@{$stk_file_HA{$mdl_name}}, 
                    \@overflow_seq_A, \@overflow_mxsize_A, \%opt_HH, \%ofile_info_HH);

    # add n_div errors: sequences that were too divergent to align (cmalign was unable to align with a DP matrix of allowable size)
    $mdl_n_div_H{$mdl_name} = scalar(@overflow_seq_A);
    if($mdl_n_div_H{$mdl_name} > 0) { 
      alert_add_n_div(\@overflow_seq_A, \@overflow_mxsize_A, \%alt_seq_instances_HH, \%alt_info_HH, \%opt_HH, \%ofile_info_HH);
    }
  }
}

###########################
# Parse cmalign alignments
###########################
$start_secs = ofile_OutputProgressPrior("Determining annotation", $progress_w, $log_FH, *STDOUT);

for($mdl_idx = 0; $mdl_idx < $nmdl; $mdl_idx++) { 
  $mdl_name = $mdl_info_AH[$mdl_idx]{"name"};
  if(defined $mdl_seq_name_HA{$mdl_name}) { 
    my $mdl_nseq = scalar(@{$mdl_seq_name_HA{$mdl_name}});
    initialize_ftr_or_sgm_results_for_model(\@{$mdl_seq_name_HA{$mdl_name}}, \@{$ftr_info_HAH{$mdl_name}}, \%{$ftr_results_HHAH{$mdl_name}}, $FH_HR);
    initialize_ftr_or_sgm_results_for_model(\@{$mdl_seq_name_HA{$mdl_name}}, \@{$sgm_info_HAH{$mdl_name}}, \%{$sgm_results_HHAH{$mdl_name}}, $FH_HR);
    my %seq_inserts_HH = ();
    my $cmalign_stdout_file = $out_root . "." . $mdl_name . ".align.stdout";
    my $cmalign_ifile_file  = $out_root . "." . $mdl_name . ".align.ifile";

    # parse the cmalign --ifile file
    if($mdl_nseq > $mdl_n_div_H{$mdl_name}) { # at least 1 sequence was aligned
      cmalign_parse_ifile($cmalign_ifile_file, \%seq_inserts_HH, \%{$ofile_info_HH{"FH"}});
    }

    # parse the cmalign alignments
    for(my $a = 0; $a < scalar(@{$stk_file_HA{$mdl_name}}); $a++) { 
      if(-s $stk_file_HA{$mdl_name}[$a]) { # skip empty alignments, which will exist for any r1 run that fails
        cmalign_parse_stk_and_add_alignment_alerts($stk_file_HA{$mdl_name}[$a], \%seq_len_H, \%seq_inserts_HH, \@{$sgm_info_HAH{$mdl_name}},
                                                   \@{$ftr_info_HAH{$mdl_name}}, \%alt_info_HH, \%{$sgm_results_HHAH{$mdl_name}},
                                                   \%alt_ftr_instances_HHH, \%opt_HH, \%{$ofile_info_HH{"FH"}});
      }
    }

    # fetch the features and add alerts pertaining to CDS and mature peptides
    fetch_features_and_add_cds_and_mp_alerts($sqfile, $mdl_name, \@{$mdl_seq_name_HA{$mdl_name}}, \%seq_len_H, 
                                             \@{$ftr_info_HAH{$mdl_name}}, \@{$sgm_info_HAH{$mdl_name}}, \%alt_info_HH, 
                                             \%{$sgm_results_HHAH{$mdl_name}}, \%{$ftr_results_HHAH{$mdl_name}}, 
                                             \%alt_ftr_instances_HHH, \%opt_HH, \%ofile_info_HH);
  }
}

ofile_OutputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

#########################################################################################
# Run BLASTX: all full length sequences and all fetched CDS features versus all proteins
#########################################################################################
$start_secs = ofile_OutputProgressPrior("Running and parsing BLASTX", $progress_w, $log_FH, *STDOUT);

for($mdl_idx = 0; $mdl_idx < $nmdl; $mdl_idx++) { 
  $mdl_name = $mdl_info_AH[$mdl_idx]{"name"};
  if(defined $mdl_seq_name_HA{$mdl_name}) { 
    run_blastx_and_summarize_output(\%execs_H, $out_root, \%{$mdl_info_AH[$mdl_idx]}, \@{$ftr_info_HAH{$mdl_name}}, 
                                    \%opt_HH, \%ofile_info_HH);

    parse_blastx_results($ofile_info_HH{"fullpath"}{($mdl_name . ".blastx-summary")}, \@{$mdl_seq_name_HA{$mdl_name}}, \%seq_len_H, 
                         \@{$ftr_info_HAH{$mdl_name}}, \%{$ftr_results_HHAH{$mdl_name}}, \%opt_HH, \%ofile_info_HH);

    add_blastx_alerts(\@{$mdl_seq_name_HA{$mdl_name}}, \%seq_len_H, \@{$ftr_info_HAH{$mdl_name}}, \%alt_info_HH, 
                      \%{$ftr_results_HHAH{$mdl_name}}, \%alt_ftr_instances_HHH, \%opt_HH, \%{$ofile_info_HH{"FH"}});
  }                
}
ofile_OutputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

##############################################################
# Add b_zft errors for sequences with zero annotated features
##############################################################
# add per-sequence 'b_zft' errors (zero annotated features)
for($mdl_idx = 0; $mdl_idx < $nmdl; $mdl_idx++) { 
  $mdl_name = $mdl_info_AH[$mdl_idx]{"name"};
  if(defined $mdl_seq_name_HA{$mdl_name}) { 
    alert_add_b_zft(\@{$mdl_seq_name_HA{$mdl_name}}, \@{$ftr_info_HAH{$mdl_name}}, \%alt_info_HH, \%{$ftr_results_HHAH{$mdl_name}}, 
                    \%alt_seq_instances_HH, \%alt_ftr_instances_HHH, \%opt_HH, \%{$ofile_info_HH{"FH"}});
  }
}

################################
# Output annotations and alerts
################################
# open files for writing
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "ant_tbl",      $out_root . ".sqa.tbl", 1, "per-sequence tabular annotation summary file");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "cls_tbl",      $out_root . ".sqc.tbl", 1, "per-sequence tabular classification summary file");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "ftr_tbl",      $out_root . ".ftr.tbl", 1, "per-feature tabular summary file");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "sgm_tbl",      $out_root . ".sgm.tbl", 1, "per-model-segment tabular summary file");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "mdl_tbl",      $out_root . ".mdl.tbl", 1, "per-model tabular summary file");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "alt_tbl",      $out_root . ".alt.tbl", 1, "per-alert tabular summary file");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "alc_tbl",      $out_root . ".alc.tbl", 1, "alert count tabular summary file");

ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "pass_ftbl",      $out_root . ".ap.sqtable",        1, "Sequin feature table output for passing sequences");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "fail_ftbl",      $out_root . ".af.sqtable",        1, "Sequin feature table output for failing sequences");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "pass_list",      $out_root . ".ap.seqlist",        1, "list of passing sequences");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "fail_list",      $out_root . ".af.seqlist",        1, "list of failing sequences");
ofile_OpenAndAddFileToOutputInfo(\%ofile_info_HH, $pkgname, "alerts_list",    $out_root . ".altlist",           1, "list of errors in the sequence tables");

########################
# tabular output files #
########################
my %class_alerts_per_seq_H = ();

$start_secs = ofile_OutputProgressPrior("Generating tabular output", $progress_w, $log_FH, *STDOUT);
my ($zero_cls, $zero_alt) = output_tabular(\@mdl_info_AH, \%mdl_cls_ct_H, \%mdl_ant_ct_H, \@seq_name_A, \%seq_len_H, 
                                           \%ftr_info_HAH, \%sgm_info_HAH, \%alt_info_HH, \%cls_output_HH, \%ftr_results_HHAH, \%sgm_results_HHAH, 
                                           \%alt_seq_instances_HH, \%alt_ftr_instances_HHH, \%opt_HH, \%ofile_info_HH);
ofile_OutputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

######################
# feature table file #
######################
$start_secs = ofile_OutputProgressPrior("Generating feature table output", $progress_w, $log_FH, *STDOUT);

my $npass = output_feature_table(\%mdl_cls_ct_H, \@seq_name_A, \%ftr_info_HAH, \%sgm_info_HAH, \%alt_info_HH, 
                                 \%cls_results_HHH, \%ftr_results_HHAH, \%sgm_results_HHAH, \%alt_seq_instances_HH,
                                 \%alt_ftr_instances_HHH, \%opt_HH, \%ofile_info_HH);

ofile_OutputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

################################
# output optional output files #
################################
if(exists $ofile_info_HH{"FH"}{"ftrinfo"}) { 
  utl_HAHDump("Feature information", \%ftr_info_HAH, $ofile_info_HH{"FH"}{"ftrinfo"});
}
if(exists $ofile_info_HH{"FH"}{"sgminfo"}) { 
  utl_HAHDump("Segment information", \%sgm_info_HAH, $ofile_info_HH{"FH"}{"sgminfo"});
}
if(exists $ofile_info_HH{"FH"}{"altinfo"}) { 
  dng_AlertInfoDump(\%alt_info_HH, $ofile_info_HH{"FH"}{"altinfo"});
  dng_AlertInfoDump(\%alt_info_HH, *STDOUT);
}

############
# Conclude #
############
# close the two files we may output to stdout and the log
close($ofile_info_HH{"FH"}{"mdl_tbl"}); 
close($ofile_info_HH{"FH"}{"alc_tbl"}); 

my @conclude_A = ();
push(@conclude_A, "#");
if($zero_cls) { 
  push(@conclude_A, "# Zero sequences were classified.");
}
else { 
  push(@conclude_A, "# Summary of classified sequences:");
  push(@conclude_A, "#");
  my @file_A = ();
  utl_FileLinesToArray($ofile_info_HH{"fullpath"}{"mdl_tbl"}, 1, \@file_A, $FH_HR);
  push(@conclude_A, @file_A);
}
push(@conclude_A, "#");
if($zero_alt) { 
  push(@conclude_A, "# Zero alerts were reported.");
}
else { 
  push(@conclude_A, "# Summary of reported alerts:");
  push(@conclude_A, "#");
  my @file_A = ();
  utl_FileLinesToArray($ofile_info_HH{"fullpath"}{"alc_tbl"}, 1, \@file_A, $FH_HR);
  push(@conclude_A, @file_A);
}

foreach my $line (@conclude_A) { 
  ofile_OutputString($log_FH, 1, $line . "\n");
}

$total_seconds += ofile_SecondsSinceEpoch();
ofile_OutputConclusionAndCloseFiles($total_seconds, "DNAORG", $dir, \%ofile_info_HH);

###############
# SUBROUTINES #
################################################################
# List of subroutines in this file, divided into categories. 
#
# The names of the subroutines are meant to be descriptive. The
# convention for subroutine names is to use underscores to separate
# words (e.g. 'get_value_from_array()') for subroutines in *this* file as
# opposed to a Perl module where they're named in camel caps
# (e.g. getValueFromArray()).
#
#################################################################
#
#################################################################
#
# Subroutines related to cmsearch and classification:
# cmsearch_wrapper
# cmsearch_run
# cmsearch_parse_sorted_tblout
# cmsearch_store_hit
# add_classification_errors
# populate_per_model_data_structures_given_classification_results
#
# Subroutines related to cmalign and alignment:
# cmalign_wrapper
# cmalign_wrapper_helper
# cmalign_run
# cmalign_parse_ifile 
# cmalign_parse_stk_and_add_alignment_alerts 
# cmalign_store_overflow
# fetch_features_and_add_cds_and_mp_alerts 
# sqstring_check_start
# sqstring_find_stops 
#
# Subroutines related to blastx:
# add_blastx_alerts 
# run_blastx_and_summarize_output
# parse_blastx_results 
# helper_blastx_breakdown_query
# helper_blastx_breakdown_max_indel_str
# helper_blastx_db_seqname_to_ftr_idx 
#
# Other subroutines related to alerts: 
# alert_list_option
# alert_pass_fail_options
# alert_sequence_instance_add 
# alert_feature_instance_add 
# alert_sequence_instance_fetch
# alert_feature_instance_fetch
# alert_add_b_zft 
# alert_add_n_div 
# alert_instances_check_prevents_annot
#
# Subroutines for creating output:
# output_tabular
# helper_tabular_ftr_results_strand
# helper_tabular_ftr_results_trunc_string
# helper_tabular_sgm_results_trunc_string
# helper_tabular_replace_spaces
#
# output_feature_table
# output_parent_child_relationships 
# helper_ftable_coords_from_nt_prediction 
# helper_ftable_coords_prot_only_prediction 
# helper_ftable_start_stop_arrays_to_coords 
# helper_ftable_coords_to_out_str 
# helper_ftable_add_qualifier_from_ftr_info
# helper_ftable_add_qualifier_from_ftr_results
# helper_ftable_class_model_for_sequence
# helper_ftable_process_sequence_alerts
# helper_ftable_process_feature_alerts
#
# helper_output_sequence_alert_strings
# helper_output_feature_alert_strings
#
# Miscellaneous subroutines:
# initialize_ftr_or_sgm_results()
# convert_pp_char_to_pp_avg ()
# group_subgroup_string_from_classification_results()
#
#################################################################
# Subroutine:  cmsearch_wrapper()
# Incept:      EPN, Mon Mar 18 14:44:46 2019
#
# Purpose:     Run one or more cmsearch jobs on the farm
#              or locally, after possibly splitting up the input
#              sequence file with dng_SplitFastaFile and 
#              then calling dng_CmalignOrCmsearchWrapperHelper(). 
#
# Arguments: 
#  $execs_HR:        ref to executables with "esl-ssplit" and "cmsearch"
#                    defined as keys
#  $mdl_file:        name of model file to use
#  $mdl_name:        name of model to fetch from $mdl_file (undef to not fetch)
#  $seq_file:        name of sequence file with all sequences to run against
#  $opt_str:         option string for cmsearch run
#  $out_root:        string for naming output files
#  $round:           round, 1 or 2 
#  $nseq:            number of sequences in $seq_file
#  $tot_len_nt:      total length of all nucleotides in $seq_file
#  $progress_w:      width for outputProgressPrior output
#  $opt_HHR:         REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:  REF to 2D hash of output file information
#
# Returns:     void, updates $$nfa_created_R with number of
#              fasta files created.
# 
# Dies: If an executable doesn't exist, or cmalign or nhmmscan or esl-ssplit
#       command fails if we're running locally
################################################################# 
sub cmsearch_wrapper { 
  my $sub_name = "cmsearch_wrapper";
  my $nargs_expected = 12;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($execs_HR, $mdl_file, $mdl_name, $seq_file, $opt_str, 
      $out_root, $round, $nseq, $tot_len_nt, $progress_w, $opt_HHR, $ofile_info_HHR) = @_;

  my $log_FH = $ofile_info_HHR->{"FH"}{"log"}; # for convenience
  my $do_parallel = opt_Get("-p", $opt_HHR);

  # set up output file names
  my @seq_file_A  = (); # [0..$nr-1]: name of sequence file for this run
  my @out_file_AH = (); # array of hashes ([0..$nr-1]) of output files for cmsearch runs
  my $nseq_files = 1; # number of sequence files/runs 

  # split up sequence file, if -p and we're going to do more than one job
  my $do_split = 0; # set to '1' if we run dng_SplitFastaFile
  if($do_parallel) { 
    # -p used: we need to split up the sequence file, and submit a separate 
    # cmsearch job for each
    my $targ_nseqfiles = dng_SplitNumSeqFiles($tot_len_nt, $opt_HHR);
    if($targ_nseqfiles > 1) { # we are going to split up the fasta file 
      $do_split = 1;
      $nseq_files = dng_SplitFastaFile($execs_HR->{"esl-ssplit"}, $seq_file, $targ_nseqfiles, $opt_HHR, $ofile_info_HHR);
      # dng_SplitFastaFile will return the actual number of fasta files created, 
      # which can differ from the requested amount (which is $targ_nseqfiles) that we pass in. 
      for(my $i = 0; $i < $nseq_files; $i++) { 
        $seq_file_A[$i] = $seq_file . "." . ($i+1);
      }
    }
    else { # targ_nseqfiles is 1, no need to split
      $seq_file_A[0] = $seq_file;
    }
  }
  else { # -p not used
    $seq_file_A[0] = $seq_file;
  }
    
  # determine description of the runs we are about to do
  my $desc = "";
  if($round == 1) { 
    $desc = ($do_parallel) ? 
        "Submitting $nseq_files cmsearch classification job(s) to the farm" : 
        sprintf("Classifying sequences ($nseq seq%s)", ($nseq > 1) ? "s" : "");
  }
  else { 
    if($do_parallel) { 
      $desc = sprintf("Submitting $nseq_files cmsearch coverage determination job(s) ($mdl_name: $nseq seq%s) to the farm", 
                      ($nseq > 1) ? "s" : "");
    }
    else { 
      $desc = sprintf("Determining sequence coverage ($mdl_name: $nseq seq%s)", ($nseq > 1) ? "s" : "");
    }
  }
  my $start_secs = ofile_OutputProgressPrior($desc, $progress_w, $log_FH, *STDOUT);
  if($do_parallel) { ofile_OutputString($log_FH, 1, "\n"); }
  # run cmsearch
  my $out_key;
  my @out_keys_A = ("stdout", "err", "tblout");
  for(my $s = 0; $s < $nseq_files; $s++) { 
    %{$out_file_AH[$s]} = (); 
    foreach my $out_key (@out_keys_A) { 
      $out_file_AH[$s]{$out_key} = $out_root . ".search.r" . $round . ".s" . $s . "." . $out_key;
    }
    cmsearch_run($execs_HR, $mdl_file, $mdl_name, $seq_file_A[$s], $opt_str, \%{$out_file_AH[$s]}, $opt_HHR, $ofile_info_HHR);   
  }

  if($do_parallel) { 
    # wait for the jobs to finish
    $start_secs = ofile_OutputProgressPrior(sprintf("Waiting a maximum of %d minutes for all farm jobs to finish", opt_Get("--wait", $opt_HHR)), 
                                            $progress_w, $log_FH, *STDOUT);
    my $njobs_finished = dng_WaitForFarmJobsToFinish(0, # we're not running cmalign
                                                     \@out_file_AH, undef, undef, "[ok]", $opt_HHR, $ofile_info_HHR->{"FH"});
    if($njobs_finished != $nseq_files) { 
      ofile_FAIL(sprintf("ERROR in $sub_name only $njobs_finished of the $nseq_files are finished after %d minutes. Increase wait time limit with --wait", opt_Get("--wait", $opt_HHR)), 1, $ofile_info_HHR->{"FH"});
    }
    ofile_OutputString($log_FH, 1, "# "); # necessary because waitForFarmJobsToFinish() creates lines that summarize wait time and so we need a '#' before 'done' printed by ofile_OutputProgressComplete()
  }

  # concatenate files into one
  foreach $out_key (@out_keys_A) { 
    if(($do_parallel) || ($out_key ne "err")) { # .err files don't exist if (! $do_parallel)
      my $concat_key  = sprintf("search.r%s.%s%s", $round, (defined $mdl_name) ? $mdl_name . "." : "", $out_key);                                
      my $concat_file = $out_root . "." . $concat_key;
      my @concat_A = ();
      utl_ArrayOfHashesToArray(\@out_file_AH, \@concat_A, $out_key);
      utl_ConcatenateListOfFiles(\@concat_A, $concat_file, $sub_name, $opt_HHR, $ofile_info_HHR->{"FH"});
      # utl_ConcatenateListOfFiles() removes individual files unless --keep enabled
      ofile_AddClosedFileToOutputInfo($ofile_info_HHR, "dnaorg", $concat_key, $concat_file, 0, sprintf("round $round search $out_key file%s", (defined $mdl_name) ? "for model $mdl_name" : ""));
    }
  }

  # remove sequence files if we created any
  if(($do_split) && (! opt_Get("--keep", $opt_HHR))) { 
    utl_FileRemoveList(\@seq_file_A, $sub_name, $opt_HHR, $ofile_info_HHR->{"FH"});
  }

  ofile_OutputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

  return;
}

#################################################################
# Subroutine:  cmsearch_run()
# Incept:      EPN, Wed Feb  6 12:38:11 2019
#
# Purpose:     Run Infernal's cmsearch executable using $mdl_file
#              as the model file on sequence file $seq_file, either
#              locally or on the farm.
#
# Arguments: 
#  $execs_HR:         ref to hash with paths to cmsearch and cmfetch
#  $mdl_file:         path to the CM file
#  $mdl_name:         name of model to fetch from $mdl_file (undef to not fetch)
#  $seq_file:         path to the sequence file
#  $opt_str:          option string for cmsearch run
#  $out_file_HR:      ref to hash of output files to create
#                     required keys: "stdout", "tblout", "err"
#  $opt_HHR:          REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:   REF to 2D hash of output file information
# 
# Returns:     void
# 
################################################################# 
sub cmsearch_run {
  my $sub_name = "cmsearch_run()";
  my $nargs_expected = 8;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 
  
  my ($execs_HR, $mdl_file, $mdl_name, $seq_file, $opt_str, $out_file_HR, $opt_HHR, $ofile_info_HHR) = @_;
  
  my $FH_HR       = (defined $ofile_info_HHR->{"FH"}) ? $ofile_info_HHR->{"FH"} : undef;
  my $do_parallel = opt_Get("-p", $opt_HHR) ? 1 : 0;

  my $stdout_file = $out_file_HR->{"stdout"};
  my $tblout_file = $out_file_HR->{"tblout"};
  my $err_file    = $out_file_HR->{"err"};
  if(! defined $stdout_file) { ofile_FAIL("ERROR in $sub_name, stdout output file name is undefined", "dnaorg", 1, $FH_HR); }
  if(! defined $tblout_file) { ofile_FAIL("ERROR in $sub_name, tblout output file name is undefined", "dnaorg", 1, $FH_HR); }
  if(! defined $err_file)    { ofile_FAIL("ERROR in $sub_name, err    output file name is undefined", "dnaorg", 1, $FH_HR); }
  if(-e $stdout_file) { unlink $stdout_file; }
  if(-e $tblout_file) { unlink $tblout_file; }
  if(-e $err_file)    { unlink $err_file; }
  
  utl_FileValidateExistsAndNonEmpty($mdl_file, "CM file", $sub_name, 1, $FH_HR); 
  utl_FileValidateExistsAndNonEmpty($seq_file, "sequence file", $sub_name, 1, $FH_HR);

  if(! (defined $opt_str)) { $opt_str = ""; }
  $opt_str .= " --tblout $tblout_file"; 

  my $cmd = undef;
  if(defined $mdl_name) { 
    $cmd = $execs_HR->{"cmfetch"} . " $mdl_file $mdl_name | " . $execs_HR->{"cmsearch"} . " $opt_str - $seq_file > $stdout_file";
  }
  else { 
    $cmd = $execs_HR->{"cmsearch"} . " $opt_str $mdl_file $seq_file > $stdout_file";
  }
  if($do_parallel) { 
    my $job_name = "J" . utl_RemoveDirPath($seq_file);
    my $nsecs  = opt_Get("--wait", $opt_HHR) * 60.;
    my $mem_gb = (opt_Get("--mxsize", $opt_HHR) / 1000.) * 2; # multiply --mxsize Gb by 2 to be safe
    if($mem_gb < 8.) { $mem_gb = 8.; } # set minimum of 8 Gb
    dng_SubmitJob($cmd, $job_name, $err_file, $mem_gb, $nsecs, $opt_HHR, $ofile_info_HHR);
  }
  else { 
    utl_RunCommand($cmd, opt_Get("-v", $opt_HHR), 0, $FH_HR);
  }
  return; 
}

#################################################################
# Subroutine:  cmsearch_parse_sorted_tblout()
# Incept:      EPN, Wed Mar 20 13:30:16 2019
#
# Purpose:     Parse a sorted cmsearch tblout output file and 
#              store results in %{$results_HHHR}. This is 
#              done differently depending on if $round is 1 or 2.
#
# Arguments: 
#  $tblout_file:   name of sorted tblout file to parse
#  $round:         round, '1' or '2'
#  $mdl_info_AHR:  ref to model info array of hashes
#  $results_HHHR:  ref to results 3D hash
#  $opt_HHR:       ref to options 2D hash
#  $FH_HR:         ref to file handle hash
# 
# Returns: void
# 
# Dies: if there's a problem parsing the tblout file
#      
################################################################# 
sub cmsearch_parse_sorted_tblout {
  my $sub_name = "cmsearch_parse_sorted_tblout()";
  my $nargs_expected = 6;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 
  
  my ($tblout_file, $round, $mdl_info_AHR, $results_HHHR, $opt_HHR, $FH_HR) = @_;

  if((! defined $round) || (($round != 1) && ($round != 2))) { 
    ofile_FAIL("ERROR in $sub_name, round is not 1 or 2", 1, $FH_HR);
  }

  # determine if we have an expected group and subgroup
  # (--subgroup requires --group)
  # and if so, fill hashes of model groups and subgroups, 
  # (this data is in @{$mdl_info_HAR} already, we fill 
  # these hashes only for convenience)
  my $exp_group    = opt_Get("--group", \%opt_HH);
  my $exp_subgroup = opt_Get("--subgroup", \%opt_HH);
  # fill hashes of model groups and subgroups, for convenience
  my %mdl_group_H    = ();
  my %mdl_subgroup_H = ();
  my $nmdl = scalar(@{$mdl_info_AHR});
  if($round == 1) { 
    for(my $mdl_idx = 0; $mdl_idx < $nmdl; $mdl_idx++) { 
      my $mdl_name = $mdl_info_AHR->[$mdl_idx]{"name"};
      if(defined $mdl_info_AHR->[$mdl_idx]{"group"}) { 
        $mdl_group_H{$mdl_name} = $mdl_info_AHR->[$mdl_idx]{"group"}; 
      }
      if(defined $mdl_info_AHR->[$mdl_idx]{"subgroup"}) { 
        $mdl_subgroup_H{$mdl_name} = $mdl_info_AHR->[$mdl_idx]{"subgroup"}; 
      }
    }
  }

  my $seq;      # sequence name
  my $model;    # model name
  my $score;    # bit score
  my $m_from;   # model from position
  my $m_to;     # model to position
  my $s_from;   # sequence from position
  my $s_to;     # sequence to position
  my $strand;   # strand of hit
  my $bias;     # bias score
  my $key2;     # key in 2nd dim of %results
  my $group;    # group for current sequence, can be undef
  my $subgroup; # subgroup for current sequence, can be undef
  open(IN, $tblout_file) || ofile_FileOpenFailure($tblout_file, "dnaorg", $sub_name, 1, "reading", $FH_HR);

  while(my $line = <IN>) { 
    my $HR = undef; # ref to 3rd dimension hash in %results_HHH we will update for this hit
    if($line !~ m/^\#/) { 
      chomp $line;
      $seq    = undef;
      $model  = undef;
      $score  = undef;
      $m_from = undef;
      $m_to   = undef;
      $s_from = undef;
      $s_to   = undef;
      $strand = undef;
      my @el_A = split(/\s+/, $line);
      if($round == 1) { # round 1 --trmF3 tblout 
        ##sequence                    modelname  score  start    end strand bounds ovp      seqlen
        ##--------------------------- --------- ------ ------ ------ ------ ------ --- -----------
        #gi|307574518|dbj|AB525810.1| NC_001959   85.5      1    338      +     []  ?          338
        if(scalar(@el_A) != 9) { 
          ofile_FAIL("ERROR parsing $tblout_file for round 1, unexpected number of space-delimited tokens on line $line", "dnaorg", 1, $FH_HR); 
        }
        ($seq, $model, $score, $s_from, $s_to, $strand) = ($el_A[0], $el_A[1], $el_A[2], $el_A[3], $el_A[4], $el_A[5]);
        if(! defined $results_HHHR->{$seq}) { 
          %{$results_HHHR->{$seq}} = ();
        }
        $group    = (defined $mdl_group_H{$model})    ? $mdl_group_H{$model}    : undef;
        $subgroup = (defined $mdl_subgroup_H{$model}) ? $mdl_subgroup_H{$model} : undef;

        # determine if we are going to store this hit, and to what 2D keys 
        # (the following code only works because we know we are sorted by score)
        my $is_1   = 0; # should we store this in $results_HHHR->{$seq}{"r1.1"} ? 
        my $is_2   = 0; # should we store this in $results_HHHR->{$seq}{"r1.2"} ? 
        my $is_eg  = 0; # should we store this in $results_HHHR->{$seq}{"r1.eg"} ? 
        my $is_esg = 0; # should we store this in $results_HHHR->{$seq}{"r1.esg"} ? 

        # store hit as r1.1 only if it's the first hit seen to any model, or it's an additional hit to the r1.1 model
        # SHOULD WE ONLY BE STORING TOP HIT IN ROUND 1?
        if((! defined $results_HHHR->{$seq}{"r1.1"}) || # first (best) hit for this sequence 
           ($results_HHHR->{$seq}{"r1.1"}{"model"} eq $model)) { # additional hit for r1.1 sequence/model pair
          $is_1 = 1; 
        }
        # store hit as r1.2 only if it's an additional hit to the r1.2 model
        # or there is no r1.2 hit yet, and r1.1 model and r1.2 model are not in the same subgroup
        # (if either r1.1 or r1.2 models do not have a subgroup, they are considered to NOT be in the same subgroup)
        elsif((defined $results_HHHR->{$seq}{"r1.2"}) && 
              ($results_HHHR->{$seq}{"r1.2"}{"model"} eq $model)) { # additional hit for r1.2 sequence/model pair
          $is_2 = 1;
        }
        elsif((! defined $results_HHHR->{$seq}{"r1.2"}) && # no r1.2 hit yet exists AND
              ((! defined $results_HHHR->{$seq}{"r1.1"}{"subgroup"}) ||       # (r1.1 hit has no subgroup OR
               (! defined $subgroup) ||                                       #  this hit has no subgroup OR
               ($results_HHHR->{$seq}{"r1.1"}{"subgroup"} ne $subgroup))) {   #  both have subgroups but they differ)
          $is_2 = 1;
        }               

        # determine if we are going to store this hit as best in 'group' and/or 'subgroup'
        # to the expected group and/or expected subgroup
        if((defined $exp_group) && (defined $group) && ($exp_group eq $group)) { 
          if((! defined $results_HHHR->{$seq}{"r1.eg"}) || # first (top) hit for this sequence to this group
             ($results_HHHR->{$seq}{"r1.eg"}{"model"} eq $model)) { # additional hit for this sequence/model pair
            $is_eg = 1; 
          }
          if((defined $exp_subgroup) && (defined $subgroup) && ($exp_subgroup eq $subgroup)) { 
            if((! defined $results_HHHR->{$seq}{"r1.esg"}) || # first (top) hit for this sequence to this subgroup
               ($results_HHHR->{$seq}{"r1.esg"}{"model"} eq $model)) { # additional hit for this sequence/model pair
              $is_esg = 1; 
            }
          }
        }
        if($is_1)   { cmsearch_store_hit(\%{$results_HHHR->{$seq}{"r1.1"}},   $model, $score, $strand, $bias, $s_from, $s_to, $m_from, $m_to, $group, $subgroup, $FH_HR); }
        if($is_2)   { cmsearch_store_hit(\%{$results_HHHR->{$seq}{"r1.2"}},   $model, $score, $strand, $bias, $s_from, $s_to, $m_from, $m_to, $group, $subgroup, $FH_HR); }
        if($is_eg)  { cmsearch_store_hit(\%{$results_HHHR->{$seq}{"r1.eg"}},  $model, $score, $strand, $bias, $s_from, $s_to, $m_from, $m_to, $group, $subgroup, $FH_HR); }
        if($is_esg) { cmsearch_store_hit(\%{$results_HHHR->{$seq}{"r1.esg"}}, $model, $score, $strand, $bias, $s_from, $s_to, $m_from, $m_to, $group, $subgroup, $FH_HR); }
      }
      else { # round 2
        ##target name                 accession query name           accession mdl mdl from   mdl to seq from   seq to strand trunc pass   gc  bias  score   E-value inc description of target
        ##--------------------------- --------- -------------------- --------- --- -------- -------- -------- -------- ------ ----- ---- ---- ----- ------ --------- --- ---------------------
        #gi|1215708385|gb|KY594653.1| -         NC_039477            -         hmm     5089     5389        1      301      +     -    6 0.52   0.0  268.1   3.4e-85 !   Norovirus GII.4 isolate Hu/GII/CR7410/CHN/2014 VP1 gene, partial cds
        if(scalar(@el_A) < 18) { 
          ofile_FAIL("ERROR parsing $tblout_file for round 2, unexpected number of space-delimited tokens on line $line", "dnaorg", 1, $FH_HR); 
        }
        ($seq, $model, $m_from, $m_to, $s_from, $s_to, $strand, $bias, $score) = ($el_A[0], $el_A[2], $el_A[5], $el_A[6], $el_A[7], $el_A[8], $el_A[9], $el_A[13], $el_A[14]);
        # determine if we are going to store this hit
        if((! defined $results_HHHR->{$seq}{"r2"}) || # first (top) hit for this sequence 
           ($results_HHHR->{$seq}{"r2"}{"model"} eq $model)) { # additional hit for this sequence/model pair
          cmsearch_store_hit(\%{$results_HHHR->{$seq}{"r2"}},  $model, $score, $strand, $bias, $s_from, $s_to, $m_from, $m_to, undef, undef, $FH_HR); # undefs are for group and subgroup which are irrelevant in round 2
        }
        elsif((defined $results_HHHR->{$seq}{"r2"}) &&
              ($results_HHHR->{$seq}{"r2"}{"model"} ne $model)) { 
          ofile_FAIL("ERROR in $sub_name, seq $seq has hits to multiple models in round 2 search", 1, $FH_HR);
        }
      }
    }
  }

  return; 
}

#################################################################
# Subroutine:  cmsearch_store_hit()
# Incept:      EPN, Thu Mar 21 14:55:25 2019
#
# Purpose:     Store information on a hit in %{$HR}. 
#              Initialize %{$HR} if this is the first hit.
#
# Arguments: 
#  $HR:            hash to store hit info in
#  $model:         model name
#  $score:         score of hit
#  $strand:        strand of hit
#  $bias:          bias score
#  $s_from:        start position on sequence
#  $s_to:          end position on sequence
#  $m_from:        start position on model
#  $m_to:          end position on model
#  $group:         group for $model, can be undef
#  $subgroup:      subgroup for $model, can be undef
#  $FH_HR:         ref to file handle hash
# 
# Returns: void
# 
# Dies: if not the first hit, but $HR->{"model"} ne $model
#      
################################################################# 
sub cmsearch_store_hit { 
  my $sub_name = "cmsearch_store_hit()";
  my $nargs_expected = 12;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 
  
  my ($HR, $model, $score, $strand, $bias, $s_from, $s_to, $m_from, $m_to, $group, $subgroup, $FH_HR) = @_;

  if(scalar(keys(%{$HR})) == 0) { # initialize
    $HR->{"model"}    = $model; # all hits stored in this hash will be to $model
    $HR->{"bstrand"}  = $strand; # strand of 'best hit' (first hit)
    $HR->{"s_coords"} = "";
    $HR->{"score"}    = "";
    if(defined $m_from) { $HR->{"m_coords"} = ""; }
    if(defined $bias)   { $HR->{"bias"}     = ""; }
  }
  else { 
    if($HR->{"model"} ne $model) { 
      ofile_FAIL("ERROR in $sub_name, trying to add additional hit to a different model", 1, $FH_HR);
    }
    $HR->{"s_coords"} .= ",";
    $HR->{"score"}    .= ",";
    if(defined $m_from) { $HR->{"m_coords"} .= ","; }
    if(defined $bias)   { $HR->{"bias"}     .= ","; }
  }
  $HR->{"s_coords"} .= $s_from . ".." . $s_to . ":" . $strand;
  $HR->{"score"}    .= sprintf("%.1f", $score);
  if(defined $m_from)   { $HR->{"m_coords"} .= $m_from . ".." . $m_to . ":+"; }
  if(defined $bias)     { $HR->{"bias"}     .= sprintf("%.1f", $bias); }
  if(defined $group)    { $HR->{"group"}     = $group; }
  if(defined $subgroup) { $HR->{"subgroup"}  = $subgroup; }

  return;
}

#################################################################
# Subroutine: add_classification_alerts()
# Incept:     EPN, Thu Mar 21 05:59:00 2019
# Purpose:    Adds c_* alerts for sequences based on classification
#             results in %{$cls_results_HHHR}.
#
# Types of 
# Arguments:
#  $alt_seq_instances_HHR:   REF to 2D hash with per-sequence alerts, added to here
#  $seq_len_HR:              REF to hash of sequence lengths
#  $mdl_info_AHR:            REF to array of hashes with information on the sequences, PRE-FILLED
#  $alt_info_HHR:            REF to the alert info hash of arrays, PRE-FILLED
#  $cls_results_HHHR:        REF to 3D hash with classification search results, PRE-FILLED
#  $cls_output_HHR:          REF to 2D hash of classification output info, FILLED HERE 
#  $opt_HHR:                 REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:          REF to the 2D hash of output file information
#             
# Returns:  void
# 
# Dies:     never
#
#################################################################
sub add_classification_alerts { 
  my $sub_name = "add_classification_alerts";
  my $nargs_exp = 8;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($alt_seq_instances_HHR, $seq_len_HR, $mdl_info_AHR, $alt_info_HHR, $cls_results_HHHR, $cls_output_HHR, $opt_HHR, $ofile_info_HHR) = @_;

  my $FH_HR = $ofile_info_HHR->{"FH"}; # for convenience
  my $nseq = scalar(keys (%{$seq_len_HR}));

  # create the model index hash which gives index in $mdl_info_AHR[] 
  # for a given model name, this allows us to find model length given model name
  my %mdl_idx_H = ();
  utl_IdxHFromAH(\%mdl_idx_H, $mdl_info_AHR, "name", $sub_name, $FH_HR);
   
  # determine if we have an expected group and subgroup
  # (--subgroup requires --group)
  # and if so, fill hashes of model groups and subgroups, 
  # (this data is in @{$mdl_info_AHR} already, we fill 
  # these hashes onlyfor convenience)
  my $exp_group    = opt_Get("--group",    \%opt_HH);
  my $exp_subgroup = opt_Get("--subgroup", \%opt_HH);

  # get thresholds
  my $small_value        = 0.00000001; # for handling precision issues
  my $lowcovthresh_opt   = opt_Get("--lowcovthresh",   $opt_HHR) - $small_value;
  my $vlowscthresh_opt   = opt_Get("--vlowscthresh",   $opt_HHR) - $small_value;
  my $lowscthresh_opt    = opt_Get("--lowscthresh",    $opt_HHR) - $small_value;
  my $vlowdiffthresh_opt = opt_Get("--vlowdiffthresh", $opt_HHR) - $small_value;
  my $lowdiffthresh_opt  = opt_Get("--lowdiffthresh",  $opt_HHR) - $small_value;
  my $biasfract_opt      = opt_Get("--biasfract",      $opt_HHR) + $small_value;
  my $cthresh_opt        = opt_Get("--cthresh",        $opt_HHR) + $small_value;
  my $ctoponly_opt_used  = 0;
  if(opt_IsUsed("--ctoponly", $opt_HHR)) { 
    $cthresh_opt = $small_value;
    $ctoponly_opt_used = 1;
  }

  my $lowcovthresh_opt2print   = sprintf("%.3f", opt_Get("--lowcovthresh",  $opt_HHR));
  my $lowdiffthresh_opt2print  = sprintf("%.3f", opt_Get("--lowdiffthresh",  $opt_HHR));
  my $vlowdiffthresh_opt2print = sprintf("%.3f", opt_Get("--vlowdiffthresh", $opt_HHR));
  my $lowscthresh_opt2print    = sprintf("%.3f", opt_Get("--lowscthresh",  $opt_HHR));
  my $vlowscthresh_opt2print   = sprintf("%.3f", opt_Get("--vlowscthresh", $opt_HHR));
  my $biasfract_opt2print      = sprintf("%.3f", opt_Get("--biasfract", $opt_HHR));
  my $cthresh_opt2print        = sprintf("%.3f", opt_Get("--cthresh", $opt_HHR));

  %{$cls_output_HHR} = ();
  foreach $seq_name (sort keys(%{$seq_len_HR})) { 
    my $seq_len  = $seq_len_HR->{$seq_name};
    my $mdl_name = undef;
    my $mdl_len  = undef;
    %{$cls_output_HHR->{$seq_name}} = ();
    # check for c_noa alert: no hits in round 1 search
    # or >=1 hits in round 1 search but 0 hits in round 2 search (should be rare)
    if((! defined $cls_results_HHHR->{$seq_name}) || 
       ((defined $cls_results_HHHR->{$seq_name}) &&
        (defined $cls_results_HHHR->{$seq_name}{"r1.1"}) &&
        (! defined $cls_results_HHHR->{$seq_name}{"r2"}))) { 
      alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_noa", $seq_name, "-", $FH_HR);
    }
    else { 
      if(! defined $cls_results_HHHR->{$seq_name}{"r1.1"}) { 
        ofile_FAIL("ERROR in $sub_name, seq $seq_name should have but does not have any r1.1 hits", 1, $FH_HR);
      }
      # determine model name and length
      $mdl_name = $cls_results_HHHR->{$seq_name}{"r2"}{"model"};
      $mdl_len  = $mdl_info_AHR->[$mdl_idx_H{$mdl_name}]{"length"};
      # gather the information we need to detect alerts for this sequence
      # convert coords values into start, stop and strand arrays
      # hash of hit info, hash key is one of "r1.1", "r1.2", "r1.eg", "r1.esg", "r2"
      # we need to fill s_start_HA, s_stop_HA and s_strand_HA because 
      # not all hits might be to best strand, and we only want to collect
      # data on hits to best strand
      my %s_start_HA  = (); # sequence start positions for each hit for this sequence/model pair
      my %s_stop_HA   = (); # sequence stop  positions for each hit for this sequence/model pair
      my %s_strand_HA = (); # sequence strands for each hit for this sequence/model pair      
      my %score_H     = (); # summed score of all hits
      my %bias_H      = (); # summed bias of all hits
      my %scpnt_H     = (); # score per nt 
      my %s_length_H  = (); # total length of all hits in sequence coords
      my %m_length_H  = (); # total length of all hits in model coords
      my %bstrand_H   = (); # strand of highest-scoring hit
      my %nhits_H     = (); # number of hits
      my @m_start_A   = (); # model start positions for r2 hit for this sequence/model pair
      my @m_stop_A    = (); # model stop  positions for r2 hit for this sequence/model pair
      foreach my $rkey (keys (%{$cls_results_HHHR->{$seq_name}})) { 
        my $results_HR = \%{$cls_results_HHHR->{$seq_name}{$rkey}}; # for convenience
        @{$s_start_HA{$rkey}}  = ();
        @{$s_stop_HA{$rkey}}   = ();
        @{$s_strand_HA{$rkey}} = ();
        dng_FeatureStartStopStrandArrays($results_HR->{"s_coords"},
                                         \@{$s_start_HA{$rkey}},
                                         \@{$s_stop_HA{$rkey}},
                                         \@{$s_strand_HA{$rkey}}, $FH_HR);


        my $nhits = scalar(@{$s_start_HA{$rkey}});
        my @score_A = split(",", $results_HR->{"score"});
        if(scalar(@score_A) != $nhits) { 
          ofile_FAIL("ERROR in $sub_name, problem checking alerts for seq $seq_name, round $rkey, hit count differs for s_coords and score", 1, $FH_HR);
        }

        my @bias_A = ();
        if($rkey eq "r2") { 
          @bias_A = split(",", $results_HR->{"bias"});
          if(scalar(@bias_A) != $nhits) { 
            ofile_FAIL("ERROR in $sub_name, problem checking alerts for seq $seq_name, round $rkey, hit count differs for s_coords and bias", "dnaorg", 1, $FH_HR);
          }
          dng_FeatureStartStopStrandArrays($results_HR->{"m_coords"},
                                           \@m_start_A,
                                           \@m_stop_A,
                                           undef, $FH_HR);
        }

        my $bstrand  = $s_strand_HA{$rkey}[0];
        my $s_length = abs($s_start_HA{$rkey}[0] - $s_stop_HA{$rkey}[0]) + 1;
        my $score    = $score_A[0];
        my $m_length = ($rkey eq "r2") ? $m_stop_A[0] - $m_start_A[0] + 1 : undef;
        my $bias     = ($rkey eq "r2") ? $bias_A[0] : undef;
        my $nhits_bstrand = 1;
        for(my $i = 1; $i < $nhits; $i++) { 
          if($s_strand_HA{$rkey}[$i] eq $bstrand) { 
            $s_length += abs($s_start_HA{$rkey}[$i] - $s_stop_HA{$rkey}[$i]) + 1;
            $score    += $score_A[$i];
            if(defined $m_length) { 
              $m_length += $m_stop_A[$i] - $m_start_A[$i] + 1;
            }
            if(defined $bias) { 
              $bias += $bias_A[$i];
            }
            $nhits_bstrand++;
          }
        }
        $score_H{$rkey}    = $score;
        $scpnt_H{$rkey}    = $score / $s_length;
        $s_length_H{$rkey} = $s_length;
        $bstrand_H{$rkey}  = $bstrand;
        $nhits_H{$rkey}    = $nhits_bstrand;
        $bias_H{$rkey}     = (defined $bias)     ? $bias     : undef;
        $m_length_H{$rkey} = (defined $m_length) ? $m_length : undef;
      } # end of foreach $rkey

      #####################################################################
      # Go through and report alerts and update $cls_output_HHR->{$seq_name} 
      # which we will use later in output_tabular

      # classification alerts that depend on round 1 results
      # low score (c_los) and very low score (c_vls)
      if(defined $scpnt_H{"r1.1"}) { 
        my $scpnt2print = sprintf("%.3f", $scpnt_H{"r1.1"});
        $cls_output_HHR->{$seq_name}{"scpnt"} = $scpnt2print;
        $cls_output_HHR->{$seq_name}{"score"} = sprintf("%.1f", $score_H{"r1.1"});
        if($scpnt_H{"r1.1"} < $vlowscthresh_opt) { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_vls", $seq_name, $scpnt2print . "<" . $vlowscthresh_opt2print . " bits/nt", $FH_HR);
        }
        elsif($scpnt_H{"r1.1"} < $lowscthresh_opt) { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR,  "c_los", $seq_name, $scpnt2print . "<" . $lowscthresh_opt2print . " bits/nt", $FH_HR);
        }
      }
      # low difference (c_lod) and very low difference (c_vld)
      if(defined $scpnt_H{"r1.2"}) { 
        my $diffpnt = $scpnt_H{"r1.1"} - $scpnt_H{"r1.2"};
        my $diffpnt2print = sprintf("%.3f", $diffpnt);
        $cls_output_HHR->{$seq_name}{"scdiff"}  = sprintf("%.1f", $score_H{"r1.1"} - $score_H{"r1.2"});
        $cls_output_HHR->{$seq_name}{"diffpnt"} = $diffpnt2print;
        my $group_str = "best group/subgroup: " . 
            group_subgroup_string_from_classification_results($cls_results_HHHR->{$seq_name}{"r1.1"}) . 
            ", second group/subgroup: " . 
            group_subgroup_string_from_classification_results($cls_results_HHHR->{$seq_name}{"r1.2"});

        if($diffpnt < $vlowdiffthresh_opt) { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_vld", $seq_name, $diffpnt2print . "<" . $vlowdiffthresh_opt2print . " bits/nt, " . $group_str, $FH_HR);
        }
        elsif($diffpnt < $lowdiffthresh_opt) { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_lod", $seq_name, $diffpnt2print . "<" . $lowdiffthresh_opt2print . " bits/nt, " . $group_str, $FH_HR);
        }
      }
      # unexpected group (c_ugr) 
      # $exp_group must be defined 
      # - no hits in r1.eg (no hits to group)
      # OR 
      # - hit(s) in r1.eg but scpernt diff between
      #   r1.eg and r1.1 exceeds cthresh_opt
      #
      # unexpected subgroup (c_usg) 
      # - no hits in r1.esg (no hits to subgroup)
      # OR 
      # - hit(s) in r1.esg but scpernt diff between
      #   r1.esg and r1.1 exceeds cthresh_opt
      my $ugr_flag = 0;
      if(defined $exp_group) { 
        if(! defined $scpnt_H{"r1.eg"}) { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_ugr", $seq_name, 
                                       "no hits to expected group $exp_group, best model group/subgroup: " . 
                                       group_subgroup_string_from_classification_results($cls_results_HHHR->{$seq_name}{"r1.1"}), $FH_HR);
          $ugr_flag = 1;
        }
        else { 
          my $diff = $scpnt_H{"r1.1"} - $scpnt_H{"r1.eg"};
          my $diff2print = sprintf("%.3f", $diff);
          if($diff > $cthresh_opt) { 
            my $alt_str = ($ctoponly_opt_used) ? $diff2print . ">0.0" : $diff2print . ">" . $cthresh_opt2print . 
                " bits/nt, best model group/subgroup: " . group_subgroup_string_from_classification_results($cls_results_HHHR->{$seq_name}{"r1.1"});
            alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_ugr", $seq_name, $alt_str, $FH_HR);
            $ugr_flag = 1;
          }
        }
      }

      # unexpected subgroup (c_usg) 
      # - c_ugr not already detected
      # - no hits in r1.esg (no hits to subgroup)
      # OR 
      # - hit(s) in r1.esg but scpernt diff between
      #   r1.esg and r1.1 exceeds cthresh_opt
      if((! $ugr_flag) && (defined $exp_subgroup)) { 
        if(! defined $scpnt_H{"r1.esg"}) { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_usg", $seq_name, "no hits to expected subgroup $exp_subgroup", $FH_HR);
        }
        else { 
          my $diff = $scpnt_H{"r1.1"} - $scpnt_H{"r1.esg"};
          my $diff2print = sprintf("%.3f", $diff);
          if($diff > $cthresh_opt) { 
            my $alt_str = ($ctoponly_opt_used) ? $diff2print . ">0.0" : $diff2print . ">" . $cthresh_opt2print . 
                " bits/nt, best model group/subgroup: " . group_subgroup_string_from_classification_results($cls_results_HHHR->{$seq_name}{"r1.1"});
            alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_usg", $seq_name, $alt_str, $FH_HR);
          }
        }
      }

      # classification alerts that depend on round 2 results
      if(defined $nhits_H{"r2"}) { $cls_output_HHR->{$seq_name}{"nhits"} = $nhits_H{"r2"}; }
      if(defined $bias_H{"r2"})  { $cls_output_HHR->{$seq_name}{"bias"}  = $bias_H{"r2"}; }

      # minus strand (c_mst)
      if(defined $bstrand_H{"r2"}) { 
        $cls_output_HHR->{$seq_name}{"bstrand"} = $bstrand_H{"r2"};
        if($bstrand_H{"r2"} eq "-") { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_mst", $seq_name, "", $FH_HR);
        }
      }
      # low coverage (c_loc)
      if(defined $s_length_H{"r2"}) { 
        my $scov = $s_length_H{"r2"} / $seq_len;
        my $scov2print = sprintf("%.3f", $scov);
        my $mcov2print = sprintf("%.3f", $m_length_H{"r2"} / $mdl_len);
        $cls_output_HHR->{$seq_name}{"scov"} = $scov2print;
        $cls_output_HHR->{$seq_name}{"mcov"} = $mcov2print;
        if($scov < $lowcovthresh_opt) { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_loc", $seq_name, $scov2print . "<" . $lowcovthresh_opt2print, $FH_HR);
        }
      }
      # high bias (c_hbi) 
      if(defined $bias_H{"r2"}) { 
        my $bias_fract = $bias_H{"r2"} / ($score_H{"r2"} + $bias_H{"r2"});
        my $bias_fract2print = sprintf("%.3f", $bias_fract);
        # $score_H{"r2"} has already had bias subtracted from it so we need to add it back in before we compare with biasfract
        if($bias_fract > $biasfract_opt) { 
          alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "c_hbi", $seq_name, $bias_fract2print . "<" . $biasfract_opt2print, $FH_HR);
        }
      }
      
      # finally fill $cls_output_HHR->{$seq_name} info related to models and groups
      if(defined $cls_results_HHHR->{$seq_name}{"r1.1"}) { 
        $cls_output_HHR->{$seq_name}{"model1"}    = $cls_results_HHHR->{$seq_name}{"r1.1"}{"model"};
        $cls_output_HHR->{$seq_name}{"group1"}    = $cls_results_HHHR->{$seq_name}{"r1.1"}{"group"};    # can be undef
        $cls_output_HHR->{$seq_name}{"subgroup1"} = $cls_results_HHHR->{$seq_name}{"r1.1"}{"subgroup"}; # can be undef
      }
      if(defined $cls_results_HHHR->{$seq_name}{"r1.2"}) { 
        $cls_output_HHR->{$seq_name}{"model2"}    = $cls_results_HHHR->{$seq_name}{"r1.2"}{"model"};
        $cls_output_HHR->{$seq_name}{"group2"}    = $cls_results_HHHR->{$seq_name}{"r1.2"}{"group"};    # can be undef
        $cls_output_HHR->{$seq_name}{"subgroup2"} = $cls_results_HHHR->{$seq_name}{"r1.2"}{"subgroup"}; # can be undef
      }
    } # else entered if we didn't report a c_noa alert
  } # end of foreach seq loop

  return;
}

#################################################################
# Subroutine:  populate_per_model_data_structures_given_classification_results
# Incept:      EPN, Tue Apr  2 11:33:29 2019
#
# Purpose:    Given classification results, fill several 'per-model'
#             data structures with sequences that match best to that
#             model. 
# 
#             This subroutine is called twice, once following round
#             1 classification and once following round 2 classification
#             and does extra work following round 2. We determine
#             which round of classification was just performed
#             based on if $alt_seq_instances_HHR is defined or not.
#             If it is defined we just performed round 2, else round 1.
#
# Arguments: 
#  $seq_name_AR:           ref to sequence names
#  $seq_len_HR:            ref to hash of sequence lengths
#  $cls_results_HHHR:      ref to 3D hash of classification results, PRE-FILLED
#  $cls_output_HHR:        ref to 2D hash of classification results to output, PRE-FILLED
#                          can be undef if $alt_seq_instances_HHR is undef
#  $alt_info_HHR:          ref to 2d hash of alert info, PRE-FILLED
#                          can be undef if $alt_seq_instances_HHR is undef
#  $alt_seq_instances_HHR: ref to hash of per-seq alert instances, PRE-FILLED
#                          undef to use cls_results_HHHR->{}{"r1.1"} # round 1 search
#                          undef to use cls_results_HHHR->{}{"r2"}   # round 2 search
#  $mdl_seq_name_HAR:      ref to hash of arrays of sequences per model, FILLED HERE
#  $mdl_seq_len_HR:        ref to hash of summed sequence length per model, FILLED HERE
#  $mdl_ct_HR:             ref to hash of number of sequences per model, FILLED HERE
#  $FH_HR:                 ref to hash of file handles
#
# Returns:   void
#
#
################################################################# 
sub populate_per_model_data_structures_given_classification_results {
  my $sub_name = "populate_per_model_data_structures_given_classification_results";
  my $nargs_exp = 10;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name_AR, $seq_len_HR, $cls_results_HHHR, $cls_output_HHR, $alt_info_HHR, $alt_seq_instances_HHR, $mdl_seq_name_HAR, $mdl_seq_len_HR, $mdl_ct_HR, $FH_HR) = @_;

  # determine what round results we are using
  my $cls_2d_key = (defined $alt_seq_instances_HHR) ? "r2" : "r1.1";

  for(my $seq_idx = 0; $seq_idx < $nseq; $seq_idx++) { 
    $seq_name = $seq_name_AR->[$seq_idx];
    $mdl_name = ((defined $cls_results_HHH{$seq_name}) && 
                 (defined $cls_results_HHH{$seq_name}{$cls_2d_key}) && 
                 (defined $cls_results_HHH{$seq_name}{$cls_2d_key}{"model"})) ? 
                 $cls_results_HHH{$seq_name}{$cls_2d_key}{"model"} : undef;
    if(defined $mdl_name) { 
      if(! defined $mdl_seq_name_HAR->{$mdl_name}) { 
        @{$mdl_seq_name_HAR->{$mdl_name}} = ();
        $mdl_seq_len_HR->{$mdl_name} = 0;
        $mdl_ct_HR->{$mdl_name} = 0;
      }
      # determine if we are going to add this sequence to our per-model hashes, depending on what round
      my $add_seq = 0;
      if($cls_2d_key eq "r1.1") { 
        $add_seq = 1; # always add seq after round 1
      }
      else { 
        # if "r2", check if this sequence has any alerts that prevent annotation
        $add_seq = (alert_instances_check_prevents_annot($seq_name, $alt_info_HHR, $alt_seq_instances_HHR, $FH_HR)) ? 0 : 1;
        # update "annot" key
        $cls_output_HHR->{$seq_name}{"annot"} = ($add_seq) ? 1 : 0;
      }
      if($add_seq) { 
        push(@{$mdl_seq_name_HAR->{$mdl_name}}, $seq_name);
        $mdl_seq_len_HR->{$mdl_name} += $seq_len_HR->{$seq_name};
        $mdl_ct_HR->{$mdl_name}++;
      }
    }
  }

  return;
}

#################################################################
#
# Subroutines related to cmalign and alignment:
# cmalign_wrapper
# cmalign_wrapper_helper
# cmalign_run
# cmalign_parse_ifile 
# cmalign_parse_stk_and_add_alignment_alerts 
# cmalign_store_overflow
# fetch_features_and_add_cds_and_mp_alerts 
# sqstring_check_start
# sqstring_find_stops 
#
#################################################################
# Subroutine:  cmalign_wrapper()
# Incept:      EPN, Mon Mar 18 14:20:56 2019
#
# Purpose:     Run one or more cmalign jobs on the farm
#              or locally, after possibly splitting up the input
#              sequence file with dng_SplitFastaFile and 
#              then calling dng_CmalignOrCmsearchWrapperHelper(). 
#
#              We may have to do two rounds of sequence file splitting
#              and job running/submission because there is an error
#              case in cmalign that we want to be able to detect. That
#              error case is when the sequence requires too much
#              memory to align. In order to catch those error cases we
#              need to run each offending sequence individually, so
#              our strategy for cmalign is:
#
#              Split full fasta file up using default method and run
#              >= 1 cmalign jobs. If any of those runs R fail, then 
#              split up run R's sequence file into >= 1 files with
#              exactly 1 sequence in them. One or more of those should
#              fail and that reveals which specific sequences are
#              causing the memory overflow.
# 
# Arguments: 
#  $execs_HR:              ref to executables with "esl-ssplit" and "cmalign"
#                          defined as keys
#  $mdl_file:              name of model file to use
#  $mdl_name:              name of model to fetch from $mdl_file (undef to not fetch)
#  $seq_file:              name of sequence file with all sequences to run against
#  $out_root:              string for naming output files
#  $nseq:                  total number of all seqs in $seq_file
#  $tot_len_nt:            total length of all nucleotides in $seq_file
#  $progress_w:            width for outputProgressPrior output
#  $stk_file_AR:           ref to array of stockholm files created here, FILLED HERE
#  $overflow_seq_AR:       ref to array of sequences that failed due to matrix overflows, FILLED HERE
#  $overflow_mxsize_AR:    ref to array of required matrix sizes for each sequence that failed due to matrix overflows, FILLED HERE
#  $opt_HHR:               REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:        REF to 2D hash of output file information
#
# Returns:     void, updates $$nfa_created_R with number of
#              fasta files created.
# 
# Dies: If an executable doesn't exist, or cmalign or nhmmscan or esl-ssplit
#       command fails if we're running locally
################################################################# 
sub cmalign_wrapper { 
  my $sub_name = "cmalign_wrapper";
  my $nargs_expected = 13;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($execs_HR, $mdl_file, $mdl_name, $seq_file, $out_root,
      $nseq, $tot_len_nt, $progress_w, $stk_file_AR, $overflow_seq_AR, 
      $overflow_mxsize_AR, $opt_HHR, $ofile_info_HHR) = @_;

  my $nfasta_created = 0; # number of fasta files created by esl-ssplit
  my $log_FH = $ofile_info_HHR->{"FH"}{"log"}; # for convenience
  my $start_secs; # timing start
  my $do_parallel = opt_Get("-p", $opt_HHR);
  @{$overflow_seq_AR} = (); # we will fill this with names of sequences that fail cmalign because
                            # the matrix required to align them is too big

  # set up output file names
  my @concat_keys_A = (); # %r{1,2}_out_file_HAR keys we are going to concatenate files for
  my %concat_HA = ();     # hash of arrays of all files to concatenate together
  my $out_key;            # key for an output file: e.g. "stdout", "ifile", "tfile", "tblout", "err"
  @concat_keys_A = ("stdout", "ifile", "tfile"); 
  if($do_parallel) { push(@concat_keys_A, "err"); }
  foreach $out_key (@concat_keys_A) { 
    @{$concat_HA{$out_key}} = ();
  }    

  my $nr1 = 0; # number of runs in round 1 (one per sequence file we create)
  my @r1_out_file_AH = (); # array of hashes ([0..$nr1-1]) of output files for cmalign round 1 runs
  my @r1_success_A   = (); # [0..$nr1-1]: '1' if this run finishes successfully, '0' if not
  my @r1_mxsize_A    = (); # [0..$nr1-1]: if $r1_success_A[$r1_i] is '0', required size for dp mx, else '0'
  my @r1_seq_file_A  = (); # [0..$nr1-1]: name of sequence file for this run
  my $r1_i;                # counter over round 1 runs
  my $r1_do_split = 0;     # set to '1' if we split up fasta file
  # we need to split up the sequence file, and submit a separate set of cmalign jobs for each
  my $targ_nseqfiles = dng_SplitNumSeqFiles($tot_len_nt, $opt_HHR);
  if($targ_nseqfiles > 1) { # we are going to split up the fasta file 
    $r1_do_split = 1;
    $nr1 = dng_SplitFastaFile($execs_HR->{"esl-ssplit"}, $seq_file, $targ_nseqfiles, $opt_HHR, $ofile_info_HHR);
    # dng_SplitFastaFile will return the actual number of fasta files created, 
    # which can differ from the requested amount (which is $targ_nseqfiles) that we pass in. 
    for($r1_i = 0; $r1_i < $nr1; $r1_i++) { # update sequence file names
      $r1_seq_file_A[$r1_i] = $seq_file . "." . ($r1_i+1);
    }
  }
  else { # not going to split up the sequence file
    $nr1 = 1;
    $r1_seq_file_A[0] = $seq_file;
  }
  
  cmalign_wrapper_helper($execs_HR, $mdl_file, $mdl_name, $out_root, 1, $nseq, $progress_w, 
                         \@r1_seq_file_A, \@r1_out_file_AH, \@r1_success_A, \@r1_mxsize_A, 
                         $opt_HHR, $ofile_info_HHR);

  my $nr2            = 0;  # number of round 2 runs (sequence files)
  my @r2_out_file_AH = (); # array of hashes ([0..$nr2-1]) of output files for cmalign round 2 runs
  my @r2_success_A   = (); # [0..$nr2-1]: '1' if this run finishes successfully, '0' if not
  my @r2_mxsize_A    = (); # [0..$nr2-1]: if $r2_success_A[$r2_i] is '0', required size for dp mx, else '0'
  my @r2_seq_file_A  = (); # [0..$nr2-1]: name of sequence file for this run
  my $r2_i;                # counter over round 2 runs

  # go through each run:
  # if it finished successfully record its output files to concatenate later
  # if it did not finish successfully rerun all of its sequences (if $do_cmalign)
  for($r1_i = 0; $r1_i < $nr1; $r1_i++) { 
    if($r1_success_A[$r1_i]) { 
      # run finished successfully
      foreach $out_key (@concat_keys_A) { 
        push(@{$concat_HA{$out_key}}, $r1_out_file_AH[$r1_i]{$out_key});
      }
      push(@{$stk_file_AR}, $r1_out_file_AH[$r1_i]{"stk"});
    }
    else { 
      # run did not finish successfully
      # split this sequence file up into multiple files with only 1 sequence each, 
      my $cur_nr2 = dng_SplitFastaFile($execs_HR->{"esl-ssplit"}, $r1_seq_file_A[$r1_i], -1, $opt_HHR, $ofile_info_HHR);
      if($cur_nr2 == 1) { 
        # special case, r1 sequence file had only 1 sequence, so we know the culprit
        # and don't need to rerun cmalign
        cmalign_store_overflow($r1_seq_file_A[$r1_i], $r1_mxsize_A[$r1_i], $overflow_seq_AR, $overflow_mxsize_AR, $ofile_info_HHR->{"FH"}); 
        unlink $r1_seq_file_A[$r1_i] . ".1"; # remove the file we just created 
        $nr2 = 0;
      }
      else { 
        # r1 sequence file had > 1 sequence, we need to run each sequence independently through cmalign
        for($r2_i = 0; $r2_i < $cur_nr2; $r2_i++) { 
          push(@r2_seq_file_A, $r1_seq_file_A[$r1_i] . "." . ($r2_i+1));
        }
        $nr2 += $cur_nr2;
      }
    }
  }

  # do all round 2 runs
  if($nr2 > 0) { 
    cmalign_wrapper_helper($execs_HR, $mdl_file, $mdl_name, $out_root, 2, $nr2, $progress_w, 
                           \@r2_seq_file_A, \@r2_out_file_AH, \@r2_success_A, \@r2_mxsize_A, 
                           $opt_HHR, $ofile_info_HHR);
    # go through all round 2 runs: 
    # if it finished successfully record its output files to concatenate later
    # if it did not finish successfully, record the name of the sequence and mxsize required
    for($r2_i = 0; $r2_i < $nr2; $r2_i++) { 
      if($r2_success_A[$r2_i]) { 
        # run finished successfully
        foreach my $out_key (@concat_keys_A) { 
          push(@{$concat_HA{$out_key}}, $r2_out_file_AH[$r2_i]{$out_key});
        }
        push(@{$stk_file_AR}, $r2_out_file_AH[$r2_i]{"stk"});
      }
      else { 
        # run did not finish successfully
        cmalign_store_overflow($r2_seq_file_A[$r2_i], $r2_mxsize_A[$r2_i], $overflow_seq_AR, $overflow_mxsize_AR, $ofile_info_HHR->{"FH"}); 
      }
    }
    # remove sequence files if --keep not used
    if(! opt_Get("--keep", $opt_HHR)) { 
      utl_FileRemoveList(\@r2_seq_file_A, $sub_name, $opt_HHR, $ofile_info_HHR->{"FH"});
    }
  }
    
  # concatenate files into one 
  foreach $out_key (@concat_keys_A) { 
    my $concat_file = sprintf($out_root . ".%salign.$out_key", (defined $mdl_name) ? $mdl_name . "." : "");                                
    utl_ConcatenateListOfFiles($concat_HA{$out_key}, $concat_file, $sub_name, $opt_HHR, $ofile_info_HHR->{"FH"});
    # utl_ConcatenateListOfFiles() removes individual files unless --keep enabled
    my $out_root_key = sprintf(".concat.%salign.$out_key", (defined $mdl_name) ? $mdl_name . "." : "");
    ofile_AddClosedFileToOutputInfo($ofile_info_HHR, "dnaorg", $out_root_key, $concat_file, 0, sprintf("align $out_key file%s", (defined $mdl_name) ? "for model $mdl_name" : ""));
  }
  # remove sequence files 
  if(($r1_do_split) && (! opt_Get("--keep", $opt_HHR))) { 
    utl_FileRemoveList(\@r1_seq_file_A, $sub_name, $opt_HHR, $ofile_info_HHR->{"FH"});
  }

  return;
}

#################################################################
# Subroutine:  cmalign_wrapper_helper()
# Incept:      EPN, Wed Mar 20 06:20:51 2019
#
# Purpose:     Run one or more cmalign on the farm or locally.
#
#              Helper subroutine for cmalign_wrapper()
#              see that sub's "Purpose" for more details.
#
# Arguments: 
#  $execs_HR:              ref to hash with paths to cmalign, cmsearch and cmfetch
#  $mdl_file:              name of model file to use
#  $mdl_name:              name of model to fetch from $mdl_file (undef to not fetch)
#  $out_root:              string for naming output files
#  $round:                 round we are on, "1" or "2"
#  $nseq:                  total number of sequences in all seq files in @{$seq_file_AR}
#  $progress_w:            width for ofile_OutputProgress* subroutines
#  $seq_file_AR:           ref to array of sequence file names for each cmalign/nhmmscan call, PRE-FILLED
#  $out_file_AHR:          ref to array of hashes of output file names, FILLED HERE 
#  $success_AR:            ref to array of success values, can be undef if $executable is "cmsearch"
#                          $success_AR->[$j] set to '1' if job finishes successfully
#                                            set to '0' if job fails due to mx overflow (must be cmalign)
#  $mxsize_AR:             ref to array of required matrix sizes, can be undef if $executable is "cmsearch"
#                          $mxsize_AR->[$j] set to value readh from cmalign output, if $success_AR->[$j] == 0
#                                           else set to '0'
#  $opt_HHR:               REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:        REF to 2D hash of output file information
#
# Returns:     void
# 
# Dies: If an executable doesn't exist, or command fails (and its not a cmalign allowed failure)
#
################################################################# 
sub cmalign_wrapper_helper { 
  my $sub_name = "cmalign_wrapper_helper";
  my $nargs_expected = 13;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($execs_HR, $mdl_file, $mdl_name, $out_root, $round, $nseq, $progress_w, $seq_file_AR, $out_file_AHR, $success_AR, $mxsize_AR, $opt_HHR, $ofile_info_HHR) = @_;

  my $log_FH         = $ofile_info_HHR->{"FH"}{"log"}; # for convenience
  my $do_parallel    = opt_Get("-p", $opt_HHR) ? 1 : 0;
  my $nseq_files     = scalar(@{$seq_file_AR});

  # determine description of the runs we are about to do, 
  # depends on $do_parallel, $round, and ($progress_w < 0), and 
  my $desc = "";
  if($do_parallel) { 
    $desc = sprintf("Submitting $nseq_files cmalign job(s) ($mdl_name: $nseq seq%s) to the farm%s", 
                    ($nseq > 1) ? "s" : "",
                    ($round == 1) ? "" : " to find seqs too divergent to annotate");
  }
  else { 
    $desc = sprintf("Aligning sequences ($mdl_name: $nseq seq%s)%s", 
                    ($nseq > 1) ? "s" : "",
                    ($round == 1) ? "" : " to find seqs too divergent to annotate");
  }
  my $start_secs = ofile_OutputProgressPrior($desc, $progress_w, $log_FH, *STDOUT);
  if($do_parallel) { ofile_OutputString($log_FH, 1, "\n"); }

  my $key; # a file key
  my $s;   # counter over sequence files
  my @out_keys_A = ("stdout", "err", "ifile", "tfile", "stk");
  @{$out_file_AHR} = ();
  for(my $s = 0; $s < $nseq_files; $s++) { 
    %{$out_file_AHR->[$s]} = (); 
    foreach $key (@out_keys_A) { 
      $out_file_AHR->[$s]{$key} = $out_root . "." . $mdl_name . ".align.r" . $round . ".s" . $s . "." . $key;
    }
    $success_AR->[$s] = cmalign_run($execs_HR, $mdl_file, $mdl_name, $seq_file_AR->[$s], \%{$out_file_AHR->[$s]},
                                    (defined $mxsize_AR) ? \$mxsize_AR->[$s] : undef, 
                                    $opt_HHR, $ofile_info_HHR);   
    # if we are running parallel, ignore the return values from the run{Cmalign,Cmsearch} subroutines
    # dng_WaitForFarmJobsToFinish() will fill these later
    if($do_parallel) { $success_AR->[$s] = 0; }
  }
  ofile_OutputProgressComplete($start_secs, undef, $log_FH, *STDOUT);

  if($do_parallel) { 
    if((opt_Exists("--skipalign", $opt_HHR)) && (opt_Get("--skipalign", $opt_HHR))) { 
      for($s = 0; $s < $nseq_files; $s++) { 
        $success_AR->[$s] = 1; 
      }
    }
    else { 
      # --skipalign not enabled
      # wait for the jobs to finish
      $start_secs = ofile_OutputProgressPrior(sprintf("Waiting a maximum of %d minutes for all farm jobs to finish", opt_Get("--wait", $opt_HHR)), 
                                              $progress_w, $log_FH, *STDOUT);
      my $njobs_finished = dng_WaitForFarmJobsToFinish(1, # we are doing cmalign
                                                       $out_file_AHR,
                                                       $success_AR, 
                                                       $mxsize_AR,  
                                                       "", # value is irrelevant for cmalign
                                                       $opt_HHR, $ofile_info_HHR->{"FH"});
      if($njobs_finished != $nseq_files) { 
        ofile_FAIL(sprintf("ERROR in $sub_name only $njobs_finished of the $nseq_files are finished after %d minutes. Increase wait time limit with --wait", opt_Get("--wait", $opt_HHR)), 1, $ofile_info_HHR->{"FH"});
      }
      ofile_OutputString($log_FH, 1, "# "); # necessary because waitForFarmJobsToFinish() creates lines that summarize wait time and so we need a '#' before 'done' printed by ofile_OutputProgressComplete()
    }
  }
  
  return;
}

#################################################################
# Subroutine:  cmalign_run()
# Incept:      EPN, Wed Feb  6 12:30:08 2019
#
# Purpose:     Run Infernal's cmalign executable using $mdl_file
#              as the model file on sequence file $seq_file, either
#              locally or on the farm.
#              
#              If job does not finish successfully, we need to 
#              parse the stderr output (which we redirect to stdout)
#              and see if it failed because of a specific type of
#              error, because the required DP matrix exceeded the
#              size limit. That error looks like this:
#        
#              Error: HMM banded truncated alignment mxes need 60.75 Mb > 2.00 Mb limit.
#              Use --mxsize, --maxtau or --tau.
#              
# Arguments: 
#  $execs_HR:         ref to hash with paths to cmalign and cmfetch
#  $mdl_file:         path to the CM file
#  $mdl_name:         name of model to fetch from $mdl_file (undef to not fetch)
#  $seq_file:         path to the sequence file
#  $out_file_HR:      ref to hash of output files to create
#                     required keys: "stdout", "ifile", "tfile", "stk", "err"
#  $ret_mxsize_R:     REF to required matrix size, only filled if return value is '0'
#  $opt_HHR:          REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:   REF to 2D hash of output file information
# 
# Returns:     '1' upon success, which occurs if
#                  job run on farm and submission went ok
#                  job run locally and finished without error
#              '0' upon allowed failure, which occurs if
#                  job run locally and fails because of too big a required matrix
#
# Dies: upon unallowed failure, which occurs if
#                  job run on farm and submission failed
#                  job run locally and finished with unallowed failure
# 
################################################################# 
sub cmalign_run { 
  my $sub_name = "cmalign_run()";
  my $nargs_expected = 8;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($execs_HR, $mdl_file, $mdl_name, $seq_file, $out_file_HR, $ret_mxsize_R, $opt_HHR, $ofile_info_HHR) = @_;

  if(defined $ret_mxsize_R) { 
    $$ret_mxsize_R = 0; # overwritten below if nec
  }

  my $FH_HR       = (defined $ofile_info_HHR->{"FH"}) ? $ofile_info_HHR->{"FH"} : undef;
  my $do_parallel = opt_Get("-p", $opt_HHR) ? 1 : 0;

  my $stdout_file = $out_file_HR->{"stdout"};
  my $ifile_file  = $out_file_HR->{"ifile"};
  my $tfile_file  = $out_file_HR->{"tfile"};
  my $stk_file    = $out_file_HR->{"stk"};
  my $err_file    = $out_file_HR->{"err"};
  if(! defined $stdout_file) { ofile_FAIL("ERROR in $sub_name, stdout output file name is undefined", "dnaorg", 1, $FH_HR); }
  if(! defined $ifile_file)  { ofile_FAIL("ERROR in $sub_name, ifile  output file name is undefined", "dnaorg", 1, $FH_HR); }
  if(! defined $tfile_file)  { ofile_FAIL("ERROR in $sub_name, tfile  output file name is undefined", "dnaorg", 1, $FH_HR); }
  if(! defined $stk_file)    { ofile_FAIL("ERROR in $sub_name, stk    output file name is undefined", "dnaorg", 1, $FH_HR); }
  if(! defined $err_file)    { ofile_FAIL("ERROR in $sub_name, err    output file name is undefined", "dnaorg", 1, $FH_HR); }
  if((! opt_Exists("--skipalign", $opt_HHR)) || (! opt_Get("--skipalign", $opt_HHR))) { 
    if(-e $stdout_file) { unlink $stdout_file; }
    if(-e $ifile_file)  { unlink $ifile_file; }
    if(-e $tfile_file)  { unlink $tfile_file; }
    if(-e $stk_file)    { unlink $stk_file; }
    if(-e $err_file)    { unlink $err_file; }
  }
  utl_FileValidateExistsAndNonEmpty($mdl_file, "CM file", $sub_name, 1, $FH_HR); 
  utl_FileValidateExistsAndNonEmpty($seq_file, "sequence file", $sub_name, 1, $FH_HR);

  # determine cmalign options based on command line options
  my $opts = sprintf(" --verbose --cpu 0 --ifile $ifile_file --tfile $tfile_file -o $stk_file --tau %s --mxsize %s", opt_Get("--tau", $opt_HHR), opt_Get("--mxsize", $opt_HHR));
  # add --sub and --notrunc unless --nosub used
  if(! opt_Get("--nosub", $opt_HHR)) { 
    $opts .= " --sub --notrunc"; 
  }
  # add -g unless --noglocal used
  if(! opt_Get("--noglocal", $opt_HHR)) { 
    $opts .= " -g"; 
  }
  if(! opt_Get("--nofixedtau", $opt_HHR)) { 
    $opts .= " --fixedtau"; 
  }

  my $cmd = undef;
  if(defined $mdl_name) { 
    $cmd = $execs_HR->{"cmfetch"} . " $mdl_file $mdl_name | " . $execs_HR->{"cmalign"} . " $opts - $seq_file > $stdout_file 2>&1";
  }
  else { 
    $cmd = $execs_HR->{"cmalign"} . " $opts $mdl_file $seq_file > $stdout_file 2>&1";
  }

  my $success = 1;
  if($do_parallel) { 
    my $job_name = "J" . utl_RemoveDirPath($seq_file);
    my $nsecs  = opt_Get("--wait", $opt_HHR) * 60.;
    my $mem_gb = (opt_Get("--mxsize", $opt_HHR) / 1000.) * 3; # multiply --mxsize Gb by 3 to be safe
    if($mem_gb < 8.) { $mem_gb = 8.; } # set minimum of 8 Gb
    if((! opt_Exists("--skipalign", $opt_HHR)) || (! opt_Get("--skipalign", $opt_HHR))) { 
      dng_SubmitJob($cmd, $job_name, $err_file, $mem_gb, $nsecs, $opt_HHR, $ofile_info_HHR);
    }
  }
  else { 
    if((! opt_Exists("--skipalign", $opt_HHR)) || (! opt_Get("--skipalign", $opt_HHR))) { 
      utl_RunCommand($cmd, opt_Get("-v", $opt_HHR), 1, $FH_HR); # 1 says: it's okay if job fails
    }
    # command has completed, check for the error in the stdout, or a final line of 'CPU' indicating that it worked.
    $success = dng_CmalignCheckStdOutput($stdout_file, $ret_mxsize_R, $FH_HR);
    if($success == -1) { # indicates job did not finish properly, this shouldn't happen because utl_RunCommand() didn't die
      ofile_FAIL("ERROR in $sub_name, cmalign failed in a bad way, see $stdout_file for error output", 1, $ofile_info_HHR->{"FH"});
    }
  }
  
  return $success; 
}

#################################################################
# Subroutine : cmalign_parse_ifile()
# Incept:      EPN, Thu Jan 31 13:06:54 2019
#
# Purpose:    Parse Infernal 1.1 cmalign --ifile output and store
#             results in %{$seq_inserts_HR}.
#
# Arguments: 
#  $ifile_file:       ifile file to parse
#  $seq_inserts_HHR:  REF to hash of hashes with insert information, added to here
#  $FH_HR:            REF to hash of file handles
#
# Returns:    void
#
# Dies:       if unable to parse the ifile
#
################################################################# 
sub cmalign_parse_ifile { 
  my $sub_name = "cmalign_parse_ifile()";
  my $nargs_exp = 3;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }
  
  my ($ifile_file, $seq_inserts_HHR, $FH_HR) = @_;
  
  open(IN, $ifile_file) || ofile_FileOpenFailure($ifile_file, "dnaorg", $sub_name, $!, "reading", $FH_HR);

  my $line_ctr = 0;  # counts lines in ifile_file
  while(my $line = <IN>) { 
    $line_ctr++;
    if($line !~ m/^\#/) { 
      chomp $line;
      if($line =~ m/\r$/) { chop $line; } # remove ^M if it exists
      # 2 types of lines, those with 2 tokens, and those with 4 or more tokens
      #norovirus.NC_039477 7567
      #gi|669176088|gb|KM198574.1| 7431 17 7447  2560 2539 3  2583 2565 3
      my @el_A = split(/\s+/, $line);
      if   (scalar(@el_A) == 2) { ; } # ignore these lines
      elsif(scalar(@el_A) >= 4) { 
        my $nel = scalar(@el_A); 
        if((($nel - 4) % 3) != 0) { # check number of elements makes sense
          ofile_FAIL("ERROR in $sub_name, unexpected number of elements ($nel) in ifile line in $ifile_file on line $line_ctr:\n$line\n", "dnaorg", 1, $FH_HR);
        }          
        my ($seqname, $seqlen, $spos, $epos) = ($el_A[0], $el_A[1], $el_A[2], $el_A[3]);
        if(! defined $seq_inserts_HHR->{$seqname}) { 
          # initialize
          %{$seq_inserts_HHR->{$seqname}} = ();
        }
        # create the insert string
        my $insert_str = "";
        for(my $el_idx = 4; $el_idx < scalar(@el_A); $el_idx += 3) { 
          $insert_str .= $el_A[$el_idx] . ":" . $el_A[$el_idx+1] . ":" . $el_A[$el_idx+2] . ";"; 
        }
        $seq_inserts_HHR->{$seqname}{"spos"} = $spos;
        $seq_inserts_HHR->{$seqname}{"epos"} = $epos;
        $seq_inserts_HHR->{$seqname}{"ins"}  = $insert_str;
      }
    }
  }
  close(IN);
  
  return;
}

#################################################################
# Subroutine : cmalign_parse_stk_and_add_alignment_alerts()
# Incept:      EPN, Thu Jan 31 13:06:54 2019
#
# Purpose:    Parse Infernal 1.1 cmalign stockholm alignment file
#             and store results in @{$mdl_results_AAHR}. 
#             
#             Detects and adds the following alerts to 
#             @{$alt_ftr_instances_AAHR}:
#             n_gp5: gap at 5' boundary of model span for a feature segment
#             n_gp3: gap at 5' boundary of model span for a feature segment
#             n_lp5: low posterior prob at 5' boundary of model span for a feature segment
#             n_lp3: low posterior prob at 5' boundary of model span for a feature segment
#
# Arguments: 
#  $stk_file:               stockholm alignment file to parse
#  $seq_len_HR:             REF to hash of sequence lengths, PRE-FILLED
#  $seq_inserts_HHR:        REF to hash of hashes with sequence insert information, PRE-FILLED
#  $sgm_info_AHR:           REF to hash of arrays with information on the model segments, PRE-FILLED
#  $ftr_info_AHR:           REF to hash of arrays with information on the features, PRE-FILLED
#  $alt_info_HHR:           REF to hash of hashes with information on the errors, PRE-FILLED
#  $sgm_results_HAHR:       REF to results AAH, FILLED HERE
#  $alt_ftr_instances_HHHR: REF to error instances HAH, ADDED TO HERE
#  $opt_HHR:                REF to 2D hash of option values
#  $FH_HR:                  REF to hash of file handles
#
# Returns:    void
#
# Dies:
#
################################################################# 
sub cmalign_parse_stk_and_add_alignment_alerts { 
  my $sub_name = "cmalign_parse_stk_and_add_alignment_alerts()";
  my $nargs_exp = 10;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }
  
  my ($stk_file, $seq_len_HR, $seq_inserts_HHR, $sgm_info_AHR, $ftr_info_AHR, $alt_info_HHR, $sgm_results_HAHR, $alt_ftr_instances_HHHR, $opt_HHR, $FH_HR) = @_;

  my $pp_thresh = opt_Get("--ppmin", $opt_HHR);
  my $small_value = 0.000001; # for checking if PPs are below threshold
  my $nsgm = scalar(@{$sgm_info_AHR});

  # create an ESL_MSA object from the alignment
  # open and validate file
  my $msa = Bio::Easel::MSA->new({
    fileLocation => $stk_file,
    isDna => 1});  

  # build a map of aligned positions to model RF positions and vice versa, only need to do this once per alignment
  my $alen = $msa->alen;
  my @rf2a_A = (); # [1..$rfpos..$rflen] = $apos;  rf position $rfpos maps to alignment position $apos [1..$alen]  ($rf2a_A[0] = -1  (dummy value))
  $rf2a_A[0] = -1; 
  my $rf_str = $msa->get_rf;
  my @rf_A = split("", $rf_str);
  if(scalar(@rf_A) != $alen) { 
    ofile_FAIL(sprintf("ERROR in $sub_name, unexpected alignment length mismatch $alen != %d\n", scalar(@rf_A)), "dnaorg", 1, $FH_HR);
  }
  my $rfpos = 0; # nongap RF (model) position [1..$rflen]
  my $apos  = 0; # alignment position [1..$alen]
  for($apos = 1; $apos <= $alen; $apos++) { 
    if($rf_A[($apos-1)] ne ".") { 
      # nongap RF (model position)
      $rfpos++;
      $rf2a_A[$rfpos] = $apos;
    }
  }
  my $rflen = $rfpos;

  # move through each sequence in the alignment and determine its boundaries for each model region
  my $nseq = $msa->nseq; 
  # for each sequence, go through all models and fill in the start and stop (unaligned seq) positions
  for(my $i = 0; $i < $nseq; $i++) { 
    my $seq_name = $msa->get_sqname($i);
    if(! exists $seq_len_HR->{$seq_name}) { 
      ofile_FAIL("ERROR in $sub_name, do not have length information for sequence $seq_name from alignment in $stk_file", "dnaorg", 1, $FH_HR);
    }
    my $seq_len = $seq_len_HR->{$seq_name};
    if(! defined $seq_inserts_HHR->{$seq_name}{"ins"}) { 
      ofile_FAIL("ERROR in $sub_name, do not have insert information for sequence $seq_name from alignment in $stk_file", "dnaorg", 1, $FH_HR);
    }
    my $seq_ins = $seq_inserts_HHR->{$seq_name}{"ins"}; # string of inserts

    # fill sequence-specific arrays
    # insert info from seq_info_HAR (read previously from cmalign --ifile output)
    my @rf2ipos_A = (); # [0..$rfpos..$rflen] = $uapos; rf position $rfpos has an insert immediately after it start at unaligned position $uapos [1..$seq_len], 0 for none
    my @rf2ilen_A = (); # [0..$rfpos..$rflen] = $ilen;  rf position $rfpos has an insert immediately after it of length $ilen, 0 for none
    # fill insert arrays, need to do this once per sequence
    # initialize insert arrays
    for($rfpos = 0; $rfpos <= $rflen; $rfpos++) { 
      $rf2ipos_A[$rfpos] = -1;
      $rf2ilen_A[$rfpos] = -1;
    }
    
    if($seq_ins ne "") { 
      my @ins_A = split(";", $seq_inserts_HHR->{$seq_name}{"ins"});
      foreach my $ins_tok (@ins_A) { 
        #printf("ins_tok: $ins_tok\n");
        if($ins_tok =~ /^(\d+)\:(\d+)\:(\d+)$/) { 
          my ($i_rfpos, $i_uapos, $i_len) = ($1, $2, $3);
          $rf2ipos_A[$i_rfpos] = $i_uapos;
          $rf2ilen_A[$i_rfpos] = $i_len;
          #printf("rf2ipos_A[%5d]: %5d rf2ilen_A[%5d]: %5d\n", $i_rfpos, $i_uapos, $i_rfpos, $i_len);
        }
        else { 
          ofile_FAIL("ERROR in $sub_name, failed to parse insert information read from ifile for $seq_name:\n" . $seq_inserts_HHR->{$seq_name}{"ifile_ins"}, "dnaorg", 1, $FH_HR);
        }
      }
    }    

    # alignment info, filled once per sequence then used for all model spans
    my @min_rfpos_after_A  = (); # [0..$rfpos..rflen+1]: $rfpos2 is minimum rfpos >= $rfpos that is not a gap 
                                 #                       OR is a gap but has an insert *after* it (before $rfpos2+1)
                                 #                       possible values are [-1,1..rflen] (-1 if none) with two *exceptions*:
                                 #                       element [0]       is special: can be 0 if inserts exist after position 0 (before position 1)
                                 #                       element [rflen+1] is special: always -1
    my @max_rfpos_before_A = (); # [0..$rfpos..rflen+1]: $rfpos2 is maximum rfpos >= $rfpos that is not a gap 
                                 #                       OR is a gap but has an insert *before* it (after $rfpos2-1)
                                 #                       possible values are [-1,1..rflen] (-1 if none) with two *exceptions*
                                 #                       element [0]       is special: always -1
                                 #                       element [rflen+1] is special: can be rfpos+1 if inserts exist after rflen (before position rflen+1)

    my @min_uapos_after_A  = (); # [0..$rfpos..rflen+1]: minimum unaligned position for current sequence 
                                 #                       that aligns at or inserts *after*  $min_rfpos_after_A[$rfpos]
                                 #                       -1 if $min_rfpos_after_A[$rfpos]  == -1
    my @max_uapos_before_A = (); # [0..$rfpos..rflen+1]: maximum unaligned position for current sequence 
                                 #                       that aligns at or inserts *before* $max_rfpos_before_A[$rfpos]
                                 #                       -1 if $max_rfpos_before_A[$rfpos] == -1

    my @rfpos_pp_A = ();         # [0..$rfpos..rflen+1]: posterior probability character for current sequence at RF position $rfpos
                                 #                       '.' if sequence is a gap at that RF position $rfpos
                                 #                       special values: $rfpos_pp_A[0] = -1, $rfpos_pp_A[$rflen+1] = -1

    $rfpos = 0;    # model positions (nongap RF position)
    my $uapos = 0; # unaligned sequence position (position in actual sequence)
    # initialize
    for($rfpos = 0; $rfpos <= ($rflen+1); $rfpos++) { 
      $min_rfpos_after_A[$rfpos]  = -1;
      $max_rfpos_before_A[$rfpos] = -1;
      $min_uapos_after_A[$rfpos]  = -1;
      $max_uapos_before_A[$rfpos] = -1;
      $rfpos_pp_A[$rfpos]         = ".";
    }
    # get aligned sequence, length will be alen
    my $sqstring_aligned = $msa->get_sqstring_aligned($i);
    my $ppstring_aligned = $msa->get_ppstring_aligned($i);
    if(length($sqstring_aligned) != $alen) { 
      ofile_FAIL(sprintf("ERROR in $sub_name, fetched aligned seqstring of unexpected length (%d, not %d)\n$sqstring_aligned\n", length($sqstring_aligned), $alen), "dnaorg", 1, $FH_HR);
    }
    if(length($ppstring_aligned) != $alen) { 
      ofile_FAIL(sprintf("ERROR in $sub_name, fetched aligned posterior probability string of unexpected length (%d, not %d)\n$sqstring_aligned\n", length($ppstring_aligned), $alen), "dnaorg", 1, $FH_HR);
    }
    my @sq_A = split("", $sqstring_aligned);
    my @pp_A = split("", $ppstring_aligned);
    # printf("sq_A size: %d\n", scalar(@sq_A));
    # printf("seq_len: $seq_len\n");

    # first pass, from right to left to fill $min_**pos_after arrays, and rf
    my $min_rfpos = -1;
    my $min_uapos = $seq_len+1;
    for($rfpos = $rflen; $rfpos >= 0; $rfpos--) { 
      $apos = $rf2a_A[$rfpos];
      my $nongap_rf    = (($rfpos > 0) && ($sq_A[($apos-1)] ne ".") && ($sq_A[($apos-1)] ne "-")) ? 1 : 0;
      my $insert_after = ($rf2ipos_A[$rfpos] != -1) ? 1 : 0;
      if($nongap_rf || $insert_after) { 
        $min_rfpos = $rfpos;
      }
      if($insert_after) { 
        $min_uapos -= $rf2ilen_A[$rfpos]; # subtract inserts between $rfpos and ($rfpos+1)
      }
      if($nongap_rf) { 
        $min_uapos--;
        $rfpos_pp_A[$rfpos] = $pp_A[($apos-1)];
      }
      $min_rfpos_after_A[$rfpos] = $min_rfpos;
      $min_uapos_after_A[$rfpos] = $min_uapos;
      # printf("rfpos: %5d  apos: %5d  min_rfpos: %5d  min_uapos: %5d\n", $rfpos, $apos, $min_rfpos, $min_uapos);
    }
    if($min_uapos != 1) { 
      ofile_FAIL("ERROR in $sub_name, failed to account for all nucleotides when parsing alignment for $seq_name, pass 1 (min_uapos should be 1 but it is $min_uapos)", "dnaorg", 1, $FH_HR);
    }      

    # second pass, from left to right to fill $max_**pos_before arrays:
    my $max_rfpos = -1;
    my $max_uapos = 0;
    for($rfpos = 1; $rfpos <= ($rflen+1); $rfpos++) { 
      $apos = $rf2a_A[$rfpos];
      my $nongap_rf     = (($rfpos <= $rflen) && ($sq_A[($apos-1)] ne ".") && ($sq_A[($apos-1)] ne "-")) ? 1 : 0;
      my $insert_before = ($rf2ipos_A[($rfpos-1)] != -1) ? 1 : 0;
      if($nongap_rf || $insert_before) { 
        $max_rfpos = $rfpos;
      }
      if($insert_before) { 
        $max_uapos += $rf2ilen_A[($rfpos-1)]; # subtract inserts between ($rfpos-1) and $rfpos
      }
      if($nongap_rf) { 
        $max_uapos++;
        $rfpos_pp_A[$rfpos] = $pp_A[($apos-1)];
      }
      $max_rfpos_before_A[$rfpos] = $max_rfpos;
      $max_uapos_before_A[$rfpos] = $max_uapos;
 #     if($rfpos <= $rflen) { 
 #       printf("rfpos: %5d  apos: %5d  max_rfpos: %5d  max_uapos: %5d\n", $rfpos, $apos, $max_rfpos, $max_uapos);
 #     }
    }
    if($max_uapos != $seq_len) { 
      ofile_FAIL("ERROR in $sub_name, failed to account for all nucleotides when parsing alignment for $seq_name, pass 2 (max_uapos should be $seq_len but it is $max_uapos)", "dnaorg", 1, $FH_HR);
    }      
    
    # Debugging print block
#    printf("***************************************************\n");
#    printf("DEBUG print $seq_name\n");
#    for($rfpos = 0; $rfpos <= ($rflen+1); $rfpos++) { 
#      printf("rfpos[%5d] min_rf_after_A: %5d  min_ua_after_A: %5d  max_rf_before_A: %5d  max_ua_before_A: %5d\n", 
#             $rfpos, 
#             $min_rfpos_after_A[$rfpos],
#             $min_uapos_after_A[$rfpos],
#             $max_rfpos_before_A[$rfpos],
#             $max_uapos_before_A[$rfpos]);
#    }
#    printf("***************************************************\n");

    # given model span s..e
    # if strand eq "+"
    #   if C[rfpos] > D[rfpos] then no hit (A[rfpos] should be > B[rfpos])
    #   else (C[rfpos] <= D[rfpos]) 
    #        hit uaseq span is from C[rfpos] to D[rfpos]
    #        hit rf span is from A[rfpos] to B[rfpos]

    # now we have all the info we need for this sequence to determine sequence boundaries for each model segment
    for(my $sgm_idx = 0; $sgm_idx < $nsgm; $sgm_idx++) { 
      my $sgm_start_rfpos = $sgm_info_AHR->[$sgm_idx]{"start"};
      my $sgm_stop_rfpos  = $sgm_info_AHR->[$sgm_idx]{"stop"};
      my $sgm_strand      = $sgm_info_AHR->[$sgm_idx]{"strand"};

# Debugging print block
#      printf("segment $sgm_idx $sgm_start_rfpos..$sgm_stop_rfpos\n");
#      $rfpos = $sgm_start_rfpos;
#      printf("\trfpos[%5d] min_rf_after_A: %5d  min_ua_after_A: %5d  max_rf_before_A: %5d  max_ua_before_A: %5d\n", 
#             $rfpos, 
#             $min_rfpos_after_A[$rfpos],
#             $min_uapos_after_A[$rfpos],
#             $max_rfpos_before_A[$rfpos],
#             $max_uapos_before_A[$rfpos]);
#      $rfpos = $sgm_stop_rfpos;
#      printf("\trfpos[%5d] min_rf_after_A: %5d  min_ua_after_A: %5d  max_rf_before_A: %5d  max_ua_before_A: %5d\n", 
#             $rfpos, 
#             $min_rfpos_after_A[$rfpos],
#             $min_uapos_after_A[$rfpos],
#             $max_rfpos_before_A[$rfpos],
#             $max_uapos_before_A[$rfpos]);

      my $start_rfpos = -1; # model position of start of this model region for this aligned sequence, stays at -1 if none
      my $stop_rfpos  = -1; # model position of stop  of this model region for this aligned sequence, stays at -1 if none
      my $start_uapos = -1; # unaligned position of start of this model region for this aligned sequence, stays at -1 if none
      my $stop_uapos  = -1; # unaligned position of stop  of this model region for this aligned sequence, stays at -1 if none
      my $p_5seqflush = undef;
      my $p_3seqflush = undef;

      # this should work regardless of strand
      if(($min_rfpos_after_A[$sgm_start_rfpos] != -1) && 
         ($max_rfpos_before_A[$sgm_stop_rfpos] != -1)) { 

        $start_uapos = $min_uapos_after_A[$sgm_start_rfpos];
        $stop_uapos  = $max_uapos_before_A[$sgm_stop_rfpos];

        $start_rfpos = $min_rfpos_after_A[$sgm_start_rfpos];
        $stop_rfpos  = $max_rfpos_before_A[$sgm_stop_rfpos];

        if($sgm_strand eq "+") { 
          $p_5seqflush = ($start_uapos == 1)        ? 1 : 0;
          $p_3seqflush = ($stop_uapos  == $seq_len) ? 1 : 0;
        }
        else { 
          $p_5seqflush = ($start_uapos == $seq_len) ? 1 : 0;
          $p_3seqflush = ($stop_uapos  == 1)        ? 1 : 0;
        }

        %{$sgm_results_HAHR->{$seq_name}[$sgm_idx]} = ();
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"sstart"}    = $start_uapos;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"sstop"}     = $stop_uapos;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"mstart"}    = $start_rfpos;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"mstop"}     = $stop_rfpos;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"strand"}    = $sgm_strand;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"5seqflush"} = $p_5seqflush;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"3seqflush"} = $p_3seqflush;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"5trunc"}    = ($p_5seqflush && ($start_rfpos != $sgm_start_rfpos)) ? 1 : 0;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"3trunc"}    = ($p_3seqflush && ($stop_rfpos  != $sgm_stop_rfpos))  ? 1 : 0;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"startgap"}  = ($rfpos_pp_A[$sgm_start_rfpos] eq ".") ? 1  : 0;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"stopgap"}   = ($rfpos_pp_A[$sgm_stop_rfpos]  eq ".") ? 1  : 0;
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"startpp"}   = ($rfpos_pp_A[$sgm_start_rfpos] eq ".") ? -1 : convert_pp_char_to_pp_avg($rfpos_pp_A[$sgm_start_rfpos], $FH_HR);
        $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"stoppp"}    = ($rfpos_pp_A[$sgm_stop_rfpos]  eq ".") ? -1 : convert_pp_char_to_pp_avg($rfpos_pp_A[$sgm_stop_rfpos], $FH_HR);
        
        # add errors, if nec
        if(! $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"5trunc"}) { 
          if($sgm_results_HAHR->{$seq_name}[$sgm_idx]{"startgap"}) { 
            alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "n_gp5", $seq_name, $sgm_info_AHR->[$sgm_idx]{"map_ftr"},
                                       "RF position $sgm_start_rfpos" . dng_FeatureSummarizeSegment($ftr_info_AHR, $sgm_info_AHR, $sgm_idx), 
                                       $FH_HR);
          } 
          elsif(($sgm_results_HAHR->{$seq_name}[$sgm_idx]{"startpp"} - $pp_thresh) < $small_value) { # only check PP if it's not a gap
            alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "n_lp5", $seq_name, $sgm_info_AHR->[$sgm_idx]{"map_ftr"},
                                       sprintf("%.2f < %.2f, RF position $sgm_start_rfpos" . dng_FeatureSummarizeSegment($ftr_info_AHR, $sgm_info_AHR, $sgm_idx), $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"startpp"}, $pp_thresh),
                                       $FH_HR);
          }
        }
        if(! $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"3trunc"}) { 
          if($sgm_results_HAHR->{$seq_name}[$sgm_idx]{"stopgap"}) { 
            alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "n_gp3", $seq_name, $sgm_info_AHR->[$sgm_idx]{"map_ftr"},
                                       "RF position $sgm_stop_rfpos" . dng_FeatureSummarizeSegment($ftr_info_AHR, $sgm_info_AHR, $sgm_idx), 
                                       $FH_HR);
          }
          elsif(($sgm_results_HAHR->{$seq_name}[$sgm_idx]{"stoppp"} - $pp_thresh) < $small_value) { # only check PP if it's not a gap
            alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "n_lp3", $seq_name, $sgm_info_AHR->[$sgm_idx]{"map_ftr"},
                                       sprintf("%.2f < %.2f, RF position $sgm_stop_rfpos" . dng_FeatureSummarizeSegment($ftr_info_AHR, $sgm_info_AHR, $sgm_idx), $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"stoppp"}, $pp_thresh),
                                       $FH_HR);
          }
        }

        # Debugging print block
        #printf("segment $sgm_idx: $sgm_start_rfpos to $sgm_stop_rfpos\n");
        #foreach my $key ("sstart", "sstop", "mstart", "mstop", "strand", "5seqflush", "3seqflush", "5trunc", "3trunc", "startgap", "stopgap", "startpp", "stoppp") { 
        #printf("\tstored $key $sgm_results_HAHR->{$seq_name}[$sgm_idx]{$key}\n");
        #}
      }
    } # end of 'for(my $sgm_idx = 0; $sgm_idx < $nsgm; $sgm_idx++)'
  } # end of 'for(my $i = 0; $m < $nseq; $m++)'
  undef $msa;

  return;
}

#################################################################
# Subroutine:  cmalign_store_overflow()
# Incept:      EPN, Wed Feb 13 16:04:53 2019
#
# Purpose:     Store information on a sequence that has caused
#              a DP matrix memory overflow. 
#              
# Arguments: 
#  $seq_file:           the sequence file with the single sequence that failed in it
#  $mxsize:             matrix size to add to @{$overflow_mxsize_AR}
#  $overflow_seq_AR:    ref to array of sequences that failed due to matrix overflows, to add to
#  $overflow_mxsize_AR: ref to array of required matrix sizes for each sequence that failed due to matrix overflows, to add to
#  $FH_HR:              ref to file handle hash
# 
# Returns:     void
#
# Dies: if there's some problem opening the sequence file
#
################################################################# 
sub cmalign_store_overflow { 
  my $sub_name = "cmalign_store_overflow";
  my $nargs_expected = 5;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 

  my ($seq_file, $mxsize, $overflow_seq_AR, $overflow_mxsize_AR, $FH_HR) = @_;

  my $sqfile = Bio::Easel::SqFile->new({ fileLocation => $seq_file }); # the sequence file object

  my ($overflow_seq, undef) = $sqfile->fetch_next_seq_name_length();
  push(@{$overflow_seq_AR},    $overflow_seq);
  push(@{$overflow_mxsize_AR}, $mxsize);

  $sqfile = undef;

  return;
}

#################################################################
# Subroutine: fetch_features_and_add_cds_and_mp_alerts()
# Incept:     EPN, Fri Feb 22 14:25:49 2019
#
# Purpose:   For each sequence, fetch each feature sequence, and 
#            detect n_str, n_trc, n_stp, n_nst, n_ext, and n_nm3 alerts 
#            where appropriate. For n_trc alerts, correct the predictions
#            and fetch the corrected feature.
#
# Arguments:
#  $sqfile:                 REF to Bio::Easel::SqFile object, open sequence file containing the full input seqs
#  $mdl_name:               name of model these sequences were assigned to
#  $seq_name_AR:            REF to array of sequence names
#  $seq_len_HR:             REF to hash of sequence lengths, PRE-FILLED
#  $ftr_info_AHR:           REF to hash of arrays with information on the features, PRE-FILLED
#  $sgm_info_AHR:           REF to hash of arrays with information on the model segments, PRE-FILLED
#  $alt_info_HHR:           REF to the alert info hash of arrays, PRE-FILLED
#  $sgm_results_HAHR:       REF to model segment results HAH, pre-filled
#  $ftr_results_HAHR:       REF to feature results NAH, added to here
#  $alt_ftr_instances_HHHR: REF to array of 2D hashes with per-feature alerts, PRE-FILLED
#  $opt_HHR:                REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:         REF to the 2D hash of output file information
#             
# Returns:  void
# 
# Dies:     never
#
#################################################################
sub fetch_features_and_add_cds_and_mp_alerts { 
  my $sub_name = "fetch_features_and_add_cds_and_mp_alerts";
  my $nargs_exp = 12;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($sqfile, $mdl_name, $seq_name_AR, $seq_len_HR, $ftr_info_AHR, $sgm_info_AHR, $alt_info_HHR, $sgm_results_HAHR, $ftr_results_HAHR, $alt_ftr_instances_HHHR, $opt_HHR, $ofile_info_HHR) = @_;

  my $FH_HR  = $ofile_info_HHR->{"FH"}; # for convenience

  my $nseq = scalar(@{$seq_name_AR});
  my $nftr = scalar(@{$ftr_info_AHR});
  my $nsgm = scalar(@{$sgm_info_AHR});

  # get children info for all features, we'll use this in the loop below
  my @children_AA = ();
  dng_FeatureInfoChildrenArrayOfArrays($ftr_info_AHR, \@children_AA, $FH_HR);

  my $ftr_idx;
  my @ftr_fileroot_A = (); # for naming output files for each feature
  my @ftr_outroot_A  = (); # for describing output files for each feature
  for($ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
    $ftr_fileroot_A[$ftr_idx] = dng_FeatureTypeAndTypeIndexString($ftr_info_AHR, $ftr_idx, ".");
    $ftr_outroot_A[$ftr_idx]  = dng_FeatureTypeAndTypeIndexString($ftr_info_AHR, $ftr_idx, "#");
  }

  for(my $seq_idx = 0; $seq_idx < $nseq; $seq_idx++) { 
    my $seq_name = $seq_name_AR->[$seq_idx];
    my $seq_len  = $seq_len_HR->{$seq_name};
    @{$ftr_results_HAHR->{$seq_name}} = ();

    for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
      if(! dng_FeatureIsDuplicate($ftr_info_AHR, $ftr_idx)) { 
        my $ftr_is_cds_or_mp = dng_FeatureTypeIsCdsOrMatPeptide($ftr_info_AHR, $ftr_idx);
        my $ftr_is_cds       = dng_FeatureTypeIsCds($ftr_info_AHR, $ftr_idx);
        my $ftr_is_mp        = dng_FeatureTypeIsMatPeptide($ftr_info_AHR, $ftr_idx);
        my $ftr_type_idx     = $ftr_fileroot_A[$ftr_idx];
        my $ftr_sqstring = "";
        my $ftr_seq_name = undef;
        my @ftr2org_pos_A = (); # [1..$ftr_pos..$ftr_len] original sequence position that corresponds to this position in the feature
        $ftr2org_pos_A[0] = -1; # invalid
        my $ftr_len = 0;
        my $ftr_strand = undef;
        my $ftr_is_5trunc = undef;
        my $ftr_is_3trunc = undef;
        my $ftr_start  = undef; # predicted start for the feature
        my $ftr_stop   = undef; # predicted stop  for the feature
        my $ftr_stop_c = undef; # corrected stop  for the feature, stays undef if no correction needed (no 'trc' or 'ext')
        my $ftr_ofile_key = $mdl_name . ".pfa." . $ftr_idx;
        %{$ftr_results_HAHR->{$seq_name}[$ftr_idx]} = ();
        my $ftr_results_HR = \%{$ftr_results_HAHR->{$seq_name}[$ftr_idx]}; # for convenience
        my $ftr_nchildren = scalar(@{$children_AA[$ftr_idx]});
        # printf("in $sub_name, set ftr_results_HR to ftr_results_HAHR->{$seq_name}[$ftr_idx]\n");

        my %alt_str_H = ();   # added to as we find alerts below
                              # n_str, n_nm3, n_stp, n_ext, n_nst, n_trc
        my $alt_flag = 0; # set to '1' if we set an alert for this feature
        
        for(my $sgm_idx = $ftr_info_AHR->[$ftr_idx]{"5p_sgm_idx"}; $sgm_idx <= $ftr_info_AHR->[$ftr_idx]{"3p_sgm_idx"}; $sgm_idx++) { 
          if((defined $sgm_results_HAHR->{$seq_name}) && 
             (defined $sgm_results_HAHR->{$seq_name}[$sgm_idx]) && 
             (defined $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"sstart"})) { 
            my $sgm_results_HR = $sgm_results_HAHR->{$seq_name}[$sgm_idx]; # for convenience
            my ($start, $stop, $strand) = ($sgm_results_HR->{"sstart"}, $sgm_results_HR->{"sstop"}, $sgm_results_HR->{"strand"});
              
            # update truncated mode
            if($sgm_idx == $ftr_info_AHR->[$ftr_idx]{"5p_sgm_idx"}) { 
              $ftr_start = $start;
              $ftr_is_5trunc = $sgm_results_HR->{"5trunc"};
            }
            if($sgm_idx == $ftr_info_AHR->[$ftr_idx]{"3p_sgm_idx"}) { 
              $ftr_stop = $stop;
              $ftr_is_3trunc = $sgm_results_HR->{"3trunc"};
            }
            
            # check or update feature strand, but only if cds or mp (otherwise we don't care)
            if(! defined $ftr_strand) { 
              $ftr_strand = $strand; 
            }
            elsif($ftr_strand ne $strand) { 
              # mixture of strands on different segments, this shouldn't happen if we're a CDS or mat_peptide
              if($ftr_is_cds_or_mp) { 
                # this 'shouldn't happen' for a CDS or mature peptide, all segments should be the sames strand
                ofile_FAIL("ERROR, in $sub_name, different model sgements have different strands for a CDS or MP feature $ftr_idx", "dnaorg", 1, undef);
              }
              # mixture of strands, set to "!" 
              $ftr_strand = "!";
            }
            
            # update $ftr_sqstring, $ftr_seq_name, $ftr_len, @ftr2org_pos_A, and @ftr2sgm_idx_A
            my $sgm_len = abs($stop - $start) + 1;
            $ftr_sqstring .= $sqfile->fetch_subseq_to_sqstring($seq_name, $start, $stop, ($strand eq "-"));
            if(! defined $ftr_seq_name) { 
              $ftr_seq_name = $seq_name . "/" . $ftr_type_idx . "/"; 
            }
            else { 
              $ftr_seq_name .= ",";
            }
            $ftr_seq_name .= $start . ".." . $stop . ":" . $strand;
            
            if($ftr_is_cds_or_mp) { 
              # update ftr2org_pos_A, if nec
              my $sgm_offset = 0;
              for(my $sgm_offset = 0; $sgm_offset < $sgm_len; $sgm_offset++) { 
                $ftr2org_pos_A[$ftr_len + $sgm_offset + 1] = ($strand eq "-") ? $start - $sgm_offset : $start + $sgm_offset;
                # slightly wasteful in certain cases, if $ftr_is_5trunc && $ftr_is_3trunc then we won't use this
              }
            }
            $ftr_len += $sgm_len;
          } # end of 'if(defined $sgm_results_HAHR->{$seq_name}...'
        } # end of 'for(my $sgm_idx = $ftr_info_AHR->[$ftr_idx]{"5p_sgm_idx"}...

        # printf("in $sub_name seq_idx: $seq_idx ftr_idx: $ftr_idx ftr_len: $ftr_len ftr_start: $ftr_start ftr_stop: $ftr_stop\n");
        if($ftr_len > 0) { 
          # we had a prediction for at least one of the segments for this feature
          
          # output the sequence
          if(! exists $ofile_info_HHR->{"FH"}{$ftr_ofile_key}) { 
            ofile_OpenAndAddFileToOutputInfo($ofile_info_HHR, "dnaorg", $ftr_ofile_key,  $out_root . "." . $mdl_name . "." . $ftr_fileroot_A[$ftr_idx] . ".predicted.hits.fa", 1, "predicted hits to model $mdl_name for feature " . $ftr_outroot_A[$ftr_idx]);
          }
          print { $ofile_info_HHR->{"FH"}{$ftr_ofile_key} } (">" . $ftr_seq_name . "\n" . seq_SqstringAddNewlines($ftr_sqstring, 60) . "\n"); 
              
          if(! $ftr_is_5trunc) { 
            # feature is not 5' truncated, look for a start codon if it's the proper feature
            if($ftr_is_cds) { 
              if(! sqstring_check_start($ftr_sqstring, $FH_HR)) { 
                $alt_str_H{"n_str"} = "";
              }
            }
          }
          if((! $ftr_is_5trunc) && (! $ftr_is_3trunc)) { 
            if($ftr_is_cds_or_mp) { 
              # feature is not truncated on either end, look for stop codons
              if(($ftr_len % 3) != 0) { 
                # not a multiple of 3, this will also catch any feature with length < 3 (which should be very very rare, 
                # but which could cause weird downstream problems)
                $alt_str_H{"n_nm3"} = "$ftr_len";
              }
              else { 
                # feature length is a multiple of 3, look for all valid in-frame stops 
                my @ftr_nxt_stp_A = ();
                sqstring_find_stops($ftr_sqstring, \@ftr_nxt_stp_A, $FH_HR);
                
                if($ftr_is_cds) { 
                  # check that final add codon is a valid stop, and add 'n_stp' alert if not
                  if($ftr_nxt_stp_A[($ftr_len-2)] != $ftr_len) { 
                    $alt_str_H{"n_stp"} = sprintf("%s ending at position %d on %s strand", 
                                                  substr($ftr_sqstring, ($ftr_len-3), 3), # watch off-by-one ($ftr_len-2-1)
                                                  $ftr2org_pos_A[$ftr_len], $ftr_strand);
                  }
                  if($ftr_nxt_stp_A[1] != $ftr_len) { 
                    # first stop codon 3' of $ftr_start is not $ftr_stop
                    # We will need to add an alert, (exactly) one of:
                    # 'n_ext': no stop exists in $ftr_sqstring, but one does 3' of end of $ftr_sqstring
                    # 'n_nst': no stop exists in $ftr_sqstring, and none exist 3' of end of $ftr_sqstring either
                    # 'n_trc': an early stop exists in $ftr_sqstring
                    if($ftr_nxt_stp_A[1] == 0) { 
                      # there are no valid in-frame stops in $ftr_sqstring
                      # we have a 'n_nst' or 'n_ext' alert, to find out which 
                      # we need to fetch the sequence ending at $fstop to the end of the sequence 
                      if($ftr_stop < $seq_len) { 
                        # we have some sequence left 3' of ftr_stop
                        my $ext_sqstring = undef;
                        if($ftr_strand eq "+") { 
                          $ext_sqstring = $sqfile->fetch_subseq_to_sqstring($seq_name, $ftr_stop+1, $seq_len, 0); 
                        }
                        else { # negative strand
                          $ext_sqstring = $sqfile->fetch_subseq_to_sqstring($seq_name, $ftr_stop-1, 1, 1);
                        }
                        my @ext_nxt_stp_A = ();
                        sqstring_find_stops($ftr_sqstring, \@ext_nxt_stp_A, $FH_HR);
                        if($ext_nxt_stp_A[1] != 0) { 
                          # there is an in-frame stop codon, n_ext alert
                          # determine what position it is
                          $ftr_stop_c = ($ftr_strand eq "+") ? ($ftr_stop + $ext_nxt_stp_A[1]) : ($ftr_stop - $ext_nxt_stp_A[1]);
                          $alt_str_H{"n_ext"} = $ftr_stop_c;
                        }
                      } # end of 'if($ftr_stop < $seq_len)'
                      if(! defined $ftr_stop_c) { 
                        # if we get here, either $ftr_stop == $seq_len (and there was no more seq to check for a stop codon)
                        # or we checked the sequence but didn't find any
                        # either way, we have a n_nst alert:
                        $ftr_stop_c = "?"; # special case, we don't know where the stop is, but we know it's not $ftr_stop;
                        $alt_str_H{"n_nst"} = "";
                      }
                    } # end of 'if($ftr_nxt_stp_A[1] == 0) {' 
                    else { 
                      # there is an early stop (n_trc) in $ftr_sqstring
                      if($ftr_nxt_stp_A[1] > $ftr_len) { 
                        # this shouldn't happen, it means there's a bug in sqstring_find_stops()
                        ofile_FAIL("ERROR, in $sub_name, problem identifying stops in feature sqstring for ftr_idx $ftr_idx, found a stop at position that exceeds feature length", "dnaorg", 1, undef);
                      }
                      $ftr_stop_c = $ftr2org_pos_A[$ftr_nxt_stp_A[1]];
                      $alt_str_H{"n_trc"} = sprintf("revised to %d..%d (stop shifted %d nt)", $ftr_start, $ftr_stop_c, abs($ftr_stop - $ftr_stop_c));
                    }
                  } # end of 'if($ftr_nxt_stp_A[1] != $ftr_len) {' 
                } # end of 'if($ftr_is_cds) {' 
              } # end of 'else' entered if feature is a multiple of 3
              # if we added an alert for a CDS, step through all children of this feature (if any) and add b_per
              my $alt_flag = 0;
              foreach my $alt_code (sort keys %alt_str_H) { 
                alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, $alt_code, $seq_name, $ftr_idx, $alt_str_H{$alt_code}, $FH_HR);
                $alt_flag = 1;
              }
              if(($ftr_is_cds) && ($alt_flag) && ($ftr_nchildren > 0)) { 
                for(my $child_idx = 0; $child_idx < $ftr_nchildren; $child_idx++) { 
                  my $child_ftr_idx = $children_AA[$ftr_idx][$child_idx];
                  alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "b_per", $seq_name, $child_ftr_idx, "", $FH_HR);
                }
              }
            } # end of 'if($ftr_is_cds_or_mp)'
          } # end of 'if((! $ftr_is_5trunc) && (! $ftr_is_3trunc))

          # if we are a mature peptide, make sure we are adjacent to the next one, if there is one
          if($ftr_is_mp && ($ftr_info_AHR->[$ftr_idx]{"3pa_ftr_idx"} != -1)) { 
            my $ftr_3pa_idx = $ftr_info_AHR->[$ftr_idx]{"3pa_ftr_idx"};
            my $sgm_5p_idx  = $ftr_info_AHR->[$ftr_idx]{"3p_sgm_idx"};     
            # yes, the 3'-most segment of $ftr_idx is the 5'-most mature peptide we are interested in
            my $sgm_3p_idx  = $ftr_info_AHR->[$ftr_3pa_idx]{"5p_sgm_idx"}; 
            # and, yes, the 5'-most segment of the 3' adjacent $ftr_idx is the 3'-most mature peptide we're interested in
            
            my $sgm_5p_valid = ((defined $sgm_results_HAHR->{$seq_name}) && 
                                (defined $sgm_results_HAHR->{$seq_name}[$sgm_5p_idx]) && 
                                (defined $sgm_results_HAHR->{$seq_name}[$sgm_5p_idx]{"sstart"})) ? 1 : 0;
            my $sgm_3p_valid = ((defined $sgm_results_HAHR->{$seq_name}) && 
                                (defined $sgm_results_HAHR->{$seq_name}[$sgm_3p_idx]) && 
                                (defined $sgm_results_HAHR->{$seq_name}[$sgm_3p_idx]{"sstart"})) ? 1 : 0;
            my $sgm_5p_3flush = ($sgm_5p_valid && $sgm_results_HAHR->{$seq_name}[$sgm_5p_idx]{"3seqflush"}) ? 1 : 0;
            my $sgm_3p_5flush = ($sgm_3p_valid && $sgm_results_HAHR->{$seq_name}[$sgm_3p_idx]{"5seqflush"}) ? 1 : 0;
            
            my $stop_5p  = ($sgm_5p_valid) ? $sgm_results_HAHR->{$seq_name}[$sgm_5p_idx]{"sstop"}  : undef;
            my $start_3p = ($sgm_3p_valid) ? $sgm_results_HAHR->{$seq_name}[$sgm_3p_idx]{"sstart"} : undef;
            
            # Three ways we can get a 'n_adj' alert: 
            if($sgm_5p_valid && $sgm_3p_valid) { # both are valid 
              if((abs($stop_5p - $start_3p)) != 1) { # they're not adjacent
                # 1) both mature peptides are annotated but not adjacent, alert on $ftr_idx
                alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "n_adj", $seq_name, $ftr_idx, 
                                           sprintf("abs($stop_5p - $start_3p) != 1 (strand:%s)", $sgm_results_HAHR->{$seq_name}[$sgm_5p_idx]{"strand"}), 
                                           $FH_HR);
              }
            }
            elsif(($sgm_5p_valid) && (! $sgm_3p_valid) && (! $sgm_5p_3flush)) { 
              # 2) 5' mature peptide is annotated and ends before end of sequence, but 3' mature peptide is not annotated, alert for $ftr_idx
              alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "n_adj", $seq_name, $ftr_idx, 
                                         sprintf("feature stops at seq position $stop_5p on %s strand which is not terminal but expected 3'-adjacent feature is not annotated", $sgm_results_HAHR->{$seq_name}[$sgm_5p_idx]{"strand"}),
                                         $FH_HR);
            }
            elsif(($sgm_3p_valid) && (! $sgm_5p_valid) && (! $sgm_3p_5flush)) { 
              # 3) 3' mature peptide is annotated and starts after start of sequence, but 5' mature peptide is not annotated, alert for $ftr_3pa_idx (NOT $ftr_idx)
              alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "n_adj", $seq_name, $ftr_3pa_idx, 
                                         sprintf("feature starts at seq position $start_3p on %s strand which is not terminal but expected 5'-adjacent feature is not annotated", $sgm_results_HAHR->{$seq_name}[$sgm_3p_idx]{"strand"}),
                                         $FH_HR);
            }
          } # end of 'if($ftr_is_mp && ($ftr_info_AHR->[$ftr_idx]{"3pa_ftr_idx"} != -1))'

          # update %ftr_results_HR
          $ftr_results_HR->{"n_strand"} = $ftr_strand;
          $ftr_results_HR->{"n_start"}  = $ftr_start;
          $ftr_results_HR->{"n_stop"}   = $ftr_stop;
          $ftr_results_HR->{"n_stop_c"} = (defined $ftr_stop_c) ? $ftr_stop_c : $ftr_stop;
          $ftr_results_HR->{"n_5trunc"} = $ftr_is_5trunc;
          $ftr_results_HR->{"n_3trunc"} = $ftr_is_3trunc;
          $ftr_results_HR->{"n_len"}    = $ftr_len;
          #printf("set ftr_results_HR->{n_start} to " . $ftr_results_HR->{"n_start"} . "\n");
          #printf("set ftr_results_HR->{n_stop}  to " . $ftr_results_HR->{"n_stop"} . "\n");
        } # end of 'if($ftr_len > 0)'
      } # end of 'if(! dng_FeatureIsDuplicate($ftr_info_AHR, $ftr_idx)) {' 
    } # end of 'for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { '
  } # end of 'for(my $seq_idx = 0; $seq_idx < $nseq; $seq_idx++) {'
  
  return;
}  

#################################################################
# Subroutine: sqstring_check_start()
# Incept:     EPN, Sat Feb 23 10:18:22 2019
#
# Arguments:
#  $sqstring: the sequence string
#  $FH_HR:    REF to hash of file handles
#  
# Returns: '1' if $sqstring starts with a valid
#           start codon on the positive strand
#           '0' if not
# 
#################################################################
sub sqstring_check_start {
  my $sub_name = "sqstring_check_start";
  my $nargs_exp = 2;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($sqstring, $FH_HR) = @_;

  my $sqlen = length($sqstring);
  if($sqlen < 3) { return 0; } 

  my $start_codon = substr($sqstring, 0, 3);
  $start_codon =~ tr/a-z/A-Z/; # convert to uppercase
  $start_codon =~ tr/U/T/;     # convert to DNA

  return seq_CodonValidateStartCapDna($start_codon);

}

#################################################################
# Subroutine: sqstring_find_stops()
# Incept:     EPN, Fri Feb 22 14:52:53 2019
#
# Purpose:   Find all occurences of stop codons in an 
#            input sqstring (on the positive strand only),
#            and update the input array.
#           
#            This subroutine could be easily modified to 
#            find the nearest stop codon in each frame, 
#            but currently it is only concerned with 
#            frame 1.           
#
# Arguments:
#  $sqstring:       the sequence string
#  $nxt_stp_AR:     [1..$i..$sqlen] = $x; closest stop codon at or 3' of position
#                   $i in frame 1 on positive strand *ends* at position $x; 
#                   '0' if there are none.
#                   special values: 
#                   $nxt_stp_AR->[0] = -1
#  $FH_HR:          REF to hash of file handles
#             
# Returns:  void, updates arrays that are not undef
# 
# Dies:     If one but not both pos*AAR are undef
#           If one but not both neg*AAR are undef
#
#################################################################
sub sqstring_find_stops { 
  my $sub_name = "sqstring_find_stops";
  my $nargs_exp = 3;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($sqstring, $nxt_stp_AR, $FH_HR) = @_;
  
  @{$nxt_stp_AR} = ();
  $nxt_stp_AR->[0] = -1;

  # create the @sqstring_A we'll use to find the stops
  $sqstring =~ tr/a-z/A-Z/; # convert to uppercase
  $sqstring =~ tr/U/T/;     # convert to DNA
  my $sqlen = length($sqstring);
  # add a " " as first character of $sqstart so we get nts in elements 1..$sqlen 
  my @sqstring_A = split("", " " . $sqstring);

  my $i       = undef; # [1..$i..$sqlen]: sequence position
  my $frame   = undef; # 1, 2, or 3
  my $cstart  = undef; # [1..$sqlen] start position of current codon
  my $codon   = undef; # the codon
  my $cur_stp = 0;     # closest stop codon at or 3' of current position
                       # in frame 1 *ends* at position $cur_stp;

  # pass over sequence from right to left, filling @{$nxt_stp_AR}
  $cur_stp = 0;
  for($i = ($sqlen-2); $i >= 1; $i--) { 
    $frame  = (($i - 1) % 3) + 1; # 1 -> 1; 2 -> 2; 3 -> 3; 
    $cstart = $i;
    $codon = $sqstring_A[$cstart] . $sqstring_A[($cstart+1)] . $sqstring_A[($cstart+2)];
    if($frame == 1) { 
      if(seq_CodonValidateStopCapDna($codon)) { 
        $cur_stp = $i+2;
      }
    }
    $nxt_stp_AR->[$i] = $cur_stp;
  }
  $nxt_stp_AR->[($sqlen-1)] = 0;
  $nxt_stp_AR->[$sqlen]     = 0;

#  for($i = 1; $i <= $sqlen; $i++) { 
#    printf("HEYA position $i: nxt_stp: %5d\n", $i, $nxt_stp_AR->[$i]);
#  }

  return;
}

#################################################################
#
# Subroutines related to blastx:
# add_blastx_alerts 
# run_blastx_and_summarize_output
# parse_blastx_results 
# helper_blastx_breakdown_query
# helper_blastx_breakdown_max_indel_str
# helper_blastx_db_seqname_to_ftr_idx 
#
#################################################################
#################################################################
# Subroutine:  add_blastx_alerts
# Incept:      EPN, Tue Oct 23 15:54:50 2018
#
# Purpose:    Report blastx related errors for features of type 'cds'
#             using data stored in earlier parsing of blast results 
#             in @{$ftr_results_AAH} (filled in parse_blastx_results()).
#
#             Types of alerts added are:
#             "b_non": adds this alert if blastx has a prediction 
#                      for a feature for which there is no CM/nucleotide based prediction
#             "b_nop": adds this alert if blastx validation of a CDS prediction fails due to
#                      no blastx hits
#             "b_cst": adds this alert if blastx validation of a CDS prediction fails due to
#                      strand mismatch between CM and blastx prediction
#             "b_p5l": adds this alert if blastx validation of a CDS prediction fails due to
#                      BLASTX alignment being too long on 5' end (extending past CM alignment by > 0 nt)
#             "b_p5s": adds this alert if blastx validation of a CDS prediction fails due to
#                      BLASTX alignment being too short on 5' end (more than $xalntol shorter than CM)
#             "b_p3l": adds this alert if blastx validation of a CDS prediction fails due to
#                      BLASTX alignment being too long on 3' end (extending past CM alignment by > 0 nt)
#             "b_p3s": adds this alert if blastx validation of a CDS prediction fails due to
#                      BLASTX alignment being too short on 3' end (more than $xalntol shorter than CM)
#             "p_lin": adds this alert if blastx validation of a CDS prediction fails due to
#                      too long of an insert
#             "p_lde": adds this alert if blastx validation of a CDS prediction fails due to
#                      too long of a delete
#             "p_trc": adds this alert if blastx validation of a CDS prediction fails due to
#                      an in-frame stop codon in the blastx alignment
#
# Arguments: 
#  $seq_name_AR:            REF to array of sequence names, PRE-FILLED
#  $seq_len_HR:             REF to hash of of sequence lengths, PRE-FILLED
#  $ftr_info_AHR:           REF to array of hashes with information on the features, PRE-FILLED
#  $alt_info_HHR:           REF to array of hashes with information on the alerts, PRE-FILLED
#  $ftr_results_HAHR:       REF to feature results HAH, PRE-FILLED
#  $alt_ftr_instances_HHHR: REF to alert instances HAH, ADDED TO HERE
#  $opt_HHR:                REF to 2D hash of option values, see top of epn-options.pm for description
#  $FH_HR:                  REF to hash of file handles
#
# Returns:    void
#
################################################################# 
sub add_blastx_alerts { 
  my $sub_name = "add_blastx_alerts";
  my $nargs_expected = 8;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 
  
  my ($seq_name_AR, $seq_len_HR, $ftr_info_AHR, $alt_info_HHR, $ftr_results_HAHR, $alt_ftr_instances_HHHR, $opt_HHR, $FH_HR) = @_;
  
  my $nseq = scalar(@{$seq_name_AR});
  my $nftr = scalar(@{$ftr_info_AHR});
  my $seq_idx;   # counter over sequences
  my $seq_name;  # name of one sequence
  my $ftr_idx;   # counter over features
  
  my $aln_tol   = opt_Get("--xalntol",   $opt_HHR); # maximum allowed difference between start/end point prediction between CM and blastx
  my $xmaxins   = opt_Get("--xmaxins",   $opt_HHR); # maximum allowed insertion length in blastx output
  my $xmaxdel   = opt_Get("--xmaxdel",   $opt_HHR); # maximum allowed deletion length in blastx output
  my $xminntlen = opt_Get("--xminntlen", $opt_HHR);
  
  # get children info for all features
  my @children_AA = ();
  my $ftr_nchildren = undef;
  dng_FeatureInfoChildrenArrayOfArrays($ftr_info_AHR, \@children_AA, $FH_HR);

  # get info on position-specific insert and delete maximum exceptions if there are any
  my @maxins_exc_AH = ();
  my @maxdel_exc_AH = ();
  for($ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
    %{$maxins_exc_AH[$ftr_idx]} = ();
    %{$maxdel_exc_AH[$ftr_idx]} = ();
    dng_FeaturePositionSpecificValueBreakdown($ftr_info_AHR, $ftr_idx, "xmaxins_exc", \%{$maxins_exc_AH[$ftr_idx]}, $FH_HR);
    dng_FeaturePositionSpecificValueBreakdown($ftr_info_AHR, $ftr_idx, "xmaxdel_exc", \%{$maxdel_exc_AH[$ftr_idx]}, $FH_HR);
  }

  # for each sequence, for each feature, detect and report alerts
  for($seq_idx = 0; $seq_idx < $nseq; $seq_idx++) { 
    # for each feature
    $seq_name = $seq_name_AR->[$seq_idx];
    if($seq_len_HR->{$seq_name} >= $xminntlen) { 
      for($ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
        if(dng_FeatureTypeIsCds($ftr_info_AHR, $ftr_idx)) { 
          $ftr_nchildren = scalar(@{$children_AA[$ftr_idx]});
          my $ftr_results_HR = \%{$ftr_results_HAHR->{$seq_name}[$ftr_idx]}; # for convenience
          # printf("in $sub_name, set ftr_results_HR to ftr_results_HAHR->{$seq_name}[$ftr_idx] ");
          my %alt_str_H = ();   # added to as we find alerts below, possible keys are:
          # "b_non", "b_nop", "b_cst", "b_p5l", "b_p5s", "b_p3l", "b_p3s", "p_lin", "p_lde", "p_trc"
          
          # initialize 
          my $n_start        = undef; # predicted start  from CM 
          my $n_stop         = undef; # predicted stop   from CM 
          my $n_strand       = undef; # predicted strand from CM 
          my $n_len          = undef; # predicted length from CM (summed over all segments)
          my $p_start        = undef; # predicted start  from blastx
          my $p_stop         = undef; # predicted stop   from blastx
          my $p_start2print  = undef; # predicted start  from blastx, to output
          my $p_stop2print   = undef; # predicted stop   from blastx, to output
          my $p_strand       = undef; # predicted strand from blastx
          my $p_ins          = undef; # insert string from blastx
          my $p_del          = undef; # delete string from blastx
          my $p_trcstop      = undef; # premature stop from blastx
          my $p_score        = undef; # raw score from blastx
          my $p_query        = undef; # query name from blastx hit
          my $p_qlen         = undef; # length of query sequence, if $p_feature_flag == 1
          my $p_hlen         = undef; # length of blastx hit
          my $p_feature_flag = 0; # set to '1' if $p_query is a fetched feature sequence, not a full length input sequence
          my $p_qseq_name    = undef; # query seq name parsed out of blast query $p_query
          my $p_qftr_idx     = undef; # feature idx a blast query pertains to, parsed out of blast query $p_query
          
          my $start_diff = undef; # difference in start values between CM and blastx
          my $stop_diff  = undef; # difference in start values between CM and blastx
          
          if(defined $ftr_results_HR->{"n_start"}) { 
            $n_start  = $ftr_results_HR->{"n_start"};
            $n_stop   = $ftr_results_HR->{"n_stop"};
            $n_strand = $ftr_results_HR->{"n_strand"};
            $n_len    = $ftr_results_HR->{"n_len"};
          }

          # only proceed if we have a nucleotide prediction >= min length OR
          # we have no nucleotide prediction
          if(((defined $n_start) && ($n_len >= $xminntlen)) || (! defined $n_start)) { 

            if((defined $ftr_results_HR->{"p_start"}) && 
               (defined $ftr_results_HR->{"p_stop"})) { 
              $p_start   = $ftr_results_HR->{"p_start"};
              $p_stop    = $ftr_results_HR->{"p_stop"};
              $p_strand  = $ftr_results_HR->{"p_strand"};
              $p_query   = $ftr_results_HR->{"p_query"};
              $p_hlen    = $ftr_results_HR->{"p_len"};
              if(defined $ftr_results_HR->{"p_ins"})     { $p_ins     = $ftr_results_HR->{"p_ins"};  }
              if(defined $ftr_results_HR->{"p_del"})     { $p_del     = $ftr_results_HR->{"p_del"};  }
              if(defined $ftr_results_HR->{"p_trcstop"}) { $p_trcstop = $ftr_results_HR->{"p_trcstop"}; }
              if(defined $ftr_results_HR->{"p_score"})   { $p_score   = $ftr_results_HR->{"p_score"};   }

              # determine if the query is a full length sequence, or a fetched sequence feature:
              ($p_qseq_name, $p_qftr_idx, $p_qlen) = helper_blastx_breakdown_query($p_query, $seq_len_HR, $FH_HR); 
              if($p_qseq_name ne $seq_name) { 
                ofile_FAIL("ERROR, in $sub_name, unexpected query name parsed from $p_query (parsed $p_qseq_name, expected $seq_name)", "dnaorg", 1, $FH_HR);
              }
              $p_feature_flag = ($p_qftr_idx ne "") ? 1 : 0;
              # printf("seq_name: $seq_name ftr: $ftr_idx p_query: $p_query p_qlen: $p_qlen p_feature_flag: $p_feature_flag p_start: $p_start p_stop: $p_stop p_score: $p_score\n");
            }

            # add alerts as needed:
            # check for b_non
            if((! defined $n_start) && (defined $p_start) && (defined $p_score))  { 
              # no nucleotide-based prediction but there is a protein-based blastx prediction
              # only add this if length meets our minimum
              if($p_hlen >= $xminntlen) { 
                $alt_str_H{"b_non"} = "$p_start to $p_stop with score $p_score";
              }
            }
            if(defined $n_start) { 
              # check for b_nop
              if(! defined $p_start) { 
                $alt_str_H{"b_nop"} = "";
              }
              else { 
                # we have both $n_start and $p_start, we can compare CM and blastx predictions

                # check for b_cst: strand mismatch failure, differently depending on $p_feature_flag
                if(((  $p_feature_flag) && ($p_strand eq "-")) || 
                   ((! $p_feature_flag) && ($n_strand ne $p_strand))) { 
                  $alt_str_H{"b_cst"} = "";
                }
                else { 
                  # we have both $n_start and $p_start and predictions are on the same strand
                  # determine if predictions are 'close enough' in terms of sequence positions
                  # calcuate $start_diff and $stop_diff, differently depending on if hit
                  # was to the full sequence or a fetched features (true if $p_feature_flag == 1)
                  if($p_feature_flag) { 
                    $start_diff = $p_start - 1; 
                    $stop_diff  = $p_qlen - $p_stop;
                    $p_start2print = sprintf("$n_start %s $start_diff", ($n_strand eq "+") ? "+" : "-");
                    $p_stop2print  = sprintf("$n_stop %s $stop_diff",  ($n_strand eq "+") ? "-" : "+");
                  }
                  else { 
                    $start_diff = abs($n_start - $p_start);
                    $stop_diff  = abs($n_stop  - $p_stop);
                    $p_start2print = $p_start;
                    $p_stop2print  = $p_stop;
                  }
                  # check for 'b_p5l': only for non-feature seqs blastx alignment extends outside of nucleotide/CM alignment on 5' end
                  if((! $p_feature_flag) && 
                     ((($n_strand eq "+") && ($p_start < $n_start)) || 
                      (($n_strand eq "-") && ($p_start > $n_start)))) { 
                    $alt_str_H{"b_p5l"} = "strand:$n_strand CM:$n_start blastx:$p_start2print";
                  }
                  # check for 'b_p5s': blastx 5' end too short, not within $aln_tol nucleotides
                  if(! exists $alt_str_H{"b_p5l"}) { # only add b_p5s if b_p5l does not exist
                    if($start_diff > $aln_tol) { 
                      $alt_str_H{"b_p5s"} = "$start_diff > $aln_tol (strand:$n_strand CM:$n_start blastx:$p_start2print)";
                    }                
                  }
                  # check for 'b_p3l': blastx alignment extends outside of nucleotide/CM alignment on 3' end
                  if((! $p_feature_flag) && 
                     ((($n_strand eq "+") && ($p_stop  > $n_stop)) || 
                      (($n_strand eq "-") && ($p_stop  < $n_stop)))) { 
                    $alt_str_H{"b_p3l"} = "(strand:$n_strand CM:$n_stop blastx:$p_stop2print)";
                  }
                  # check for 'b_p3s': blastx 3' end too short, not within $aln_tol nucleotides
                  # for the stop coordinates, we do this differently if the nucleotide prediction 
                  # includes the stop codon or not, if it does, we allow 3 more positions different
                  my $cur_aln_tol = undef;
                  my $cur_stop_str = undef;
                  my $n_has_stop_codon = 1;
                  if(($ftr_results_HR->{"n_3trunc"}) || 
                     (defined (alert_feature_instance_fetch($alt_ftr_instances_HHHR, $seq_name, $ftr_idx, "n_stp")))) { 
                    $n_has_stop_codon = 0; 
                  }                    
                  if($n_has_stop_codon) { 
                    $cur_aln_tol  = $aln_tol + 3;
                    $cur_stop_str = "valid stop codon";
                  }
                  else { 
                    $cur_aln_tol  = $aln_tol;
                    $cur_stop_str = "no valid stop codon";
                  }
                  if(! exists $alt_str_H{"b_p3l"}) { # only add b_p3s if b_p3l does not exist
                    if($stop_diff > $cur_aln_tol) { 
                      $alt_str_H{"b_p3s"} = "$stop_diff > $cur_aln_tol (strand:$n_strand CM:$n_stop blastx:$p_stop2print, $cur_stop_str in CM prediction)";
                    }
                  }
                  # check for 'p_lin': too long of an insert
                  if(defined $p_ins) { 
                    my @p_ins_qpos_A = ();
                    my @p_ins_spos_A = ();
                    my @p_ins_len_A  = ();
                    my $nins = helper_blastx_breakdown_max_indel_str($p_ins, \@p_ins_qpos_A, \@p_ins_spos_A, \@p_ins_len_A, $FH_HR);
                    for(my $ins_idx = 0; $ins_idx < $nins; $ins_idx++) { 
                      my $local_xmaxins = defined ($maxins_exc_AH[$ftr_idx]{$p_ins_spos_A[$ins_idx]}) ? $maxins_exc_AH[$ftr_idx]{$p_ins_spos_A[$ins_idx]} : $xmaxins;
                      if($p_ins_len_A[$ins_idx] > $local_xmaxins) { 
                        if(defined $alt_str_H{"p_lin"}) { $alt_str_H{"p_lin"} .= ":DNAORGSEP:"; }
                        $alt_str_H{"p_lin"} = "blastx predicted insert of length " . $p_ins_len_A[$ins_idx] . ">$local_xmaxins starting at reference amino acid posn " . $p_ins_spos_A[$ins_idx];
                      }
                    }
                  }
                  # check for 'p_lde': too long of a deletion
                  if(defined $p_del) { 
                    my @p_del_qpos_A = ();
                    my @p_del_spos_A = ();
                    my @p_del_len_A  = ();
                    my $ndel = helper_blastx_breakdown_max_indel_str($p_del, \@p_del_qpos_A, \@p_del_spos_A, \@p_del_len_A, $FH_HR);
                    for(my $del_idx = 0; $del_idx < $ndel; $del_idx++) { 
                      my $local_xmaxdel = defined ($maxdel_exc_AH[$ftr_idx]{$p_del_spos_A[$del_idx]}) ? $maxdel_exc_AH[$ftr_idx]{$p_del_spos_A[$del_idx]} : $xmaxdel;
                      if($p_del_len_A[$del_idx] > $local_xmaxdel) { 
                        if(defined $alt_str_H{"p_lde"}) { $alt_str_H{"p_lde"} .= ":DNAORGSEP:"; }
                        $alt_str_H{"p_lde"} = "blastx predicted delete of length " . $p_del_len_A[$del_idx] . ">$local_xmaxdel starting at reference amino acid posn " . $p_del_spos_A[$del_idx];
                      }
                    }
                  }
                  # check for 'p_trc': blast predicted truncation
                  if(defined $p_trcstop) { 
                    $alt_str_H{"p_trc"} = "$p_trcstop";
                  }
                }
              }
            } # end of 'if(defined $n_start)' entered to identify b_* alerts
            my $alt_flag = 0;
            foreach my $alt_code (sort keys %alt_str_H) { 
              my @alt_str_A = split(":DNAORGSEP:", $alt_str_H{$alt_code});
              foreach my $alt_str (@alt_str_A) { 
                alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, $alt_code, $seq_name, $ftr_idx, $alt_str, $FH_HR);
                $alt_flag = 1;
              }
            }
            # if we added an alert, step through all children of this feature (if any) and add p_per
            if(($alt_flag) && ($ftr_nchildren > 0)) { 
              for(my $child_idx = 0; $child_idx < $ftr_nchildren; $child_idx++) { 
                my $child_ftr_idx = $children_AA[$ftr_idx][$child_idx];
                if(! defined $alt_ftr_instances_HHHR->{$seq_name}{$child_ftr_idx}{"b_per"}) { 
                  alert_feature_instance_add($alt_ftr_instances_HHHR, $alt_info_HHR, "b_per", $seq_name, $child_ftr_idx, "", $FH_HR);
                }
              }
            }
          } # end of 'if(((defined $n_start) && ($n_len >= $xminntlen)) || (! defined $n_start))'
        } # end of 'if(featureTypeIsCds($ftr_info_AHR, $ftr_idx))'
      } # end of 'for($ftr_idx' loop
    } # end of 'if($seq_len_HR->{$seq_name} >= $xminntlen)'
  } # end of 'for($seq_idx' loop
  return;
}   

#################################################################
# Subroutine:  run_blastx_and_summarize_output()
# Incept:      EPN, Thu Oct  4 15:25:00 2018
#
# Purpose:    For each fasta file of predicted hits, run them as
#             blastx queries against the appropriate target blast DBs.
#
# Arguments: 
#  $execs_HR:          REF to a hash with "blastx" and "parse_blastx.pl""
#                      executable paths
#  $out_root:          output root for the file names
#  $mdl_info_HR:       REF to hash of model info
#  $ftr_info_AHR:      REF to hash of arrays with information on the features, PRE-FILLED
#  $opt_HHR:           REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:    REF to 2D hash of output file information, ADDED TO HERE
#
# Returns:    void
#
# Dies:       If blastx fails.
#
################################################################# 
sub run_blastx_and_summarize_output {
  my $sub_name = "run_blastx_and_summarize_output";
  my $nargs_exp = 6;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($execs_HR, $out_root, $mdl_info_HR, $ftr_info_AHR, $opt_HHR, $ofile_info_HHR) = @_;
  
  my $nftr = scalar(@{$ftr_info_AHR});
  my $mdl_name = $mdl_info_HR->{"name"};
  my $blastx_db_file = $mdl_info_HR->{"blastdbpath"};
  if(! defined $blastx_db_file) { 
    ofile_FAIL("ERROR, in $sub_name, path to BLAST DB is unknown for model $mdl_name", "dnaorg", 1, $FH_HR);
  }

  my $mdl_fa_file     = $out_root . "." . $mdl_name . ".a.fa";

  # make a query fasta file for blastx, consisting of full length
  # sequences (with sequence descriptions removed because they can
  # affect the output and mess up our parsing if they are too long)
  # AND all the predicted CDS sequences
  my $blastx_query_file = $out_root . "." . $mdl_name . ".a.blastx.fa";
  sqf_FastaFileRemoveDescriptions($mdl_fa_file, $blastx_query_file, $ofile_info_HHR);
  # now add the predicted CDS sequences
  for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
    if(dng_FeatureTypeIsCds($ftr_info_AHR, $ftr_idx)) { 
      my $ofile_info_key = $mdl_name . ".pfa." . $ftr_idx;
      if(exists $ofile_info_HH{"fullpath"}{$ofile_info_key}) { 
        utl_RunCommand("cat " . $ofile_info_HH{"fullpath"}{$ofile_info_key} . " >> $blastx_query_file", opt_Get("-v", \%opt_HH), 0, $ofile_info_HHR->{"FH"});
      }
    }
  }

  # run blastx 
  my $blastx_out_file = $out_root . "." . $mdl_name . ".blastx.out";
  my $blastx_cmd = $execs_HR->{"blastx"} . " -query $blastx_query_file -db $blastx_db_file -seg no -out $blastx_out_file";
  utl_RunCommand($blastx_cmd, opt_Get("-v", $opt_HHR), 0, $ofile_info_HHR->{"FH"});
  ofile_AddClosedFileToOutputInfo($ofile_info_HHR, "dnaorg", $mdl_name . ".blastx-out", $blastx_out_file, 0, "blastx output for model $mdl_name");

  # now summarize its output
  my $blastx_summary_file = $out_root . "." . $mdl_name . ".blastx.summary.txt";
  my $parse_cmd = $execs_HR->{"parse_blastx"} . " --input $blastx_out_file > $blastx_summary_file";
  utl_RunCommand($parse_cmd, opt_Get("-v", $opt_HHR), 0, $ofile_info_HHR->{"FH"});
  ofile_AddClosedFileToOutputInfo($ofile_info_HHR, "dnaorg", $mdl_name . ".blastx-summary", $blastx_summary_file, 0, "parsed (summarized) blastx output");

  return;
}

#################################################################
# Subroutine:  parse_blastx_results()
# Incept:      EPN, Thu Oct  4 15:25:00 2018
#              [modified from subroutine of same name by Alejandro Schaffer, compare_predictions.pl]
#
# Purpose:    Parse blastx summary file and store results
#             in ftr_results.
#
# Arguments: 
#  $blastx_summary_file: path to blastx summary file to parse
#  $seq_name_AR:         REF to array of sequence names
#  $seq_len_HR:          REF to hash of sequence lengths
#  $ftr_info_AHR:        REF to array of hashes with feature info 
#  $ftr_results_HAHR:    REF to feature results HAH, ADDED TO HERE
#  $opt_HHR:             REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:      REF to 2D hash of output file information, ADDED TO HERE
#
# Returns:    void
#
# Dies:       If blastx fails.
#
################################################################# 
sub parse_blastx_results { 
  my $sub_name = "parse_blastx_results";
  my $nargs_exp = 7;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($blastx_summary_file, $seq_name_AR, $seq_len_HR, $ftr_info_AHR, $ftr_results_HAHR, $opt_HHR, $ofile_info_HHR) = @_;

  my $FH_HR = (defined $ofile_info_HHR->{"FH"}) ? $ofile_info_HHR->{"FH"} : undef;

  utl_FileValidateExistsAndNonEmpty($blastx_summary_file, "blastx summary file", $sub_name, 1, $FH_HR);
  my $nftr = scalar(@{$ftr_info_AHR});

  # create a hash mapping ftr_type_idx strings to ftr_idx:
  my %ftr_type_idx2ftr_idx_H = ();
  for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
    my $ftr_type_idx = dng_FeatureTypeAndTypeIndexString($ftr_info_AHR, $ftr_idx, ".");
    $ftr_type_idx2ftr_idx_H{$ftr_type_idx} = $ftr_idx;
  }

  open(IN, $blastx_summary_file) || ofile_FileOpenFailure($blastx_summary_file, "dnaorg", $sub_name, $!, "reading", $FH_HR);
  
  # first step, determine which sequence each hit corresponds to
  my $query      = undef;
  my $target     = undef;
  my $hsp_idx    = undef;
  my $seq_name   = undef; 
  my $q_len      = undef; # length of query sequence
  my $q_ftr_idx  = undef; # feature index query pertains to, [0..$nftr-1] OR -1: a special case meaning query is full sequence (not a fetched CDS feature)
  my $t_ftr_idx  = undef; # feature index target (fetched CDS sequence from input fasta file) pertains to [0..$nftr-1]
  my $no_coords_query = undef; # name of query without coords, if query sequence is a predicted feature, e.g. "NC_002549.1/6039..8068:+" for query "NC_002549.1/6039..8068:+/10..885:+,885..2030:+"
  my $coords          = undef; # string of coordinates if this is a predicted feature, e.g. "10..885:+,885..2030:+" for "NC_002549.1/6039..8068:+/10..885:+,885..2030:+"
  my $store_flag = 0;   # should we store this query/target/hit trio? 
                        # set to '1' if current query/target pair is compatible (query is full sequence or correct CDS feature) 
                        # and this is highest scoring hit for this feature for this sequence (query/target) pair
                        # and the query (full length sequence, or predicted CDS) is at least <x> nt from --xminntlen <x>
  my $xminntlen  = opt_Get("--xminntlen", $opt_HHR);

  while(my $line = <IN>) { 
    chomp $line;
    if($line ne "END_MATCH") { 
      my @el_A = split(/\t/, $line);
      if(scalar(@el_A) != 2) { 
        ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, did not read exactly 2 tab-delimited tokens in line $line", "dnaorg", 1, $FH_HR);
      }
      my ($key, $value) = (@el_A);
      if($key eq "QACC") { 
        $query = $value;
        # determine what sequence it is
        my $q_ftr_type_idx; # feature type and index string, from $seq_name if not a full sequence (e.g. "CDS.4")
        ($seq_name, $q_ftr_type_idx, $q_len) = helper_blastx_breakdown_query($query, $seq_len_HR, $FH_HR); 
        # helper_blastx_breakdown_query() will die if $query is unparseable
        # determine what feature this query corresponds to
        $q_ftr_idx = ($q_ftr_type_idx eq "") ? -1 : $ftr_type_idx2ftr_idx_H{$q_ftr_type_idx};
        if(! defined $q_ftr_idx) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, problem parsing QACC line unable to determine feature index from query $query", "dnaorg", 1, $FH_HR);
        }
      }
      elsif($key eq "HACC") { 
        if(! defined $query) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, read HACC line before QACC line\n", "dnaorg", 1, $FH_HR);
        }
        $target = $value;
        # determine what feature it is
        if($target =~ /(\S+)\/(\S+)/) { 
          my ($accn, $coords) = ($1, $2);
          # find it in @{$ftr_info_AHR}
          $t_ftr_idx = helper_blastx_db_seqname_to_ftr_idx($target, $ftr_info_AHR, $FH_HR); # will die if problem parsing $target, or can't find $t_ftr_idx
        }
      }
      elsif($key eq "HSP") { 
        if((! defined $query) || (! defined $t_ftr_idx)) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, read HSP line before one or both of QACC and HACC lines\n", "dnaorg", 1, $FH_HR);
        }
        # printf("BLASTX HSP $key $value\n");
        if($value =~ /^(\d+)$/) { 
          $hsp_idx = $value;
          # printf("BLASTX set hsp_idx to $hsp_idx\n");
        }
        else { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, unable to parse blastx summary HSP line $line", "dnaorg", 1, $FH_HR);
        }
      }
      elsif($key eq "QRANGE") { 
        if($value eq "..") { # special case, no hits, silently move on
          ;
        }
        elsif((! defined $query) || (! defined $t_ftr_idx) || (! defined $hsp_idx)) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, read QRANGE line before one or more of QACC, HACC, or HSP lines\n", "dnaorg", 1, $FH_HR);
        }
        elsif($store_flag) { 
          if($value =~ /^(\d+)..(\d+)$/) { 
            my ($blast_start, $blast_stop) = ($1, $2);
            my $blast_strand = ($blast_start <= $blast_stop) ? "+" : "-";
            $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_start"}  = $blast_start;
            $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_stop"}   = $blast_stop;
            $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_strand"} = $blast_strand;
            $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_query"}  = $query;
            $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_len"}    = abs($blast_start - $blast_stop) + 1;
            # printf("BLASTX set ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{p_start}  to " . $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_start"} . "\n");
            # printf("BLASTX set ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{p_stop}   to " . $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_stop"} . "\n");
            # printf("BLASTX set ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{p_strand} to " . $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_strand"} . "\n");
          }
          else { 
            ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, unable to parse blastx summary QRANGE line $line", "dnaorg", 1, $FH_HR);
          }
        }
      }
      elsif($key eq "INS") { 
        if((! defined $query) || (! defined $t_ftr_idx) || (! defined $hsp_idx)) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, read MAXIN line before one or more of QACC, HACC, or HSP lines\n", "dnaorg", 1, $FH_HR);
        }
        if($store_flag && ($value ne "")) { 
          my $ins = $value;
          $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_ins"} = $ins;
          # printf("BLASTX set ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{p_ins} to " . $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_ins"} . "\n");
        }
      }
      elsif($key eq "DEL") { 
        if((! defined $query) || (! defined $t_ftr_idx) || (! defined $hsp_idx)) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, read MAXDE line before one or more of QACC, HACC, or HSP lines\n", "dnaorg", 1, $FH_HR);
        }
        if($store_flag && ($value ne "")) { 
          my $del = $value;
          $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_del"} = $del;
          # printf("BLASTX set ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{p_del} to " . $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_del"} . "\n");
        }
      }
      elsif($key eq "FRAME") { 
        if((! defined $query) || (! defined $t_ftr_idx) || (! defined $hsp_idx)) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, read FRAME line before one or more of QACC, HACC, or HSP lines\n", "dnaorg", 1, $FH_HR);
        }
        if($store_flag) { 
          if($value =~ /^[\+\-]([123])$/) { 
            my $frame = $1;
            $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_frame"} = $frame;
            # printf("BLASTX set ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{x_frame} to " . $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_frame"} . "\n");
          }
          else { 
            ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, unable to parse blastx summary FRAME line $line ($key $value)", "dnaorg", 1, $FH_HR);
          }
        }
      }
      elsif($key eq "STOP") { 
        if((! defined $query) || (! defined $t_ftr_idx) || (! defined $hsp_idx)) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, read STOP line before one or more of QACC, HACC, or HSP lines\n", "dnaorg", 1, $FH_HR);
        }
        if($store_flag) { 
          $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_trcstop"} = $value;
          # printf("BLASTX set ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{x_trcstop} to " . $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_trcstop"} . "\n");
        }
      }
      elsif($key eq "SCORE") { 
        if((! defined $query) || (! defined $t_ftr_idx) || (! defined $hsp_idx)) { 
          ofile_FAIL("ERROR in $sub_name, reading $blastx_summary_file, read SCORE line before one or more of QACC, HACC, or HSP lines\n", "dnaorg", 1, $FH_HR);
        }
        # should we store this query/target/hit trio (set $store_flag to 1)? 
        # we do if:
        #  - this query/target pair is compatible (query is full sequence or correct CDS feature) 
        #  - this is the highest scoring hit for this feature for this sequence (query/target pair)? 
        #  - query length (full length seq or predicted CDS) is at least <x> nt from --xmminntlen
        if((($q_ftr_idx == -1) || ($q_ftr_idx == $t_ftr_idx)) && # query is full sequence OR query is fetched CDS that pertains to target
           ((! exists $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_score"}) ||  # first hit, so must be highest
            ($value > $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_score"})) && # highest scoring hit
           ($q_len >= $xminntlen)) { # length >= --xminntlen
          $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_score"} = $value;
          $store_flag = 1;
          # printf("BLASTX set ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{x_score} to " . $ftr_results_HAHR->{$seq_name}[$t_ftr_idx]{"p_score"} . "\n");
        }
        else { 
          $store_flag = 0;
        }
      }
      # Add elsif($key eq "") blocks here to store more values from the blastx.summary file
    }
  }
  close(IN);

  # go back through and remove any hits that are below the minimum score
  # UNLESS that hit overlaps by at least 1 nt on same strand with a 
  # CM prediction
  my $min_x_score = opt_Get("--xlonescore", $opt_HHR); # minimum score for a lone hit (no corresponding CM prediction) to be considered
  my $nseq = scalar(@{$seq_name_AR}); 
  for(my $seq_idx = 0; $seq_idx < $nseq; $seq_idx++) { 
    $seq_name = $seq_name_AR->[$seq_idx];
    if(defined $ftr_results_HAHR->{$seq_name}) { 
      for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
        if(defined $ftr_results_HAHR->{$seq_name}[$ftr_idx]) { 
          if((defined $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_score"}) && 
             $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_score"} < $min_x_score) { # blastx hit is below minimum score
            my $remove_blastx_hit = 1; # could be changed to '0' below
            if(defined $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_start"}) { 
              # there is a CM prediction, check if it overlaps on same strand
              if(($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_strand"} eq "+") &&
                 ($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_strand"} eq "+") &&
                 ($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_strand"} eq "+") &&
                 (seq_Overlap($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_start"},
                              $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_stop"},
                              $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_start"},
                              $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_stop"}, $FH_HR) > 0)) { 
                # overlaps on '+' strand by at least 1 nt: DO NOT REMOVE blastx hit
                $remove_blastx_hit = 0;
              }
              if(($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_strand"} eq "-") &&
                 ($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_strand"} eq "-") &&
                 ($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_strand"} eq "-") &&
                 (seq_Overlap($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_stop"},
                              $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_start"},
                              $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_stop"},
                              $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_start"}, $FH_HR) > 0)) { 
                
                # overlaps on '-' strand by at least 1 nt: DO NOT REMOVE blastx hit
                $remove_blastx_hit = 0;
              }
            }
            if($remove_blastx_hit) { 
              # set all values of "p_*" keys to undef
              foreach my $p_key (keys %{$ftr_results_HAHR->{$seq_name}[$ftr_idx]}) { 
                if($p_key =~ m/^p\_/) { # key starts with "p_"
                  $ftr_results_HAHR->{$seq_name}[$ftr_idx]{$p_key} = undef;
                }
              }
            }
          }
        }
      }
    }
  }

  return 0;
}

#################################################################
# Subroutine: helper_blastx_breakdown_query()
# Incept:     EPN, Wed Dec 19 12:05:02 2018
#
# Purpose: Given a query name from blastx output, determine if it is
#          for an entire input sequence, or a feature sequence
#          fetched from an input sequence.  The way we tell is by
#          looking up $in_query in $seq_len_HR.  If it exists as a
#          key, then the query is an entire input sequence. If it
#          does not exist as a key, then it should be
#          "<seq_name>/<ftr_type_idx>/<coords>", and <seq_name>
#          should be a key in $seq_info_HAR.
#
# Arguments:
#   $in_query:     query name from blastx output 
#   $seq_len_HR:   ref to hash, keys are possible sequence names, values are sequence lengths
#   $FH_HR:        ref to hash of file handles, including 'log'
#             
# Returns:  3 values:
#           <seq_name>:     name of input sequence this query corresponds to
#           <ftr_type_idx>: "" if $in_query eq <seq_name>, else a string 
#                           of feature type and index separated by a '.'
#                           e.g. 'CDS.4', derived from $in_query.
#           <len>:          length of sequence ($seq_len_HR->{<seq_name>} if 
#                           $in_query eq <seq_name> else length derived from
#                           coordinate ranges listed in <coords_str>.
#
# Dies: If $in_query is either not a valid <seq_name> (key in %{$seq_len_HR})
#       and $in_query cannot be broken down into a valid <seq_name><ftr_type_idx><coords_str>
#       
#
#################################################################
sub helper_blastx_breakdown_query {
  my $sub_name  = "helper_blastx_breakdown_query";
  my $nargs_expected = 3;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 
  
  my ($in_query, $seq_len_HR, $FH_HR) = (@_);

  # check for simple case, $in_query is a sequence name key in %{$seq_len_HR}
  if(defined $seq_len_HR->{$in_query}) { 
    return($in_query, "", $seq_len_HR->{$in_query});
  }

  # else, break down $in_query into:
  # <seq_name>/<ftr_type_idx>/<coords>
  # example: NC_002549.1/CDS.4/6039..6923:+,6923..8068:+
  # sequence is NC_002549.1 but we fetched feature CDS#4 as coordinates 6039..6293:+,6293..8068:+ from it
  my $ret_seq_name     = undef;
  my $ret_ftr_type_idx = undef;
  my $ret_len          = undef;
  my $coords_str       = undef;
  if($in_query =~ /^(\S+)\/([^\/]+\.\d+)\/([^\/]+$)/) { 
    ($ret_seq_name, $ret_ftr_type_idx, $coords_str) = ($1, $2, $3);
    if(! defined $seq_len_HR->{$ret_seq_name}) { 
      ofile_FAIL("ERROR in $sub_name, problem parsing query $in_query, unexpected sequence name $ret_seq_name (does not exist in input sequence length hash)", "dnaorg", 1, $FH_HR); 
    }
    $ret_len = dng_CoordsLength($coords_str, $FH_HR);
  }
  else { 
    ofile_FAIL("ERROR in $sub_name, unable to parse query $in_query", "dnaorg", 1, $FH_HR); 
  }

  return ($ret_seq_name, $ret_ftr_type_idx, $ret_len);
}

#################################################################
# Subroutine: helper_blastx_breakdown_max_indel_str()
# Incept:     EPN, Tue Apr  2 06:35:13 2019
#
# Purpose: Given a string of one or more indel strings in the format:
#          "Q<d1>:S<d2>[+-]<d3>", separated by ";" if more than one.
#          fill arrays with <d1>, <d2>, and <d3>.
#
# Arguments:
#   $in_str:       input max indel string returned from parse_blastx.pl
#   $qpos_AR:      ref to array of query positions to fill
#   $spos_AR:      ref to array of subject positions to fill
#   $len_AR:       ref to array of lengths to fill
#   $FH_HR:        ref to hash of file handles, including 'log'
#             
# Returns:  number of indel strings parsed (number of elements added to @{$qpos_AR}, 
#           @{$spos_AR} and @{$len_AR}.
#
# Dies: If $in_str is not parseable
#
#################################################################
sub helper_blastx_breakdown_max_indel_str {
  my $sub_name  = "helper_blastx_breakdown_max_indel_str";
  my $nargs_expected = 5;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 
  
  my ($in_str, $qpos_AR, $spos_AR, $len_AR, $FH_HR) = (@_);

  # printf("in $sub_name, in_str: $in_str\n");

  my @str_A = split(";", $in_str); 
  foreach my $str (@str_A) { 
    if($str =~ /^Q(\d+)\:S(\d+)[\+\-](\d+)$/) { 
      if(defined $qpos_AR) { push(@{$qpos_AR}, $1); }
      if(defined $spos_AR) { push(@{$spos_AR}, $2); }
      if(defined $len_AR)  { push(@{$len_AR},  $3); }
    }
    else { 
      ofile_FAIL("ERROR, in $sub_name, unable to parse indel string $str parsed out of $in_str", "dnaorg", 1, $FH_HR);
    }
  }

  return scalar(@str_A);
}

#################################################################
# Subroutine: helper_blastx_db_seqname_to_ftr_idx()
# Incept:     EPN, Tue Dec 18 13:27:50 2018
#
# Purpose:    Find the feature $ftr_idx that corresponds to the blastx
#             db sequence that was named with the convention:
#
#             <protein-accession>/<coords-str>
#
#             Where <coords-str> is identical to $ftr_info_AHR->{"ref_coords"}[$ftr_idx].
#
# Arguments: 
#  $blastx_seqname: sequence name
#  $ftr_info_AHR:   ref to the feature info array of hashes 
#  $FH_HR:          ref to hash of file handles
#
# Returns:    <$ftr_idx>
#
# Dies:       If we find zero features that match to this sequence
#             If we find more than 1 features that match to this sequence
#
################################################################# 
sub helper_blastx_db_seqname_to_ftr_idx { 
  my $sub_name = "helper_blastx_db_seqname_to_ftr_idx";
  my $nargs_exp = 3;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($blastx_seqname, $ftr_info_AHR, $FH_HR) = @_;

  my $nftr = scalar(@{$ftr_info_AHR});

  my $ret_ftr_idx = undef;
  if($blastx_seqname =~ /(\S+)\/(\S+)/) { 
    my ($accn, $coords) = ($1, $2);
    # find it in @{$ftr_info_AHR->{"coords"}}
    for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
      if(($ftr_info_AHR->[$ftr_idx]{"type"} eq "CDS")) { 
        if($ftr_info_AHR->[$ftr_idx]{"coords"} eq $coords) { 
          if(defined $ret_ftr_idx) { # found more than 1 features that match
            ofile_FAIL("ERROR in $sub_name, found blastx db sequence with coords that match two features, ftr_idx: $ftr_idx and $ret_ftr_idx", "dnaorg", 1, $FH_HR);
          }                  
          $ret_ftr_idx = $ftr_idx;
        }
      }
    }
    if(! defined $ret_ftr_idx) { # did not find match
      ofile_FAIL("ERROR in $sub_name, did not find matching feature for blastx db sequence $blastx_seqname", "dnaorg", 1, $FH_HR);
    }
  }
  else { 
    ofile_FAIL("ERROR in $sub_name, unable to parse blastx db sequence name $blastx_seqname", "dnaorg", 1, $FH_HR); 
  }

  return $ret_ftr_idx;
}

#################################################################
#
# Other subroutines related to alerts: 
# alert_list_option
# alert_feature_instance_add 
# alert_sequence_instance_add 
# alert_add_b_zft 
# alert_add_n_div 
# alert_instances_check_prevents_annot
#
#################################################################
# Subroutine:  alert_list_option()
# Incept:      EPN, Wed Apr  3 11:11:26 2019
#
# Purpose:    Handle the --alt_list option by outputting a list 
#             of all alerts and whether they cause failure or not
#             by default to stdout.
#
# Arguments: 
#  $alt_info_HHR:  REF to the alert info hash of arrays, PRE-FILLED
#
# Returns:    void
#
# Dies:       never
#
#################################################################
sub alert_list_option { 
  my $sub_name = "alert_list_option()"; 
  my $nargs_exp = 1;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }
  
  my ($alt_info_HHR) = @_;
  
  my $div_line = utl_StringMonoChar(60, "#", undef) . "\n";
  
  # determine order of codes to print
  my @code_A = ();
  alert_order_arrays($alt_info_HHR, \@code_A, undef, undef);
  
  my $idx = 0;
  my $code = undef;

  my @data_AA  = ();
  my @head_AA  = ();
  my @bcom_A   = ();

  @{$head_AA[0]} = ("",    "alert",  "short",       "long");
  @{$head_AA[1]} = ("idx", "code",   "description", "description");

  push(@bcom_A, $div_line);
  push(@bcom_A, "#\n");
  push(@bcom_A, "# Alert codes that ALWAYS cause a sequence to FAIL, and cannot be\n");
  push(@bcom_A, "# listed in --alt_pass or --alt_fail option strings:\n#\n");
  $idx = 0;
  foreach $code (@code_A) { 
    if($alt_info_HHR->{$code}{"always_fails"}) { 
      $idx++;
      push(@data_AA, [$idx, $code, helper_tabular_replace_spaces($alt_info_HHR->{$code}{"sdesc"}), 
                      $alt_info_HHR->{$code}{"ldesc"}]);
    }
  }
  ofile_TableHumanOutput(\@data_AA, \@head_AA, undef, \@bcom_A, undef, "  ", "-", "#", "", "", "-", *STDOUT, undef, undef);

  @bcom_A  = ();
  @data_AA = ();
  push(@bcom_A, "#\n");
  push(@bcom_A, $div_line);
  push(@bcom_A, "#\n");
  push(@bcom_A, "# Alert codes that cause a sequence to FAIL by default, but can be set\n");
  push(@bcom_A, "# to not FAIL a sequence by listing the code as part of a comma separated\n");
  push(@bcom_A, "# string of codes in <s> with the --alt_pass <s> option:\n#\n");
  $idx = 0;
  foreach $code (@code_A) { 
    if(($alt_info_HHR->{$code}{"causes_failure"}) && 
       (! $alt_info_HHR->{$code}{"always_fails"})) { 
      $idx++;
      push(@data_AA, [$idx, $code, helper_tabular_replace_spaces($alt_info_HHR->{$code}{"sdesc"}), 
                      $alt_info_HHR->{$code}{"ldesc"}]);
    }
  }
  ofile_TableHumanOutput(\@data_AA, \@head_AA, undef, \@bcom_A, undef, "  ", "-", "#", "", "", "-", *STDOUT, undef, undef);

  @bcom_A  = ();
  @data_AA = ();
  push(@bcom_A, "#\n");
  push(@bcom_A, $div_line);
  push(@bcom_A, "#\n");
  push(@bcom_A, "# Alert codes that do not cause a sequence to FAIL by default, but can be set\n");
  push(@bcom_A, "# to FAIL a sequence by listing the code as part of a comma separated\n");
  push(@bcom_A, "# string of codes in <s> with the --alt_fail <s> option:\n#\n");
  $idx = 0;
  foreach $code (@code_A) { 
    if((! $alt_info_HHR->{$code}{"causes_failure"}) && 
       (! $alt_info_HHR->{$code}{"always_fails"})) { 
      $idx++;
      push(@data_AA, [$idx, $code, helper_tabular_replace_spaces($alt_info_HHR->{$code}{"sdesc"}), 
                      $alt_info_HHR->{$code}{"ldesc"}]);
    }
  }
  ofile_TableHumanOutput(\@data_AA, \@head_AA, undef, \@bcom_A, undef, "  ", "-", "#", "", "", "-", *STDOUT, undef, undef);

  return;
}

#################################################################
# Subroutine:  alert_pass_fail_options()
# Incept:      EPN, Wed Apr  3 12:51:25 2019
#
# Purpose:    Handle the --alt_pass and --alt_fail options by 
#             parsing their strings, determining if they are valid
#             and updating the "causes_failure" values in 
#             %{$alt_info_HHR}.
#
# Arguments: 
#  $alt_info_HHR:   REF to the alert info hash of arrays, PRE-FILLED
#  $opt_HHR:        REF to 2D hash of option values
#
# Returns:    void
#
# Dies:       if --alt_pass or --alt_fail option strings are invalid
#
#################################################################
sub alert_pass_fail_options { 
  my $sub_name = "alert_pass_fail_options()"; 
  my $nargs_exp = 2;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }
  
  my ($alt_info_HHR, $opt_HHR) = @_;
  
  my @pass_A = ();
  my @fail_A = ();
  if(opt_IsUsed("--alt_pass", $opt_HHR)) { 
    @pass_A = split(",", opt_Get("--alt_pass", $opt_HHR));
  }
  if(opt_IsUsed("--alt_fail", $opt_HHR)) { 
    @fail_A = split(",", opt_Get("--alt_fail", $opt_HHR));
  }

  my $die_str = "";
  my $alt_code = undef;

  # --alt_pass codes
  foreach my $alt_code (@pass_A) { 
    if(! defined $alt_info_HHR->{$alt_code}) { 
      $die_str .= "alert code $alt_code is invalid (does not exist)\n";
    }
    elsif($alt_info_HHR->{$alt_code}{"always_fails"}) { 
      $die_str .= "alert code $alt_code always causes failure, it cannot be listed in --alt_pass string\n";
    }
    else { 
      dng_AlertInfoSetCausesFailure($alt_info_HHR, $alt_code, 0, undef);
    }
  }

  # --alt_fail codes
  foreach my $alt_code (@fail_A) { 
    if(! defined $alt_info_HHR->{$alt_code}) { 
      $die_str .= "alert code $alt_code is invalid (does not exist)\n";
    }
    else { 
      dng_AlertInfoSetCausesFailure($alt_info_HHR, $alt_code, 1, undef);
    }
  }

  if($die_str ne "") { 
    $die_str .= "Use the --alt_list to see a list possible alert codes\nto use with --alt_pass and --alt_fail.\n";
    ofile_FAIL("ERROR processing --alt_fail and/or --alt_pass options:\n$die_str", "dnaorg", 1, undef);
  }
  
  return;
}

#################################################################
# Subroutine:  alert_order_arrays()
# Incept:      EPN, Thu Apr  4 12:59:41 2019
#
# Purpose:    Fill arrays with the order of alerts for outputting.
#             Alerts that DO NOT cause failure are listed first, 
#             then alerts that DO cause failure. 
#
# Arguments: 
#  $alt_info_HHR:  ref to the alert info hash of arrays, PRE-FILLED
#  $all_order_AR:  ref to array of order of all alerts, FILLED HERE if defined
#  $seq_order_AR:  ref to array of order of per-sequence alerts, FILLED HERE if defined
#  $ftr_order_AR:  ref to array of order of per-feature alerts, FILLED HERE if defined
#
# Returns:    void
#
# Dies:       never
#
#################################################################
sub alert_order_arrays { 
  my $sub_name = "alert_order_arrays()";
  my $nargs_exp = 4;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }
  
  my ($alt_info_HHR, $all_order_AR, $seq_order_AR, $ftr_order_AR) = @_;
  
  my @all_A = ();
  my @all_pass_A = ();
  my @all_fail_A = ();
  my @seq_pass_A = ();
  my @seq_fail_A = ();
  my @ftr_pass_A = ();
  my @ftr_fail_A = ();
  my $alt_code = undef;
  # first get array using "order" key
  foreach $alt_code (sort keys (%{$alt_info_HHR})) { 
    $all_A[($alt_info_HHR->{$alt_code}{"order"})] = $alt_code;
  }

  foreach $alt_code (@all_A) { 
    if($alt_info_HHR->{$alt_code}{"causes_failure"}) { 
      push(@all_fail_A, $alt_code); 
      if($alt_info_HHR->{$alt_code}{"pertype"} eq "sequence") { 
        push(@seq_fail_A, $alt_code); 
      }
      if($alt_info_HHR->{$alt_code}{"pertype"} eq "feature") { 
        push(@ftr_fail_A, $alt_code); 
      }
    }
    else { # does not cause failure
      push(@all_pass_A, $alt_code); 
      if($alt_info_HHR->{$alt_code}{"pertype"} eq "sequence") { 
        push(@seq_pass_A, $alt_code); 
      }
      if($alt_info_HHR->{$alt_code}{"pertype"} eq "feature") { 
        push(@ftr_pass_A, $alt_code); 
      }
    }
  }

  if(defined $all_order_AR) { @{$all_order_AR} = (@all_pass_A, @all_fail_A); }
  if(defined $seq_order_AR) { @{$seq_order_AR} = (@seq_pass_A, @seq_fail_A); }
  if(defined $ftr_order_AR) { @{$ftr_order_AR} = (@ftr_pass_A, @ftr_fail_A); }

  return;
}

#################################################################
# Subroutine:  alert_sequence_instance_add()
# Incept:      EPN, Thu Apr  4 11:45:05 2019
#
# Purpose:    Add an $alt_code alert to the @{$alt_seq_instances_HHR} 
#             for sequence name $seq_name.
#
# Arguments: 
#  $alt_seq_instances_HHR:  REF to per-sequence alert instances to add to, ADDED TO HERE (maybe),
#                           can be undef if $alt_info_HHR->{$alt_code}{"pertype"} is "feature".
#  $alt_info_HHR:           REF to the alert info hash of arrays, PRE-FILLED
#  $alt_code:               alert code we're adding an alert for
#  $seq_name:               sequence name
#  $value:                  value to add as $alt_seq_instances_HHR->{$seq_name}{$code}
#  $FH_HR:                  REF to hash of file handles
#
# Returns:    void
#
# Dies:       - If we find an alert instance incompatibility.
#             - if pertype of $alt_code is not "sequence"
#
#################################################################
sub alert_sequence_instance_add { 
  my $sub_name = "alert_sequence_instance_add()";
  my $nargs_exp = 6;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($alt_seq_instances_HHR, $alt_info_HHR, $alt_code, $seq_name, $value, $FH_HR) = @_;

  # my $tmp_altmsg = "alt_code: $alt_code, seq_name: $seq_name, value: $value\n";
  # printf("in $sub_name $tmp_altmsg\n");
  
  if(! defined $alt_seq_instances_HHR) { 
    ofile_FAIL("ERROR in $sub_name, alt_seq_instances_HHR is undefined", "dnaorg", 1, $FH_HR);
  }
  if(! defined $alt_info_HHR->{$alt_code}) { 
    ofile_FAIL("ERROR in $sub_name, unrecognized alert code $alt_code", "dnaorg", 1, $FH_HR);
  }
  if($alt_info_HHR->{$alt_code}{"pertype"} ne "sequence") { 
    ofile_FAIL("ERROR in $sub_name alert code $alt_code is not a per-sequence alert", "dnaorg", 1, $FH_HR);
  }

  if(! defined $alt_seq_instances_HHR->{$seq_name}) { 
    %{$alt_seq_instances_HHR->{$seq_name}} = (); 
  }

  # if this alert already exists (rare case), add to it
  if(defined $alt_seq_instances_HHR->{$seq_name}{$alt_code}) { 
    $alt_seq_instances_HHR->{$seq_name}{$alt_code} .= ":DNAORGSEP:" . $value; 
  }
  else { # if it doesn't already exist (normal case), create it
    $alt_seq_instances_HHR->{$seq_name}{$alt_code} = $value; 
  }

  return;
}

#################################################################
# Subroutine:  alert_feature_instance_add()
# Incept:      EPN, Thu Apr  4 11:40:09 2019
#
# Purpose:    Add an $alt_code alert to the @{$alt_ftr_instances_HHHR} 
#             for sequence name $seq_name and feature index $ftr_idx.
#
# Arguments: 
#  $alt_ftr_instances_HHHR: REF to per-feature alert instances to add to, ADDED TO HERE
#  $alt_info_HHR:           REF to the alert info hash of arrays, PRE-FILLED
#  $alt_code:               alert code we're adding an alert for
#  $seq_name:               sequence name
#  $ftr_idx:                feature index
#  $value:                  value to add as $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$code}
#  $FH_HR:                  REF to hash of file handles
#
# Returns:    void
#
# Dies:       - If we find an alert instance incompatibility.
#             - if pertype of $alt_code is not "feature"
#
#################################################################
sub alert_feature_instance_add { 
  my $sub_name = "alert_feature_instance_add()";
  my $nargs_exp = 7;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($alt_ftr_instances_HHHR, $alt_info_HHR, $alt_code, $seq_name, $ftr_idx, $value, $FH_HR) = @_;

  # my $tmp_altmsg = "ftr_idx: $ftr_idx, alt_code: $alt_code, seq_name: $seq_name, value: $value\n";
  # printf("in $sub_name $tmp_altmsg\n");
  
  if(! defined $alt_ftr_instances_HHHR) { 
    ofile_FAIL("ERROR in $sub_name, but alt_ftr_instances_HHHR is undefined", "dnaorg", 1, $FH_HR);
  }
  if(! defined $alt_info_HHR->{$alt_code}) { 
    ofile_FAIL("ERROR in $sub_name, unrecognized alert code $alt_code", "dnaorg", 1, $FH_HR);
  }
  if($alt_info_HHR->{$alt_code}{"pertype"} ne "feature") { 
    ofile_FAIL("ERROR in $sub_name alert code $alt_code is not a per-feature alert", "dnaorg", 1, $FH_HR);
  }

  if(! defined $alt_ftr_instances_HHHR->{$seq_name}) { 
    %{$alt_ftr_instances_HHHR->{$seq_name}} = (); 
  }
  if(! defined $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}) { 
    %{$alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}} = (); 
  }

  # if this alert already exists (rare case), add to it
  if(defined $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$alt_code}) { 
    $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$alt_code} .= ":DNAORGSEP:" . $value; 
  }
  else { # if it doesn't already exist (normal case), create it
    $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$alt_code} .= $value; 
  }

  return;
}

#################################################################
# Subroutine: alert_sequence_instance_fetch()
# Incept:     EPN, Fri Apr  5 12:02:29 2019
# Purpose:    Return $alt_seq_instance_HHR->{$seq_name}{$alt_code} 
#             if it is defined, else returns undef.
#
# Arguments:
#  $alt_seq_instances_HHHR: ref to 2D hash of sequence alert instances
#  $seq_name:               the sequence name
#  $alt_code:               the alert code.
#
# Returns:  $alt_seq_instance_HHHR->{$seq_name}{$alt_code} 
#           undef if that is not defined
#
# Dies:     never
#
#################################################################
sub alert_sequence_instance_fetch { 
  my $sub_name = "alert_sequence_instance_fetch";
  my $nargs_exp = 3;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($alt_seq_instances_HHHR, $seq_name, $alt_code) = (@_);

  if((defined $alt_seq_instances_HHHR) && 
     (defined $alt_seq_instances_HHHR->{$seq_name}) && 
     (defined $alt_seq_instances_HHHR->{$seq_name}{$alt_code})) { 
    return $alt_seq_instances_HHHR->{$seq_name}{$alt_code}; # defined
  }

  return undef; # not defined
}

#################################################################
# Subroutine: alert_feature_instance_fetch()
# Incept:     EPN, Fri Apr  5 11:59:00 2019
# Purpose:    Return $alt_ftr_instance_HHHR->{$seq_name}{$ftr_idx}{$alt_code} 
#             if it is defined, else returns undef.
#
# Arguments:
#  $alt_ftr_instances_HHHR: ref to 3D hash of feature alert instances
#  $seq_name:               the sequence name
#  $ftr_idx:                the feature index
#  $alt_code:               the alert code.
#
# Returns:  $alt_ftr_instance_HHHR->{$seq_name}{$ftr_idx}{$alt_code} 
#           undef if that is not defined
#
# Dies:     never
#
#################################################################
sub alert_feature_instance_fetch { 
  my $sub_name = "alert_feature_instance_fetch";
  my $nargs_exp = 4;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($alt_ftr_instances_HHHR, $seq_name, $ftr_idx, $alt_code) = (@_);

  if((defined $alt_ftr_instances_HHHR) && 
     (defined $alt_ftr_instances_HHHR->{$seq_name}) && 
     (defined $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}) && 
     (defined $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$alt_code})) { 
    return $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$alt_code}; # defined
  }

  return undef; # not defined
}

#################################################################
# Subroutine: alert_add_b_zft()
# Incept:     EPN, Thu Jan 24 12:31:16 2019
# Purpose:    Adds b_zft alerts for sequences with 0 predicted features.
#
# Arguments:
#  $seq_name_AR:             REF to array of sequence names, PRE-FILLED
#  $ftr_info_AHR:            REF to array of hashes with information on the features, PRE-FILLED
#  $alt_info_HHR:            REF to array of hashes with information on the alerts, PRE-FILLED
#  $ftr_results_HAHR:        REF to feature results HAH, PRE-FILLED
#  $alt_seq_instances_HHR:   REF to 2D hash with per-sequence alerts, ADDED TO HERE
#  $alt_ftr_instances_HHHR:  REF to array of 2D hashes with per-feature alerts, PRE-FILLED
#  $opt_HHR:                 REF to 2D hash of option values, see top of epn-options.pm for description
#  $FH_HR:                   REF to hash of file handles, including 'log'
#             
# Returns:  void
# 
# Dies:     never
#
#################################################################
sub alert_add_b_zft { 
  my $sub_name = "alert_add_b_zft";
  my $nargs_exp = 8;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name_AR, $ftr_info_AHR, $alt_info_HHR, $ftr_results_HAHR, 
      $alt_seq_instances_HHR, $alt_ftr_instances_HHHR, $opt_HHR, $FH_HR) = @_;

  my $nseq = scalar(@{$seq_name_AR});
  my $nftr = scalar(@{$ftr_info_AHR});

  my @ftr_min_len_A = (); 
  for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
    $ftr_min_len_A[$ftr_idx] = (dng_FeatureTypeIsCdsOrMatPeptideOrGene($ftr_info_AHR, $ftr_idx)) ? 
        opt_Get("--xminntlen", $opt_HHR) : 1;
  }

  for(my $seq_idx = 0; $seq_idx < $nseq; $seq_idx++) { 
    my $seq_name  = $seq_name_AR->[$seq_idx];
    my $seq_nftr = 0; # number of annotated features for this sequence

    # loop over features
    for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
      if(check_for_valid_feature_prediction(\%{$ftr_results_HAHR->{$seq_name}[$ftr_idx]}, $ftr_min_len_A[$ftr_idx])) { 
        $seq_nftr++;
        $ftr_idx = $nftr; # breaks for $ftr_idx loop
      } 
    }
    if($seq_nftr == 0) { 
      alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "b_zft", $seq_name, "", $FH_HR);
    }
  }

  return;
}

#################################################################
# Subroutine: alert_add_n_div()
# Incept:     EPN, Thu Feb  7 11:54:56 2019
# Purpose:    Adds n_div alerts for sequences listed in the array @overflow_seq_A, if any.
#
# Arguments:
#  $overflow_seq_AR:         REF to array of sequences that failed due to matrix overflows, pre-filled
#  $overflow_mxsize_AR:      REF to array of required matrix sizes for each sequence that failed due to matrix overflows, pre-filled
#  $alt_seq_instances_HHR:   REF to 2D hash with per-sequence alerts, PRE-FILLED
#  $alt_info_HHR:            REF to the alert info hash of arrays, PRE-FILLED
#  $opt_HHR:                 REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:          REF to the 2D hash of output file information
#             
# Returns:  void
# 
# Dies:     never
#
#################################################################
sub alert_add_n_div { 
  my $sub_name = "alert_add_n_div";
  my $nargs_exp = 6;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($overflow_seq_AR, $overflow_mxsize_AR, $alt_seq_instances_HHR, $alt_info_HHR, $opt_HHR, $ofile_info_HHR) = @_;

  my $FH_HR = $ofile_info_HHR->{"FH"}; # for convenience

  my $noverflow = scalar(@{$overflow_seq_AR});
  for(my $s = 0; $s < $noverflow; $s++) { 
    alert_sequence_instance_add($alt_seq_instances_HHR, $alt_info_HHR, "n_div", $overflow_seq_AR->[$s], "required matrix size: $overflow_mxsize_AR->[$s] Mb", $FH_HR);
  }

  return;
}

#################################################################
# Subroutine:  alert_instances_check_prevents_annot()
# Incept:      EPN, Fri Mar 22 11:57:32 2019
#

# Purpose:    Given a sequence name, determine if any alerts 
#             stored in %{$alt_seq_instances_HHR} exist for it
#             that prevent its annotation.
#
# Arguments: 
#  $seq_name:              name of sequence
#  $alt_info_HHR:          REF to the alert info hash of arrays, PRE-FILLED
#  $alt_seq_instances_HHR: REF to 2D hashes with per-sequence alerts, PRE-FILLED
#  $FH_HR:                 REF to hash of file handles
#
# Returns:    A string with all per-sequence err codes for this sequence 
#             concatenated and separated by commas.
#
################################################################# 
sub alert_instances_check_prevents_annot { 
  my $sub_name = "alert_instances_check_prevents_annot";
  my $nargs_exp = 4;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name, $alt_info_HHR, $alt_seq_instances_HHR, $FH_HR) = @_;

  if(defined $alt_seq_instances_HHR->{$seq_name}) { 
    foreach my $alt_code (keys (%{$alt_seq_instances_HHR->{$seq_name}})) { 
      if(($alt_info_HHR->{$alt_code}{"pertype"} eq "sequence") && 
         ($alt_info_HHR->{$alt_code}{"prevents_annot"} == 1)) { 
        return 1;
      }
    }
  }
  
  return 0;
}

#################################################################
#
# Subroutines for creating tabular output:
# output_tabular
# helper_tabular_ftr_results_strand
# helper_tabular_ftr_results_trunc_string
# helper_tabular_sgm_results_trunc_string
# helper_tabular_get_ftr_alert_strings
# helper_tabular_get_seq_alert_strings
# helper_tabular_replace_spaces
# 
#################################################################
# Subroutine: output_tabular()
# Incept:     EPN, Mon Mar  4 21:02:12 2019
# Purpose:    Output tabular files.
#
# Arguments:
#  $mdl_info_AHR:            REF to array of hashes with model info
#  $mdl_cls_ct_HR:           REF to hash with counts of seqs classified per model
#  $mdl_ant_ct_HR:           REF to hash with counts of seqs annotated per model
#  $seq_name_AR:             REF to array of sequence names
#  $seq_len_HR:              REF to hash of sequence lengths
#  $ftr_info_HAHR:           REF to hash of arrays with information on the features, PRE-FILLED
#  $sgm_info_HAHR:           REF to hash of arrays with information on the segments, PRE-FILLED
#  $alt_info_HHR:            REF to the alert info hash of arrays, PRE-FILLED
#  $cls_output_HHR:          REF to 2D hash of classification results to output, PRE-FILLED
#  $ftr_results_HAHR:        REF to feature results AAH, PRE-FILLED
#  $sgm_results_HAHR:        REF to model results AAH, PRE-FILLED
#  $alt_seq_instances_HHR:   REF to 2D hash with per-sequence alerts, PRE-FILLED
#  $alt_ftr_instances_HHHR:  REF to array of 2D hashes with per-feature alerts, PRE-FILLED
#  $opt_HHR:                 REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:          REF to the 2D hash of output file information
#             
# Returns:  Two values:
#           $zero_classifications: '1' if no sequences were classified, else '0'
#           $zero_alerts:          '1' if no alerts were reported, else '0'
# 
# Dies:     never
#
#################################################################
sub output_tabular { 
  my $sub_name = "output_tabular";
  my $nargs_exp = 15;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($mdl_info_AHR, $mdl_cls_ct_HR, $mdl_ant_ct_HR, 
      $seq_name_AR, $seq_len_HR, 
      $ftr_info_HAHR, $sgm_info_HAHR, $alt_info_HHR, 
      $cls_output_HHR, $ftr_results_HHAHR, $sgm_results_HHAHR, $alt_seq_instances_HHR, 
      $alt_ftr_instances_HHHR, $opt_HHR, $ofile_info_HHR) = @_;

  my $FH_HR = $ofile_info_HHR->{"FH"}; # for convenience

  # validate input and determine maximum counts of things
  my $nseq = scalar(@{$seq_name_AR});
  my $nalt = scalar(keys %{$alt_info_HHR});
  my $nmdl = scalar(@{$mdl_info_AHR});
  my ($mdl_idx, $ftr_idx, $sgm_idx);
  my $mdl_name;

  # determine order of alert codes to print
  my $alt_code;
  my @alt_code_A     = (); # all alerts in output order
  my @seq_alt_code_A = (); # per-sequence alerts in output order
  my @ftr_alt_code_A = (); # per-feature  alerts in output order
  alert_order_arrays($alt_info_HHR, \@alt_code_A, \@seq_alt_code_A, \@ftr_alt_code_A);

  my $nalt_seq_possible = scalar(@seq_alt_code_A);
  my %alt_ct_H     = (); # total number of alerts per alert code
  my %alt_seq_ct_H = (); # number of seqs with at least one instance of each alert code
  foreach $alt_code (@alt_code_A) { 
    $alt_ct_H{$alt_code} = 0;
    $alt_seq_ct_H{$alt_code} = 0;
  }

  # make hash of model names to indices in mdl_info_AHR, we'll 
  # use this when creating the per-model table
  my %mdl_idx_H = ();
  utl_IdxHFromAH(\%mdl_idx_H, $mdl_info_AHR, "name", $sub_name, $FH_HR);
  my %mdl_pass_ct_H = (); # number of seqs per model that pass
  my %mdl_fail_ct_H = (); # number of seqs per model that fail

  # define the header columns
  my @head_ant_AA = ();
  my @data_ant_AA = ();
  @{$head_ant_AA[0]} = ("seq", "seq",  "seq", "",    "",    "best",  "",    "sub", "",    "",    "",    "",    "",      "seq");
  @{$head_ant_AA[1]} = ("idx", "name", "len", "p/f", "ant", "model", "grp", "grp", "nfa", "nfn", "nf5", "nf3", "nfalt", "alerts");
  my @clj_ant_A      = (1,     1,      0,     1,     1,     1,       1,     1,     0,     0,     0,     0,     0,       1);

  my @head_cls_AA = ();
  my @data_cls_AA = ();
  @{$head_cls_AA[0]} = ("seq", "seq",  "seq", "",    "",    "",       "",     "sub",  "",      "",      "seq", "mdl", "",     "num",  "",    "",       "",     "sub",  "score", "diff/", "seq");
  @{$head_cls_AA[1]} = ("idx", "name", "len", "p/f", "ant", "model1", "grp1", "grp1", "score", "sc/nt", "cov", "cov", "bias", "hits", "str", "model2", "grp2", "grp2", "diff",  "nt",    "alerts");
  my @clj_cls_A      = (1,     1,      0,     1,     1,     1,        1,      1,      0,       0,       0,     0,     0,      0,      0,     1,        1,      1,      0,       0,       1);

  my @head_ftr_AA = ();
  my @data_ftr_AA = ();
  @{$head_ftr_AA[0]} = ("",    "seq",  "seq", "",    "",      "ftr",  "ftr",  "ftr", "ftr", "",    "",       "",     "",        "",    "",       "",     "",        "",     "dup", "",    "",    "seq",    "model",  "ftr");
  @{$head_ftr_AA[1]} = ("idx", "name", "len", "p/f", "model", "type", "name", "len", "idx", "str", "n_from", "n_to", "n_instp", "trc", "p_from", "p_to", "p_instp", "p_sc", "idx", "nsa", "nsn", "coords", "coords", "alerts");
  my @clj_ftr_A      = (1,     1,      0,     1,     1,       1,      1,      0,     0,     0,     0,        0,      0,         1,     0,        0,      0,         0,       0,    0,     0,     0,        0,        1);

  my @head_sgm_AA = ();
  my @data_sgm_AA = ();
  @{$head_sgm_AA[0]} = ("",    "seq",  "seq", "",    "",      "ftr",  "ftr",  "ftr", "num", "sgm", "seq",  "seq", "mdl",  "mdl", "sgm", "",    "",    "5'", "3'", "5'",  "3'");
  @{$head_sgm_AA[1]} = ("idx", "name", "len", "p/f", "model", "type", "name", "idx", "sgm", "idx", "from", "to",  "from", "to",  "len", "str", "trc", "pp", "pp", "gap", "gap");
  my @clj_sgm_A      = (1,     1,      0,     1,     1,       1,      1,      0,     0,     0,     0,      0,     0,      0,     0,     0,     1,     0,    0,    1,     1);

  my @head_alt_AA = ();
  my @data_alt_AA = ();
  @{$head_alt_AA[0]} = ("",    "seq",  "",      "ftr",  "ftr",  "ftr", "alert", "",     "alert",  "alert");
  @{$head_alt_AA[1]} = ("idx", "name", "model", "type", "name", "idx", "code",  "fail", "desc",   "detail");
  my @clj_alt_A      = (1,     1,      1,       1,      1,      0,     1,       1,      1,        1);

  my @head_alc_AA = ();
  my @data_alc_AA = ();
  @{$head_alc_AA[0]} = ("",    "alert",  "causes",  "short",       "per",  "num",   "num",  "long");
  @{$head_alc_AA[1]} = ("idx", "code",   "failure", "description", "type", "cases", "seqs", "description");
  my @clj_alc_A      = (1,     1,        1,          1,            0,      0,      0,        1);

  my @head_mdl_AA = ();
  my @data_mdl_AA = ();
  @{$head_mdl_AA[0]} = ("",    "",      "",      "",         "num",  "num",  "num",  "num");
  @{$head_mdl_AA[1]} = ("idx", "model", "group", "subgroup", "seqs", "pass", "fail", "notannot");
  my @clj_mdl_A      = (1,     1,       1,       1,          0,      0,      0,      0);

  #printf $out_FH ("#sequence: sequence name\n");
  #printf $out_FH ("#product:  CDS product name\n");
  #printf $out_FH ("#cm?:      is there a CM (nucleotide-based) prediction/hit? above threshold\n");
  #printf $out_FH ("#blast?:   is there a blastx (protein-based) prediction/hit? above threshold\n");
  #printf $out_FH ("#bquery:   name of blastx query name\n");
  #printf $out_FH ("#feature?: 'feature' if blastx query was a fetched feature, from CM prediction\n");
  #printf $out_FH ("#          'full'    if blastx query was a full input sequence\n");
  #printf $out_FH ("#cmstart:  start position of CM (nucleotide-based) prediction\n");
  #printf $out_FH ("#cmstop:   stop  position of CM (nucleotide-based) prediction\n");
  #printf $out_FH ("#bxstart:  start position of blastx top HSP\n");
  #printf $out_FH ("#bxstop:   stop  position of blastx top HSP\n");
  #printf $out_FH ("#bxscore:  raw score of top blastx HSP (if one exists, even if it is below threshold)\n");
  #printf $out_FH ("#startdf:  difference between cmstart and bxstart\n");
  #printf $out_FH ("#stopdf:   difference between cmstop and bxstop\n");
  #printf $out_FH ("#bxmaxin:  maximum insert length in top blastx HSP\n");
  #printf $out_FH ("#bxmaxde:  maximum delete length in top blastx HSP\n");
  #printf $out_FH ("#bxtrc:    position of stop codon in top blastx HSP, if there is one\n");
  #printf $out_FH ("#alerts:   list of alerts for this sequence, - if none\n");

  # main loop: for each sequence
  for(my $seq_idx = 0; $seq_idx < $nseq; $seq_idx++) { 
    my $seq_name  = $seq_name_AR->[$seq_idx];
    my $seq_len   = $seq_len_HR->{$seq_name};
    my $seq_nftr_alt    = 0;
    my $seq_nseq_alt    = 0;
    my $seq_nftr_annot  = 0;
    my $seq_nftr_5trunc = 0;
    my $seq_nftr_3trunc = 0;
    my $nftr = 0;
 
   # get per-sequence info from %{$cls_output_HHR->{$seq_name}}
    my $cls_output_HR = (defined $cls_output_HHR->{$seq_name}) ? \%{$cls_output_HHR->{$seq_name}} : undef;
    my $seq_score   = ((defined $cls_output_HR) && (defined $cls_output_HR->{"score"}))     ? $cls_output_HR->{"score"}     : "-";
    my $seq_scpnt   = ((defined $cls_output_HR) && (defined $cls_output_HR->{"scpnt"}))     ? $cls_output_HR->{"scpnt"}     : "-";
    my $seq_scov    = ((defined $cls_output_HR) && (defined $cls_output_HR->{"scov"}))      ? $cls_output_HR->{"scov"}      : "-";
    my $seq_mcov    = ((defined $cls_output_HR) && (defined $cls_output_HR->{"mcov"}))      ? $cls_output_HR->{"mcov"}      : "-";
    my $seq_bias    = ((defined $cls_output_HR) && (defined $cls_output_HR->{"bias"}))      ? $cls_output_HR->{"bias"}      : "-";
    my $seq_nhits   = ((defined $cls_output_HR) && (defined $cls_output_HR->{"nhits"}))     ? $cls_output_HR->{"nhits"}     : "-";
    my $seq_strand  = ((defined $cls_output_HR) && (defined $cls_output_HR->{"bstrand"}))   ? $cls_output_HR->{"bstrand"}   : "_";
    my $seq_scdiff  = ((defined $cls_output_HR) && (defined $cls_output_HR->{"scdiff"}))    ? $cls_output_HR->{"scdiff"}    : "-";
    my $seq_diffpnt = ((defined $cls_output_HR) && (defined $cls_output_HR->{"diffpnt"}))   ? $cls_output_HR->{"diffpnt"}   : "-";
    my $seq_mdl1    = ((defined $cls_output_HR) && (defined $cls_output_HR->{"model1"}))    ? $cls_output_HR->{"model1"}    : "-";
    my $seq_mdl2    = ((defined $cls_output_HR) && (defined $cls_output_HR->{"model2"}))    ? $cls_output_HR->{"model2"}    : "-";
    my $seq_grp1    = ((defined $cls_output_HR) && (defined $cls_output_HR->{"group1"}))    ? $cls_output_HR->{"group1"}    : "-";
    my $seq_grp2    = ((defined $cls_output_HR) && (defined $cls_output_HR->{"group2"}))    ? $cls_output_HR->{"group2"}    : "-";
    my $seq_subgrp1 = ((defined $cls_output_HR) && (defined $cls_output_HR->{"subgroup1"})) ? $cls_output_HR->{"subgroup1"} : "-";
    my $seq_subgrp2 = ((defined $cls_output_HR) && (defined $cls_output_HR->{"subgroup2"})) ? $cls_output_HR->{"subgroup2"} : "-";

    my $seq_pass_fail = (check_if_sequence_passes($seq_name, $alt_info_HHR, $alt_seq_instances_HHR, $alt_ftr_instances_HHHR)) ? "PASS" : "FAIL";
    my $seq_annot     = (check_if_sequence_was_annotated($seq_name, $cls_output_HHR)) ? "yes" : "no";

    if($seq_mdl1 ne "-") { 
      if(! defined $mdl_pass_ct_H{$seq_mdl1}) { $mdl_pass_ct_H{$seq_mdl1} = 0; }
      if(! defined $mdl_fail_ct_H{$seq_mdl1}) { $mdl_fail_ct_H{$seq_mdl1} = 0; }
      if($seq_pass_fail eq "PASS") { $mdl_pass_ct_H{$seq_mdl1}++; }
      if($seq_pass_fail eq "FAIL") { $mdl_fail_ct_H{$seq_mdl1}++; }
    }

    my $ftr_nprinted   = 0; # number of total features printed for this sequence 
    my $sgm_nprinted   = 0; # number of total segments printed for this sequence
    my $alt_nprinted   = 0; # number of total alerts printed for this sequence
    my $alt_nftr       = 0; # number of features we've printed at least 1 alert for
    my $alt_nseqftr    = 0; # number of features we've printed for this sequence/feature combo
    my %alt_seqcode_H  = (); # key is alert code: '1' if we've printed >= 1 alerts for this sequence/code combo

    # print per-sequence alerts, if any
    if(defined $alt_seq_instances_HHR->{$seq_name}) { 
      foreach $alt_code (@seq_alt_code_A) { 
        my $alt_instance = alert_sequence_instance_fetch($alt_seq_instances_HHR, $seq_name, $alt_code);
        if(defined $alt_instance) { 
          if(($alt_nprinted == 0) && (scalar(@data_alt_AA) > 0)) { 
            push(@data_alt_AA, []);  # push empty array --> blank line 
          }
          if(! defined $alt_seqcode_H{$alt_code}) { 
            $alt_seq_ct_H{$alt_code}++; 
            $alt_seqcode_H{$alt_code} = 1;
          }
          if($alt_nseqftr == 0) { 
            $alt_nftr++;
          }
          my @instance_str_A = ($alt_instance eq "") ? ("") : (split(":DNAORGSEP:", $alt_instance));
          foreach my $instance_str (@instance_str_A) { 
            $alt_nseqftr++;
            $alt_ct_H{$alt_code}++;
            my $alt_idx2print = ($seq_idx + 1) . "." . $alt_nftr . "." . $alt_nseqftr;
            push(@data_alt_AA, [$alt_idx2print, $seq_name, $seq_mdl1, "-", "-", "-", $alt_code, 
                                $alt_info_HHR->{$alt_code}{"causes_failure"} ? "yes" : "no", 
                                helper_tabular_replace_spaces($alt_info_HHR->{$alt_code}{"sdesc"}), 
                                $alt_info_HHR->{$alt_code}{"ldesc"} . (($instance_str eq "") ? "" : " [" . $instance_str . "]")]);
            $alt_nprinted++;
          }
        }
      }
    }

    if($seq_mdl1 ne "-") { 
      $nftr = scalar(@{$ftr_info_HAHR->{$seq_mdl1}});
      my $ftr_info_AHR = \@{$ftr_info_HAHR->{$seq_mdl1}}; # for convenience
      for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
        my $src_idx = $ftr_info_AHR->[$ftr_idx]{"source_idx"};
        my $ftr_results_HR = $ftr_results_HHAHR->{$seq_mdl1}{$seq_name}[$src_idx]; # for convenience
        my $ftr_idx2print = ($seq_idx + 1) . "." . ($seq_nftr_annot + 1);
        if((defined $ftr_results_HR->{"n_start"}) || (defined $ftr_results_HR->{"p_start"})) { 
          $seq_nftr_annot++;
          my $ftr_name = $ftr_info_AHR->[$ftr_idx]{"outname"};
          my $ftr_name2print = helper_tabular_replace_spaces($ftr_name);
          my $ftr_type = $ftr_info_AHR->[$ftr_idx]{"type"};
          my $ftr_strand   = helper_tabular_ftr_results_strand($ftr_info_AHR, $ftr_results_HR, $src_idx);
          my $ftr_trunc    = helper_tabular_ftr_results_trunc_string($ftr_results_HR);
          my $ftr_n_start  = (defined $ftr_results_HR->{"n_start"})   ? $ftr_results_HR->{"n_start"}   : "-";
          my $ftr_n_stop   = (defined $ftr_results_HR->{"n_stop"})    ? $ftr_results_HR->{"n_stop"}    : "-";
          my $ftr_n_stop_c = (defined $ftr_results_HR->{"n_stop_c"})  ? $ftr_results_HR->{"n_stop_c"}  : "-";
          if(($ftr_n_stop_c ne "-") && ($ftr_n_stop_c == $ftr_n_stop)) { $ftr_n_stop_c = "-"; }
          my $ftr_p_start  = (defined $ftr_results_HR->{"p_start"})   ? $ftr_results_HR->{"p_start"}   : "-";
          my $ftr_p_stop   = (defined $ftr_results_HR->{"p_stop"})    ? $ftr_results_HR->{"p_stop"}    : "-";
          my $ftr_p_stop_c = (defined $ftr_results_HR->{"p_trcstop"}) ? $ftr_results_HR->{"p_trcstop"} : "-";
          if($ftr_p_stop_c ne "-") { 
            $ftr_p_stop_c =~ s/;.*$//; # keep only first early stop position
          }
          my $ftr_p_score = (defined $ftr_results_HR->{"p_score"})  ? $ftr_results_HR->{"p_score"} : "-";
          my $ftr_dupidx  = dng_FeatureIsDuplicate($ftr_info_AHR, $ftr_idx) ? $ftr_info_AHR->[$ftr_idx]{"source_idx"} : "-";
          if((defined $ftr_results_HR->{"n_5trunc"}) && ($ftr_results_HR->{"n_5trunc"})) { 
            $seq_nftr_5trunc++; 
          }
          if((defined $ftr_results_HR->{"n_3trunc"}) && ($ftr_results_HR->{"n_3trunc"})) { 
            $seq_nftr_3trunc++; 
          }

          my $ftr_alt_str = helper_output_feature_alert_strings($seq_name, $ftr_idx, 1, $alt_info_HHR, \@ftr_alt_code_A, $alt_ftr_instances_HHHR, $FH_HR);
          if($ftr_alt_str ne "") { 
            $seq_nftr_alt++; 
            $seq_nftr_alt += $ftr_alt_str =~ tr/,//; # plus 1 for each comma
          }

          my $s_coords_str   = ""; # sequence coordinate string for feature
          my $m_coords_str   = ""; # model    coordinate string for feature
          my $ftr_nsgm_annot = 0;
          my $ftr_len_by_sgm = 0;
          my $ftr_first_sgm  = $ftr_info_AHR->[$src_idx]{"5p_sgm_idx"};
          my $ftr_final_sgm  = $ftr_info_AHR->[$src_idx]{"3p_sgm_idx"};
          my $ftr_nsgm       = $ftr_final_sgm - $ftr_first_sgm + 1;
          for(my $sgm_idx = $ftr_first_sgm; $sgm_idx <= $ftr_final_sgm; $sgm_idx++) { 
            if((defined $sgm_results_HHAHR) && 
               (defined $sgm_results_HHAHR->{$seq_mdl1}) && 
               (defined $sgm_results_HHAHR->{$seq_mdl1}{$seq_name}) && 
               (defined $sgm_results_HHAHR->{$seq_mdl1}{$seq_name}[$sgm_idx]) && 
               (defined $sgm_results_HHAHR->{$seq_mdl1}{$seq_name}[$sgm_idx]{"sstart"})) { 
              $ftr_nsgm_annot++;
              my $sgm_idx2print = ($seq_idx + 1) . "." . $seq_nftr_annot . "." . $ftr_nsgm_annot;
              my $sgm_results_HR = $sgm_results_HHAHR->{$seq_mdl1}{$seq_name}[$sgm_idx]; # for convenience
              my $sgm_sstart = $sgm_results_HR->{"sstart"};
              my $sgm_sstop  = $sgm_results_HR->{"sstop"};
              my $sgm_mstart = $sgm_results_HR->{"mstart"};
              my $sgm_mstop  = $sgm_results_HR->{"mstop"};
              my $sgm_slen   = abs($sgm_sstart - $sgm_sstop) + 1;
              my $sgm_mlen   = abs($sgm_mstart - $sgm_mstop) + 1;
              my $sgm_strand = $sgm_results_HR->{"strand"};
              my $sgm_trunc  = helper_tabular_sgm_results_trunc_string($sgm_results_HR);
              my $sgm_pp5    = ($sgm_results_HR->{"startpp"} == -1) ? "-" : $sgm_results_HR->{"startpp"};
              my $sgm_pp3    = ($sgm_results_HR->{"stoppp"}  == -1) ? "-" : $sgm_results_HR->{"stoppp"};
              my $sgm_gap5   = ($sgm_results_HR->{"startgap"}) ? "yes" : "no";
              my $sgm_gap3   = ($sgm_results_HR->{"stopgap"})  ? "yes" : "no";
              
              if($s_coords_str ne "") { $s_coords_str .= ","; }
              if($m_coords_str ne "") { $m_coords_str .= ","; }
              $s_coords_str .= $sgm_sstart . ".." . $sgm_sstop . ":" . $sgm_strand;
              $m_coords_str .= $sgm_mstart . ".." . $sgm_mstop . ":+"; # always positive
              $ftr_len_by_sgm += abs($sgm_sstart - $sgm_sstop) + 1;
              
              if(($sgm_nprinted == 0) && (scalar(@data_sgm_AA) > 0)) { 
                push(@data_sgm_AA, []); # empty array -> blank line
              }
              push(@data_sgm_AA, [$sgm_idx2print, $seq_name, $seq_len, $seq_pass_fail, $seq_mdl1, $ftr_type, $ftr_name2print, ($ftr_idx+1), 
                                  $ftr_nsgm, ($sgm_idx-$ftr_first_sgm+1), $sgm_sstart, $sgm_sstop, $sgm_mstart, $sgm_mstop, $sgm_slen, $sgm_strand, 
                                  $sgm_trunc, $sgm_pp5, $sgm_pp3, $sgm_gap5, $sgm_gap3]);
              $sgm_nprinted++;
            }
          }
          my $ftr_nsgm_noannot = $ftr_nsgm - $ftr_nsgm_annot;
          if($ftr_len_by_sgm == 0) { $ftr_len_by_sgm = "-"; }
          if($ftr_alt_str eq "")   { $ftr_alt_str = "-"; }

          if(($ftr_nprinted == 0) && (scalar(@data_ftr_AA) > 0)) { 
            push(@data_ftr_AA, []); 
          } # empty array -> blank line
          push(@data_ftr_AA, [$ftr_idx2print, $seq_name, $seq_len, $seq_pass_fail, $seq_mdl1, $ftr_type, $ftr_name2print, $ftr_len_by_sgm, 
                                  ($ftr_idx+1), $ftr_strand, $ftr_n_start, $ftr_n_stop, $ftr_n_stop_c, $ftr_trunc, $ftr_p_start, $ftr_p_stop, $ftr_p_stop_c, 
                                  $ftr_p_score, ($ftr_dupidx eq "-") ? "-" : ($ftr_dupidx+1), $ftr_nsgm_annot, $ftr_nsgm_noannot, $s_coords_str, $m_coords_str,
                                  $ftr_alt_str]);
          $ftr_nprinted++;

          # print per-feature alerts, if any
          $alt_nseqftr = 0;
          if((defined $alt_ftr_instances_HHHR->{$seq_name}) && 
             (defined $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx})) { 
            foreach my $alt_code (@ftr_alt_code_A) { 
              my $alt_instance = alert_feature_instance_fetch($alt_ftr_instances_HHHR, $seq_name, $ftr_idx, $alt_code);
              if(defined $alt_instance) { 
                if(($alt_nprinted == 0) && (scalar(@data_alt_AA) > 0)) { 
                  push(@data_alt_AA, []); # empty array -> blank line
                }
                if(! defined $alt_seqcode_H{$alt_code}) { 
                  $alt_seq_ct_H{$alt_code}++; 
                  $alt_seqcode_H{$alt_code} = 1;
                }
                if($alt_nseqftr == 0) { 
                  $alt_nftr++;
                }
                my @instance_str_A = ($alt_instance eq "") ? ("") : (split(":DNAORGSEP:", $alt_instance));
                foreach my $instance_str (@instance_str_A) { 
                  $alt_nseqftr++;
                  $alt_ct_H{$alt_code}++;
                  my $alt_idx2print = ($seq_idx + 1) . "." . $alt_nftr . "." . $alt_nseqftr;
                  push(@data_alt_AA, [$alt_idx2print, $seq_name, $seq_mdl1, $ftr_type, $ftr_name2print, ($ftr_idx+1), $alt_code, 
                                      $alt_info_HHR->{$alt_code}{"causes_failure"} ? "yes" : "no", 
                                      helper_tabular_replace_spaces($alt_info_HHR->{$alt_code}{"sdesc"}), 
                                      $alt_info_HHR->{$alt_code}{"ldesc"} . (($instance_str eq "") ? "" : " [" . $instance_str . "]")]);
                  $alt_nprinted++;
                }
              }
            }
          }
        }
      }
    }
    my $seq_alt_str = helper_output_sequence_alert_strings($seq_name, 1, $alt_info_HHR, \@seq_alt_code_A, $alt_seq_instances_HHR, $FH_HR);
    if($seq_alt_str ne "") { 
      $seq_nseq_alt = 1;
      $seq_nseq_alt += $seq_alt_str =~ tr/,//; # plus 1 for each comma
    }
    my $seq_nftr_notannot = $nftr - $seq_nftr_annot;
    if($seq_alt_str eq "")   { $seq_alt_str  = "-"; }
    if($seq_annot   eq "no") { $seq_nftr_annot = $seq_nftr_notannot = $seq_nftr_5trunc = $seq_nftr_3trunc = $seq_nftr_alt = "-"; }

    push(@data_ant_AA, [($seq_idx+1), $seq_name, $seq_len, $seq_pass_fail, $seq_annot, $seq_mdl1, $seq_grp1, $seq_subgrp1, 
                            $seq_nftr_annot, $seq_nftr_notannot, $seq_nftr_5trunc, $seq_nftr_3trunc, $seq_nftr_alt, $seq_alt_str]);
    
    push(@data_cls_AA, [($seq_idx+1), $seq_name, $seq_len, $seq_pass_fail, $seq_annot, $seq_mdl1, 
                            helper_tabular_replace_spaces($seq_grp1), 
                            helper_tabular_replace_spaces($seq_subgrp1), 
                            $seq_score, $seq_scpnt, $seq_scov, $seq_mcov, $seq_bias, $seq_nhits, $seq_strand, $seq_mdl2, 
                            helper_tabular_replace_spaces($seq_grp2), 
                            helper_tabular_replace_spaces($seq_subgrp2), 
                            $seq_scdiff, $seq_diffpnt, $seq_alt_str]);
  }

  # add data to the alert count table
  my $alt_idx = 0;
  my $zero_alerts = 1; # set to '0' below if we have >= 1 alerts
  my $sum_alt_ct     = 0;
  my $sum_alt_seq_ct = 0;
  foreach my $alt_code (@alt_code_A) { 
    if($alt_ct_H{$alt_code} > 0) { 
      $alt_idx++;
      if(($alt_idx > 0) && ($alt_info_HH{$alt_code}{"causes_failure"})) { 
        # print separation line between alerts that cause and do not cause failure
        push(@data_alc_AA, []); # separator line
      }
      push(@data_alc_AA, [$alt_idx, $alt_code, 
                          ($alt_info_HH{$alt_code}{"causes_failure"} ? "yes" : "no"), 
                          helper_tabular_replace_spaces($alt_info_HH{$alt_code}{"sdesc"}), 
                          $alt_info_HH{$alt_code}{"pertype"}, 
                          $alt_ct_H{$alt_code}, $alt_seq_ct_H{$alt_code},
                          $alt_info_HHR->{$alt_code}{"ldesc"}]);
      $sum_alt_ct     += $alt_ct_H{$alt_code};
      $sum_alt_seq_ct += $alt_seq_ct_H{$alt_code};
      $zero_alerts = 0;
    }
    if(! $zero_alerts) { 
      push(@data_alc_AA, []); # separator line
    }
  }

  # add data to the model table
  my @mdl_tbl_order_A = (sort { $mdl_cls_ct_HR->{$b} <=> $mdl_cls_ct_HR->{$a} } keys (%{$mdl_cls_ct_HR}));
  my $mdl_tbl_idx = 0;
  my $zero_classifications = 1; # set to '0' below if we have >=1 classifications
  my $sum_mdl_cls_ct     = 0;
  my $sum_mdl_pass_ct    = 0;
  my $sum_mdl_fail_ct    = 0;
  my $sum_mdl_noannot_ct = 0;
  foreach $mdl_name (@mdl_tbl_order_A) { 
    if($mdl_cls_ct_HR->{$mdl_name} > 0) { 
      $mdl_tbl_idx++;
      $mdl_idx = $mdl_idx_H{$mdl_name};
      push(@data_mdl_AA, [$mdl_tbl_idx, $mdl_name, 
                              (defined $mdl_info_AHR->[$mdl_idx]{"group"})    ? $mdl_info_AHR->[$mdl_idx]{"group"}    : "-", 
                              (defined $mdl_info_AHR->[$mdl_idx]{"subgroup"}) ? $mdl_info_AHR->[$mdl_idx]{"subgroup"} : "-", 
                              $mdl_cls_ct_HR->{$mdl_name},
                              $mdl_pass_ct_H{$mdl_name}, 
                              $mdl_fail_ct_H{$mdl_name}, 
                              $mdl_cls_ct_HR->{$mdl_name} - $mdl_ant_ct_HR->{$mdl_name}]);
      $sum_mdl_cls_ct     += $mdl_cls_ct_HR->{$mdl_name};
      $sum_mdl_pass_ct    += $mdl_pass_ct_H{$mdl_name};
      $sum_mdl_fail_ct    += $mdl_fail_ct_H{$mdl_name};
      $sum_mdl_noannot_ct += $mdl_cls_ct_HR->{$mdl_name} - $mdl_ant_ct_HR->{$mdl_name};
      $zero_classifications = 0;
    }
  }
  # add mdl summary line
  if(! $zero_classifications) { 
    push(@data_mdl_AA, []); # separator line
    push(@data_mdl_AA, ["-", "*all*", "-", "-", 
                        $sum_mdl_cls_ct, 
                        $sum_mdl_pass_ct, 
                        $sum_mdl_fail_ct, 
                        $sum_mdl_noannot_ct]);
    push(@data_mdl_AA, []); # separator line
  }

  # output the tables:
  ofile_TableHumanOutput(\@data_ant_AA, \@head_ant_AA, \@clj_ant_A, undef, undef, "  ", "-", "#", "#", "", 1, $FH_HR->{"ant_tbl"}, undef, $FH_HR);
  ofile_TableHumanOutput(\@data_cls_AA, \@head_cls_AA, \@clj_cls_A, undef, undef, "  ", "-", "#", "#", "", 1, $FH_HR->{"cls_tbl"}, undef, $FH_HR);
  ofile_TableHumanOutput(\@data_ftr_AA, \@head_ftr_AA, \@clj_ftr_A, undef, undef, "  ", "-", "#", "#", "", 1, $FH_HR->{"ftr_tbl"}, undef, $FH_HR);
  ofile_TableHumanOutput(\@data_sgm_AA, \@head_sgm_AA, \@clj_sgm_A, undef, undef, "  ", "-", "#", "#", "", 1, $FH_HR->{"sgm_tbl"}, undef, $FH_HR);
  ofile_TableHumanOutput(\@data_alt_AA, \@head_alt_AA, \@clj_alt_A, undef, undef, "  ", "-", "#", "#", "", 1, $FH_HR->{"alt_tbl"}, undef, $FH_HR);
  ofile_TableHumanOutput(\@data_alc_AA, \@head_alc_AA, \@clj_alc_A, undef, undef, "  ", "-", "#", "#", "", 0, $FH_HR->{"alc_tbl"}, undef, $FH_HR);
  ofile_TableHumanOutput(\@data_mdl_AA, \@head_mdl_AA, \@clj_mdl_A, undef, undef, "  ", "-", "#", "#", "", 0, $FH_HR->{"mdl_tbl"}, undef, $FH_HR);

  return ($zero_classifications, $zero_alerts);
}
    
#################################################################
# Subroutine : helper_tabular_ftr_results_strand()
# Incept:      EPN, Tue Mar  5 09:10:36 2019
#
# Purpose:    Return string describing feature strand based on 
#             $ftr_results_HR->{"n_strand"} && $ftr_results_HR->{"p_strand"}
#
# Arguments: 
#  $ftr_info_AHR:    REF to array of hashes with information on the features, PRE-FILLED
#  $ftr_results_HR:  REF to hash of feature results for one sequence/feature pair
#  $ftr_idx:         feature index
# 
# Returns:    "+", "-" or "?" (if n_strand && p_strand disagree or neither exists)
#
# Dies:       never
#
################################################################# 
sub helper_tabular_ftr_results_strand { 
  my $sub_name = "helper_tabular_ftr_results_strand()";
  my $nargs_exp = 3;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($ftr_info_AHR, $ftr_results_HR, $ftr_idx) = (@_);

  if(dng_FeatureTypeIsCds($ftr_info_AHR, $ftr_idx)) { 
    if((! defined $ftr_results_HR->{"n_strand"}) && 
       (! defined $ftr_results_HR->{"p_strand"})) { 
      # neither defined
      return "?";
    }
    if((defined $ftr_results_HR->{"n_strand"}) && 
       (defined $ftr_results_HR->{"p_strand"})) { 
      if($ftr_results_HR->{"n_strand"} ne $ftr_results_HR->{"p_strand"}) { 
        # both defined, but they disagree
        return "?";
      }
      # both defined and both agree
      return $ftr_results_HR->{"n_strand"}; 
    }
    if(defined $ftr_results_HR->{"n_strand"}) { 
      # only n_strand defined
      return $ftr_results_HR->{"n_strand"}; 
    }
    # only p_strand defined
    return $ftr_results_HR->{"p_strand"}; 
  } # end of 'if(dng_FeatureTypeIsCds($ftr_info_AHR, $ftr_idx))'
  else { 
    return (defined $ftr_results_HR->{"n_strand"}) ? $ftr_results_HR->{"n_strand"} : "?";
  }
}

#################################################################
# Subroutine : helper_tabular_ftr_results_trunc_string()
# Incept:      EPN, Tue Mar  5 09:10:36 2019
#
# Purpose:    Return string describing truncation mode based on 
#             $ftr_results_HR->{"n_5trunc"} && $ftr_results_HR->{"n_3trunc"}
#
# Arguments: 
#  $ftr_results_HR:   REF to hash of feature results for one sequence/feature pair
#
# Returns:    "5'&3'", "5'", "3'", "no", or "?"
#
# Dies:       never
#
################################################################# 
sub helper_tabular_ftr_results_trunc_string { 
  my $sub_name = "helper_tabular_ftr_results_trunc_string()";
  my $nargs_exp = 1;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($ftr_results_HR) = (@_);

  if((! defined $ftr_results_HR->{"n_5trunc"}) || 
     (! defined $ftr_results_HR->{"n_3trunc"})) { 
    return "?";
  }
  if(($ftr_results_HR->{"n_5trunc"}) && 
     ($ftr_results_HR->{"n_3trunc"})) { 
    return "5'&3'";
  }
  if($ftr_results_HR->{"n_5trunc"}) { 
    return "5'";
  }
  if($ftr_results_HR->{"n_3trunc"}) { 
    return "3'";
  }
  return "no";
}

#################################################################
# Subroutine : helper_tabular_sgm_results_trunc_string()
# Incept:      EPN, Tue Mar  5 15:02:34 2019
#
# Purpose:    Return string describing truncation mode based on 
#             $sgm_results_HR->{"5trunc"} && $sgm_results_HR->{"3trunc"}
#
# Arguments: 
#  $sgm_results_HR:   REF to hash of model results for one sequence/model pair
#
# Returns:    "5'&3'", "5'", "3'", "no", or "?"
#
# Dies:       never
#
################################################################# 
sub helper_tabular_sgm_results_trunc_string { 
  my $sub_name = "helper_tabular_sgm_results_trunc_string()";
  my $nargs_exp = 1;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($sgm_results_HR) = (@_);

  if((! defined $sgm_results_HR->{"5trunc"}) || 
     (! defined $sgm_results_HR->{"3trunc"})) { 
    return "?";
  }
  if(($sgm_results_HR->{"5trunc"}) && 
     ($sgm_results_HR->{"3trunc"})) { 
    return "5'&3'";
  }
  if($sgm_results_HR->{"5trunc"}) { 
    return "5'";
  }
  if($sgm_results_HR->{"3trunc"}) { 
    return "3'";
  }
  return "no";
}

#################################################################
# Subroutine:  helper_tabular_replace_spaces
# Incept:      EPN, Fri Mar 29 13:57:35 2019
#
# Purpose:    Given a string, replace any spaces in it with "_".
#
# Arguments: 
#  $str:       string to remove spaces from
#
# Returns:    $str with spaces converted to "_"
#
################################################################# 
sub helper_tabular_replace_spaces { 
  my $sub_name = "helper_tabular_replace_spaces";
  my $nargs_exp = 1;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($str) = @_;

  $str =~ s/\s/\_/g;  # replace each space with "_"

  return $str;
}

#################################################################
#
# Subroutines for creating feature table output:
# output_feature_table
# output_parent_child_relationships 
# helper_ftable_coords_from_nt_prediction 
# helper_ftable_coords_prot_only_prediction 
# helper_ftable_start_stop_arrays_to_coords 
# helper_ftable_coords_to_out_str 
# helper_ftable_add_qualifier_from_ftr_info
# helper_ftable_add_qualifier_from_ftr_results
# helper_ftable_class_model_for_sequence
# helper_ftable_process_feature_alerts
# helper_ftable_process_sequence_alerts
#
#################################################################

#################################################################
# Subroutine: output_feature_table()
# Incept:     EPN, Tue Dec  5 13:49:17 2017 [rewritten Tue Oct 30 05:59:04 2018]
# Purpose:    Output the feature table for all sequences.
#
# Arguments:
#  $mdl_cls_ct_HR:           REF to hash with counts of seqs classified per model
#  $seq_name_AR:             REF to hash of arrays with information on the sequences, PRE-FILLED
#  $ftr_info_HAHR:           REF to hash of arrays with information on the features, PRE-FILLED
#  $sgm_info_HAHR:           REF to hash of arrays with information on the segments, PRE-FILLED
#  $alt_info_HHR:            REF to the alert info hash of arrays, PRE-FILLED
#  $cls_results_HHHR:        REF to 3D hash of classification results, PRE-FILLED
#  $ftr_results_HAHR:        REF to feature results AAH, PRE-FILLED
#  $sgm_results_HAHR:        REF to model results AAH, PRE-FILLED
#  $alt_seq_instances_HHR:   REF to 2D hash with per-sequence alerts, PRE-FILLED
#  $alt_ftr_instances_HHHR:  REF to array of 2D hashes with per-feature alerts, PRE-FILLED
#  $opt_HHR:                 REF to 2D hash of option values, see top of epn-options.pm for description
#  $ofile_info_HHR:          REF to the 2D hash of output file information
#             
# Returns:  Number of sequences that 'pass'.
# 
# Dies:     never
#
#################################################################
sub output_feature_table { 
  my $sub_name = "output_feature_table";
  my $nargs_exp = 12;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($mdl_cls_ct_HR, $seq_name_AR, $ftr_info_HAHR, $sgm_info_HAHR, $alt_info_HHR, 
      $cls_results_HHHR, $ftr_results_HHAHR, $sgm_results_HHAHR, $alt_seq_instances_HHR, 
      $alt_ftr_instances_HHHR, $opt_HHR, $ofile_info_HHR) = @_;

  my $FH_HR = $ofile_info_HHR->{"FH"}; # for convenience
  my $pass_ftbl_FH = $FH_HR->{"pass_ftbl"};    # feature table for PASSing sequences
  my $fail_ftbl_FH = $FH_HR->{"fail_ftbl"};    # feature table for FAILing sequences
  my $pass_list_FH = $FH_HR->{"pass_list"};    # list of PASSing seqs
  my $fail_list_FH = $FH_HR->{"fail_list"};    # list of FAILing seqs
  my $alerts_FH    = $FH_HR->{"alerts_list"};  # list of alerts
  print $alerts_FH "#sequence\terror\tfeature\terror-description\n";

  my $ret_npass = 0;  # number of sequences that pass, returned from this subroutine

  my $nseq = scalar(@{$seq_name_AR}); # nseq: number of sequences
  my $nalt = scalar(keys %{$alt_info_HHR});

  # determine order of alert codes to print
  my $alt_code;
  my @seq_alt_code_A = (); # per-sequence alerts in output order
  my @ftr_alt_code_A = (); # per-feature  alerts in output order
  alert_order_arrays($alt_info_HHR, undef, \@seq_alt_code_A, \@ftr_alt_code_A);

  # define the hard-coded type priority hash, which defines the order of types in the feature table output, lower is higher priority
  my %type_priority_H = ();
  $type_priority_H{"gene"}         = 0;
  $type_priority_H{"CDS"}          = 1;
  $type_priority_H{"misc_feature"} = 2;
  $type_priority_H{"mat_peptide"}  = 3;
  my $npriority = scalar(keys %type_priority_H);
  # reference for the way we sort the information we collect for the feature table
  #https://stackoverflow.com/questions/10395383/sorting-an-array-of-hash-by-multiple-keys-perl      

  my $qval_sep = ":GPSEP:"; # value separating multiple qualifier values in a single element of $ftr_info_HAHR->{$mdl_name}[$ftr_idx]{}
  # NOTE: $qval_sep == ':GPSEP:' is hard-coded value for separating multiple qualifier values for the same 
  # qualifier (see dnaorg.pm::dng_GenBankStoreQualifierValue)

  my %ftr_min_len_HA = (); # hash of arrays with minimum valid length per model/feature, 1D keys are model names, 2D elements are feature indices
  my $mdl_name = undef;
  my $ftr_idx = undef;
  foreach $mdl_name (sort keys (%{$mdl_cls_ct_HR})) { 
    my $nftr = scalar(@{$ftr_info_HAHR->{$mdl_name}});
    @{$ftr_min_len_HA{$mdl_name}} = ();
    for(my $ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
      $ftr_min_len_HA{$mdl_name}[$ftr_idx] = (dng_FeatureTypeIsCdsOrMatPeptideOrGene($ftr_info_HAHR->{$mdl_name}, $ftr_idx)) ?
          opt_Get("--xminntlen", $opt_HHR) : 1;
    }
  }

  # main loop: for each sequence
  for(my $seq_idx = 0; $seq_idx < $nseq; $seq_idx++) { 
    my $seq_name  = $seq_name_AR->[$seq_idx];
    
    my @ftout_AH      = (); # array of hashes with output for feature table, kept in a hash so we can sort before outputting
    my $ftidx         = 0;  # index in @ftout_AH
    my $min_coord     = -1; # minimum coord in this feature
    my $cur_min_coord = -1; # minimum coord in this segment
    my %ftr_idx2ftout_idx_H = (); # key is feature index $fidx, value is $ftidx index in @ftout_AH that $fidx corresponds to
    my $i;

    my @seq_alert_A = (); # all alerts for this sequence
    my @seq_note_A  = (); # all notes for this sequence

    my $missing_codon_start_flag = 0; # set to 1 if a feature for this sequence should have a codon_start value added but doesn't

    # first check for per-sequence alerts
    my $seq_alt_str = helper_output_sequence_alert_strings($seq_name, 0, $alt_info_HHR, \@seq_alt_code_A, $alt_seq_instances_HHR, $FH_HR);
    helper_ftable_process_sequence_alerts($seq_alt_str, $seq_name, $alt_info_HHR, $alt_seq_instances_HHR, \@seq_alert_A, $FH_HR);

    $mdl_name = helper_ftable_class_model_for_sequence($cls_results_HHHR, $seq_name);
    if(defined $mdl_name) { 
      my $ftr_info_AHR     = \@{$ftr_info_HAHR->{$mdl_name}};     # for convenience
      my $ftr_results_HAHR = \%{$ftr_results_HHAHR->{$mdl_name}}; # for convenience
      my $sgm_results_HAHR = \%{$sgm_results_HHAHR->{$mdl_name}}; # for convenience
      my $nftr = scalar(@{$ftr_info_AHR});
      
      # Determine what features we will annotate, if any,
      # and order them so that any duplicates occur after their 
      # 'source' features from which their annotation will be copied.
      # That way when we get to a duplicate, we already have the annotation
      # of its source feature.
      # Non-duplicate features are annotated if they have a nucleotide-based 
      # or protein-based prediction and (are of a minimum length if they're CDS or mat_peptide)
      # Duplicate features are annotated if their source features are annotated.
      my @ftr_idx_to_annotate_A = ();
      my @ftr_dup_idx_to_annotate_A = ();
      my $is_duplicate; # is the current feature a duplicate?
      for($ftr_idx = 0; $ftr_idx < $nftr; $ftr_idx++) { 
        my $src_idx = $ftr_info_AHR->[$ftr_idx]{"source_idx"}; # will be $ftr_idx unless this sequence is a duplicate
        $is_duplicate = dng_FeatureIsDuplicate($ftr_info_AHR, $ftr_idx);
        if(check_for_valid_feature_prediction(\%{$ftr_results_HAHR->{$seq_name}[$src_idx]}, $ftr_min_len_HA{$mdl_name}[$src_idx])) { 
          if($is_duplicate) { 
            push(@ftr_dup_idx_to_annotate_A, $ftr_idx);
          }
          else { 
            push(@ftr_idx_to_annotate_A, $ftr_idx);
          }
        }
      }
      # add the duplicates to the end of the non-duplicates
      push(@ftr_idx_to_annotate_A, @ftr_dup_idx_to_annotate_A);

      foreach $ftr_idx (@ftr_idx_to_annotate_A) { 
        # initialize
        my $is_5trunc         = 0;  # '1' if this feature is truncated at the 3' end
        my $is_3trunc         = 0;  # '1' if this feature is truncated at the 3' end
        my $is_misc_feature   = 0;  # '1' if this feature turns into a misc_feature due to alert(s)
        my $ftr_coords_str    = ""; # string of coordinates for this feature
        my $ftr_out_str       = ""; # output string for this feature

        my $defined_n_start   = (defined $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_start"}) ? 1: 0;
        my $defined_p_start   = (defined $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_start"}) ? 1: 0;
        my $feature_type      = $ftr_info_AHR->[$ftr_idx]{"type"}; # type of feature, e.g. 'CDS' or 'mat_peptide' or 'gene'
        my $orig_feature_type = $feature_type;                     # original feature type ($feature_type could be changed to misc_feature)
        $is_duplicate         = dng_FeatureIsDuplicate($ftr_info_AHR, $ftr_idx); # is this feature a duplicate?
          
        # determine coordinates for the feature differently depending on
        # if we are a duplicate or not: 
        if($is_duplicate) { 
          # copy from previously determined source feature
          if(! defined $ftr_idx2ftout_idx_H{$ftr_info_AHR->[$ftr_idx]{"source_idx"}}) { 
            ofile_FAIL("ERROR, trying to output feature table info for a duplicate feature but source feature info is undefined", 1, $ofile_info_HHR->{"FH"});;
          }
          my $dup_src_ftidx = $ftr_idx2ftout_idx_H{$ftr_info_AHR->[$ftr_idx]{"source_idx"}};
          $is_5trunc      = $ftout_AH[$dup_src_ftidx]{"5trunc"};
          $is_3trunc      = $ftout_AH[$dup_src_ftidx]{"3trunc"};
          $ftr_coords_str = $ftout_AH[$dup_src_ftidx]{"coords"};
          $min_coord      = $ftout_AH[$dup_src_ftidx]{"mincoord"};
        }
        else { # ! duplicate
          $is_5trunc = $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_5trunc"}; 
          $is_3trunc = $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"n_3trunc"}; 
          if(! $defined_n_start) { 
            # $defined_p_start must be TRUE
            $ftr_coords_str = helper_ftable_coords_prot_only_prediction($seq_name, $ftr_idx, $is_5trunc, $is_3trunc, \$min_coord, 
                                                                            $ftr_results_HAHR, $FH_HR);
          }
          else { # $is_duplicate is '0' and $defined_n_start is '1'
            $ftr_coords_str = helper_ftable_coords_from_nt_prediction($seq_name, $ftr_idx, $is_5trunc, $is_3trunc, \$min_coord, 
                                                                          $ftr_info_AHR, \%{$sgm_results_HHAHR->{$mdl_name}}, $FH_HR);
          }

          # only look up alerts if we're not a duplicate feature
          # fill an array and strings with all alerts for this sequence/feature combo
          my $ftr_alt_str = helper_output_feature_alert_strings($seq_name, $ftr_idx, 0, $alt_info_HHR, \@ftr_alt_code_A, $alt_ftr_instances_HHHR, $FH_HR);
          if(helper_ftable_process_feature_alerts($ftr_alt_str, $seq_name, $ftr_idx, $ftr_info_AHR, $alt_info_HHR, $alt_ftr_instances_HHHR, \@seq_alert_A, $FH_HR)) { 
            $is_misc_feature = 1;
            $feature_type = "misc_feature";
          }
        } # end of 'else' entered if ! $is_duplicate)'
          
        # convert coordinate string to output string
        $ftr_out_str = helper_ftable_coords_to_out_str($ftr_coords_str, $feature_type, $FH_HR);
        
        # add qualifiers: product, gene, exception and codon_start (if !duplicate)
        if(! $is_misc_feature) { 
          $ftr_out_str .= helper_ftable_add_qualifier_from_ftr_info($ftr_idx, "product",   $qval_sep, $ftr_info_AHR, $FH_HR);
          $ftr_out_str .= helper_ftable_add_qualifier_from_ftr_info($ftr_idx, "gene",      $qval_sep, $ftr_info_AHR, $FH_HR);
          $ftr_out_str .= helper_ftable_add_qualifier_from_ftr_info($ftr_idx, "exception", $qval_sep, $ftr_info_AHR, $FH_HR);
          # check for existence of "p_frame" value for all CDS, but only actually output them if 5' truncated
          if((! $is_duplicate) && (dng_FeatureTypeIsCds($ftr_info_AHR, $ftr_idx))) { 
            my $tmp_str = helper_ftable_add_qualifier_from_ftr_results($seq_name, $ftr_idx, "p_frame", "codon_start", $ftr_results_HAHR, $FH_HR);
            if($tmp_str eq "") { 
              # we didn't have an p_frame value for this CDS, so raise a flag
              # we check later that if the sequence passes that this flag 
              # is *NOT* raised, if it is, something went wrong and we die
              $missing_codon_start_flag = 1; 
            } 
            if($is_5trunc) { # only add the codon_start if we are 5' truncated (and if we're here we're not a duplicate)
              $ftr_out_str .= $tmp_str;
            }
          }
        }
        else { # we are a misc_feature, add the 'similar to X' note
          $ftr_out_str .= sprintf("\t\t\t%s\t%s\n", "note", "similar to " . $ftr_info_AHR->[$ftr_idx]{"outname"});
        }
        
        # push to the output hash
        %{$ftout_AH[$ftidx]} = ();
        $ftout_AH[$ftidx]{"5trunc"}          = $is_5trunc;
        $ftout_AH[$ftidx]{"3trunc"}          = $is_3trunc;
        $ftout_AH[$ftidx]{"mincoord"}        = $min_coord;
        $ftout_AH[$ftidx]{"type_priority"}   = (exists $type_priority_H{$orig_feature_type}) ? $type_priority_H{$orig_feature_type} : $npriority;
        $ftout_AH[$ftidx]{"coords"}          = $ftr_coords_str;
        $ftout_AH[$ftidx]{"output"}          = $ftr_out_str;
        $ftr_idx2ftout_idx_H{$ftr_idx} = $ftidx;
        $ftidx++;
      } # end of 'for(my $ftr_idx...'
    } # end of 'if(defined $mdl_name)'

    #######################################
    # OUTPUT section 
    #######################################
    # done with this sequence, determine what type of output we will have 
    my $cur_noutftr = scalar(@ftout_AH);
    my $cur_nalert  = scalar(@seq_alert_A);

    # sort output
    if($cur_noutftr > 0) { 
      @ftout_AH = sort { $a->{"mincoord"}      <=> $b->{"mincoord"} or 
                             $b->{"5trunc"}        <=> $a->{"5trunc"}   or
                             $a->{"3trunc"}        <=> $b->{"3trunc"}   or
                             $a->{"type_priority"} <=> $b->{"type_priority"} 
      } @ftout_AH;
    }              

    # sequences only pass if:
    # - at least one feature is annotated ($cur_noutftr > 0)
    # - zero notes and alerts
    my $do_pass = (($cur_noutftr > 0) && ($cur_nalert == 0)) ? 1 : 0;

    # sanity check, if we output at least one feature with zero alerts, we should also have set codon_start for all CDS features
    if($cur_noutftr > 0 && $cur_nalert == 0 && ($missing_codon_start_flag)) { 
      ofile_FAIL("ERROR in $sub_name, sequence $seq_name set to PASS, but at least one CDS had no codon_start set - shouldn't happen.", "dnaorg", 1, $ofile_info_HHR->{"FH"});
    }
    # another sanity check, our $do_pass value should match what check_if_sequence_passes() returns
    # based on alerts
    if($do_pass != check_if_sequence_passes($seq_name, $alt_info_HHR, $alt_seq_instances_HHR, $alt_ftr_instances_HHHR)) { 
      ofile_FAIL("ERROR in $sub_name, sequence $seq_name, feature table do_pass: $do_pass disagrees with PASS/FAIL designation based on alert instances - shouldn't happen.", "dnaorg", 1, $ofile_info_HHR->{"FH"});
    }
              
    if($do_pass) { 
      # print to the passing feature table file
      $ret_npass++;
      print $pass_list_FH $seq_name . "\n";
      print $pass_ftbl_FH ">Feature $seq_name\n";
      for($i = 0; $i < scalar(@ftout_AH); $i++) { 
        # print 
        print $pass_ftbl_FH $ftout_AH[$i]{"output"};
      }
    }
    else { # $do_pass == 0
      print $fail_list_FH $seq_name . "\n";
      print $fail_ftbl_FH ">Feature $seq_name\n";
      for($i = 0; $i < scalar(@ftout_AH); $i++) { 
        # print 
        print $fail_ftbl_FH $ftout_AH[$i]{"output"};
      }
      if($cur_nalert > 0) { 
        print $fail_ftbl_FH "\nAdditional note(s) to submitter:\n"; 
        for(my $e = 0; $e < scalar(@seq_alert_A); $e++) { 
          my $error_line = $seq_alert_A[$e];
          print $fail_ftbl_FH "ERROR: " . $error_line . "\n"; 
          if($error_line =~ /([^\:]+)\:\s\(([^\)]+)\)\s*(.+)$/) {
            print $alerts_FH ($seq_name . "\t" . $1 . "\t" . $2 . "\t" . $3 . "\n");
          }
          else {
            ofile_FAIL("ERROR in $sub_name, unable to split alert_line for output: $error_line", "dnaorg", 1, $ofile_info_HHR->{"FH"});
          }
        }
      } # end of 'if($cur_nalert > 0)'
    }
  } # end of loop over sequences

  return $ret_npass;
}

#################################################################
# Subroutine:  helper_ftable_coords_from_nt_prediction
# Incept:      EPN, Tue Oct 30 12:59:13 2018
#
# Purpose:    Given a sequence name and feature index, construct
#             a feature table coordinate string, possibly of 
#             multiple lines, one per segment.
#
# Arguments: 
#  $seq_name:          sequence name
#  $ftr_idx:           feature index
#  $is_5trunc:         '1' if feature is 5' truncated, else '0'
#  $is_3trunc:         '1' if feature is 3' truncated, else '0'
#  $ret_min_coord:     REF to minimum coordinate, to fill
#  $ftr_info_AHR:      REF to array of hashes with information on the features, PRE-FILLED
#  $sgm_results_HAHR:  REF to segment results HAH, PRE-FILLED
#  $FH_HR:             REF to hash of file handles
#
# Returns:    A string that gives the coordinates for the seq_idx/ftr_idx
#             pair in feature table format, or "" if no predictions exist.
#
# Dies:       Never
################################################################# 
sub helper_ftable_coords_from_nt_prediction { 
  my $sub_name = "helper_ftable_coords_from_nt_prediction";
  my $nargs_exp = 8;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name, $ftr_idx, $is_5trunc, $is_3trunc, $ret_min_coord, $ftr_info_AHR, $sgm_results_HAHR, $FH_HR) = @_;

  my @start_A = ();
  my @stop_A  = ();
  
  for(my $sgm_idx = $ftr_info_AHR->[$ftr_idx]{"5p_sgm_idx"}; $sgm_idx <= $ftr_info_AHR->[$ftr_idx]{"3p_sgm_idx"}; $sgm_idx++) { 
    if(defined $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"sstart"}) { 
      push(@start_A, $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"sstart"});
      push(@stop_A,  $sgm_results_HAHR->{$seq_name}[$sgm_idx]{"sstop"});
    }
  }
  return helper_ftable_start_stop_arrays_to_coords(\@start_A, \@stop_A, $is_5trunc, $is_3trunc, $ret_min_coord, $FH_HR);
}

#################################################################
# Subroutine:  helper_ftable_coords_prot_only_prediction
# Incept:      EPN, Tue Oct 30 12:26:05 2018
#
# Purpose:    Given a sequence name and feature index, construct
#             a feature table coordinate string, possibly of 
#             multiple lines, one per segment, for the special
#             case that this feature has a 'b_non' alert: blastx 
#             prediction but no CM prediction.
#
# Arguments: 
#  $seq_name:         sequence name
#  $ftr_idx:          feature index
#  $is_5trunc:        '1' if feature is 5' truncated, else '0'
#  $is_3trunc:        '1' if feature is 3' truncated, else '0'
#  $ret_min_coord:    REF to minimum coordinate, to fill
#  $ftr_results_HAHR: REF to feature results AAH, PRE-FILLED
#  $FH_HR:            REF to hash of file handles
#
# Returns:    A string that gives the coordinates for the seq_idx/ftr_idx
#             pair in feature table format.
#
# Dies:       if p_start or p_stop does not exist in the ftr_results_HAHR->{$seq_name}[$ftr_idx] hash
################################################################# 
sub helper_ftable_coords_prot_only_prediction { 
  my $sub_name = "helper_ftable_coords_prot_only_prediction";
  my $nargs_exp = 7;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name, $ftr_idx, $is_5trunc, $is_3trunc, $ret_min_coord, $ftr_results_HAHR, $FH_HR) = @_;

  # NOTE: for 'b_non' alerts, the x_start and x_stop are always set at the feature level
  if((! exists $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_start"}) ||
     (! exists $ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_stop"})) { 
    ofile_FAIL("ERROR in $sub_name, ftr_results_HAHR->{$seq_name}[$ftr_idx]{x_start|x_stop} does not exists", "dnaorg", 1, $FH_HR);
  }

  my @start_A = ($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_start"});
  my @stop_A  = ($ftr_results_HAHR->{$seq_name}[$ftr_idx]{"p_stop"});

  return helper_ftable_start_stop_arrays_to_coords(\@start_A, \@stop_A, $is_5trunc, $is_3trunc, $ret_min_coord, $FH_HR);
}

#################################################################
# Subroutine:  helper_ftable_start_stop_arrays_to_coords()
# Incept:      EPN, Tue Oct 30 12:39:59 2018
#
# Purpose:    Given refs to two arrays of start and stop coordinates,
#             construct coordinate strings in feature table format.
#
# Arguments: 
#  $start_AR:      REF to array of start coordinates
#  $stop_AR:       REF to array of stop coordinates
#  $is_5trunc:     '1' to do carrot for first start
#  $is_3trunc:     '1' to do carrot for final stop
#  $ret_min_coord: REF to minimum coordinate, to fill
#  $FH_HR:         REF to hash of file handles
#
# Returns:    A string that gives the coordinates in feature table format.
#             Or "" if $start_AR->[0] and/or $stop_AR->[0] is "?" and size of those arrays is 1
#
# Dies: if either @{$start_AR} or @{$stop_AR} are empty
#       if @{$start_AR} and @{$stop_AR} are different sizes
#       if $start_AR->[$i] and/or $stop_AR->[$i] eq "?"
#
################################################################# 
sub helper_ftable_start_stop_arrays_to_coords { 
  my $sub_name = "helper_ftable_start_stop_arrays_to_coords";
  my $nargs_exp = 6;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($start_AR, $stop_AR, $is_5trunc, $is_3trunc, $ret_min_coord, $FH_HR) = @_;

  my $ret_coords_str = "";
  my $ncoord = scalar(@{$start_AR});
  my $min_coord = undef;
  if($ncoord == 0) { 
    ofile_FAIL("ERROR in $sub_name, start_A array is empty", "dnaorg", 1, $FH_HR);
  }
  if($ncoord != scalar(@{$stop_AR})) { # sanity check
    ofile_FAIL("ERROR in $sub_name, start_A array and stop_A arrays are different sizes", "dnaorg", 1, $FH_HR);
  }
  for(my $c = 0; $c < $ncoord; $c++) { 
    my $is_first = ($c == 0)           ? 1 : 0;
    my $is_final = ($c == ($ncoord-1)) ? 1 : 0;
    my $start = $start_AR->[$c];
    my $stop  = $stop_AR->[$c];
    if((! defined $min_coord) || ($start < $min_coord)) { $min_coord = $start; }
    if((! defined $min_coord) || ($stop  < $min_coord)) { $min_coord = $stop;  }
    $ret_coords_str .= sprintf("%s%d\t%s%d\n", 
                               ($is_5trunc && $is_first) ? "<" : "", $start, 
                               ($is_3trunc && $is_final) ? ">" : "", $stop);
  }

  $$ret_min_coord = $min_coord;
  return $ret_coords_str;
}

#################################################################
# Subroutine:  helper_ftable_coords_to_out_str()
# Incept:      EPN, Tue Oct 30 13:37:51 2018
#
# Purpose:    Convert a string with >= 1 feature table lines of
#             coordinates to an output string for a feature.
#
# Arguments: 
#  $coords_str:      REF to array of start coordinates
#  $feature_type:    name of feature type, e.g. "CDS"
#  $FH_HR:           REF to hash of file handles
#
# Returns:    The output string, which is the coords string with the
#             feature type added at the appropriate place.
#
# Dies: if $coords_str is empty
#
################################################################# 
sub helper_ftable_coords_to_out_str { 
  my $sub_name = "helper_ftable_coords_to_out_str";
  my $nargs_exp = 3;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($coords_str, $feature_type, $FH_HR) = @_;

  my $ret_out_str = "";

  if($coords_str eq "") { 
    ofile_FAIL("ERROR in $sub_name, coords_str is empty - shouldn't happen", "dnaorg", 1, $FH_HR);
  }
  my @coords_A = split("\n", $coords_str);

  for(my $cidx = 0; $cidx < scalar(@coords_A); $cidx++) { 
    $ret_out_str .= $coords_A[$cidx];
    if($cidx == 0) { $ret_out_str .= "\t" . $feature_type; }
    $ret_out_str .= "\n";
  }
 
  return $ret_out_str;
}

#################################################################
# Subroutine:  helper_ftable_add_qualifier_from_ftr_info()
# Incept:      EPN, Tue Oct 30 13:41:58 2018
#
# Purpose:    Add a qualifier line to a string that will be 
#             part of a feature table output.
#
# Arguments: 
#  $ftr_idx:      feature index
#  $key:          key in ftr_info_AHR
#  $qval_sep:     characters that separate multiple qualifiers in $ftr_info_AHR->[$ftr_idx]{$key}
#  $ftr_info_AHR: REF to array of hashes with information on the features, PRE-FILLED
#  $FH_HR:        REF to hash of file handles
#
# Returns:    Strings to append to the feature table.
#
# Dies: never
#
################################################################# 
sub helper_ftable_add_qualifier_from_ftr_info {
  my $sub_name = "helper_ftable_add_qualifier_from_ftr_info";
  my $nargs_exp = 5;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($ftr_idx, $key, $qval_sep, $ftr_info_AHR, $FH_HR) = @_;
  
  my $ret_str = "";
  if((defined $ftr_info_AHR) && 
     (defined $ftr_info_AHR->[$ftr_idx]) && 
     (defined $ftr_info_AHR->[$ftr_idx]{$key})) { 
    my @qval_A = split($qval_sep, $ftr_info_AHR->[$ftr_idx]{$key});
    foreach my $qval (@qval_A) { 
      $ret_str .= sprintf("\t\t\t%s\t%s\n", $key, $qval);
    }
  }
  return $ret_str;
}

#################################################################
# Subroutine:  helper_ftable_add_qualifier_from_ftr_results()
# Incept:      EPN, Tue Oct 30 13:52:19 2018
#
# Purpose:    Add a qualifier line to a string that will be 
#             part of a feature table output.
#
# Arguments: 
#  $seq_name:          sequence name
#  $ftr_idx:           feature index
#  $results_key:       key in ftr_results_HAHR
#  $qualifier:         name for the qualifier
#  $ftr_results_HAHR:  REF to feature results HAH, PRE-FILLED
#  $FH_HR:             REF to hash of file handles
#
# Returns:    "" if $ftr_results_HAHR->{$seq_name}[$ftr_idx]{$results_key} does not exist
#             else a string for the feature table
#
# Dies: never
#
################################################################# 
sub helper_ftable_add_qualifier_from_ftr_results {
  my $sub_name = "helper_ftable_add_qualifier_from_ftr_results";
  my $nargs_exp = 6;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name, $ftr_idx, $results_key, $qualifier, $ftr_results_HAHR, $FH_HR) = @_;

  my $ret_str = "";

  if((defined $ftr_results_HAHR) && 
     (defined $ftr_results_HAHR->{$seq_name}) && 
     (defined $ftr_results_HAHR->{$seq_name}[$ftr_idx]) && 
     (defined $ftr_results_HAHR->{$seq_name}[$ftr_idx]{$results_key})) { 
    $ret_str = sprintf("\t\t\t%s\t%s\n", $qualifier, $ftr_results_HAHR->{$seq_name}[$ftr_idx]{$results_key});
  }
  return $ret_str;
}

#################################################################
# Subroutine:  helper_ftable_class_model_for_sequence()
# Incept:      EPN, Tue Mar 26 14:47:53 2019
#

# Purpose:    Given a sequence name and a reference of the classification
#             results 3D hash, determine what model the sequence was
#             classified to.
#
# Arguments: 
#  $cls_results_HHHR:      ref to classification results 3D hash
#  $seq_name:              name of sequence
#
# Returns:    model name $seq_name is classified to, or undef 
#             if none
#
################################################################# 
sub helper_ftable_class_model_for_sequence {
  my $sub_name = "helper_ftable_class_model_for_sequence";
  my $nargs_exp = 2;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($cls_results_HHHR, $seq_name) = @_;

  return ((defined $cls_results_HHHR->{$seq_name}) && 
          (defined $cls_results_HHHR->{$seq_name}{"r1.1"}) && 
          (defined $cls_results_HHHR->{$seq_name}{"r1.1"}{"model"})) ? 
          $cls_results_HHH{$seq_name}{"r1.1"}{"model"} : undef;
}

#################################################################
# Subroutine: helper_ftable_process_sequence_alerts()
# Incept:     EPN, Thu Jan 24 12:09:24 2019
#
# Purpose:    Given a string of per-sequence alerts that correspond
#             to a specific sequence, use the %{$alt_info_HHR} and
#             process that string to determine what (if any) 
#             alerts should be added to the feature table
#             for this sequence. Note that we do not add any 'notes'
#             as we possibly could in processFeatureAlertsForFTable() 
#             because we are dealing with the full sequence and not
#             a feature for a sequence.
#
# Arguments:
#   $alt_code_str:           string of alerts, comma separated, can be ""
#   $seq_name:               name of sequence
#   $alt_info_HHR:           REF to hash of hashes with information on the alerts, PRE-FILLED
#   $alt_seq_instances_HHR:  REF to 2D hashes with per-sequence alerts, PRE-FILLED
#   $ret_alert_AR:           REF to array of alerts, possibly added to here (not created)
#   $FH_HR:                  REF to hash of file handles, including "log" and "cmd"
# 
# Returns: number of alerts added to $ret_alert_AR
#
# Dies: Never
#################################################################
sub helper_ftable_process_sequence_alerts { 
  my $sub_name = "helper_ftable_process_sequence_alerts";
  my $nargs_expected = 6;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 
 
  my ($alt_code_str, $seq_name, $alt_info_HHR, $alt_seq_instances_HHR, $ret_alert_AR, $FH_HR) = (@_);

  if($alt_code_str eq "") { 
    return 0; 
  }

  my $ret_nadded = 0;
  # NOTE: there's some code duplication in this sub with
  # processFeatureAlertsForFtable(), possibly a chance for additional
  # subroutines

  # create a hash of all alerts in the input $alt_str, and also verify they are all valid errors
  my %input_alt_code_H = (); # $input_err_code_H{$alt_code} = 1 if $alt_code is in $alt_code_str
  my $alt_code; 
  my $alt_idx; 
  foreach $alt_code (split(",", $alt_code_str)) { 
    if(! defined $alt_info_HHR->{$alt_code}) { 
      ofile_FAIL("ERROR in $sub_name, input error of $alt_code in string $alt_code_str is invalid", "dnaorg", 1, $FH_HR);
    }
    $input_alt_code_H{$alt_code} = 1; 
  }

  my $do_report = 0; # '1' if we should report this alert in the feature table, '0' if not
  foreach $alt_code (sort keys (%input_alt_code_H)) { 
    $do_report = $alt_info_HHR->{$alt_code}{"causes_failure"}; # only report alerts that cause failure in the feature table
    # check if this alert is invalidated by another we will also report
    if(($do_report) && ($alt_info_HHR->{$alt_code}{"ftbl_invalid_by"} ne "")) { 
      my @invalid_by_alt_code_A = split(",", $alt_info_HHR->{"ftbl_invalid_by"}[$alt_idx]);
      foreach my $alt_code2 (@invalid_by_alt_code_A) {
        if(($alt_info_HHR->{$alt_code2}{"causes_failure"}) && 
           (exists $input_alt_code_H{$alt_code2})) { 
          $do_report = 0; # $alt_code is invalidated by $alt_code2, $alt_code2 causes failure and is also present in $alt_code_str
        }
      }
    }
    if($do_report) { 
      # we could have more than one instance of this sequence/alert pair
      my @instance_str_A = ();
      if($alt_seq_instances_HHR->{$seq_name}{$alt_code} eq "") { 
        @instance_str_A = ("");
      }
      else {
        @instance_str_A = split(":DNAORGSEP:", $alt_seq_instances_HHR->{$seq_name}{$alt_code});
      }
      foreach my $instance_str (@instance_str_A) { 
        my $alert_str = sprintf("%s: (*sequence*) %s%s", 
                             $alt_info_HHR->{$alt_code}{"sdesc"}, 
                             $alt_info_HHR->{$alt_code}{"ldesc"}, 
                             ($instance_str ne "") ? " [" . $instance_str . "]" : "");
        # only add the alert, if an identical alert does not already exist in @{$ret_alert_AR}
        my $idx = utl_AFindNonNumericValue($ret_alert_AR, $alert_str, $FH_HR);
        if($idx == -1) { 
          push(@{$ret_alert_AR}, $alert_str); 
          $ret_nadded++;
        }
      }
    }
  }

  return $ret_nadded;
}

#################################################################
# Subroutine: helper_ftable_process_feature_alerts()
# Incept:     EPN, Thu Nov  1 12:10:34 2018
#
# Purpose:    Given a string of alerts that correspond to a specific
#             sequence and feature, use the %{$alt_info_HHR} and
#             process that string to determine what (if any) notes,
#             and alerts should be added to the feature table
#             for this seq/feature pair.
#
# Arguments:
#   $alt_code_str:           string of errors, comma separated, can be ""
#   $seq_name:               name of sequence
#   $ftr_idx:                feature index
#   $ftr_info_AHR:           REF to array of hashes with information on the features, PRE-FILLED
#   $alt_info_HHR:           REF to hash of hashes with information on the errors, PRE-FILLED
#   $alt_ftr_instances_HHHR: REF to hash of array of hashes with per-feature errors, PRE-FILLED
#   $ret_alert_AR:           REF to array of errors, possibly added to here (not created)
#   $FH_HR:                  REF to hash of file handles, including "log" and "cmd"
# 
# Returns: number of alerts added to $ret_alert_AR
#
# Dies: Never
#################################################################
sub helper_ftable_process_feature_alerts { 
  my $sub_name = "helper_ftable_process_feature_alerts";
  my $nargs_expected = 8;
  if(scalar(@_) != $nargs_expected) { printf STDERR ("ERROR, $sub_name entered with %d != %d input arguments.\n", scalar(@_), $nargs_expected); exit(1); } 
 
  my ($alt_code_str, $seq_name, $ftr_idx, $ftr_info_AHR, $alt_info_HHR, $alt_ftr_instances_HHHR, $ret_alert_AR, $FH_HR) = (@_);

  if($alt_code_str eq "") { 
    return 0; 
  }

  # printf("HEYA in $sub_name $seq_name $ftr_idx, $alt_code_str\n");

  # create a hash of all alerts in the input $alt_str
  my %input_alt_code_H = (); # $input_slt_code_H{$alt_code} = 1 if $alt_code is in $alt_code_str
  my $alt_code; 
  foreach $alt_code (split(",", $alt_code_str)) { 
    if(! defined $alt_info_HHR->{$alt_code}) { 
      ofile_FAIL("ERROR in $sub_name, input error of $alt_code in string $alt_code_str is invalid", "dnaorg", 1, $FH_HR);
    }
    $input_alt_code_H{$alt_code} = 1; 
  }

  my $do_report = 0; # '1' if we should report this alert in the feature table, '0' if not
  my $ret_nadded = 0;
  foreach $alt_code (sort keys (%input_alt_code_H)) { 
    $do_report = $alt_info_HHR->{$alt_code}{"causes_failure"}; # only report alerts that cause failure in the feature table
    # check if this alert is invalidated by another we will also report
    if(($do_report) && ($alt_info_HHR->{$alt_code}{"ftbl_invalid_by"} ne "")) { 
      my @invalid_by_alt_code_A = split(",", $alt_info_HHR->{$alt_code}{"ftbl_invalid_by"});
      foreach my $alt_code2 (@invalid_by_alt_code_A) {
        if(($alt_info_HHR->{$alt_code2}{"causes_failure"}) && 
           (exists $input_alt_code_H{$alt_code2})) { 
          $do_report = 0; # $alt_code is invalidated by $alt_code2, $alt_code2 causes failure and is also present in $alt_code_str
          # printf("\t\t\tinvalidated by $alt_code2\n");
        }
      }
    }
    if($do_report) { 
      # we could have more than one instance of this sequence/feature/alert trio
      my @instance_str_A = ();
      if($alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$alt_code} eq "") { 
        @instance_str_A = ("");
      }
      else {
        @instance_str_A = split(":DNAORGSEP:", $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$alt_code});
      }
      foreach my $instance_str (@instance_str_A) { 
        my $alert_str = sprintf("%s: (%s) %s%s", 
                             $alt_info_HHR->{$alt_code}{"sdesc"}, 
                             $ftr_info_AHR->[$ftr_idx]{"outname"}, 
                             $alt_info_HHR->{$alt_code}{"ldesc"}, 
                             ($instance_str ne "") ? " [" . $instance_str . "]" : "");
        # only add the alert, if an identical alert does not already exist in @{$ret_alert_AR}
        my $idx = utl_AFindNonNumericValue($ret_alert_AR, $alert_str, $FH_HR);
        if($idx == -1) { 
          push(@{$ret_alert_AR}, $alert_str); 
          $ret_nadded++;
        }
      }
    }
  }

  return $ret_nadded;
}

#################################################################
# Subroutine:  helper_output_sequence_alert_strings()
# Incept:      EPN, Thu Apr  4 12:37:59 2019
#
# Purpose:    Given a sequence name, construct a string of all
#             per-sequence alerts for that sequence and return it. 
#
# Arguments: 
#  $seq_name:              name of sequence
#  $include_sdesc:         '1' to return a string with "sdesc", '0' not to
#  $alt_info_HHR:          REF to the alert info hash of arrays, PRE-FILLED
#  $alt_code_AR:           ref to alert codes in order to check
#  $alt_seq_instances_HHR: REF to array of 2D hashes with per-feature alerts, PRE-FILLED
#  $FH_HR:                 REF to hash of file handles
#
# Returns:    A string with all per-sequence alt codes for this sequence 
#             concatenated and separated by commas.
#
################################################################# 
sub helper_output_sequence_alert_strings { 
  my $sub_name = "helper_output_sequence_alert_strings";
  my $nargs_exp = 6;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name, $include_sdesc, $alt_info_HHR, $alt_code_AR, $alt_seq_instances_HHR, $FH_HR) = @_;

  my $ret_alt_str = "";
  if(defined $alt_seq_instances_HHR->{$seq_name}) { 
    foreach my $alt_code (@{$alt_code_AR}) { 
      if(defined $alt_seq_instances_HHR->{$seq_name}{$alt_code}) { 
        if($ret_alt_str ne "") { $ret_alt_str .= ","; }
        $ret_alt_str .= ($include_sdesc) ? 
            sprintf("%s(%s)", helper_tabular_replace_spaces($alt_info_HHR->{$alt_code}{"sdesc"}), $alt_code) : 
            $alt_code;
      }
    }
  }
  
  return $ret_alt_str;
}

#################################################################
# Subroutine:  helper_output_feature_alert_strings()
# Incept:      EPN, Thu Apr  4 12:31:51 2019
#
# Purpose:    Given a sequence name and feature index, construct
#             a string of all per-feature alerts for that 
#             sequence/feature pair and return it. 
#
# Arguments: 
#  $seq_name:               name of sequence
#  $ftr_idx:                feature index
#  $include_sdesc:          '1' to return a string with "sdesc", '0' not to
#  $alt_info_HHR:           REF to the alert info hash of arrays, PRE-FILLED
#  $alt_code_AR:            ref to alert codes in order to check
#  $alt_ftr_instances_HHHR: REF to array of 2D hashes with per-feature alerts, PRE-FILLED
#  $FH_HR:                  REF to hash of file handles
#
# Returns:    A string with all per-feature alt codes for this 
#             sequence/feature combo concatenated and 
#             separated by commas.
#
################################################################# 
sub helper_output_feature_alert_strings { 
  my $sub_name = "helper_output_feature_alert_strings";
  my $nargs_exp = 7;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name, $ftr_idx, $include_sdesc, $alt_info_HHR, $alt_code_AR, $alt_ftr_instances_HHHR, $FH_HR) = @_;

  my $ret_alt_str = "";
  if((defined $alt_ftr_instances_HHHR->{$seq_name}) && 
     (defined $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx})) { 
    foreach my $alt_code (@{$alt_code_AR}) { 
      if(defined $alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}{$alt_code}) { 
        if($ret_alt_str ne "") { $ret_alt_str .= ","; }
        $ret_alt_str .= ($include_sdesc) ? 
            sprintf("%s(%s)", helper_tabular_replace_spaces($alt_info_HHR->{$alt_code}{"sdesc"}), $alt_code) : 
            $alt_code;
      }
    }
  }
  
  return $ret_alt_str;
}

#################################################################
#
# Miscellaneous subroutines:
# initialize_ftr_or_sgm_results()
# convert_pp_char_to_pp_avg()
# group_subgroup_string_from_classification_results()
#
#################################################################

#################################################################
# Subroutine: initialize_ftr_or_sgm_results_for_model()
# Incept:     EPN, Tue Mar 15 06:01:32 2016
#
# Purpose:    Initialize the {ftr,sgm}_results_HAH data structure.
#             (for one model).
#
# Args:
#  $seq_name_AR:      REF to hash of arrays with information 
#                     on the sequences, PRE-FILLED
#  $info_AHR:         REF to array of hashes with information 
#                     on the features or segments, PRE-FILLED
#  $results_HAHR:     REF to the feature or segments results data 
#                     structure, INITIALIZED HERE
#  $FH_HR:            REF to hash of file handles
#
# Returns: void
#
#
#################################################################
sub initialize_ftr_or_sgm_results_for_model { 
  my $sub_name = "initialize_ftr_or_sgm_results_for_model()";
  my $nargs_exp = 4;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name_AR, $info_AHR, $results_HAHR, $FH_HR) = @_;

  my $nseq        = scalar(@{$seq_name_AR});
  my $nftr_or_sgm = scalar(@{$info_AHR});

  %{$results_HAHR} = ();
  for(my $seq_idx = 0; $seq_idx < $nseq; $seq_idx++) { 
    @{$results_HAHR->{$seq_name}} = ();
    for(my $ftr_or_sgm_idx = 0; $ftr_or_sgm_idx < $nftr_or_sgm; $ftr_or_sgm_idx++) { 
      %{$results_HAHR->{$seq_name}[$ftr_or_sgm_idx]} = ();
    }
  }
  return;
}

#################################################################
# Subroutine: convert_pp_char_to_pp_avg()
# Incept:     EPN, Thu Feb  7 11:54:56 2019
# Purpose:    Convert a cmalign alignment PP value to the average posterior 
#             probability it represents.
#
# Arguments:
#  $ppchar:  the PP character from the alignment, cannot be a gap
#  $FH_HR:   ref to hash of file handles, including 'log'
#             
# Returns:  average value for $ppchar
# 
# Dies:     if $ppchar is not ['0'-'9'] or '*'
#
#################################################################
sub convert_pp_char_to_pp_avg { 
  my $sub_name = "convert_pp_char_to_pp_avg";
  my $nargs_exp = 2;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($ppchar, $FH_HR) = @_;

  if($ppchar eq "*") { return 0.975; }
  if($ppchar eq "9") { return 0.90; }
  if($ppchar eq "8") { return 0.80; }
  if($ppchar eq "7") { return 0.70; }
  if($ppchar eq "6") { return 0.60; }
  if($ppchar eq "5") { return 0.50; }
  if($ppchar eq "4") { return 0.40; }
  if($ppchar eq "3") { return 0.30; }
  if($ppchar eq "2") { return 0.20; }
  if($ppchar eq "1") { return 0.10; }
  if($ppchar eq "0") { return 0.25; }

  ofile_FAIL("ERROR in $sub_name, invalid PP char: $ppchar", "dnaorg", 1, $FH_HR); 

  return 0.; # NEVER REACHED
}

#################################################################
# Subroutine: group_subgroup_string_from_classification_results()
# Incept:     EPN, Wed Apr  3 10:25:32 2019
# Purpose:    Return a string describing a model's group
#             and subgroup 
#             probability it represents.
#
# Arguments:
#  $results_HR: hash potentially with keys "group" and "subgroup"
#               (typically 3rd dim of cls_results_HHH,
#                e.g. cls_results_HHHR->{$seq_name}{"r1.1"})
#             
# Returns:  "*NONE*" if "group" key not defined in %{$results_HR}
#           $results_HR->{"group"}/*NONE* if "group" key defined but "subgroup" key undef
#           $results_HR->{"group"}/$results_HR->{"subgroup"} if both "group" and "subgroup" keys defined
#
# Dies:     never
#
#################################################################
sub group_subgroup_string_from_classification_results { 
  my $sub_name = "group_subgroup_string_from_classification_results";
  my $nargs_exp = 1;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($results_HR) = (@_);

  if(! defined $results_HR->{"group"}) { 
    return "*NONE*";
  }
  elsif(! defined $results_HR->{"subgroup"}) {
    return $results_HR->{"group"} . "/*NONE*";
  }
  else { 
    return $results_HR->{"group"} . "/" . $results_HR->{"subgroup"};
  }

  return; # NEVER REACHED
}

#################################################################
# Subroutine: check_for_valid_feature_prediction()
# Incept:     EPN, Wed Apr  3 13:40:42 2019
# Purpose:    Return '1' if we have a valid prediction for
#             a feature, else return '0'.
#
# Arguments:
#  $results_HR:     hash potentially with keys "n_start", "p_start", "n_len";
#  $min_len:        minimum length for the feature, can be 0
#             
# Returns:  1 if a valid feature prediction exists, else 0
#
# Dies:     never
#
#################################################################
sub check_for_valid_feature_prediction { 
  my $sub_name = "check_for_valid_feature_prediction";
  my $nargs_exp = 2;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($results_HR, $min_len) = (@_);

  if((defined $results_HR->{"n_start"} || 
      defined $results_HR->{"p_start"}) && 
     ((! defined $results_HR->{"n_len"}) || 
      ($results_HR->{"n_len"} >= $min_len))) { 
    return 1;
  }

  return 0;
}

#################################################################
# Subroutine: check_if_sequence_passes()
# Incept:     EPN, Wed Apr  3 14:09:05 2019
# Purpose:    Check if a sequence should PASS or not based
#             on alert instances. 
#
# Arguments:
#  $seq_name:               sequence name
#  $alt_info_HHR:           ref to 2D hash of alert info
#  $alt_seq_instances_HHR:  ref to 2D hash of sequence alert instances
#  $alt_ftr_instances_HHHR: ref to 3D hash of feature alert instances
#             
# Returns:  '1' if the sequence should pass, else '0'
#
# Dies:     never
#
#################################################################
sub check_if_sequence_passes { 
  my $sub_name = "check_if_sequence_passes";
  my $nargs_exp = 4;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name, $alt_info_HHR, $alt_seq_instances_HHR, $alt_ftr_instances_HHHR) = (@_);

  if((! defined $alt_seq_instances_HHR->{$seq_name}) && 
     (! defined $alt_ftr_instances_HHHR->{$seq_name})) { 
    return 1; # no alerts exist, sequence PASSes
  }
  
  my $alt_code;
  if(defined $alt_seq_instances_HHR->{$seq_name}) { 
    foreach $alt_code (keys (%{$alt_seq_instances_HHR->{$seq_name}})) { 
      if($alt_info_HHR->{$alt_code}{"causes_failure"}) { 
        return 0;  # a sequence alert that causes failure
      }
    }
  }

  my $ftr_idx;
  if(defined $alt_ftr_instances_HHHR->{$seq_name}) { 
    foreach $ftr_idx (keys (%{$alt_ftr_instances_HHHR->{$seq_name}})) { 
      foreach $alt_code (keys (%{$alt_ftr_instances_HHHR->{$seq_name}{$ftr_idx}})) { 
        if($alt_info_HHR->{$alt_code}{"causes_failure"}) { 
          return 0;  # a feature alert that causes failure
        }
      }
    }
  }

  return 1; # no alerts that cause failures, sequence passes

}

#################################################################
# Subroutine: check_if_sequence_was_annotated()
# Incept:     EPN, Wed Apr  3 14:41:58 2019
# Purpose:    Check if a sequence was annotated or not.
#
# Arguments:
#  $seq_name:           sequence name
#  $cls_output_HHR:     ref to classification output
#             
# Returns:  '1' if the sequence was annotated, else '0'
#
# Dies:     never
#
#################################################################
sub check_if_sequence_was_annotated { 
  my $sub_name = "check_if_sequence_was_annotated";
  my $nargs_exp = 2;
  if(scalar(@_) != $nargs_exp) { die "ERROR $sub_name entered with wrong number of input args"; }

  my ($seq_name, $cls_output_HHR) = (@_);

  if((defined $cls_output_HHR->{$seq_name}) && 
     (defined $cls_output_HHR->{$seq_name}{"annot"}) && 
     ($cls_output_HHR->{$seq_name}{"annot"})) { 
    return 1; # yes, it was annotated
  }

  return 0; # no, it wasn't annotated
}

