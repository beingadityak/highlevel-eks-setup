# Helm installation instructions for KEDA in EKS cluster

## Pre-requisites

Make sure that you replace the IAM role annotation (under `serviceAccount`) for the KEDA operator in order to be able to query CloudWatch metrics for scaling actions.


## Helm installation command
Following command to be used for deploying KEDA in EKS cluster:

```
helm repo add kedacore https://kedacore.github.io/charts
kubectl create namespace keda
helm upgrade --install keda kedacore/keda --namespace keda --version 2.8.2 --atomic --debug --values ./keda/keda-helm-values.yaml
```