# Format of `v-annotate.pl` output files

`v-annotate.pl` creates many output files. The formats of many of these file
types are discussed below.

### Tabular output files 

There are seven types of `v-annotate.pl` tabular output files with
fields separated by one or more spaces, that are meant to be easily
parseable. These files will be named `<outdir>.vadr.<suffix>` where
`<outdir>` is the second command line argument given to
`v-annotate.pl`. The seven suffixes are:

| suffix | description |
|--------|-----------------------|
| [`.alc`](#alcformat) | per-alert code information (counts) |
| [`.alt`](#altformat) | per-alert instance information |
| [`.ftr`](#ftrformat) | per-feature information |
| [`.mdl`](#mdlformat) | per-model information |
| [`.sgm`](#sgmformat) | per-segment information |
| [`.sqa`](#sqaformat) | per-sequence annotation information |
| [`.sqc`](#sqcformat) | per-sequence classification information |

All seven types of tabular output files share the following
characteristics: 

1. fields are separated by whitespace (with the possible exception of
   the final field) 
2. comment lines begin with `#`
3. data lines begin with a non-whitespace character other than `#`
4. all lines are either comment lines or data lines

Each format is explained in more detail below.

### Explanation of `.alc`-suffixed output files<a name="alcformat"></a>

`.alc` data lines have 8 or more fields, the names of which appear in the first two
comment lines in each file. There is one data line for each alert code
that occurs at least once in the input sequence file that
`v-annotate.pl` processed.


| idx | field                 | description |
|-----|-----------------------|-------------|
|   1 | `idx`                 | index of alert code |
|   2 | `alert code`          | 8 character VADR alert code |
|   3 | `causes failure`      | `yes` if this code is fatal and causes the associated input sequence to FAIL, `no` if this code is non-fatal |
|   4 | `short description`   | short description of the alert that often maps to error message from NCBI's submission system, multiple alert codes can have the same short description |
|   5 | `per type`            | `feature` if this alert pertains to a specific feature in a sequence, `sequence` if it does not |
|   6 | `num cases`           | number of instances of this alert in the output (number of rows for this alert in `.alt` file), can be more than 1 per sequence |
|   7 | `num seqs`            | number of input sequences with at least one instance of this alert |
|   8 to end | `long description`    |longer description of the alert, specific to each alert type; **this field contains whitespace** |

### Explanation of `.alt`-suffixed output files<a name="altformat"></a>

`.alt` data lines have 10 or more fields, the names of which appear in the first two
comment lines in each file. There is one data line for each **alert instance**
that occurs for each input sequence file that `v-annotate.pl` processed.

| idx | field                 | description |
|-----|-----------------------|-------------|
|   1 | `idx`                 | index of alert instance in format `<d1>.<d2>.<d3>`, where `<d1>` is the index of the sequence this alert instance pertains to in the input sequence file, `<d2>` is the index of the feature this alert instance pertains to (range 1..`<n>`, where `<n>` is the number of features in this sequence with at least 1 alert instance) and `<d3>` is the index of the alert instance for this sequence/feature pair |
|   2 | `seq name`            | sequence name | 
|   3 | `model`               | name of the best-matching model for this sequence |
|   4 | `ftr type`            | type of the feature this alert instance pertains to (e.g. CDS) |
|   5 | `ftr name`            | name of the feature this alert instance pertains to |
|   6 | `ftr idx`             | index (in input model info file) this alert instance pertains to |
|   7 | `alert code`          | 8 character VADR alert code |
|   8 | `fail`                | `yes` if this alert code is fatal (automatically causes the sequence to fail), `no` if not |
|   9 | `alert desc`          | short description of the alert code that often maps to error message from NCBI's submission system, multiple alert codes can have the same short description |
| 10 to end | `alert detail`  | detailed description of the alert instance, possibly with sequence position information; **this field contains whitespace** |

### Explanation of `.alt`-suffixed output files<a name="altformat"></a>

`.alt` data lines have 10 or more fields, the names of which appear in the first two
comment lines in each file. There is one data line for each **alert instance**
that occurs for each input sequence file that `v-annotate.pl` processed.

| idx | field                 | description |
|-----|-----------------------|-------------|
|   1 | `idx`                 | index of alert instance in format `<d1>.<d2>.<d3>`, where `<d1>` is the index of the sequence this alert instance pertains to in the input sequence file, `<d2>` is the index of the feature this alert instance pertains to (range 1..`<n>`, where `<n>` is the number of features in this sequence with at least 1 alert instance) and `<d3>` is the index of the alert instance for this sequence/feature pair |
|   2 | `seq name`            | sequence name this alert instance pertains to | 
|   3 | `model`               | name of the best-matching model for this sequence |
|   4 | `ftr type`            | type of the feature this alert instance pertains to (e.g. CDS) |
|   5 | `ftr name`            | name of the feature this alert instance pertains to |
|   6 | `ftr idx`             | index (in input model info file) this alert instance pertains to |
|   7 | `alert code`          | 8 character VADR alert code |
|   8 | `fail`                | `yes` if this alert code is fatal (automatically causes the sequence to fail), `no` if not |
|   9 | `alert desc`          | short description of the alert code that often maps to error message from NCBI's submission system, multiple alert codes can have the same short description |
| 10 to end | `alert detail`  | detailed description of the alert instance, possibly with sequence position information; **this field contains whitespace** |

### Explanation of `.ftr`-suffixed output files<a name="ftrformat"></a>

`.ftr` data lines have 23 fields, the names of which appear in the first two
comment lines in each file. There is one data line for each
**feature** that is annotated for each input sequence file that
`v-annotate.pl` processed. The set of possible features for each
input sequence depend on its best-matching model, and can be found in
the model info file.

| idx | field                 | description |
|-----|-----------------------|-------------|
|   1 | `idx`                 | index of feature in format `<d1>.<d2>`, where `<d1>` is the index of the sequence in which this feature is annotated in the input sequence file, `<d2>` is the index of the feature (range 1..`<n>`, where `<n>` is the number of features annotated for this sequence |
|   2 | `seq name`            | sequence name in which this feature is annotated |
|   3 | `seq len`             | length of the sequence with name `seq name` | 
|   4 | `p/f`                 | `PASS` if this sequence PASSes, `FAIL` if it fails (has >= 1 fatal alert instances) |
|   5 | `model`               | name of the best-matching model for this sequence |
|   6 | `ftr type`            | type of the feature (e.g. CDS) |
|   7 | `ftr name`            | name of the feature |
|   8 | `ftr len`             | length of the annotated feature in nucleotides in input sequence |
|   9 | `ftr idx`             | index (in input model info file) of this feature |
|  10 | `str`                 | strand on which the feature is annotated: `+` for positive/forward/Watson strand, `-` for negative/reverse/Crick strand |
|  11 | `n_from`              | nucleotide start position for this feature in input sequence |
|  12 | `n_to`                | nucleotide end position for this feature in input sequence |
|  13 | `n_instp`             | nucleotide position of stop codon not at `n_to`, or `-` if none, will be 5' of `n_to` if early stop (`cdsstopn` alert), or 3' of `n_to` if first stop is 3' of `n_to` (`mutendex` alert), or `?` if no in-frame stop exists 3' of `n_from`; will always be `-` if `trunc` is not `no`; |
|  14 | `trc`                 | indicates whether the feature is truncated or not, where one or both ends of the feature are missing due to a premature end to the sequence; possible values are `no` for not truncated; `5'` for truncated on the 5' end; `3'` for truncated on the 3' end; and `5'&3'` for truncated on both the 5' and 3' ends; |
|  15 | `p_from`              | nucleotide start position for this feature based on the blastx protein-validation step | 
|  16 | `p_to`                | nucleotide stop position for this feature based on the blastx protein-validation step | 
|  17 | `p_instp`             | nucleotide position of stop codon 5' of `p_to` if an in-frame stop exists before `p_to` |
|  18 | `p_sc`                | raw score of best blastx alignment |
|  19 | `nsa`                 | number of segments annotated for this feature |
|  20 | `nsn`                 | number of segments not annotated for this feature |
|  21 | `seq coords`          | sequence coordinates of feature, see [`format of coordinate strings`(#coordformat)] |
|  22 | `mdl coords`          | model coordinates of feature, see [`format of coordinate strings`(#coordformat)] |
|  23 | `ftr alerts`          | alerts that pertain to this feature, listed in format `SHORT_DESCRIPTION(alertcode)`, separated by commas if more than one, `-` if none |

### Explanation of `.mdl`-suffixed output files<a name="mdlformat"></a>

`.mdl` data lines have 7 fields, the names of which appear in the
first two comment lines in each file. There is one data line for each
**model** that is the best-matching model for at least one sequence in
the input file, plus 2 additional lines, a line with `*all*` in the
`model` field reports the summed counts over all models, and a line
with `*none*` in the `model` field reports the summed counts for all
sequences that did not match any models. This information is also
included in the `.log` output file.

| idx | field                 | description |
|-----|-----------------------|-------------|
|   1 | `idx`                 | index of model | 
|   2 | `model`               | name of model | 
|   3 | `group`               | group of model, defined in model info file, or `-` if none |
|   4 | `subgroup`            | subgroup of model, defined in model info file, or `-`' if none | 
|   5 | `num seqs`            | number of sequences for which this model was the best-matching model |
|   6 | `num pass`            | number of sequences from `num seqs` that passed with 0 fatal alerts | 
|   7 | `num fail`            | number of sequences from `num seqs` that failed with >= 1 fatal alerts | 

### Explanation of `.sgm`-suffixed output files<a name="sgmformat"></a>

`.sgm` data lines have 21 fields, the names of which appear in the
first two comment lines in each file. There is one data line for each
**segment** of a feature that is annotated for each input sequence
file that `v-annotate.pl` processed. Each feature is composed of
1 or more segments, as defined by the `coords` field in the model info
file. 

| idx | field                 | description |
|-----|-----------------------|-------------|
|   1 | `idx`                 | index of segment in format `<d1>.<d2>.<d3> where `<d1>` is the index of the sequence in which this segment is annotated in the input sequence file, `<d2>` is the index of the feature (range 1..`<n1>`, where `<n1>` is the number of features annotated for this sequence) and `<d3>` is the index of the segment annotated within that feature (range 1..`<n2>` where `<n2>` is the number of segments annotated for this feature | 
|   2 | `seq name`            | sequence name in which this feature is annotated |
|   3 | `seq len`             | length of the sequence with name `seq name` | 
|   4 | `p/f`                 | `PASS` if this sequence PASSes, `FAIL` if it fails (has >= 1 fatal alert instances) |
|   5 | `model`               | name of the best-matching model for this sequence |
|   6 | `ftr type`            | type of the feature (e.g. CDS) |
|   7 | `ftr name`            | name of the feature |
|   8 | `ftr idx`             | index (in input model info file) of this feature |
|   9 | `num sgm`             | number of segments annotated for this sequence/feature pair |
|  10 | `sgm idx`             | index (in feature) of this segment |
|  11 | `seq from`            | nucleotide start position for this segment in input sequence, will be <= `seq to` if strand (`str`) `-` |
|  12 | `seq to`              | nucleotide end position for this segment in input sequence, will be >= `seq from` if strand (`str`) `-` |
|  13 | `mdl from`            | model start position for this segment, will be <= `mdl to` if strand (`str`) `-` | |
|  14 | `mdl to`              | model end position for this segment, will be >= `mdl from` if strand (`str`) `-` | |
|  15 | `sgm len`             | length, in nucleotides, for this annotated segment in the input sequence |
|  16 | `str`                 | strand (`+` or `-`) for this segment in the input sequence |
|  17 | `trc`                 | indicates whether the segment is truncated or not, where one or both ends of the segment are missing due to a premature end to the sequence; possible values are `no` for not truncated; `5'` for truncated on the 5' end; `3'` for truncated on the 3' end; and `5'&3'` for truncated on both the 5' and 3' ends; |
|  18 | `5' pp`               | posterior probability of the aligned nucleotide at the 5' boundary of the segment, or `-` if 5' boundary aligns to a gap (possibly due to a 5' truncation) }
|  19 | `3' pp`               | posterior probability of the aligned nucleotide at the 3' boundary of the segment, or `-` if 3' boundary aligns to a gap (possibly due to a 3' truncation) }
|  20 | `5' gap`              | `yes` if the 5' boundary of the segment is a gap (possibly due to a 5' truncation), else `no` }
|  21 | `3' gap`              | `yes` if the 3' boundary of the segment is a gap (possibly due to a 3' truncation), else `no` }

### Explanation of `.sqa`-suffixed output files<a name="sqaformat"></a>

`.sqa` data lines have 14 fields, the names of which appear in the
first two comment lines in each file. There is one data line for each
**sequence** in the input sequence file file that `v-annotate.pl`
processed. `.sqa` files include **annotation** information for each
sequence. `.sqc` files include **classification** information for each
sequence. 


| idx | field                 | description |
|-----|-----------------------|-------------|
|   1 | `seq idx`             | index of sequence in the input file |
|   2 | `seq name`            | sequence name | 
|   3 | `seq len`             | length of the sequence with name `seq name` | 
|   4 | `p/f`                 | `PASS` if this sequence PASSes, `FAIL` if it fails (has >= 1 fatal alert instances) |
|   5 | `ant`                 | `yes` if this sequence was annotated, `no` if not, due to a per-sequence alert that prevents annotation |
|   6 | `best model`          | name of the best-matching model for this sequence |
|   7 | `grp`                 | group of model `best model`, defined in model info file, or `-` if none |
|   8 | `subgp`               | subgroup of model `best model`, defined in model info file, or `-`' if none | 
|   9 | `nfa`                 | number of features annotated for this sequence |
|  10 | `nfn`                 | number of features in model `best model` that are not annotated for this sequence |
|  11 | `nf5`                 | number of annotated features that are 5' truncated |
|  12 | `nf3`                 | number of annotated features that are 3' truncated |
|  13 | `nfalt`               | number of per-feature alerts reported for this sequence (does not count per-sequence alerts) |
|  14 | `seq alerts`          | per-sequence alerts that pertain to this sequence, listed in format `SHORT_DESCRIPTION(alertcode)`, separated by commas if more than one, `-` if none |

### Explanation of `.sqc`-suffixed output files<a name="sqaformat"></a>

`.sqc` data lines have 21 fields, the names of which appear in the
first two comment lines in each file. There is one data line for each
**sequence** in the input sequence file file that `v-annotate.pl`
processed. `.sqc` files include **classification** information for
each sequence.  `.sqa` files include **annotation** information for
each sequence. For more information on bit scores and `bias` see the Infernal User's Guide
(http://eddylab.org/infernal/Userguide.pdf)

| idx | field                 | description |
|-----|-----------------------|-------------|
|   1 | `seq idx`             | index of sequence in the input file |
|   2 | `seq name`            | sequence name | 
|   3 | `seq len`             | length of the sequence with name `seq name` | 
|   4 | `p/f`                 | `PASS` if this sequence PASSes, `FAIL` if it fails (has >= 1 fatal alert instances) |
|   5 | `ant`                 | `yes` if this sequence was annotated, `no` if not, due to a per-sequence alert that prevents annotation |
|   6 | `model1`              | name of the best-matching model for this sequence, this is the model with the top-scoring hit for this sequence in the classification stage |
|   7 | `grp1`                | group of model `model1`, defined in model info file, or `-` if none |
|   8 | `subgrp1`             | subgroup of model `model1`, defined in model info file, or `-` if none |
|   9 | `score`               | summed bit score for all hits on strand `str` to model `model1` for this sequence in the classification stage |
|  10 | `sc/nt`               | bit score per nucleotide; `score` divided by total length (in sequence positions) of all hits to model `model1` on strand `str` in the classification stage |
|  11 | `seq cov`             | fraction of sequence positions (`seq len`) covered by any hit to model `model1` on strand `str` in the coverage determination stage | 
|  12 | `mdl cov`             | fraction of model positions (model length - the number of reference positions in `model1`) covered by any hit to model `model1` on strand `str` in the coverage determination stage | 
|  13 | `bias`                | summed bit score due to biased composition (deviation from expected nucleotide frequencies) of all hits on strand `str` to model `model1` for this sequence in the coverage determination stage |
|  14 | `num hits`            | number of hits on strand `str` to model `model1` for this sequence in the coverage determination stage |
|  15 | `str`                 | strand with the top-scoring hit to `model1` for this sequence in the classification stage |
|  16 | `model2`              | name of the second best-matching model for this sequence, this is the model with the top-scoring hit for this sequence across all hits that are not to `model1` in the classification stage |
|  17 | `grp2`                | group of model `model2`, defined in model info file, or `-` if none |
|  18 | `subgrp2`             | subgroup of model `model2`, defined in model info file, or `-`' if none | 
|  19 | `score diff`          | bit score difference between summed bit score for all hits to `model1` on strand `str` and summed bit score for all hits to `model2` on strand with top-scoring hit to `model2` in the classification stage |
|  20 | `diff/nt`             | bit score difference per nucleotide; `sc/nt` minus sc2/nt where sc2/nt is summed bit score for all hits to `model2` on strand with top-scoring hit to `model2` in the classification stage |
|  21 | `seq alerts`          | per-sequence alerts that pertain to this sequence, listed in format `SHORT_DESCRIPTION(alertcode)`, separated by commas if more than one, `-` if none |

TODO:
* `v-build.pl` output formats (including `modelinfo`)
* `coords` field in modelinfo explanation
* `posterior probability` explanation