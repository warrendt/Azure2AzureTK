clear-host
Write-Host "####################################################################################################" -ForegroundColor DarkMagenta
Write-Host "## RETRIEVING ALL AVAILABILITIES IN THIS SUBSCRIPTION                                             ##" -ForegroundColor DarkMagenta
Write-Host "####################################################################################################" -ForegroundColor DarkMagenta
Write-Host ""

# REST API: Retrieve access token for REST API
Write-Host "Retrieving access token for REST API" -ForegroundColor Yellow
$AccessToken = az account get-access-token --query accessToken -o tsv
$SubscriptionId = az account show --query id -o tsv  # Automatically retrieve the current subscription ID
$BaseUri = "https://management.azure.com/subscriptions"

# REST API: Define headers with the access token
$Headers = @{
    Authorization = "Bearer $AccessToken"
}

# Namespaces and resource types: Start
Write-Host "Retrieving all available namespaces and resource types" -ForegroundColor Yellow
$Resources_All = az provider list --query "[].{Namespace:namespace, ResourceTypes:resourceTypes[].{Type:resourceType, Locations:locations}}" -o json | ConvertFrom-Json

# Save namespaces and resource types to a JSON file
Write-Host "  Saving namespaces and resource types to file: Azure_Resources.json" -ForegroundColor Green
$Resources_All | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_Resources.json"

# Region information: Start
Write-Host "Working on regions" -ForegroundColor Yellow
Write-Host "  Retrieving regions information" -ForegroundColor Green
$LocationUri = "$BaseUri/$SubscriptionId/locations?api-version=2022-12-01"
$LocationResponse = Invoke-RestMethod -Uri $LocationUri -Headers $Headers -Method Get

# Sort regions alphabetically by displayName
Write-Host "  Sorting regions" -ForegroundColor Green
$LocationResponse.value = $LocationResponse.value | Sort-Object displayName

# Flatten metadata to the top level and remove unwanted properties
Write-Host "  Region information flattening and PII deletion" -ForegroundColor Green
$NewLocations = @()
$TotalRegionsFlat = $LocationResponse.value.Count
$CurrentFlatIndex = 0
foreach ($region in $LocationResponse.value) {
    $CurrentFlatIndex++
    Write-Host ("    Removing information for region {0:D03} of {1:D03}: {2}" -f $CurrentFlatIndex, $TotalRegionsFlat, $region.displayName) -ForegroundColor Blue

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
Write-Host "  Saving regions to file: Azure_Regions.json" -ForegroundColor Green
$LocationResponse | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_Regions.json"

# VM SKUs: Start
Write-Host "Working on VM SKUs" -ForegroundColor Yellow

# Retrieve available regions from Microsoft.Compute
Write-Host "  Retrieving available regions from Microsoft.Compute" -ForegroundColor Green
$ComputeProvider = az provider show --namespace Microsoft.Compute --query "resourceTypes[?resourceType=='virtualMachines'].locations[]" -o tsv
$Regions = $ComputeProvider -split "`n"  # Split regions into an array for processing

# Sort the available regions (alphabetically)
Write-Host "  Sorting VM SKUs by location" -ForegroundColor Green
$Regions = $Regions | Sort-Object

$TotalRegions = $Regions.Count
$CurrentRegionIndex = 0

Write-Host "  Adding VM SKUs for consolidated regions" -ForegroundColor Green
$VMResource = @{}
foreach ($Region in $Regions) {
    $CurrentRegionIndex++
    Write-Host ("    Retrieving VM SKUs for region {0:D03} of {1:D03}: {2}" -f $CurrentRegionIndex, $TotalRegions, $Region) -ForegroundColor Blue

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
Write-Host "  Saving VM SKUs to file: Azure_SKUs_VM.json" -ForegroundColor Green
$VM_SKU | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_SKUs_VM.json"

# Storage Account SKUs: Start
Write-Host "Working on storage account SKUs" -ForegroundColor Yellow
Write-Host "  Retrieving storage account SKUs" -ForegroundColor Green
$Storage_SKU = @()

# REST API Endpoint for Storage SKUs
$StorageUri = "$BaseUri/$SubscriptionId/providers/Microsoft.Storage/skus?api-version=2021-01-01"
$StorageResponse = Invoke-RestMethod -Uri $StorageUri -Headers $Headers -Method Get

# Sort storage response by the first location value
Write-Host "  Sorting storage account SKUs by location" -ForegroundColor Green
$StorageResponseSorted = $StorageResponse.value | Sort-Object { $_.locations[0] }

# Replace region names with display names in $StorageResponseSorted and property of regions not available in this subscription will be empty
Write-Host "  Changing region names to display names" -ForegroundColor Green
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
Write-Host "  Removing regions not available in this subscription" -ForegroundColor Green
$StorageResponseSorted = $StorageResponseSorted | Where-Object { $_.locations.Count -gt 0 }

# Count distinct storage locations, excluding empty strings
$TotalStorageLocations = ($StorageResponseSorted | ForEach-Object { $_.locations[0] } | Where-Object { $_ -ne "" } | Sort-Object | Get-Unique).Count
$CurrentLocationIndex = 0

Write-Host "  Adding storage SKUs for consolidated regions" -ForegroundColor Green
$LastLocation = $null
$StorageResponseSorted | ForEach-Object {
    $CurrentLocation = $_.locations[0]
    if ($CurrentLocation -ne $LastLocation) {
        $CurrentLocationIndex++
        $LastLocation = $CurrentLocation
        Write-Host ("    Retrieving storage SKUs for region {0:D03} of {1:D03}: {2}" -f $CurrentLocationIndex, $TotalStorageLocations, $CurrentLocation) -ForegroundColor Blue
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
Write-Host "  Saving Storage SKUs to file: Azure_SKUs_Storage.json" -ForegroundColor Green
$Storage_SKU | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_SKUs_Storage.json"

Write-Host "  All files have been saved successfully!" -ForegroundColor Green

Write-Host ""
Write-Host "####################################################################################################" -ForegroundColor DarkMagenta
Write-Host "## AVAILABILITY MAPPING TO CURRENT IMPLEMENTATION                                                 ##" -ForegroundColor DarkMagenta
Write-Host "####################################################################################################" -ForegroundColor DarkMagenta
Write-Host ""

# Loading summary file of script 1-Collect
Write-Host "Retrieving current implementation information" -ForegroundColor Yellow
$SummaryFilePath = "$(Get-Location)\..\1-Collect\summary.json"

if (Test-Path $SummaryFilePath) {
    Write-Host "  Loading summary file: ../1-Collect/summary.json" -ForegroundColor Green
    $Resources_Implementation = Get-Content -Path $SummaryFilePath | ConvertFrom-Json
} else {
    Write-Host "Summary file not found: ../1-Collect/summary.json" -ForegroundColor Red
    exit
}

# Check for empty SKUs and remove 'ResourceSkus' property if its value is 'N/A'
Write-Host "  Cleaning up SKU information with 'N/A'" -ForegroundColor Green
$Resources_Implementation = $Resources_Implementation | ForEach-Object {
    if (((($_.ResourceSkus -is [array]) -and ($_.ResourceSkus.Count -eq 1) -and ($_.ResourceSkus[0] -eq "N/A"))) -or ($_.ResourceSkus -eq "N/A")) {
        $_ | Select-Object * -ExcludeProperty ResourceSkus
    }
    else {
        $_
    }
}

# Change of property name from 'AzureRegions' to 'ImplementedRegions' and region names to display names
Write-Host "  Renaming the property 'AzureRegions' to 'ImplementedRegions' and changing region names to display names" -ForegroundColor Green
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

Write-Host "Working on general availability mapping without SKU consideration" -ForegroundColor Yellow
$TotalResourceTypes = $Resources_Implementation.Count
$CurrentResourceTypeIndex = 0

Write-Host "  Adding Azure regions with resource availability information" -ForegroundColor Green
foreach ($resource in $Resources_Implementation) {
    $CurrentResourceTypeIndex++
    Write-Host ("    Processing resource type {0:D03} of {1:D03}: {2}" -f $CurrentResourceTypeIndex, $TotalResourceTypes, $resource.ResourceType) -ForegroundColor Blue
    
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
                Write-Host ("      Resource type '{0}' under namespace '{1}' not found in Resources_All" -f $rt, $ns) -ForegroundColor Red
            }
        } else {
            Write-Host ("      Namespace '{0}' not found in Resources_All" -f $ns) -ForegroundColor Red
        }
    } else {
        Write-Host ("      Invalid ResourceType format: {0}" -f $resource.ResourceType) -ForegroundColor Red
    }
}

# Save the availability mapping to a JSON file
Write-Host "  Saving availability mapping to file: Availability_Mapping.json" -ForegroundColor Green
$Resources_Implementation | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Availability_Mapping.json"
