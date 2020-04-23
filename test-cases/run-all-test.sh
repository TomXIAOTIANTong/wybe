#!/bin/bash

exitcode=0
echo "--------------------------------------------------------"
echo "Final Dump Test"
echo "--------------------------------------------------------"
./final-dump-test.sh
[ $? -ne 0 ] && exitcode=1
echo "--------------------------------------------------------"
echo ""
echo "--------------------------------------------------------"
echo "Execution Test"
echo "--------------------------------------------------------"
./execution-test.sh
[ $? -ne 0 ] && exitcode=1
echo "--------------------------------------------------------"

exit $exitcode