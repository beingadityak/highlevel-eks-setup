# Helm installation instructions for KEDA in EKS cluster

Following command to be used for deploying KEDA in EKS cluster:

```
helm repo add kedacore https://kedacore.github.io/charts
kubectl create namespace keda
helm upgrade --install keda kedacore/keda --namespace keda --version 2.8.2 --atomic --debug --values ./keda/keda-helm-values.yaml
```