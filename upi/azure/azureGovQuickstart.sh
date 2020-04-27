#!/bin/bash

# Initialize global variables
VERBOSE=no
LOGOUTPUT=no
WORKERNODES=3
OCPRELEASE=4.3
LOGFILE=quickstart.log

function try()
{
    [[ $- = *e* ]]; SAVED_OPT_E=$?
    set +e
}

function throw()
{   
    while [[ "$1" != "" ]]; do
      echo $1  > /dev/stderr
      shift
    done
    exit 1
}

function catch()
{
    export ex_code=$?
    (( $SAVED_OPT_E )) && set +e
    return $ex_code
}

function throwErrors()
{
    set -e
}

function ignoreErrors()
{
    set +e
}

function cleanupError()
{
    set +x
}

function help() 
{
      echo "Create UPI OCP $OCPRELEASE on Azure MAG, see Readme"
      echo " "
      echo "options:"
      echo "-h, --help                show brief help"
      echo "-w, --worker-nodes=number specify number of worker nodes, 3 default"
      echo "--login                   Perform az login prompting for user credentials"
      echo "--verbose                 Verbose output from Azure commands"
      echo "--log-output              Log output to a file"
      exit 0
 }

function echoDo()
# $1: Description
# $2: Command
{
    redirect=""
    if [ "$LOGOUTPUT" == "yes" ]; then
      redirect="| tee -a ${LOGFILE}"
    fi
    echo "Task: $1" $redirect
    shift
    C=''
    for i in "$@"; do 
       i="${i//\\/\\\\}"
       C="$C \"${i//\"/\\\"}\""
    done
    echo $C
    eval $C $redirect
    res=$?
    echo "--->> Result Code $res" $redirect
    return $res
}

# Display help before checking for executables called during parameter checks
if [ "$1" == "-h" -o "$1" == "--help" ]; then
  help
  exit 0
fi

echo "Making sure all the correct applications are in your path"
echo "checking az cli"
which az &>/dev/null || throw "Az cli is not installed, please install. https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest"
echo "checking jq"
which jq &>/dev/null || throw "jq is not installed, please install. https://stedolan.github.io/jq/download/"
echo "checking yq"
which yq &>/dev/null || throw "jq is not installed, please install. https://github.com/mikefarah/yq/releases"
echo "checking oc client"
which oc &>/dev/null || throw "oc is not installed, please install. https://docs.openshift.com/container-platform/$OCPRELEASE/cli_reference/openshift_cli/getting-started-cli.html#cli-installing-cli_cli-developer-commands"
echo "checking kubectl"
which kubectl &>/dev/null || throw "kubectl is not installed, please install. https://kubernetes.io/docs/tasks/tools/install-kubectl/"
echo "checking openshift-install"
which openshift-install &>/dev/null || throw "openshift-install is not installed, please install. https://docs.openshift.com/container-platform/$OCPRELEASE/installing/installing_azure/installing-azure-default.html#installation-obtaining-installer_installing-azure-default"

while test $# -gt 0; do
  case "$1" in
    -h|--help)
     help
     exit 0
     ;;
    -w)
      shift
      if test $# -gt 0; then
        WORKERNODES=$1
      else
        WORKERNODES=3
      fi
      ;;
    --worker-nodes*)
      WORKERNODES=$(echo $1 | sed -e 's/^[^=]*=//g')
      ;;
    --login)
      az login || throw "Unable to login to azure" 
      ;;
    --verbose)
      VERBOSE=yes
      ;;
    --log-output)
      LOGOUTPUT=yes
      ;;
    *)
      break
      ;;
  esac
  shift
done

# Begin processing
throwErrors

az vm list -o none &>> /dev/null
azure_ok=$?
echo "Azure Check result $azure_ok"
if [[ $azure_ok > 0 ]]; then
   throw "No valid Azure session. Try az login again"
   exit 1
fi
az cloud set -n AzureUSGovernment

azout="-o none"

if [[ "$VERBOSE" == "yes" ]]; then
  azout="-o json"
fi

if [ ! -f install-config.yaml ]; then
  echo Missing "install-config.yaml" >/dev/stderr
  echo Please create install-config.yaml using template in README.md > /dev/stderr
  exit 1
fi 

CLUSTER_NAME=$(yq -r .metadata.name install-config.yaml)
AZURE_REGION=$(yq -r .platform.azure.region install-config.yaml)
SSH_KEY=$(yq -r .sshKey install-config.yaml | xargs)
BASE_DOMAIN=$(yq -r .baseDomain install-config.yaml)
BASE_DOMAIN_RESOURCE_GROUP=$(yq -r .platform.azure.baseDomainResourceGroupName install-config.yaml)

if [[ "$CLUSTERNAME" == "" -o "$BASE_DOMAIN" == "example.com" ]]; then
  throw "install-config.yaml is not properly configured. Please fill it out before running openshift-install"
  exit 1
fi   

python3 -c '
import yaml;
path = "install-config.yaml";
data = yaml.full_load(open(path));
data["compute"][0]["replicas"] = 0;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'
openshift-install create manifests || throw "Unable to create manifests"
rm -fv openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -fv openshift/99_openshift-cluster-api_worker-machineset-*.yaml
python3 -c '
import yaml;
path = "manifests/cluster-scheduler-02-config.yml";
data = yaml.full_load(open(path));
data["spec"]["mastersSchedulable"] = False;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'
python3 -c '
import yaml;
path = "manifests/cluster-dns-02-config.yml";
data = yaml.full_load(open(path));
del data["spec"]["publicZone"];
del data["spec"]["privateZone"];
open(path, "w").write(yaml.dump(data, default_flow_style=False))'
INFRA_ID=$(yq -r '.status.infrastructureName' manifests/cluster-infrastructure-02-config.yml)
RESOURCE_GROUP=$(yq -r '.status.platformStatus.azure.resourceGroupName' manifests/cluster-infrastructure-02-config.yml)
openshift-install create ignition-configs

trap cleanupError 0  # Stop debug when failing
# set -x
echoDo "Create Resource Group" az group create --name $RESOURCE_GROUP --location $AZURE_REGION ${azout}
echoDo "Create Identity" az identity create -g $RESOURCE_GROUP -n ${INFRA_ID}-identity ${azout}
echoDo "Create Storage Account" az storage account create -g $RESOURCE_GROUP --location $AZURE_REGION --name ${CLUSTER_NAME}sa --kind Storage --sku Standard_LRS ${azout}
ACCOUNT_KEY=$(az storage account keys list -g $RESOURCE_GROUP --account-name ${CLUSTER_NAME}sa --query "[0].value" -o tsv)
VHD_URL=$(curl -s https://raw.githubusercontent.com/openshift/installer/release-$OCPRELEASE/data/data/rhcos.json | jq -r .azure.url)
echoDo "Create vhd Storage Container" az storage container create --name vhd --account-name ${CLUSTER_NAME}sa ${azout}
echoDo "Create file Storage Container" az storage container create --name files --account-name ${CLUSTER_NAME}sa --public-access blob ${azout}
echoDo "Upload bootstrap.ign to file storage" az storage blob upload --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c "files" -f "bootstrap.ign" -n "bootstrap.ign" ${azout}
echoDo "Start VHD to image creation" az storage blob copy start --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY --destination-blob "rhcos.vhd" --destination-container vhd --source-uri "$VHD_URL"
PRINCIPAL_ID=$(az identity show -g $RESOURCE_GROUP -n ${INFRA_ID}-identity --query principalId --out tsv)
RESOURCE_GROUP_ID=$(az group show -g $RESOURCE_GROUP --query id --out tsv)
echoDo "Create Service Account" az role assignment create --assignee "$PRINCIPAL_ID" --role 'Contributor' --scope "$RESOURCE_GROUP_ID" ${azout}
echoDo "Create public DNS Zone" az network dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN} ${azout}
nsServer0=$(az network dns zone show --resource-group $RESOURCE_GROUP --name ${CLUSTER_NAME}.${BASE_DOMAIN} --query "nameServers[0]" -o tsv)
nsServer1=$(az network dns zone show --resource-group $RESOURCE_GROUP --name ${CLUSTER_NAME}.${BASE_DOMAIN} --query "nameServers[1]" -o tsv)
echoDo "Create NS Record Sets" az network dns record-set ns create --name ${CLUSTER_NAME} --resource-group $BASE_DOMAIN_RESOURCE_GROUP --zone-name ${BASE_DOMAIN} ${azout}
echoDo "Create NS record" az network dns record-set ns add-record --nsdname $nsServer0 -n ${CLUSTER_NAME} -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} ${azout}
echoDo "Create NS record" az network dns record-set ns add-record --nsdname $nsServer1 -n ${CLUSTER_NAME} -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} ${azout}
echoDo "Create Private DNS zone" az network private-dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN} ${azout}
status="unknown"
while [ "$status" != "success" ]
do
  status=$(az storage blob show --container-name vhd --name "rhcos.vhd" --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -o tsv --query properties.copy.status)
  echo $status
done
echoDo "Create VNET"  az deployment group create -g $RESOURCE_GROUP \
  --template-file "01_vnet.json" \
  --parameters baseName="$INFRA_ID" ${azout}
echoDo "Associate private-dns with virtual network" az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${INFRA_ID}-network-link -v "${INFRA_ID}-vnet" -e false ${azout}
VHD_BLOB_URL=$(az storage blob url --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c vhd -n "rhcos.vhd" -o tsv)
# looks like we need a short delay here
sleep 10
echoDo "Setup azure VHD storage" az deployment group create -g $RESOURCE_GROUP \
  --template-file "02_storage.json" \
  --parameters vhdBlobURL="$VHD_BLOB_URL" \
  --parameters baseName="$INFRA_ID" ${azout}
echoDo "Setup PrivateDNS records for infrastructure" az deployment group create -g $RESOURCE_GROUP \
  --template-file "03_infra.json" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
  --parameters baseName="$INFRA_ID" ${azout}
PUBLIC_IP=$(az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${INFRA_ID}-master-pip'] | [0].ipAddress" -o tsv)
echoDo "Add public A record for api end point" az network dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api -a $PUBLIC_IP --ttl 60
BOOTSTRAP_URL=$(az storage blob url --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c "files" -n "bootstrap.ign" -o tsv)
BOOTSTRAP_IGNITION=$(jq -rcnM --arg v "2.2.0" --arg url $BOOTSTRAP_URL '{ignition:{version:$v,config:{replace:{source:$url}}}}' | base64 -w0)
echoDo "Create Bootstrap" az deployment group create -g $RESOURCE_GROUP \
  --template-file "04_bootstrap.json" \
  --parameters bootstrapIgnition="$BOOTSTRAP_IGNITION" \
  --parameters sshKeyData="$SSH_KEY" \
  --parameters baseName="$INFRA_ID" ${azout}
MASTER_IGNITION=$(base64 -w0 master.ign)
echoDo "Create masters" az deployment group create -g $RESOURCE_GROUP \
  --template-file "05_masters.json" \
  --parameters masterIgnition="$MASTER_IGNITION" \
  --parameters sshKeyData="$SSH_KEY" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}" \
  --parameters baseName="$INFRA_ID" ${azout}
echoDo "Wait for OCP Bootstrap to complete" openshift-install wait-for bootstrap-complete --log-level debug
az network nsg rule delete -g $RESOURCE_GROUP --nsg-name ${INFRA_ID}-controlplane-nsg --name bootstrap_ssh_in
az vm stop -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap
az vm deallocate -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap
az vm delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap --yes
az disk delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap_OSDisk --no-wait --yes
az network nic delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap-nic --no-wait
az storage blob delete --account-key $ACCOUNT_KEY --account-name ${CLUSTER_NAME}sa --container-name files --name bootstrap.ign
az network public-ip delete -g $RESOURCE_GROUP --name ${INFRA_ID}-bootstrap-ssh-pip
export KUBECONFIG="$PWD/auth/kubeconfig"
oc get nodes
oc get clusteroperator

echoDo "Create Worker Nodes" az deployment group create -g $RESOURCE_GROUP \
  --template-file "06_workers.json" \
  --parameters workerIgnition="$(base64 -w0 worker.ign)" \
  --parameters sshKeyData="$SSH_KEY" \
  --parameters baseName="$INFRA_ID" \
  --parameters numberOfNodes="$WORKERNODES" ${azout}
