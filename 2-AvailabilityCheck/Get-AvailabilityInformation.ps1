<#.SYNOPSIS
    This script evaluates the availability of Azure providers and SKUs across multiple regions by querying
    Azure Resource Graph to retrieve specific properties and metadata. The extracted data will then be
    analyzed and compared against the customer's current implementation to identify potential regions suitable
    for migration.

.DESCRIPTION
    This script assesses the availability of Azure services, resources, and SKUs across multiple regions.
    By integrating its output with the data collected from the 1-Collect script, it delivers a comprehensive
    analysis of potential migration destinations, identifying suitable regions and highlighting factors that
    may impact feasibility, such as availability constraints specific to each region. All extracted data,
    including availability details and region-specific insights, will be systematically stored in JSON files
    for further evaluation and decision-making.

.EXAMPLE
    PS C:\> .\Get-AvailabilityInformation.ps1
    Runs the script and outputs the results to the default files.

.OUTPUTS
    Availability_Mapping.json
    Mapping of all currently implemented resources and their SKUs, to Azure regions with availabilities.

.OUTPUTS
    Azure_Providers.json
    All Azure providers and their resource types, including locations.

.OUTPUTS
    Azure_Regions.json
    All Azure regions with their display names, metadata, and availability information.

.OUTPUTS
    Azure_SKUs_SQL_Managed_Instance.json
    All Azure SQL managed instance SKUs with name and sku information.

.OUTPUTS
    Azure_SKUs_SQL_Server_Database.json
    All Azure SQL Server database SKUs with name, tier, family, and capacity information.

.OUTPUTS
    Azure_SKUs_StorageAccount.json
    All Azure storage account SKUs with their locations, tiers, and capabilities.

.OUTPUTS
    Azure_SKUs_VM.json
    All Azure VM SKUs with their locations, number of cores, and memory.

.NOTES
    - Requires Azure PowerShell module to be installed and authenticated.
#>

# Main script
clear-host
Write-Output "####################################################################################################"
Write-Output "## RETRIEVING ALL AVAILABILITIES IN THIS SUBSCRIPTION                                             ##"
Write-Output "####################################################################################################"
Write-Output ""

# Initialize REST API
Write-Output "Initializing REST API"
Write-Output "  Retrieving access token and subscription ID"
$AzAccessTokenSecure = Get-AzAccessToken -AsSecureString
$SecureToken = $AzAccessTokenSecure.Token
$REST_AccessToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken))
$REST_SubscriptionId = (Get-AzContext).Subscription.Id
Write-Output "    Access token and Subscription ID successfully retrieved"
Write-Output "    Subscription ID: $REST_SubscriptionId"
Write-Output "  Setting up BaseUri and headers"
$REST_BaseUri = "https://management.azure.com/subscriptions"
$REST_Headers = @{
    Authorization = "Bearer $REST_AccessToken"
}

# Providers: Start
Write-Output "Retrieving all available provider"
$Providers_Uri = "$REST_BaseUri/$REST_SubscriptionId/providers?api-version=2021-04-01" 2>$null
$Providers_Response = Invoke-RestMethod -Uri $Providers_Uri -Headers $REST_Headers -Method Get

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
$Location_Uri = "$REST_BaseUri/$REST_SubscriptionId/locations?api-version=2022-12-01" 2>$null
$Location_Response = Invoke-RestMethod -Uri $Location_Uri -Headers $REST_Headers -Method Get

# Sort regions alphabetically by displayName
Write-Output "  Sorting regions"
$Location_Response.value = $Location_Response.value | Sort-Object displayName

# Flatten metadata to the top level and remove unwanted properties
Write-Output "  Region information flattening and PII deletion"
$Location_NewLocations = @()
$Location_TotalLocations = $Location_Response.value.Count
$Location_CurrentLocationIndex = 0
foreach ($region in $Location_Response.value) {
    $Location_CurrentLocationIndex++
    Write-Output ("    Removing information for region {0:D03} of {1:D03}: {2}" -f $Location_CurrentLocationIndex, $Location_TotalLocations, $region.displayName)
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
    $Location_NewLocations += $newRegion
}
$Location_Response.value = $Location_NewLocations

# Save regions to a JSON file
Write-Output "  Saving regions to file: Azure_Regions.json"
$Location_Response | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_Regions.json"

# VM SKUs: Start
Write-Output "Working on VM SKUs"
Write-Output "  Retrieving VM SKU regions information"
$VM_Uri = "$REST_BaseUri/$REST_SubscriptionId/providers/Microsoft.Compute?api-version=2025-03-01" 2>$null
$VM_Response = Invoke-RestMethod -Uri $VM_Uri -Headers $REST_Headers -Method Get

# Filter for the resource type "virtualMachines" and extract its locations array
$VM_Regions = ($VM_Response.resourceTypes | Where-Object { $_.resourceType -eq "virtualMachines" }).locations | Sort-Object

# Retrieve SKU information for every region where VM SKUs are available
Write-Output "  Adding VM SKUs for consolidated regions"
$VM_TotalRegions = $VM_Regions.Count
$VM_CurrentRegionIndex = 0
$VM_HashSKU = @{}
foreach ($region in $VM_Regions) {
    $VM_CurrentRegionIndex++
    Write-Output ("    Retrieving VM SKUs for region {0:D03} of {1:D03}: {2}" -f $VM_CurrentRegionIndex, $VM_TotalRegions, $region)
    # REST API endpoint for VM SKUs
    $VM_Uri2 = "$REST_BaseUri/$REST_SubscriptionId/providers/Microsoft.Compute/locations/$region/vmSizes?api-version=2024-07-01"
    $VM_Response2 = Invoke-RestMethod -Uri $VM_Uri2 -Headers $REST_Headers -Method Get
    # Process the API response
    foreach ($size in $VM_Response2.value) {
        if (-not $VM_HashSKU.ContainsKey($size.name)) {
            $VM_HashSKU[$size.name] = @{
                Name          = $size.name
                Locations     = @($region)  # Initialize with the current region
                NumberOfCores = $size.numberOfCores
                MemoryInMB    = $size.memoryInMB
            }
        } else {
            # Add the region to the existing size's locations, ensuring no duplicates
            if (-not ($VM_HashSKU[$size.name].Locations -contains $region)) {
                $VM_HashSKU[$size.name].Locations += $region
            }
        }
    }
}

# Convert the hash table to an array and save the VM SKUs to a JSON file
$VM_SKU = $VM_HashSKU.Values
Write-Output "  Saving VM SKUs to file: Azure_SKUs_VM.json"
$VM_SKU | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Azure_SKUs_VM.json"

# SQL managed instance SKUs: Start
Write-Output "Working on SQL managed instance SKUs"
$SQL_ManagedInstance_SKU = @()

# Find the Microsoft.Sql provider from the available providers
Write-Output "  Retrieving SQL managed instance SKU regions information"
$SQL_ManagedInstance_Provider = $Resources_All | Where-Object { $_.Namespace -ieq "Microsoft.Sql" }
if ($SQL_ManagedInstance_Provider) {
    # Select the resource type for SQL managed instance SKUs
    $SQL_ManagedInstance_ResourceType = $SQL_ManagedInstance_Provider.ResourceTypes | Where-Object { $_.Type -ieq "managedInstances" }
    if ($SQL_ManagedInstance_ResourceType) {
        Write-Output "  Adding SQL managed instance SKUs for consolidated regions"
        $SQL_ManagedInstance_Regions = $SQL_ManagedInstance_ResourceType.Locations
        $TotalSQLManagedInstanceRegions = $SQL_ManagedInstance_Regions.Count
        $CurrentSQLManagedInstanceRegionIndex = 0        
        foreach ($region in $SQL_ManagedInstance_Regions) {
            $CurrentSQLManagedInstanceRegionIndex++
            # Convert the display region into a region code for the URL
            $regionCode = ($region -replace '\s','').ToLower()
            Write-Output ("    Retrieving SQL managed instance SKU for region {0:D03} of {1:D03}: {2}" -f $CurrentSQLManagedInstanceRegionIndex, $TotalSQLManagedInstanceRegions, $region)            
            $SQL_ManagedInstance_Uri = "$REST_BaseUri/$REST_SubscriptionId/providers/Microsoft.Sql/locations/$regionCode/capabilities?api-version=2021-02-01-preview" 2>$null
            try {
                $SQL_ManagedInstance_Response = Invoke-RestMethod -Uri $SQL_ManagedInstance_Uri -Headers $REST_Headers -Method Get
                # Select only the supportedManagedInstanceVersions property from the response
                $FilteredCapabilities = $SQL_ManagedInstance_Response | Select-Object -Property supportedManagedInstanceVersions                
                # Rebuild supportedManagedInstanceVersions
                if ($FilteredCapabilities -and $FilteredCapabilities.supportedManagedInstanceVersions) {
                    $FilteredCapabilities.supportedManagedInstanceVersions = $FilteredCapabilities.supportedManagedInstanceVersions | ForEach-Object {
                        $allSkus = @()
                        if ($_.supportedEditions) {
                            foreach ($edition in $_.supportedEditions) {
                                if ($edition.supportedFamilies) {
                                    $allSkus += $edition.supportedFamilies
                                }
                            }
                        }
                        # Group and consolidate duplicates based on family sku and family name
                        $uniqueSkus = $allSkus | Group-Object -Property { "$($_.sku)|$($_.name)" } | ForEach-Object { $_.Group[0] }
                        # Transform each consolidated object
                        $uniqueSkus = $uniqueSkus | ForEach-Object {
                            [PSCustomObject]@{
                                name = $_.name
                                sku  = $_.sku
                            }
                        }
                        [PSCustomObject]@{
                            skus = $uniqueSkus
                        }
                    }
                }                
                # Flatten the output
                if ($FilteredCapabilities.supportedManagedInstanceVersions.Count -gt 0) {
                    $sv = $FilteredCapabilities.supportedManagedInstanceVersions[0]
                }
                else {
                    $sv = [PSCustomObject]@{ skus = @() }
                }
                
                # Append the flattened object with region context
                $SQL_ManagedInstance_SKU += [PSCustomObject]@{
                    Region     = $region
                    RegionCode = $regionCode
                    skus       = $sv.skus
                }
            }
            catch {
                Write-Output ("      Error retrieving SQL managed instance SKUs for {0}: {1}" -f $regionCode, $_.Exception.Message)
            }
        }
    }
    else {
        Write-Output "  No resource type 'managedInstances' found for Microsoft.Sql in provider information."
    }
}
else {
    Write-Output "  Microsoft.Sql provider not found in provider information."
}

# Save the flattened SQL managed instance SKUs to a JSON file
Write-Output "  Saving SQL managed instance SKUs to file: Azure_SKUs_SQL_Managed_Instance.json"
$SQL_ManagedInstance_SKU | ConvertTo-Json -Depth 20 | Out-File "$(Get-Location)\Azure_SKUs_SQL_Managed_Instance.json"

# SQL Server database SKUs: Start
Write-Output "Working on SQL Server database SKUs"
$SQL_Server_Database_SKU = @()

# Find the Microsoft.Sql provider from the available providers
Write-Output "  Retrieving SQL Server database SKU regions information"
$SQL_Server_Database_Provider = $Resources_All | Where-Object { $_.Namespace -ieq "Microsoft.Sql" }
if ($SQL_Server_Database_Provider) {
    # Select the resource type for SQL Server database SKUs
    $SQL_Server_Database_ResourceType = $SQL_Server_Database_Provider.ResourceTypes | Where-Object { $_.Type -ieq "servers/databases" }
    if ($SQL_Server_Database_ResourceType) {
        Write-Output "  Adding SQL Server database SKUs for consolidated regions"
        $SQL_Server_Database_Regions = $SQL_Server_Database_ResourceType.Locations
        $TotalSQLServerDatabaseRegions = $SQL_Server_Database_Regions.Count
        $CurrentSQLServerDatabaseRegionIndex = 0

        foreach ($region in $SQL_Server_Database_Regions) {
            $CurrentSQLServerDatabaseRegionIndex++
            # Convert the display region into a region code for the URL
            $regionCode = ($region -replace '\s','').ToLower()
            Write-Output ("    Retrieving SQL Server database SKU for region {0:D03} of {1:D03}: {2}" -f $CurrentSQLServerDatabaseRegionIndex, $TotalSQLServerDatabaseRegions, $region)

            $SQL_Server_Database_Uri = "$REST_BaseUri/$REST_SubscriptionId/providers/Microsoft.Sql/locations/$regionCode/capabilities?api-version=2021-02-01-preview" 2>$null
            try {
                $SQL_Server_Database_Response = Invoke-RestMethod -Uri $SQL_Server_Database_Uri -Headers $REST_Headers -Method Get

                # Get only the supportedServerVersions property from the response
                $FilteredCapabilities = $SQL_Server_Database_Response | Select-Object -Property supportedServerVersions

                # Rebuild supportedServerVersions
                if ($FilteredCapabilities -and $FilteredCapabilities.supportedServerVersions) {
                    $FilteredCapabilities.supportedServerVersions = $FilteredCapabilities.supportedServerVersions | ForEach-Object {
                        $allSkus = @()
                        if ($_.supportedEditions) {
                            foreach ($edition in $_.supportedEditions) {
                                if ($edition.supportedServiceLevelObjectives) {
                                    $allSkus += ($edition.supportedServiceLevelObjectives | ForEach-Object {
                                        $_.sku
                                    })
                                }
                            }
                        }
                        # Group and consolidate duplicates based on sku name, tier, family, and capacity
                        $uniqueSkus = $allSkus |
                            Group-Object -Property { "$($_.name)|$($_.tier)|$($_.family)|$($_.capacity)" } |
                            ForEach-Object { $_.Group[0] }
                        # Transform each consolidated SKU object, retaining the original properties
                        $uniqueSkus = $uniqueSkus | ForEach-Object {
                            $obj = [PSCustomObject]@{
                                name     = $_.name
                                tier     = $_.tier
                                capacity = $_.capacity
                            }
                            if ($_.family) {
                                $obj | Add-Member -MemberType NoteProperty -Name family -Value $_.family
                            }
                            $obj
                        }
                        [PSCustomObject]@{
                            skus = $uniqueSkus
                        }
                    }
                }                
                # Flatten the output
                if ($FilteredCapabilities.supportedServerVersions.Count -gt 0) {
                    $sv = $FilteredCapabilities.supportedServerVersions[0]
                }
                else {
                    $sv = [PSCustomObject]@{ skus = @() }
                }                
                # Append the flattened object with region context
                $SQL_Server_Database_SKU += [PSCustomObject]@{
                    Region     = $region
                    RegionCode = $regionCode
                    skus       = $sv.skus
                }
            }
            catch {
                Write-Output ("      Error retrieving SQL Server database SKUs for {0}: {1}" -f $regionCode, $_.Exception.Message)
            }
        }
    }
    else {
        Write-Output "  No resource type 'servers/databases' found for Microsoft.Sql in provider information."
    }
}
else {
    Write-Output "  Microsoft.Sql provider not found in provider information."
}

# Save the flattened SQL Server database SKUs to a file
Write-Output "  Saving SQL Server database SKUs to file: Azure_SKUs_SQL_Server_Database.json"
$SQL_Server_Database_SKU | ConvertTo-Json -Depth 20 | Out-File "$(Get-Location)\Azure_SKUs_SQL_Server_Database.json"

# Storage Account SKUs: Start
Write-Output "Working on storage account SKUs"
Write-Output "  Retrieving storage account SKUs"
$StorageAccount_SKU = @()

# REST API Endpoint for storage account SKUs
$StorageAccount_Uri = "$REST_BaseUri/$REST_SubscriptionId/providers/Microsoft.Storage/skus?api-version=2021-01-01" 2>$null
$StorageAccount_Response = Invoke-RestMethod -Uri $StorageAccount_Uri -Headers $REST_Headers -Method Get

# Sort storage account response by the first location value
Write-Output "  Sorting storage account SKUs by location"
$StorageAccount_Response = $StorageAccount_Response.value | Sort-Object { $_.locations[0] }

# Replace region names with display names in $StorageAccount_Response and property of regions not available in this subscription will be empty
Write-Output "  Changing region names to display names"
$Location_Map = @{}
foreach ($location in $Location_Response.value) {
    $Location_Map[$location.name] = $location.displayName
}

foreach ($obj in $StorageAccount_Response) {
    $StorageAccount_NewLocations = @()
    foreach ($region in $obj.locations) {
        if ($Location_Map.ContainsKey($region)) {
            $StorageAccount_NewLocations += $Location_Map[$region]
        }
    }
    $obj.locations = $StorageAccount_NewLocations
}

# Filter out SKU objects whose locations array is empty
Write-Output "  Removing regions not available in this subscription"
$StorageAccount_Response = $StorageAccount_Response | Where-Object { $_.locations.Count -gt 0 }

# Count distinct storage account locations, excluding empty strings
Write-Output "  Adding storage account SKUs for consolidated regions"
$LastLocation = $null
$StorageAccount_TotalLocations = ($StorageAccount_Response | ForEach-Object { $_.locations[0] } | Where-Object { $_ -ne "" } | Sort-Object | Get-Unique).Count
$StorageAccount_CurrentLocationIndex = 0
$StorageAccount_Response | ForEach-Object {
    $StorageAccount_CurrentLocation = $_.locations[0]
    if ($StorageAccount_CurrentLocation -ne $LastLocation) {
        $StorageAccount_CurrentLocationIndex++
        $LastLocation = $StorageAccount_CurrentLocation
        Write-Output ("    Retrieving storage account SKUs for region {0:D03} of {1:D03}: {2}" -f $StorageAccount_CurrentLocationIndex, $StorageAccount_TotalLocations, $StorageAccount_CurrentLocation)
    }
    # Convert Capabilities into individual properties
    $CapabilitiesProperties = @{}
    $_.capabilities | ForEach-Object {
        $Capability = "$($_.name):$($_.value)"
        $NameValuePair = $Capability -split ":"
        if ($NameValuePair.Length -eq 2) {
            $Key = $NameValuePair[0].Trim()
            $CapabilitiesProperties[$Key] = $NameValuePair[1].Trim()
        }
    }
    foreach ($location in $_.locations) {  # Process each location as its own entry
        $StorageAccount_SKU += @{
            Name     = $_.name
            Location = $location
            Tier     = $_.tier
            Kind     = $_.kind
        }
        # Flatten the details properties to top-level
        foreach ($key in $CapabilitiesProperties.Keys) {
            $StorageAccount_SKU[-1] | Add-Member -MemberType NoteProperty -Name $key -Value $CapabilitiesProperties[$key] -Force
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
    Write-Output "File 'summary.json' not found in '../1-Collect/summary.json'."
    exit 1
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
            if ($Location_Map.ContainsKey($region)) {
                $newRegions += $Location_Map[$region]
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

# Map current implementation data to general Azure region availabilities
Write-Output "  Adding Azure regions with resource availability information"
$Resources_TotalImplementations = $Resources_Implementation.Count
$Resources_CurrentImplementationIndex = 0
foreach ($resource in $Resources_Implementation) {
    $Resources_CurrentImplementationIndex++
    Write-Output ("    Processing resource type {0:D03} of {1:D03}: {2}" -f $Resources_CurrentImplementationIndex, $Resources_TotalImplementations, $resource.ResourceType)
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
                # Create a mapped regions array directly using $Location_Response.value
                $MappedRegions = @()
                foreach ($region in $Location_Response.value) {
                    # Skip adding the region if its displayName is "Global"
                    if ($region.displayName -eq "Global") { continue }
                    # Check if the region is available for the resource type or if it's global available
                    $availability = if ($resourceTypeObject.Locations -contains $region.displayName -or $resourceTypeObject.Locations -contains "Global") { "true" } else { "false" }
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

# Availability SKU mapping: microsoft.compute/virtualmachines
Write-Output "  Processing SKUs for resource type: microsoft.compute/virtualmachines"
foreach ($resource in $Resources_Implementation) {
    if ($resource.ResourceType -ieq "microsoft.compute/virtualmachines") {
        # Filter regions to those available and having a SKUs property
        $Location_ValidRegions = $resource.AllRegions | Where-Object { $_.available -eq "true" -and $_.SKUs }
        $Location_TotalLocations = $Location_ValidRegions.Count
        $Location_CurrentLocationIndex = 0
        foreach ($region in $Location_ValidRegions) {
            $Location_CurrentLocationIndex++
            Write-Output ("    Processing region {0:D03} of {1:D03}: {2}" -f $Location_CurrentLocationIndex, $Location_TotalLocations, $region.region)
            $newSKUs = @()
            foreach ($sku in $region.SKUs) {
                # Convert SKU to string and extract the value using a regex
                $skuStr = [string]$sku
                if ($skuStr -match 'vmSize=(.+?)}') {
                    $skuName = $matches[1]
                }
                $isAvailable = "false"
                foreach ($vmSku in $VM_SKU) {
                    # Check if the SKU locations information contains the region and a matching SKU
                    if (($vmSku.Locations -contains $region.region) -and ($vmSku.Name -eq $skuName)) {
                        $isAvailable = "true"
                        break  # Found a matching SKU; stop looping
                    }
                }
                # Create a new object for the SKU
                $newObj = New-Object PSObject -Property @{
                    name      = $skuName
                    available = $isAvailable
                }
                $newSKUs += $newObj
            }
            # Replace the original SKUs array with the updated one
            $region.SKUs = $newSKUs
        }
    }
}

# Availability SKU mapping: microsoft.compute/disks
# Check is against storage account SKUs because because compute disks will be reported back in storage account SKU format
Write-Output "  Processing SKUs for resource type: microsoft.compute/disks"
foreach ($resource in $Resources_Implementation) {
    if ($resource.ResourceType -ieq "microsoft.compute/disks") {
        # Filter regions to those available and having a SKUs property
        $Location_ValidRegions = $resource.AllRegions | Where-Object { $_.available -eq "true" -and $_.SKUs }
        $Location_TotalLocations = $Location_ValidRegions.Count
        $Location_CurrentLocationIndex = 0
        foreach ($region in $Location_ValidRegions) {
            $Location_CurrentLocationIndex++
            Write-Output ("    Processing region {0:D3} of {1:D3}: {2}" -f $Location_CurrentLocationIndex, $Location_TotalLocations, $region.region)
            $newSKUs = @()
            foreach ($sku in $region.SKUs) {
                $isAvailable = "false"
                foreach ($store in $StorageAccount_SKU) {
                    # Check if the SKU locations information contains the region and a matching SKU
                    if (($store.Location -ieq $region.region) -and ($store.Name -eq $sku.name) -and ($store.Tier -eq $sku.tier)) {
                        $isAvailable = "true"
                        break  # Found a matching SKU; stop looping
                    }
                }
                # Create a new object for the SKU
                $newObj = New-Object PSObject -Property @{
                    name      = $sku.name
                    tier      = $sku.tier
                    available = $isAvailable
                }
                $newSKUs += $newObj
            }
            # Replace the original SKUs array with the updated one
            $region.SKUs = $newSKUs
        }
    }
}

# Save the availability mapping to a JSON file
Write-Output "  Saving availability mapping to file: Availability_Mapping.json"
$Resources_Implementation | ConvertTo-Json -Depth 10 | Out-File "$(Get-Location)\Availability_Mapping.json"
