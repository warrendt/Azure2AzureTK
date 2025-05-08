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

# Namespaces and resource types: Start
Write-Output "Retrieving all available namespaces and resource types"
$Resources_All = az provider list --query "[].{Namespace:namespace, ResourceTypes:resourceTypes[].{Type:resourceType, Locations:locations}}" -o json | ConvertFrom-Json

# Save namespaces and resource types to a JSON file
Write-Output "  Saving namespaces and resource types to file: Azure_Resources.json"
$Resources_All | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_Resources.json"

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
$TotalRegionsFlat = $LocationResponse.value.Count
$CurrentFlatIndex = 0
foreach ($region in $LocationResponse.value) {
    $CurrentFlatIndex++
    Write-Output ("    Removing information for region {0:D03} of {1:D03}: {2}" -f $CurrentFlatIndex, $TotalRegionsFlat, $region.displayName)
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

# Retrieve available regions from Microsoft.Compute
Write-Output "  Retrieving available regions from Microsoft.Compute"
$ComputeProvider = az provider show --namespace Microsoft.Compute --query "resourceTypes[?resourceType=='virtualMachines'].locations[]" -o tsv
$Regions = $ComputeProvider -split "`n"  # Split regions into an array for processing

# Sort the available regions (alphabetically)
Write-Output "  Sorting VM SKUs by location"
$Regions = $Regions | Sort-Object

$TotalRegions = $Regions.Count
$CurrentRegionIndex = 0

Write-Output "  Adding VM SKUs for consolidated regions"
$VMResource = @{}
foreach ($Region in $Regions) {
    $CurrentRegionIndex++
    Write-Output ("    Retrieving VM SKUs for region {0:D03} of {1:D03}: {2}" -f $CurrentRegionIndex, $TotalRegions, $Region)

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
$Storage_SKU = @()

# REST API Endpoint for Storage SKUs
$StorageUri = "$BaseUri/$SubscriptionId/providers/Microsoft.Storage/skus?api-version=2021-01-01"
$StorageResponse = Invoke-RestMethod -Uri $StorageUri -Headers $Headers -Method Get

# Sort storage response by the first location value
Write-Output "  Sorting storage account SKUs by location"
$StorageResponseSorted = $StorageResponse.value | Sort-Object { $_.locations[0] }

# Replace region names with display names in $StorageResponseSorted and property of regions not available in this subscription will be empty
Write-Output "  Changing region names to display names"
$LocationMap = @{}
foreach ($loc in $LocationResponse.value) {
    $LocationMap[$loc.name] = $loc.displayName
}

foreach ($obj in $StorageResponseSorted) {
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
$StorageResponseSorted = $StorageResponseSorted | Where-Object { $_.locations.Count -gt 0 }

# Count distinct storage locations, excluding empty strings
$TotalStorageLocations = ($StorageResponseSorted | ForEach-Object { $_.locations[0] } | Where-Object { $_ -ne "" } | Sort-Object | Get-Unique).Count
$CurrentLocationIndex = 0

Write-Output "  Adding storage SKUs for consolidated regions"
$LastLocation = $null
$StorageResponseSorted | ForEach-Object {
    $CurrentLocation = $_.locations[0]
    if ($CurrentLocation -ne $LastLocation) {
        $CurrentLocationIndex++
        $LastLocation = $CurrentLocation
        Write-Output ("    Retrieving storage SKUs for region {0:D03} of {1:D03}: {2}" -f $CurrentLocationIndex, $TotalStorageLocations, $CurrentLocation)
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
        $Storage_SKU += @{
            Name     = $_.name
            Location = $Location
            Tier     = $_.tier
            Kind     = $_.kind
        }
        # Flatten the details properties to top-level
        foreach ($Key in $CapabilitiesProperties.Keys) {
            $Storage_SKU[-1] | Add-Member -MemberType NoteProperty -Name $Key -Value $CapabilitiesProperties[$Key] -Force
        }
    }
}

# Save the Storage SKUs to a JSON file
Write-Output "  Saving Storage SKUs to file: Azure_SKUs_Storage.json"
$Storage_SKU | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_SKUs_Storage.json"
Write-Output "  All files have been saved successfully!"

Write-Output ""
Write-Output "####################################################################################################"
Write-Output "## AVAILABILITY MAPPING TO CURRENT IMPLEMENTATION                                                 ##"
Write-Output "####################################################################################################"
Write-Output ""

# Loading summary file of script 1-Collect
Write-Output "Retrieving current implementation information"
$SummaryFilePath = "$(Get-Location)\..\1-Collect\summary.json"

if (Test-Path $SummaryFilePath) {
    Write-Output "  Loading summary file: ../1-Collect/summary.json"
    $Resources_Implementation = Get-Content -Path $SummaryFilePath | ConvertFrom-Json
} else {
    Write-Output "Summary file not found: ../1-Collect/summary.json"
    exit
}

# Check for empty SKUs and remove 'ResourceSkus' property if its value is 'N/A'
Write-Output "  Cleaning up SKU information with 'N/A'"
$Resources_Implementation = $Resources_Implementation | ForEach-Object {
    if (((($_.ResourceSkus -is [array]) -and ($_.ResourceSkus.Count -eq 1) -and ($_.ResourceSkus[0] -eq "N/A"))) -or ($_.ResourceSkus -eq "N/A")) {
        $_ | Select-Object * -ExcludeProperty ResourceSkus
    }
    else {
        $_
    }
}

# Change of property name from 'AzureRegions' to 'ImplementedRegions' and region names to display names
Write-Output "  Renaming the property 'AzureRegions' to 'ImplementedRegions' and changing region names to display names"
$Resources_Implementation = $Resources_Implementation | ForEach-Object {
    if ($_.PSObject.Properties["AzureRegions"]) {
        $oldRegions = $_.AzureRegions
        $newRegions = @()
        foreach ($region in $oldRegions) {
            if ($LocationMap.ContainsKey($region)) {
                $newRegions += $LocationMap[$region]
            } else {
                $newRegions += $region
            }
        }
        $_ | Add-Member -Force -MemberType NoteProperty -Name ImplementedRegions -Value $newRegions
        $_ | Select-Object * -ExcludeProperty AzureRegions
    }
    else {
        $_
    }
}

Write-Output "Working on general availability mapping without SKU consideration"
$TotalResourceTypes = $Resources_Implementation.Count
$CurrentResourceTypeIndex = 0

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

# Save the availability mapping to a JSON file
Write-Output "  Saving availability mapping to file: Availability_Mapping.json"
$Resources_Implementation | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Availability_Mapping.json"
