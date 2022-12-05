# Kubernetes deployments for NodeJS application

This directory contains the code for the following deployments:

1. KEDA helm values and HPA (horizontal pod autoscaler) configuration
2. AWS Load Balancer Controller Helm chart values
3. Node.js application deployment, service and ingress manifests
4. Deployment steps for AWS LB controller & KEDA helm charts

The cluster uses AWS LB controller for ingress in the application and KEDA for performing auto-scaling actions.