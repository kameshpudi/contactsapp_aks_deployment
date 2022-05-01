#!/bin/bash

location=westeurope
aks_rg=kpr-aks-rg
aks_cluster_name=kpr-cluster
acr_name=kpracrcluster
aks_deployment_namespace=contactsapp
aks_monitoring_namespace=monitoring
aks_ingress_namespace=ingress
aks_ssl_namespace=contacts-certmanager
aks_ingress_name=contactsingress

az group create --name $aks_rg --location $location

az aks create --resource-group $aks_rg --name $aks_cluster_name --enable-managed-identity --generate-ssh-keys --kubernetes-version 1.22.6

# az acr create --name $acr_name --resource-group $aks_rg --sku basic --admin-enabled

# # now let's attach the container registry to the cluster
az aks update --resource-group $aks_rg --name $aks_cluster_name --attach-acr $acr_name

# # AKS login
az aks get-credentials --resource-group $aks_rg --name $aks_cluster_name

# ACR login

ACRPWD=$(az acr credential show -n $acr_name --query "passwords[0].value" -o tsv)
docker login $acr_name.azurecr.io -u $acr_name -p $ACRPWD


cd ../../
# contacts api:
az acr build -r $acr_name -t $acr_name.azurecr.io/adc-contacts-api:2.0 -f ./src/apps/dotnetcore/Scm/Adc.Scm.Api/Dockerfile ./src/apps/dotnetcore/Scm

# resources api:
az acr build -r $acr_name -t $acr_name.azurecr.io/adc-resources-api:2.0 ./src/apps/dotnetcore/Scm.Resources/Adc.Scm.Resources.Api

# Image resize function:
az acr build -r $acr_name -t $acr_name.azurecr.io/adc-resources-func:2.0 ./src/apps/dotnetcore/Scm.Resources/Adc.Scm.Resources.ImageResizer

# Search API:
az acr build -r $acr_name -t $acr_name.azurecr.io/adc-search-api:2.0 ./src/apps/dotnetcore/Scm.Search/Adc.Scm.Search.Api

# Search Indexer:
az acr build -r $acr_name -t $acr_name.azurecr.io/adc-search-func:2.0 ./src/apps/dotnetcore/Scm.Search/Adc.Scm.Search.Indexer

# Visitors API:
az acr build -r $acr_name -t $acr_name.azurecr.io/adc-visitreports-api:2.0 ./src/apps/nodejs/visitreport

# Text Analytics Function:
az acr build -r $acr_name -t $acr_name.azurecr.io/adc-textanalytics-func:2.0 ./src/apps/nodejs/textanalytics

# UI:
az acr build -r $acr_name -t $acr_name.azurecr.io/adc-frontend-ui:2.0 ./src/apps/frontend/scmfe

# Execute TF 0_tf
cd ../src/aks-config/deployment/0_tf
terraform -chdir=./src/aks-config/deployment/0_tf init
terraform -chdir=./src/aks-config/deployment/0_tf apply --auto-approve
terraform -chdir=./src/aks-config/deployment/0_tf output -json > ./src/aks-config/deployment/0_tf/azure_output.json

cd /

Execute 1_tf to update secrets and configmap with Base64 values
cd src/aks-config/deployment/1_config
./src/aks-config/deployment/1_config/
./replace_variables.sh

AKS namespace
kubectl create ns $aks_deployment_namespace
kubectl config set-context --current --namespace=$aks_deployment_namespace

kubectl apply -f ./src/aks-config/deployment/1_config/local-configmap.yaml --namespace $aks_deployment_namespace
kubectl apply -f ./src/aks-config/deployment/1_config/local-secrets.yaml --namespace $aks_deployment_namespace

kubectl create ns $aks_ingress_namespace
#Create Ingress and SSL
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
# To do
#helm upgrade $aks_ingress_name --install ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace $aks_ingress_namespace --set controller.service.externalTrafficPolicy=Local

# #Get Ingress Public IP
kubectl --namespace $aks_ingress_namespace get services $aks_ingress_name-ingress-nginx-controller

#Secure Endpoints with SSL:
kubectl create ns $aks_ssl_namespace
helm repo add jetstack https://charts.jetstack.io
helm repo update

cd bonus_1 directory
helm upgrade -i -f ./src/aks-config/deployment/ssl/cert-manager-values.yaml --namespace $aks_ssl_namespace cert-manager jetstack/cert-manager
kubectl apply -f ./src/aks-config/deployment/ssl/encrypt-contacts-cluster-issuer.yaml --namespace $aks_ssl_namespace

# Update ymls with ACR and Ingress Public IP in respective yml files then apply yaml files 2_apis, 3_functions, 4_frontend

kubectl apply -f ./src/aks-config/deployment/2_apis/1_contactsapi --namespace $aks_deployment_namespace
kubectl apply -f ./src/aks-config/deployment/2_apis/2_resourcesapi --namespace $aks_deployment_namespace
kubectl apply -f ./src/aks-config/deployment/2_apis/3_searchapi --namespace $aks_deployment_namespace
kubectl apply -f ./src/aks-config/deployment/2_apis/4_visitreports --namespace $aks_deployment_namespace

kubectl apply -f ./src/aks-config/deployment/3_functions/1_resourcesfunc --namespace $aks_deployment_namespace
kubectl apply -f ./src/aks-config/deployment/3_functions/2_searchfunc --namespace $aks_deployment_namespace
kubectl apply -f ./src/aks-config/deployment/3_functions/3_textanalyticsfunc --namespace $aks_deployment_namespace

kubectl apply -f ./src/aks-config/deployment/4_frontend/1_ui --namespace $aks_deployment_namespace

##############################
# Prometheus Setup
##############################

kubectl create ns $aks_monitoring_namespace

kubectl create -f ./src/aks-monitoring/clusterRole.yaml  --namespace $aks_monitoring_namespace
kubectl apply -f ./src/aks-monitoring/config-map.yaml --namespace $aks_monitoring_namespace
kubectl create  -f ./src/aks-monitoring/prometheus-deployment.yaml --namespace $aks_monitoring_namespace
#Update ingress .yml with Ingress Controller Public IP
kubectl create -f ./src/aks-monitoring/prometheus-service.yaml --namespace $aks_monitoring_namespace
kubectl create -f ./src/aks-monitoring/prometheus-ingress.yaml --namespace $aks_monitoring_namespace

##############################
# AlertManager Setup
##############################

kubectl create -f ./src/aks-alertmanager/AlertManagerConfigmap.yaml  --namespace $aks_monitoring_namespace
kubectl create -f ./src/aks-alertmanager/AlertTemplateConfigmap.yaml --namespace $aks_monitoring_namespace
kubectl create -f ./src/aks-alertmanager/Deployment.yaml --namespace $aks_monitoring_namespace
kubectl create -f ./src/aks-alertmanager/Service.yaml --namespace $aks_monitoring_namespace
kubectl apply -f ./src/aks-alertmanager/AlertManagerIngress.yaml --namespace $aks_monitoring_namespace

##############################
# Grafana Setup
##############################

kubectl create -f ./src/grafana/grafana-datasource-config.yaml  --namespace $aks_monitoring_namespace
kubectl create -f ./src/grafana/deployment.yaml --namespace $aks_monitoring_namespace
kubectl create -f ./src/grafana/service.yaml --namespace $aks_monitoring_namespace
kubectl create -f ./src/grafana/ingress.yaml --namespace $aks_monitoring_namespace