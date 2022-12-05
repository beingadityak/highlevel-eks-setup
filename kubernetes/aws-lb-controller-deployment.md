# Instructions for deploying AWS LB controller Helm chart

## Pre-requisites

Make sure that you replace the IAM role annotation (under `serviceAccount`) for the AWS LB Controller in order to be able to create ingresses via Kubernetes manifests.


## Helm installation command

Following command to be used for installing AWS LB controller in EKS cluster:

```
helm install -n kube-system --version 1.4.6 aws-load-balancer-controller aws-load-balancer-controller --repo https://aws.github.io/eks-charts --values ./aws-lb-controller-values.yaml  --atomic --debug
```