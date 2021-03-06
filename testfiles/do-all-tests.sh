#!/bin/bash

RETVAL=0;

# Run tests in t/ subdir
for t in \
    do-prove-all-tests.sh \
    ; do
    sh $VADRSCRIPTSDIR/t/$t teamcity
    if [ $? != 0 ]; then
        RETVAL=1;
    fi   
done

# Run sequip tests in sequip/t/ subdir
for t in \
    do-prove-all-tests-from-vadr.sh \
    ; do
    sh $VADRSEQUIPDIR/t/$t teamcity
    if [ $? != 0 ]; then
        RETVAL=1;
    fi   
done

# If you want to test -p option for parallelization, add
# do-install-tests-parallel.sh to the following for loop.
# Note: this test requires qsub is in your path and qsub options are
# configured similarly to ncbi cluster, email eric.nawrocki@nih.gov
# for information on how to configure for different clusters
for t in \
    do-install-tests-local.sh \
    do-fs-tests.sh \
    do-replace-tests.sh \
    do-seed-tests.sh \
    do-hmmer-tests.sh \
    do-nindel-tests.sh \
    do-outaln-tests.sh \
    do-mxsize-tests.sh \
    do-uj-tests.sh \
    do-noftr-tests.sh \
    do-nends-tests.sh \
    do-ftskipfl-tests.sh \
    github-issues/do-issue-tests.sh \
    ; do
    sh $VADRSCRIPTSDIR/testfiles/$t
    if [ $? != 0 ]; then
        RETVAL=1;
    fi   
done

if [ $RETVAL == 0 ]; then
   echo "Success: all tests passed"
   exit 0
else 
   echo "FAIL: at least one test failed"
   exit 1
fi
