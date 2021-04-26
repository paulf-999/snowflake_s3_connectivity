default: get_snowflake_vpcid update_s3_bucket_policies create_tmp_snowflake_iam_role create_sf_storage_int_obj create_snowflake_iam_role

# fetch inputs from config (json) file
SNOWFLAKE_CONN_PROFILE=#name of your snowsql connection profile
CONFIG_FILE=
SNOWSQL_QUERY_OPTS=snowsql -c ${SNOWFLAKE_CONN_PROFILE} -o friendly=false -o header=false -o timing=false
AWS_PROFILE=#your AWS credentials profile, e.g. ${MY_AWS_PROFILE}

#$(eval [VAR_NAME]=$(shell jq '.Parameters.[VAR_NAME]' ${CONFIG_FILE}))
$(eval PROGRAM=$(shell jq '.Parameters.Program' ${CONFIG_FILE}))
$(eval PROGRAM_LOWER = $(shell echo $(PROGRAM) | tr 'A-Z' 'a-z'))
$(eval ENV=$(shell jq '.Parameters.Environment' ${CONFIG_FILE}))
$(eval AWS_ACCOUNT_ID=$(shell jq '.Parameters.AwsAccountId' ${CONFIG_FILE}))
$(eval SNOWFLAKE_VPCID=$(shell jq '.Parameters.SnowflakeParameters.SnowflakeVPCID' ${CONFIG_FILE}))
$(eval SNOWFLAKE_IAM_ROLE_NAME=$(shell jq '.Parameters.SnowflakeParameters.SnowflakeIAMRoleName' ${CONFIG_FILE}))
$(eval SNOWFLAKE_ACCOUNT_NAME=$(shell jq '.Parameters.SnowflakeParameters.SnowflakeAccountName' ${CONFIG_FILE}))
$(eval S3_BUCKET=$(shell jq '.Parameters.AdditionalParameters.S3Bucket' ${CONFIG_FILE}))
$(eval CAPABILITIES=$(shell jq '.Parameters.AdditionalParameters.CloudFormationStackCapabilities' ${CONFIG_FILE}))
CAPABILITIES=CAPABILITY_IAM CAPABILITY_NAMED_IAM
S3_BUCKET_LIST='s3://${S3_BUCKET}'#,'s3://${S3_BUCKET_NEXUS}','s3://${S3_BUCKET_GENESYS}'

deps:
	$(info [+] Install dependencies (snowsql))
	# need to source your bash_profile, post-install
	brew cask install snowflake-snowsql && . ~/.bash_profile

get_snowflake_vpcid:
	$(info [+] Get Snowflake's VPCID)
	@${SNOWSQL_QUERY_OPTS} -q 'SELECT system$$get_snowflake_platform_info();' -r accountadmin > op/stg/snowflake-query-op/snowflake-vpcid.txt

update_s3_bucket_policies:
	$(info [+] Change S3 bucket policies, to allow communication from Snowflake's VPC ID)
	@$(eval VPCID=$(shell python3 py/parse_snowflake_op.py get_snowflake_vpcid ${SNOWFLAKE_ACCOUNT_NAME}))
	@aws cloudformation create-stack \
	--profile ${AWS_PROFILE} \
	--stack-name ${PROGRAM}-s3-bucket-policy-update-for-snowflake \
	--template-body file://aws/cfn/s3/bucket-policy/s3-bucket-policy-snowflake.yml \
	--parameters ParameterKey=S3BucketName,ParameterValue=${S3_BUCKET} \
	ParameterKey=VPCID,ParameterValue=$(SNOWFLAKE_VPCID) \

create_tmp_snowflake_iam_role:
	$(info [+] Create a tmp Snowflake IAM role, to allow a SF storage int object to be initially created)
	#1) Create a temporary Snowflake IAM role
	@aws cloudformation create-stack \
	--profile ${AWS_PROFILE} \
	--stack-name ${PROGRAM_LOWER}-iam-role-tmp-snowflake-access \
	--capabilities ${CAPABILITIES} \
	--template-body file://aws/cfn/iam/tmp/snowflake-tmp-iam-role.yml \
	--parameters ParameterKey=IAMRoleName,ParameterValue=tmp-${SNOWFLAKE_IAM_ROLE_NAME} \
	ParameterKey=TrustedAccountID,ParameterValue=${AWS_ACCOUNT_ID}

create_sf_storage_int_obj:
	#1) Create a storage integration object
	@${SNOWSQL_QUERY_OPTS} -o quiet=true -f sql/dwh/account-objects/storage-integration/v1-create-s3-storage-integration.sql -D PROGRAM=${PROGRAM} -D ENV=${ENV} -D IAMROLENAME=${SNOWFLAKE_IAM_ROLE_NAME} -D AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID} -D ALLOWED_S3_LOCATIONS="${BUCKET_LIST}"
	#2) Grant usage permissions of Storage Integration object to '{PROGRAM}_{ENV}_SI_ADMIN' (storage integration admin)
	@${SNOWSQL_QUERY_OPTS} -o quiet=true -f sql/dwh/account-objects/role/v1-create-role-sf-si-admin.sql -D PROGRAM=${PROGRAM} -D ENV=${ENV}
	@${SNOWSQL_QUERY_OPTS} -o quiet=true -f sql/dwh/account-objects/role/permissions/v1-grant-perms-to-sf-si-admin-role.sql -D PROGRAM=${PROGRAM} -D ENV=${ENV}
	#3) Capture the snowsql query op
	@${SNOWSQL_QUERY_OPTS} -q "desc integration ${PROGRAM}_${ENV}_S3_INT;" -r accountadmin > op/stg/snowflake-query-op/snowflake-iam-user.txt

create_snowflake_iam_role:
	$(info [+] Create the finalised Snowflake IAM role/policy, used to allow comms between AWS and Snowflake)
	#1) assign vars to the snowsql query op
	$(eval SNOWFLAKE_IAM_USER_ARN=$(shell python3 py/parse_snowflake_op.py get_snowflake_iam_user_arn ${SNOWFLAKE_ACCOUNT_NAME}))
	$(eval SNOWFLAKE_EXT_ID=$(shell python3 py/parse_snowflake_op.py get_ext_id ${SNOWFLAKE_ACCOUNT_NAME}))
	@echo
	@echo "SNOWFLAKE_IAM_USER_ARN = ${SNOWFLAKE_IAM_USER_ARN}"
	@echo "SNOWFLAKE_EXT_ID = ${SNOWFLAKE_EXT_ID}"
	@echo
	@aws cloudformation create-stack \
	--profile ${AWS_PROFILE} \
	--stack-name ${PROGRAM_LOWER}-iam-role-snowflake-access \
	--capabilities ${CAPABILITIES} \
	--template-body file://aws/cfn/iam/snowflake-iam-role.yml \
	--parameters ParameterKey=IAMRoleName,ParameterValue=${SNOWFLAKE_IAM_ROLE_NAME} \
	ParameterKey=SnowflakeUserARN,ParameterValue=${SNOWFLAKE_IAM_USER_ARN} \
	ParameterKey=SnowflakeExternalID,ParameterValue=${SNOWFLAKE_EXT_ID}

	#2) Then delete the stack of the temporary snowflake IAM role
	#@aws cloudformation delete-stack --stack-name ${PROGRAM_LOWER}-iam-role-tmp-snowflake-access --profile ${AWS_PROFILE}

del_cfn_stacks:
	$(info [+] Quickly delete cfn templates)
	rm -r op/stg/snowflake-query-op/
	@aws cloudformation delete-stack --stack-name ${PROGRAM}-iam-role-snowflake-access --profile ${AWS_PROFILE}
	@aws cloudformation delete-stack --stack-name ${PROGRAM}-iam-role-tmp-snowflake-access --profile ${AWS_PROFILE}
	