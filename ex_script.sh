#!/usr/bin/env bash

#set -x
# Main loop for the lambda, function must be called "handler" to work with lambda_bash
handler () {
    # must exit on errors
    set -e

    # The Event that triggered this script is provided as json as arg to function
    EVENT_DATA=$1
    # Print the event information
    echo "EVENT DATA: `echo $EVENT_DATA | jq`"
    echo

    # See buckets
    echo "list of s3 buckets"
    aws s3 ls
    echo

    # if this lambda was triggered by a s3 event, show the bucket content
    if [ $EVENT_DATA ]; then
        BUCKET=`echo $EVENT_DATA | jq -r .Records[0].s3.bucket.name`
        KEY=`echo $EVENT_DATA | jq -r .Records[0].s3.object.key`
        echo "listing s3 bucket $BUCKET that triggered this lambda with $KEY"
        aws s3 ls $BUCKET
        echo
    fi
}
