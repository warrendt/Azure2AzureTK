# Background

This guide describes how to leverage the Azure to Azure migration toolkit when migrating your workload from one Azure region to another.  

> Note that this is a preview solution intended to encourage feedback for further development which should be tested in a safe environment before using in production to protect against possible failures/unnecessary cost.
> Also note that this repo is public and as such you should never upload or otherwise divulge sensitive information to this repo. If there is any concern, please contact your Microsoft counterparts for detailed advice.

The repo at present contains code and details for the following:

- Script and supporting files to collect Azure resource inventory and properties from either an Azure resource group, an Azure subscription (default behavior) or multiple Azure subscriptions. This functionality is contained in the 1-Collect directory.
- Script to determine service availability in the target region based on the inventory collected in the previous step. This functionality is contained in the 2-AvailabilityCheck directory. Note that this functionality is not yet complete and is a work in progress.

## Prerequisites

1. Microsoft Entra ID Tenant.
1. Azure RBAC Reader access to minimum one resource group for when collecting inventory. Note that depending on the scope of the inventory collection, you may need to have Reader access to either a single resource group, a subscription or multiple subscriptions.
1. You will need to have the following installed on the platform you are running the scripts from:
    - PowerShell Core 7.5.1 or later
    - Azure Powershell module Az.Monitor 5.2.2 or later
    - Azure Powershell module Az.ResourceGraph 1.2.0 or later
    - Azure Powershell module Az.Accounts 4.1.0 or later

## High Level Steps

- Fork this repo to your own GitHub organization, you should not create a direct clone of the repo. Pull requests based off direct clones of the repo will not be allowed.
- Clone the repo from your own GitHub organization to whatever platform you are using to access Azure.
- Open the PowerShell console and navigate to the directory where you cloned the repo.
- Navigate to the `1-Collect` directory.
- Logon to Azure with an account that has the required permissions to collect the inventory using `Connect-AzAccount`.
- Run the script `Get-AzureServices.ps1` to collect the Azure resource inventory and properties, for yor relevant scope (resource group, subscription or multiple subscriptions). The script will generate a resources.json and a summary.json file in the same directory. The resources.json file contains the full inventory of resources and their properties, while the summary.json file contains a summary of the resources collected. For examples on how to run the script for different scopes please see 1-Collect scope examples - [1-Collect Scope Examples](#1-collect-scope-examples) below.
- After collecting inventory, you will be able to run a number of scripts to determine various aspects of the resources collected relevant to migration. These scripts are described as follows:
  - `2-AvailabilityCheck/Get-AvailabilityInformation.ps1` - This script will check the availability of the services in the target region based on the inventory collected in the previous step. It will generate a services.json file in the same directory, which contains the availability information for the services in the target region. Note that this functionality is not yet complete and is a work in progress. For examples on how to run the script please see 2-AvailabilityCheck examples - [2-AvailabilityCheck Examples](#2-availabilitycheck-examples) below.
  
  - `3-CostInformation/Get-CostInformation.ps1` - This script will query the cost information for the resources collected in the previous step. It will generate a cost.json file in the same directory, which contains the cost information for the resources in the target region.
  
Once you have run scripts relevant to your migration scenario, the final information will be available in a series of json files. For ease of use, you can use the `7-Report/Get-Report.ps1` script to output the information in a more readable format. This script will generate a Microsoft Excel file in the same directory, containing the collected information.

### 1-Collect Scope Examples

- To collect the inventory for a single resource group, run the script as follows:

```powershell
Get-AzureServices.ps1 -scopeType resourceGroup -resourceGroupName <resource-group-name> -subscriptionId <subscription-id>
```

- To collect the inventory for a single subscription, run the script as follows:

```powershell
Get-AzureServices.ps1 -scopeType subscription -subscriptionId <subscription-id>
```

- To collect the inventory for multiple subscriptions, you will need to create a json file containing the subscription ids in scope. See [here](./subscriptions.json) for a sample json file. Once the file is created, run the script as follows:

```powershell
Get-AzureServices.ps1 -multiSubscription -workloadFile <path-to-workload-file>
```

### 2-AvailabilityCheck Examples

- To check the availability of services in a specific region, it is necessary to first run the Get-AvailabilityInformation script which will collect service availability in all regions. The resulting json files is then used with the Get-Region script to determine specific service availability for one or more regions to be used for reporting eventually. Note that the Get-AvailabilityInformation script only needs to be run once to collect the availability information for all regions, which takes a little while. After that, you can use the Get-Region script to check the availability of services in specific regions. Availability information is available in the `Availability_Mapping_<Region>.json` file, which is generated in the same directory as the script.

```powershell
Get-AvailabilityInformation.ps1
# Wait for the script to complete, this may take a while.
Get-Region.ps1 -region <target-region1>
# Example1: Get-Region.ps1 -region "east us"
# Example2: Get-Region.ps1 -region "west us"
# Example3: Get-Region.ps1 -region "sweden central"
```
