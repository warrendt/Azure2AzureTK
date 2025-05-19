<#
.SYNOPSIS
    Exports Azure resource availability comparison between regions to Excel or CSV.

.DESCRIPTION
    Reads the output from Get-AvailabilityInformation.ps1, structures it, and
    exports to an Excel or CSV file, including SKU details.

.PARAMETER InputPath
    Path to the JSON or CSV file containing availability information.

.PARAMETER OutputPath
    Path where the report should be saved (without extension).

.PARAMETER ExportExcel
    If specified, exports to .xlsx (requires ImportExcel module), otherwise .csv.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath
)

# Import data
try {
    if ($InputPath.EndsWith(".json")) {
        $rawdata = Get-Content $InputPath | ConvertFrom-Json
    } elseif ($InputPath.EndsWith(".csv")) {
        $rawdata = Import-Csv $InputPath
    } else {
        throw "Unsupported input format. Please provide a JSON or CSV file."
    }
} catch {
    Write-Error "Failed to read input data: $_"
    exit 1
}

# Initialize an array to collect output
$reportData = @()

# Process each item in the JSON
foreach ($item in $rawdata) {
    $reportItem = [PSCustomObject]@{
        ResourceType       = $item.ResourceType
        ResourceCount      = $item.ResourceCount
        ImplementedRegions = ($item.ImplementedRegions -join ", ")
        SelectedRegion     = $item.SelectedRegion.region
        IsAvailable        = $item.SelectedRegion.available
    }

    $reportData += $reportItem
}

# Get current timestamp in format yyyyMMdd_HHmmss
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Define output file name with timestamp
$csvFileName = "Availability_Report_$timestamp.csv"
$xlsxFileName = "Availability_Report_$timestamp.xlsx"

# Export to CSV
$reportData | Export-Csv -Path $csvFileName -NoTypeInformation

# Export to Excel (requires ImportExcel module)
if (Get-Module -ListAvailable -Name ImportExcel) {
    $reportData | Export-Excel -Path $xlsxFileName -AutoSize
} else {
    Write-Warning "Excel export skipped. 'ImportExcel' module not found. Install with: Install-Module -Name ImportExcel"
}