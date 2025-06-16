# Cost data retrieval

## About the script

This script is intended to take a collection of given resource IDs and return the cost incurred during previous months, grouped as needed. For this we use the Microsoft.CostManagement provider of each subscription. This means one call of the Cost Management PowerShell module per subscription.

Requires Az.CostManagement module version 0.4.2.

`PS1> Install-Module -Name Az.CostManagement`

Instructions for use:

1. Log on to Azure using `Connect-AzAccount`. Ensure that you have Cost Management Reader access to each subscription listed in the resources file (default `resources.json`)
2. Navigate to the 3-CostInformation folder and run the script using `.\Get-CostInformation.ps1`. The script will generate a CSV file in the current folder.

## Documentation links
Documentation regarding the Az.CostManagement module is not always straightforward. Helpful links are:

| Documentation | Link |
| -------- | ------- |
| Cost Management Query (API) | [Link](https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage) |
| Az.CostManagement Query (PowerShell) | [Link](https://learn.microsoft.com/en-us/powershell/module/az.costmanagement/invoke-azcostmanagementquery) |

Valid dimensions for grouping are:

``` text
AccountName
BenefitId
BenefitName
BillingAccountId
BillingMonth
BillingPeriod
ChargeType
ConsumedService
CostAllocationRuleName
DepartmentName
EnrollmentAccountName
Frequency
InvoiceNumber
MarkupRuleName
Meter
MeterCategory
MeterId
MeterSubcategory
PartNumber
PricingModel
PublisherType
ReservationId
ReservationName
ResourceGroup
ResourceGroupName
ResourceGuid
ResourceId
ResourceLocation
ResourceType
ServiceName
ServiceTier
SubscriptionId
SubscriptionName
```