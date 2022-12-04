# Instructions for deploying AWS LB controller Helm chart

```
helm install -n kube-system --version 1.4.6 aws-load-balancer-controller aws-load-balancer-controller --repo https://aws.github.io/eks-charts --values ./aws-lb-controller-values.yaml  --atomic --debug
```