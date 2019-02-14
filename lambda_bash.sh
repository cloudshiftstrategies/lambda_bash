#!/usr/bin/env bash
# This script deploys a bash shell script to AWS Lambda using AWS layers
# Thanks to https://github.com/gkrizek/bash-lambda-layer for the inspiration

# Some static variables suitable for functions
TIMEOUT=900 # 15 minutes
MEMORY_SIZE=1024 # 1GB
ASSUME_ROLE_POLICY=assume_role_policy.json
S3_EVENT_CONFIG=s3_event.json

#set -x
set -e 

# Usage
function print_usage {
    echo
    echo "Usage: $0 -o [deploy|run|tail|update|describe|destroy] -s script_name.sh [-r aws_region] [-p aws_policy] [-e event_arn] [-b bucket] [-h]"
    echo 
    echo " -o operation. generally deploy first, then run, then update, then destroy"
    echo " -s script. This is the bash script that you want to turn into a lambda"
    echo " -r aws region. (optional) if region is not provided will check AWS_DEFAULT_REGION env variable"
    echo " -p aws managed policy to attach to execution role. (optional) if not provided, default is AdministratorAccess"
    echo " -e event arn to trigger the lambda (Kinesis, DynamoDB Streams, SQS). (optional) default is None"
    echo " -b bucket name to trigger the lambda. (optional) default is None. Details of trigger defined in s3_event.json"
    echo
    echo "  Notes: the bash script must contain a function called \"handler\""
    echo "         parameters policy (-p) event (-e) & bucket (-b) are only used on deploy operations (not on update)."
    echo 
}

# Parse input parameters
while getopts ":o:s:r:p:e:b:h:" opt; do
    case "${opt}" in 
        o ) # the operation requested
            OPERATION=${OPTARG}
            ;;
        s ) # the script name
            SCRIPT=${OPTARG}
            ;;
        r ) # the region to deploy
            REGION=${OPTARG}
            ;;
        p ) # the aws managed policy to apply
            POLICY=${OPTARG}
            ;;
        e ) # The event arn to attach
            EVENT_ARN=${OPTARG}
            ;;
        b) # The s3 bucket to watch for events
            BUCKET=${OPTARG}
            ;;
        h ) # requested help
            print_usage
            exit 1
            ;;
        * ) # an unknown option was passed
            print_usage
            exit 1
            ;;
    esac
done

# Check for certain installed programs
for BIN in "aws jq"; do
    which $BIN > /dev/null
    if [ $? -ne 0 ]; then
        echo "ERROR: the executable: $BIN must be in PATH" 1>&2
        exit 1
    fi
done

# Check aws cli version
AWS_VERSION=`aws --version 2>&1 | awk '{print$1}' | awk -F'/' '{print$2}'`
AWS_REQUIRED=1.16.00 # for lambda layers support. # TODO: figure out when layers was really released in awscli
if [ $(printf '%s\n' $AWS_VERSION $AWS_REQUIRED | sort -rV | head -n 1) != $AWS_VERSION ]; then
    echo "ERROR: aws cli version must be $AWS_REQUIRED or greater" 1>&2
    exit 1
fi

# Check to make sure we have a valid operation
if [ -z $OPERATION ]; then
    # didnt get an operation
    echo "ERROR: did not get a valid operation via -o param" 1>&2
    print_usage
    exit 1
fi

# Check to make sure we have a valid script
if [ -z $SCRIPT ]; then
    # didnt get a script param
    echo "ERROR: must specify a script name with -s param" 1>&2
    print_usage
    exit 1
elif [ ! -f $SCRIPT ]; then
    # Script file doesnt exist
    echo "ERROR: script $SCRIPT does not exist" 1>&2
    exit 1
else
    # Everything seems ok.. set up the vars
    BASE_NAME=$(echo `basename ${SCRIPT}` | awk -F'.' '{print$1}')
    FUNCTION=${BASE_NAME}
    ZIP=${BASE_NAME}.zip
    HANDLER=${BASE_NAME}.handler
fi

# Check that we got a region
if [ -z $REGION ]; then
    # The REGION variable didnt get set from the -r param
    if [ $AWS_DEFAULT_REGION ]; then
        # If the default region env variable is set use that
        REGION=$AWS_DEFAULT_REGION
    else
        echo "ERROR: must specifiy a region via env variable AWS_DEFAULT_REGION or -r param" 1>&2
        print_usage
        exit 1
    fi
fi
# Check that the region name is valid
if [ `aws ec2 describe-regions | jq .Regions[].RegionName | grep -c $REGION` -lt 1 ]; then
    echo "ERROR: invalid region name specified: $REGION" 1>&2
    exit 1
fi
# Set the region environment var for the aws cli
export AWS_DEFAULT_REGION=$REGION

# Check to see if user specified an AWS policy name to attach to IAM role
if [ -z $POLICY ]; then
    # user didnt supply a policy. Default to Admin access
    POLICY_ARN=arn:aws:iam::aws:policy/AdministratorAccess
else
    # TODO: check the policy for validity
    # TODO: accept non AWS managed policies (user could provide an ARN)
    POLICY_ARN=arn:aws:iam::aws:policy/$POLICY
fi
# Define the name for the IAM role
ROLE_NAME=${BASE_NAME}_lambdarole

# The main loop
case $OPERATION in
    deploy ) # Deploy the IAM role and function from scratch
        # Create the role for the lambda
        if [ `aws iam list-roles | jq .Roles[].RoleName | grep -c $ROLE_NAME` -lt 1 ]; then
            echo "creating role $ROLE_NAME"
            # Create the file with the assume-role-policy-document
            # TODO: should validate if the role is already correct
            aws iam create-role \
                --role-name $ROLE_NAME \
                --assume-role-policy-document file://$ASSUME_ROLE_POLICY > /dev/null
            # Attach the policy
            echo "attaching IAM policy $POLICY_ARN to role $ROLE_NAME"
            aws iam attach-role-policy \
                --role-name $ROLE_NAME \
                --policy-arn $POLICY_ARN
            # Allow a second for role to attach
            SLEEP=20
            echo "sleeping $SLEEP seconds to allow role to attach"
            sleep $SLEEP
        fi
        # Get the role ARN
        ROLE_ARN=`aws iam get-role --role-name $ROLE_NAME | jq .Role.Arn | sed s/\"//g`

        # Deploy function
        # TODO: Should validate that the function is setup right first
        if [ `aws lambda list-functions | jq .Functions[].FunctionName | grep -c $FUNCTION` -lt 1 ]; then 
            zip $ZIP $SCRIPT > /dev/null
            echo "deploying function $FUNCTION"
            aws lambda create-function \
                --function-name $FUNCTION \
                --memory-size $MEMORY_SIZE \
                --timeout $TIMEOUT \
                --role $ROLE_ARN \
                --handler $HANDLER \
                --runtime provided \
                --layers arn:aws:lambda:$REGION:744348701589:layer:bash:3 \
                --zip-file fileb://$ZIP > /dev/null
            rm $ZIP
        else
            echo "WARNING: function $FUNCTION already deployed"
        fi
        # Attach the event ARN if defined
        if [ ! -z $EVENT_ARN ]; then
            # TODO: do some sanity checking on ARN names
            echo "attaching event source arn $EVENT_ARN to function $FUNCTION"
            aws lambda create-event-source-mapping \
                --function-name $FUNCTION \
                --event-source-arn $EVENT_ARN \
                --enabled
        fi
        # Attach the bucket notification if defined
        if [ ! -z $BUCKET ]; then
            # Get the deployed function arn
            FUNCTION_ARN=`aws lambda get-function --function-name $FUNCTION | jq .Configuration.FunctionArn | sed s/\"//g`
            # Update the s3_event config file with the correct function arn
            echo "updating s3 event config $S3_EVENT_CONFIG with FunctionArn: $FUNCTION_ARN"
            cat $S3_EVENT_CONFIG | cat s3_event.json | \
                jq --arg functionarn "$FUNCTION_ARN" '(.LambdaFunctionConfigurations[].LambdaFunctionArn = $functionarn)' > $S3_EVENT_CONFIG.tmp
            mv $S3_EVENT_CONFIG.tmp $S3_EVENT_CONFIG
            # Update the bucket to notify the lambda on event
            echo "adding permission for s3 to invoke function $FUNCTION"
            aws lambda add-permission \
                --function-name $FUNCTION \
                --statement-id "allow" \
                --action "lambda:InvokeFunction" \
                --principal s3.amazonaws.com \
                --source-arn "arn:aws:s3:::$BUCKET" > /dev/null
            echo "attaching bucket-notification to bucket $BUCKET for lambda $FUNCTION with config $S3_EVENT_CONFIG"
            aws s3api put-bucket-notification-configuration \
                --bucket $BUCKET \
                --notification-configuration file://$S3_EVENT_CONFIG
        fi
        ;;

    update ) # update the code (note, does not update lambda params or IAM role, even if speficified)
        # TODO: check the validity of role an lambda params on update 
        if [ `aws lambda list-functions | jq .Functions[].FunctionName | grep -c $FUNCTION` -lt 1 ]; then 
            echo "ERROR: lambda function $FUNCTION does not exist" 2>&1
            exit 1
        else
            zip $ZIP $SCRIPT > /dev/null
            echo "Updating function $FUNCTION code"
            aws lambda update-function-code \
                --function-name $FUNCTION \
                --zip-file fileb://$ZIP > /dev/null
        fi
        rm $ZIP
        ;;

    run ) # run the script as a lambda, print result to stdout
        if [ `aws lambda list-functions | jq .Functions[].FunctionName | grep -c $FUNCTION` -lt 1 ]; then 
            echo "ERROR: lambda function $FUNCTION does not exist" 2>&1
            exit 1
        else
            echo "invoking lambda $FUNCTION"
            echo "---------START RESPONSE------------"
            aws lambda invoke \
                --function-name $FUNCTION \
                --log-type Tail /dev/null \
                | jq .LogResult | sed s/\"//g | base64 --decode
            echo "---------END RESPONSE------------"
        fi
        ;;

    destroy ) # Delete the lambda and role
        if [ `aws lambda list-functions | jq .Functions[].FunctionName | grep -c $FUNCTION` -lt 1 ]; then 
            echo "WARNING: lambda function $FUNCTION does not exist"
        else
            echo "deleting lambda $FUNCTION"
            aws lambda delete-function \
                --function-name $FUNCTION
        fi
        if [ `aws iam list-roles | jq .Roles[].RoleName | grep -c $ROLE_NAME` -lt 1 ]; then 
            echo "WARNING: role $ROLE_NAME does not exist"
        else
            for POLICY_ARN in `aws iam list-attached-role-policies --role-name $ROLE_NAME | jq .AttachedPolicies[].PolicyArn | sed s/\"//g`; do
                echo "detaching POLICY_ARN $POLICY_ARN from Role $ROLE_NAME"
                aws iam detach-role-policy \
                    --role-name $ROLE_NAME \
                    --policy-arn $POLICY_ARN
            done
            echo "deleting ROLE: $ROLE_NAME"
            aws iam delete-role --role-name $ROLE_NAME
        fi
        ;;

    describe ) # get function attributes
        if [ `aws lambda list-functions | jq .Functions[].FunctionName | grep -c $FUNCTION` -lt 1 ]; then 
            echo "WARNING: lambda function $FUNCTION does not exist"
        else
            echo "getting lambda $FUNCTION"
            aws lambda get-function \
                --function-name $FUNCTION
        fi
        ;;

    tail ) # tail the cloudwatch logs
        GROUP_NAME="/aws/lambda/$FUNCTION"
        START_SECONDS_AGO=3600
        # Get the UTC time in mili seconds where we want to start
        START_TIME=$(( (`date -u +"%s"`-$START_SECONDS_AGO) * 1000 ))
        while true; do
            # Pull a list of log lines since the start time
            LOGLINES=`aws logs filter-log-events --log-group-name "$GROUP_NAME" --interleaved --start-time $START_TIME`
            # Determine the timestamp of the last log entry
            LAST_LOG_TIME=`echo $LOGLINES | jq -r .events[].timestamp | sort -n | tail -1`
            if [ $LAST_LOG_TIME ]; then
                # Set the start time to be the last log time +1
                START_TIME=$(( $LAST_LOG_TIME + 1 ))
            else
                # We didnt pull any logs in the last iteration, so add 1 mili-second to the old START_TIME
                START_TIME=$(( $START_TIME + 1 ))
            fi
            # Print the timestamps and the log messages
            echo $LOGLINES | jq -j '.events[] | (.timestamp / 1000 | strftime("%Y-%m-%d_%H:%M:%S") ) + " - " + .message'
            #echo $LOGLINES | jq -j '.events[].message'
            sleep 2
        done
        ;;

    * )
        echo "ERROR: unknown operation type $OPERATION" 2>&1
        print_usage
        exit 1
        ;;

esac

