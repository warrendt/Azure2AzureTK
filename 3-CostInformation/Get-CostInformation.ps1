<#
.SYNOPSIS
    Take a collection of given resource IDs and return the cost incurred during previous months,
    grouped as needed. For this we use the Microsoft.CostManagement provider of each subscription.
    Requires Az.CostManagement module 0.4.2 or later.
    PS1> Install-Module -Name Az.CostManagement

.PARAMETER startDate
    The start date of the period to be examined (default is the first day of the previous month)

.PARAMETER endDate
    The end date of the period to be examined (default is the last day of the previous month)

.PARAMETER resourceFile
    A JSON file containing the resources

.PARAMETER outputFile
    The stem of the output file to be created. The extension will be added automatically based on the output format. Not used if outputFormat is 'console'.

.PARAMETER outputFormat
    The format of the output file. Supported formats are 'json', 'csv', and 'console'. Default is 'json'.

.PARAMETER testMode
    If set, only the first subscription ID will be used to retrieve a quick result set for testing purposes.

.EXAMPLE
    .\Get-CostInformation.ps1
    .\Get-CostInformation.ps1 -startDate "2023-01-01" -endDate "2023-06-30" -resourceFile "resources.json" -outputFile "resource_cost" -outputFormat "json"

#>

param (
    [string]$startDate    = (Get-Date).AddMonths(-1).ToString("yyyy-MM-01"),                    # the first day of the previous month
    [string]$endDate      = (Get-Date).AddDays(-1 * (Get-Date).Day).ToString("yyyy-MM-dd"),     # the last day of the previous month
    [string]$resourceFile = "resources.json",
    [string]$outputFile   = "resource_cost",
    [string]$outputFormat = "json",                # json, csv or console
    [switch]$testMode
)

# Input checking
# Check that the resource file exists
if (-not (Test-Path -Path $resourceFile)) {
    Write-Error "Resource file '$resourceFile' does not exist."
    exit 1
}

# Check that the requested output format is valid
if ($outputFormat -notin @("json", "csv", "console")) {
    Write-Error "Output format '$outputFormat' is not supported. Supported formats are 'json', 'csv', and 'console'."
    exit 1
}

# Timeframe
# Supported types are BillingMonthToDate, Custom, MonthToDate, TheLastBillingMonth, TheLastMonth, WeekToDate
$timeframe = "Custom"

# Granularity
# Supported types are Daily and Monthly so far. Omit just to get the total cost.
#$granularity = "Monthly"

# Type
# Supported types are Usage (deprecated), ActualCost, and AmortizedCost
# https://stackoverflow.com/questions/68223909/in-the-azure-consumption-usage-details-api-what-is-the-difference-between-the-m
$type = "AmortizedCost"

# Read the content of the workloads file
$jsonContent = Get-Content -Path $resourceFile -Raw

# Convert the JSON content to a PowerShell object
$workloads = $jsonContent | ConvertFrom-Json
$resourceTable = $workloads | Select-Object ResourceSubscriptionId, ResourceId

if ($testMode) {
    $subscriptionIds = @($subscriptionIds[0]) # For testing, use only the first subscription ID
}

$grouping = @(
    @{
        type = "Dimension"
        name = "BillingMonth"
    },
    @{
        type = "Dimension"
        name = "ResourceId"
    },
    @{
        type = "Dimension"
        name = "PricingModel"
    },
    @{
        type = "Dimension"
        name = "MeterCategory"
    },
    @{
        type = "Dimension"
        name = "MeterSubcategory"
    },
    @{
        type = "Dimension"
        name = "Meter"
    }
)

# Aggregation
# Supported types are Sum, Average, Minimum, Maximum, Count, and Total.
$aggregation = @{
    PreTaxCost = @{
        type = "Sum"
        name = "PreTaxCost"
    }
}

$table = @()

$subscriptionIds = $resourceTable.ResourceSubscriptionId | Sort-Object -Unique

if ($subscriptionIds.Count -eq 1) {
    $subscriptionIds = @($subscriptionIds) # If only one subscription ID is found, use it as an array
}

# Loop through subscription IDs and issue a cost management query for the resources in each subscription

for ($subIndex = 0; $subIndex -lt $subscriptionIds.Count; $subIndex++) {
    $scope = "/subscriptions/$($subscriptionIds[$subIndex])"

    $resourceIds = $resourceTable | Where-Object { $_.ResourceSubscriptionId -eq $subscriptionIds[$subIndex] } | Select-Object -ExpandProperty ResourceId
    Write-Output "Querying subscription $(${subIndex}+1) of $($subscriptionIds.Count): $($subscriptionIds[$subIndex])"

    $dimensions = New-AzCostManagementQueryComparisonExpressionObject -Name 'ResourceId' -Value $resourceIds
    $filter = New-AzCostManagementQueryFilterObject -Dimensions $dimensions

    $queryResult = Invoke-AzCostManagementQuery `
        -Scope $scope `
        -Timeframe $timeframe `
        -Type $type `
        -TimePeriodFrom $startDate `
        -TimePeriodTo $endDate `
        -DatasetAggregation $aggregation `
        -DatasetGrouping $grouping `
        -DatasetFilter $filter
        # -DatasetGranularity $granularity

    # Convert the query result into a table
    for ($i = 0; $i -lt $queryResult.Row.Count; $i++) {
        $row = [PSCustomObject]@{}
        for ($j = 0; $j -lt $queryResult.Column.Count; $j++) {
            $row | Add-Member -MemberType NoteProperty -Name $queryResult.Column.Name[$j] -Value $queryResult.Row[$i][$j]
        }
        $table += $row
    }
    # For testing - limit to one subscription
    # $subIndex = $subscriptionIds.Count
}

# Output in the desired format
if ($outputFormat -eq "json") {
    if ($outputFile -notmatch '\.json$') {
        $outputFile += ".json"
    }
    $table | ConvertTo-Json | Out-File -FilePath $outputFile -Encoding UTF8
    Write-Output "$($table.Count) rows written to $outputFile"
} elseif ($outputFormat -eq "csv") {
    if ($outputFile -notmatch '\.csv$') {
        $outputFile += ".csv"
    }
    $table | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
    Write-Output "$($table.Count) rows written to $outputFile"
} else {
    # Display the table in the console
    $table | Format-Table -AutoSize
}
