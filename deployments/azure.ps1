$config=Get-Content azure.json | ConvertFrom-Json

function DeployAzureObject() {
    param(
        $resourceGroupIndex,
        $objectIndex
    )
    $objectType=$config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].objectType
    $rg=$config.azure.resourceGroups[$resourceGroupIndex].name
    "Setting up an Azure object of type '$objectType' in resource group '$rg'"
 
    $retval=az group show -n $config.azure.resourceGroups[$resourceGroupIndex].name 2> $null
    if ( -not $retval) {
        "Creating resource group '$rg'"
        az group create --name $rg --location $config.azure.resourceGroups[$resourceGroupIndex].location
        if( -not $? ) {
            "Unable to set up resource group"
            exit
        }
    }
 
    $name=$config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].name
    $location=$config.azure.resourceGroups[$resourceGroupIndex].location
    switch( $objectType) {
        acr {
            $retval=az acr show -g $rg --name $name  2> $null
            if ( -not $retval ) {
                "Creating the Azure Container Registry '$name'"
                az acr create --name $name -g $rg --sku $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].sku
                if( -not $? ) { 
                    "Could not create ACR"
                    exit 
                }
            } else {
                "Azure Container Registry already created"
            }
            $id=az acr show --name $name -g $rg --query id |ConvertFrom-Json
            if( -not $? ) { 
                "Could not find ACR"
                exit 
            }
        }
        keyvault {
            $retval=az keyvault show -g $rg -n $name 2> $null
            if ( -not $retval ) {
                "Creating the Azure Key Vault '$name'"
                az keyvault create -n $name -g $rg -l $location
                if( -not $? ) { 
                    "Could not create Azure Keyvault"
                    exit 
                }
            } else {
                "Azure Key Vault already created"
            }
            $id=az keyvault show -n $name -g $rg --output json --query id |ConvertFrom-Json
            if( -not $? ) { 
                "Could not find Azure Keyvault"
                exit 
            }
        }
        vnet {
            $retval=az network vnet show -g $rg --name $name 2> $null
            if ( -not $retval ) {
                "Create virtual network '$name'"
                az network vnet create -g $rg --name $name --location $location --address-prefixes $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].addressPrefix
                if( -not $? ) { 
                    "Could not create vnet"
                    exit 
                }
            } else {
                "Virtual network already created"
            }      
            $id=az network vnet show -g $rg --name $name --output json --query id |ConvertFrom-Json
            if( -not $? ) { 
                "Could not find vnet"
                exit 
            }
        }
        subnet {
            $retval=az network vnet subnet show -g $rg --name $name --vnet-name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vnetName 2> $null
            if (-not $retval) {
                az network vnet subnet create -g $rg `
                    --name $name `
                    --address-prefix $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].addressPrefix `
                    --vnet-name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vnetName
                if( -not $? ) { 
                    "Could not create subnet"
                    exit 
                }
            } else {
                "Subnet already created"
            }
            $id=az network vnet subnet show -g $rg `
                --name $name `
                --vnet-name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vnetName `
                --output json --query id |ConvertFrom-Json
            if( -not $? ) { 
                "Could not find subnet"
                exit 
            }
        }
        aks {
            $retval=az aks show -g $rg --name $name 2> $null
            if ( -not $retval) {
                $aksSubnetId=az network vnet subnet show `
                    -g $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vnetResourceGroup `
                    --name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vnetSubnetName `
                    --vnet-name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vnetName --output json --query id |ConvertFrom-Json
                if( -not $? ) {
                    "Unable to find ID for AKS Subnet"
                    exit
                }
                az aks create -g $rg --name $name `
                    --node-count $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].nodeCount `
                    --enable-managed-identity `
                    --enable-cluster-autoscaler `
                    --max-count $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].maxCount `
                    --min-count $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].minCount `
                    -s $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].nodeSize `
                    --nodepool-name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].nodePoolName `
                    --enable-addons monitoring,azure-keyvault-secrets-provider `
                    --enable-rbac `
                    --network-plugin $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].networkPlugin `
                    --vnet-subnet-id $aksSubnetId `
                    --docker-bridge-address 10.1.0.1/16 `
                    --dns-service-ip 10.0.0.10 `
                    --service-cidr 10.0.0.0/16 `
                    --aci-subnet-name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vnetSubnetName `
                    --dns-name-prefix $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].dnsNamePrefix `
                    --yes
                if( -not $? ) {
                    "Unable to create the AKS cluster"
                    exit
                }
            } else {
                "AKS already created"
            }
            $id=az aks show -g $rg --name $name --output json --query id |ConvertFrom-Json
            if( -not $? ) { exit }
        }
        role {
            switch( $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].assigneeType ) {
                aksPool {
                    $assigneeId=az aks show -g $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].assigneeResourceGroup `
                        --name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].assigneeName --query "identityProfile.kubeletidentity.objectId"
                }
                default {
                    "Unknown assignee type: $($config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].assigneeType)"
                    exit
                }
            }
            "Assignee ID is $assigneeId"
            switch( $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].scopeType ) {
                acr {
                    $scopeId=az acr show -g $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].scopeResourceGroup `
                        --name $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].scopeName --query id
                }
                default {
                    "Unknown scope type: $($config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].scopeType)"
                    exit
                }
            }
            "Scope ID is $scopeId"
            az role assignment create --role $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].role --assignee $assigneeId --scope $scopeId
            if( -not $? ) {
                "Unable to assign role"
                exit
            }
            "Role has been assigned"
            return
        }
        pubip {
            $retval=az network public-ip show -g $rg --name $name  2> $null
            if ( -not $retval ) {
                "Creating the public IP '$name'"
                az network public-ip create --name $name -g $rg
                if( -not $? ) {
                    "Could not create public IP "
                    exit
                }
            } else {
                "Public IP already created"
            }
            $id=az network public-ip show --name $name -g $rg --query id |ConvertFrom-Json
            if( -not $? ) {
                "Could not find public IP"
                exit
            }
        }
        vpngw {
            $retval=az network vnet-gateway show -g $rg --name $name  2> $null
            if ( -not $retval ) {
                "Creating the VPN Gateway '$name'"
                $aadTenantId = az account show --query tenantId |ConvertFrom-Json
                az network vnet-gateway create --name $name -g $rg `
                --vnet $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vnetName `
                --public-ip-address $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].publicIpAddress `
                --address-prefixes $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].addressPrefix `
                --gateway-type Vpn `
                --sku $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].sku `
                --vpn-type $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].vpnType `
                --client-protocol $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].clientProtocol `
                --aad-audience $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].aadAudience `
                --aad-issuer https://sts.windows.net/$aadTenantId/ `
                --aad-tenant https://login.microsoftonline.com/$aadTenantId/
                               
                if( -not $? ) {
                    "Could not create VPN gateway"
                    exit
                }
            } else {
                "VPN gateway already created"
            }
            $id=az network vnet-gateway show --name $name -g $rg --query id |ConvertFrom-Json
            if( -not $? ) {
                "Could not find VPN gateway"
                exit
            }
        }
        vm {
            $retval=az vm show -g $rg --name $name
            if ( -not $retval ) {
                "Creating the virtual machine '$name'"
                $retval=az deployment group create -g $rg `
                    --template-file $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].templateFile `
                    --parameters $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].parametersFile
                if( -not $? ) {
                    "Could not complete the deployment group"
                    exit
                }            
            } else {
                "The virtual machine is already created"
            }
            $id=az vm show -g $rg --name $name --query id |ConvertFrom-Json
        }
        default {
            "Unknown object type: '$objectType'"
            exit
        }

    }
    $config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].id=$id
    "Object has ID '$($config.azure.resourceGroups[$resourceGroupIndex].objects[$objectIndex].id)'"    
}


az login > $null
if( -not $? ) {
    "Error logging in"
    exit
}

"------------------------------------------------------------------"
"Successfully logged in"


az account set --subscription $config.azure.subscription
if( -not $? ) {
    "Error setting subscription"
    exit
}

"------------------------------------------------------------------"
"Subscription set to $($config.azure.subscription)"

for($rgIndex=0; $rgIndex -lt ($config.azure.resourceGroups.Length); ++$rgIndex ) {
    "Setting up the objects of resource group $($config.azure.resourceGroups[$rgIndex].name)"
    for($oIndex=0; $oIndex -lt ($config.azure.resourceGroups[$rgIndex].objects.Length); ++$oIndex) {
        "------------------------------------------------------------------"
        DeployAzureObject -resourceGroupIndex $rgIndex -objectIndex $oIndex
    }

}
