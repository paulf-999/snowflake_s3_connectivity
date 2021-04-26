## Snowflake-S3-Connectivity

Automation script to orchestrate of the steps required establish comms between an S3 bucket and Snowflake, using Snowflake Storage Integration objects.

### High-level summary

A `makefile` has been used to orchestrate the steps required to create a Snowflake Storage Integration object. Where these steps consist of:

1) Updating the S3 Bucket Policies for the source S3 bucket
    * To allow communication from the VPC ID of the  cluster
2) Creating an AWS IAM role, initially with a trust policy against your AWS account ID (this is subsequently revised in step 4)
3) Creating the Snowflake Storage Integration Object
4) And then revising the IAM role created in step 2, to use Snowflake-generated IAM entity details

### How-to run:

The steps involved in building and executing involve:

1) Updating the input parameters within `env/env.json`
2) and running `make -f setup_s3_connectivity.mk`!