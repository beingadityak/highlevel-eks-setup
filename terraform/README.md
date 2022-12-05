# Terraform Code for EKS cluster

This directory contains the code for creating EKS cluster as well as relevant dependent resources.

Following is the list of resources created by this TF code:

1. IAM roles for KEDA & AWS LB controller helm manifests
2. VPC for deploying the cluster
3. EKS cluster itself
4. ECR repository for Node.js Application

Also note that the ECR deployment is automated via Github Actions and is deployed on push for main branch whenever there's a change in the application (`/app` directory)

The states are set in a remote S3 bucket and need to be created before-hand in order to deploy the infrastructure in another account.

This code uses the following external Terraform modules for deploying the cluster:

1. AWS VPC module
2. AWS EKS module