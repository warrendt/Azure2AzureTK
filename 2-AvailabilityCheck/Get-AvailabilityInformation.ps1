<#.SYNOPSIS
    Assess Azure availabilities by querying Resource Graph and extracting specific properties or metadata.
    Then those extracted information will be compared against actual

.DESCRIPTION
    This script evaluates the availability of Azure services, resources, and SKUs across different regions.
    When combined with the output from the 1-Collect script, it provides a comprehensive overview of potential
    migration destinations, identifying feasible regions and the reasons for their suitability or limitations,
    such as availability constraints per region.
    All data, including availability details and region-specific insights, will be stored in JSON files.

.EXAMPLE
    PS C:\> .\Get-AvailabilityInformation.ps1
    Runs the script outputs the results to the default files.

.OUTPUTS
    JSON files containing the providers and SKU availabilities in line with per-region availabilities for a specific implementation.

.NOTES
    - Requires Azure PowerShell module to be installed and authenticated.
#>

# Main script
clear-host
Write-Output "####################################################################################################"
Write-Output "## RETRIEVING ALL AVAILABILITIES IN THIS SUBSCRIPTION                                             ##"
Write-Output "####################################################################################################"
Write-Output ""

# REST API: Retrieve access token for REST API
Write-Output "Retrieving access token for REST API"
$AccessToken = az account get-access-token --query accessToken -o tsv
$SubscriptionId = az account show --query id -o tsv  # Automatically retrieve the current subscription ID
$BaseUri = "https://management.azure.com/subscriptions"

# REST API: Define headers with the access token
$Headers = @{
    Authorization = "Bearer $AccessToken"
}

# Providers: Start
Write-Output "Retrieving all available provider"
$Providers_Uri = "$BaseUri/$SubscriptionId/providers?api-version=2021-04-01"
$Providers_Response = Invoke-RestMethod -Uri $Providers_Uri -Headers $Headers -Method Get

# Transform the response to the desired structure
$Resources_All = foreach ($provider in $Providers_Response.value) {
    # Build an array of resource types using plain hashtables
    $rtArray = @()
    foreach ($rt in $provider.resourceTypes) {
        $rtArray += @{
            Type      = $rt.resourceType
            Locations = $rt.locations
        }
    }
    # Return a hashtable for each provider
    @{
        Namespace     = $provider.namespace
        ResourceTypes = $rtArray
    }
}

# Save providers to a JSON file
Write-Output "  Saving providers to file: Azure_Providers.json"
$Resources_All | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_Providers.json"

# Region information: Start
Write-Output "Working on regions"
Write-Output "  Retrieving regions information"
$LocationUri = "$BaseUri/$SubscriptionId/locations?api-version=2022-12-01"
$LocationResponse = Invoke-RestMethod -Uri $LocationUri -Headers $Headers -Method Get

# Sort regions alphabetically by displayName
Write-Output "  Sorting regions"
$LocationResponse.value = $LocationResponse.value | Sort-Object displayName

# Flatten metadata to the top level and remove unwanted properties
Write-Output "  Region information flattening and PII deletion"
$NewLocations = @()
$VM_TotalRegionsFlat = $LocationResponse.value.Count
$CurrentFlatIndex = 0
foreach ($region in $LocationResponse.value) {
    $CurrentFlatIndex++
    Write-Output ("    Removing information for region {0:D03} of {1:D03}: {2}" -f $CurrentFlatIndex, $VM_TotalRegionsFlat, $region.displayName)
    if ($region.metadata) {
        # Remove subscription ID from pairedRegion and just keep the region name
        if ($region.metadata.pairedRegion) {
            $region.metadata.pairedRegion = $region.metadata.pairedRegion | ForEach-Object { $_.name }
        }
        # Lift all properties from metadata to the top level
        foreach ($key in $region.metadata.PSObject.Properties.Name) {
            $region | Add-Member -MemberType NoteProperty -Name $key -Value $region.metadata.$key -Force
        }
    }
    # Rebuild the object without metadata and id
    $newRegion = $region | Select-Object * -ExcludeProperty metadata, id
    $NewLocations += $newRegion
}
$LocationResponse.value = $NewLocations

# Save regions to a JSON file
Write-Output "  Saving regions to file: Azure_Regions.json"
$LocationResponse | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_Regions.json"

# VM SKUs: Start
Write-Output "Working on VM SKUs"
Write-Output "  Retrieving VM SKU regions information"
$VM_Uri = "$BaseUri/$SubscriptionId/providers/Microsoft.Compute?api-version=2025-03-01"
$VM_Response = Invoke-RestMethod -Uri $VM_Uri -Headers $Headers -Method Get

# Filter for the resource type "virtualMachines" and extract its locations array
$VM_Locations = ($VM_Response.resourceTypes | Where-Object { $_.resourceType -eq "virtualMachines" }).locations | Sort-Object

$VM_TotalRegions = $VM_Locations.Count
$CurrentRegionIndex = 0

Write-Output "  Adding VM SKUs for consolidated regions"
$VMResource = @{}
foreach ($Region in $VM_Locations) {
    $CurrentRegionIndex++
    Write-Output ("    Retrieving VM SKUs for region {0:D03} of {1:D03}: {2}" -f $CurrentRegionIndex, $VM_TotalRegions, $Region)

    # REST API endpoint for VM SKUs
    $VMUri = "$BaseUri/$SubscriptionId/providers/Microsoft.Compute/locations/$Region/vmSizes?api-version=2024-07-01"

    # Make the REST API call for VM SKUs
    $VMResponse = Invoke-RestMethod -Uri $VMUri -Headers $Headers -Method Get

    # Process the API response
    foreach ($Size in $VMResponse.value) {
        if (-not $VMResource.ContainsKey($Size.name)) {
            $VMResource[$Size.name] = @{
                Name          = $Size.name
                Locations     = @($Region)  # Initialize with the current region
                NumberOfCores = $Size.numberOfCores
                MemoryInMB    = $Size.memoryInMB
            }
        } else {
            # Add the region to the existing size's locations, ensuring no duplicates
            if (-not ($VMResource[$Size.name].Locations -contains $Region)) {
                $VMResource[$Size.name].Locations += $Region
            }
        }
    }
}

# Convert the hash table to an array and save the VM SKUs to a JSON file
$VM_SKU = $VMResource.Values
Write-Output "  Saving VM SKUs to file: Azure_SKUs_VM.json"
$VM_SKU | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_SKUs_VM.json"

# Storage Account SKUs: Start
Write-Output "Working on storage account SKUs"
Write-Output "  Retrieving storage account SKUs"
$StorageAccount_SKU = @()

# REST API Endpoint for storage account SKUs
$StorageAccount_Uri = "$BaseUri/$SubscriptionId/providers/Microsoft.Storage/skus?api-version=2021-01-01"
$StorageAccount_Response = Invoke-RestMethod -Uri $StorageAccount_Uri -Headers $Headers -Method Get

# Sort storage account response by the first location value
Write-Output "  Sorting storage account SKUs by location"
$StorageAccount_ResponseSorted = $StorageAccount_Response.value | Sort-Object { $_.locations[0] }

# Replace region names with display names in $StorageAccount_ResponseSorted and property of regions not available in this subscription will be empty
Write-Output "  Changing region names to display names"
$LocationMap = @{}
foreach ($loc in $LocationResponse.value) {
    $LocationMap[$loc.name] = $loc.displayName
}

foreach ($obj in $StorageAccount_ResponseSorted) {
    $newLocations = @()
    foreach ($region in $obj.locations) {
        if ($LocationMap.ContainsKey($region)) {
            $newLocations += $LocationMap[$region]
        }
    }
    $obj.locations = $newLocations
}

# Filter out SKU objects whose locations array is empty
Write-Output "  Removing regions not available in this subscription"
$StorageAccount_ResponseSorted = $StorageAccount_ResponseSorted | Where-Object { $_.locations.Count -gt 0 }

# Count distinct storage account locations, excluding empty strings
$TotalStorageLocations = ($StorageAccount_ResponseSorted | ForEach-Object { $_.locations[0] } | Where-Object { $_ -ne "" } | Sort-Object | Get-Unique).Count
$CurrentLocationIndex = 0

Write-Output "  Adding storage account SKUs for consolidated regions"
$LastLocation = $null
$StorageAccount_ResponseSorted | ForEach-Object {
    $CurrentLocation = $_.locations[0]
    if ($CurrentLocation -ne $LastLocation) {
        $CurrentLocationIndex++
        $LastLocation = $CurrentLocation
        Write-Output ("    Retrieving storage account SKUs for region {0:D03} of {1:D03}: {2}" -f $CurrentLocationIndex, $TotalStorageLocations, $CurrentLocation)
    }
    # Convert Capabilities into individual properties
    $CapabilitiesProperties = @{}
    $_.capabilities | ForEach-Object {
        $Capability = "$($_.name):$($_.value)"
        $NameValuePair = $Capability -split ":"
        if ($NameValuePair.Length -eq 2) {
            $Key = $NameValuePair[0].Trim()
            $Value = $NameValuePair[1].Trim()
            $CapabilitiesProperties[$Key] = $Value
        }
    }
    foreach ($Location in $_.locations) {  # Process each location as its own entry
        $StorageAccount_SKU += @{
            Name     = $_.name
            Location = $Location
            Tier     = $_.tier
            Kind     = $_.kind
        }
        # Flatten the details properties to top-level
        foreach ($Key in $CapabilitiesProperties.Keys) {
            $StorageAccount_SKU[-1] | Add-Member -MemberType NoteProperty -Name $Key -Value $CapabilitiesProperties[$Key] -Force
        }
    }
}

# Save the storage account SKUs to a JSON file
Write-Output "  Saving storage account SKUs to file: Azure_SKUs_StorageAccount.json"
$StorageAccount_SKU | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_SKUs_StorageAccount.json"
Write-Output "  All files have been saved successfully!"

Write-Output ""
Write-Output "####################################################################################################"
Write-Output "## AVAILABILITY MAPPING TO CURRENT IMPLEMENTATION                                                 ##"
Write-Output "####################################################################################################"
Write-Output ""

# Processing and data massaging of summary file of script 1-Collect: Start
Write-Output "Retrieving current implementation information"
$SummaryFilePath = "$(Get-Location)\..\1-Collect\summary.json"

if (Test-Path $SummaryFilePath) {
    Write-Output "  Loading summary file: ../1-Collect/summary.json"
    $Resources_Implementation = Get-Content -Path $SummaryFilePath | ConvertFrom-Json
} else {
    Write-Output "Summary file not found: ../1-Collect/summary.json"
    exit
}

# Check for empty SKUs and remove 'ResourceSkus' property if its value is 'N/A' in current implementation data
Write-Output "  Cleaning up implementation data"
$Resources_Implementation = $Resources_Implementation | ForEach-Object {
    if (((($_.ResourceSkus -is [array]) -and ($_.ResourceSkus.Count -eq 1) -and ($_.ResourceSkus[0] -eq "N/A"))) -or ($_.ResourceSkus -eq "N/A")) {
        $_ | Select-Object * -ExcludeProperty ResourceSkus
    }
    else {
        $_
    }
}

# Change of property names to better show current implementation
Write-Output "  Massaging implementation data"
$Resources_Implementation = $Resources_Implementation | ForEach-Object {
    $obj = $_
    # Rename 'AzureRegions' to 'ImplementedRegions'
    if ($obj.PSObject.Properties["AzureRegions"]) {
        $newRegions = @()
        foreach ($region in $obj.AzureRegions) {
            if ($LocationMap.ContainsKey($region)) {
                $newRegions += $LocationMap[$region]
            }
            else {
                $newRegions += $region
            }
        }
        $obj | Add-Member -Force -MemberType NoteProperty -Name ImplementedRegions -Value $newRegions
        $obj = $obj | Select-Object * -ExcludeProperty AzureRegions
    }
    # Rename 'ResourceSkus' to 'ImplementedSkus'
    if ($obj.PSObject.Properties["ResourceSkus"]) {
        $newSkus = @()
        foreach ($sku in $obj.ResourceSkus) {
            $newSkus += $sku
        }
        $obj | Add-Member -Force -MemberType NoteProperty -Name ImplementedSkus -Value $newSkus
        $obj = $obj | Select-Object * -ExcludeProperty ResourceSkus
    }

    $obj
}

# General availability mapping (without SKUs): Start
Write-Output "Working on general availability mapping without SKU consideration"
$TotalResourceTypes = $Resources_Implementation.Count
$CurrentResourceTypeIndex = 0

# Map current implementation data to general Azure region availabilities
Write-Output "  Adding Azure regions with resource availability information"
foreach ($resource in $Resources_Implementation) {
    $CurrentResourceTypeIndex++
    Write-Output ("    Processing resource type {0:D03} of {1:D03}: {2}" -f $CurrentResourceTypeIndex, $TotalResourceTypes, $resource.ResourceType)
    # Split the resource type string into namespace and type (keeping everything after the first "/" as the type)
    $splitParts = $resource.ResourceType -split "/", 2
    if ($splitParts.Length -eq 2) {
        $ns = $splitParts[0]
        $rt = $splitParts[1]
        # Find the namespace object in Resources_All
        $nsObject = $Resources_All | Where-Object { $_.Namespace -ieq $ns }
        if ($nsObject) {
            # Locate the corresponding resource type under that namespace
            $resourceTypeObject = $nsObject.ResourceTypes | Where-Object { $_.Type -ieq $rt }
            if ($resourceTypeObject) {
                # Create a mapped regions array directly using $LocationResponse.value
                $MappedRegions = @()
                foreach ($region in $LocationResponse.value) {
                    $availability = if ($resourceTypeObject.Locations -contains $region.displayName) { "true" } else { "false" }
                    $MappedRegions += New-Object -TypeName PSObject -Property @{
                        region    = $region.displayName
                        available = $availability
                    }
                }
                # Add or replace the AllRegions property with the mapped availability array
                $resource | Add-Member -Force -MemberType NoteProperty -Name AllRegions -Value $MappedRegions
            } else {
                Write-Output ("      Resource type '{0}' under namespace '{1}' not found in Resources_All" -f $rt, $ns)
            }
        } else {
            Write-Output ("      Namespace '{0}' not found in Resources_All" -f $ns)
        }
    } else {
        Write-Output ("      Invalid ResourceType format: {0}" -f $resource.ResourceType)
    }
}

# Availability SKU mapping (without SKUs): Start
Write-Output "Working on availability SKU mapping"


# Add the SKUs property to each region in the AllRegions array when the resource type is available in that region
Write-Output "  Adding implemented SKUs to Azure regions with general availability"
foreach ($resource in $Resources_Implementation) {
    if ($resource.ImplementedSkus) {
        foreach ($region in $resource.AllRegions) {
            if ($region.available -eq "true") {
                # Add the SKUs property containing the array from the current resource object.
                $region | Add-Member -MemberType NoteProperty -Name SKUs -Value $resource.ImplementedSkus -Force
            }
        }
    }
}

# Availability SKU mapping storage accounts: Start

### TBD ###






# Save the availability mapping to a JSON file
Write-Output "  Saving availability mapping to file: Availability_Mapping.json"
$Resources_Implementation | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Availability_Mapping.json"
