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
    # if implementedSkus is exists and is not null
    if ($item.ImplementedSkus -and $item.ImplementedSkus.Count -gt 0) {
        $implementedSkus = ($item.ImplementedSkus | ForEach-Object {
            # Return the SKU name based on the resource type
            if ($item.ResourceType -eq "microsoft.compute/disks") {
                $_.name
            } elseif ($item.ResourceType -eq "microsoft.compute/virtualmachines") {
                $_.vmSize
            } elseif ($item.ResourceType -eq "microsoft.keyvault/vaults") {
                $_.name + " (Family: " + $_.family + ")"
            } elseif ($item.ResourceType -eq "microsoft.network/applicationgateways") {
                $_.name + " (Family: " + $_.family + ")"
            } elseif ($item.ResourceType -eq "microsoft.network/publicipaddresses") {
                $_.name + " (" + $_.tier + ")"
            } elseif ($item.ResourceType -eq "microsoft.operationalinsights/workspaces") {
                $_.name + " (Last Sku Update: " + $_.lastSkuUpdate + ")"
            } elseif ($item.ResourceType -eq "microsoft.recoveryservices/vaults") {
                $_.name + " (" + $_.tier + ")"
            } elseif ($item.ResourceType -eq "microsoft.sql/servers/databases") {
                $_.name + " (Capacity: " + $_.capacity + ")"
            } elseif ($item.ResourceType -eq "microsoft.storage/storageaccounts") {
                $_.name
            } else {
                # No action for other resource types
            }
        }) -join ", "
    } else {
        $implementedSkus = "N/A"
    }

    $reportItem = [PSCustomObject]@{
        ResourceType       = $item.ResourceType
        ResourceCount      = $item.ResourceCount
        ImplementedRegions = ($item.ImplementedRegions -join ", ")
        ImplementedSkus    = $implementedSkus
        SelectedRegion     = $item.SelectedRegion.region
        IsAvailable        = $item.SelectedRegion.available
    }

    $reportData += $reportItem
}

# Define output file name with current timestamp (yyyyMMdd_HHmmss)
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvFileName = "Availability_Report_$timestamp.csv"
$xlsxFileName = "Availability_Report_$timestamp.xlsx"

$excelParams = @{
    Path           = $xlsxFileName
    WorksheetName  = "General"
    AutoSize       = $true
    TableStyle     = 'None'
    PassThru       = $true
}

# Export to CSV
$reportData | Export-Csv -Path $csvFileName -NoTypeInformation

# Make the Excel first row (header) with blue background and white text
$excelParams = @{
    Path           = $xlsxFileName
    WorksheetName  = "General"
    AutoSize       = $true
    TableStyle     = 'None'
    PassThru       = $true
}

if (Get-Module -ListAvailable -Name ImportExcel) {
    $excelPkg = $reportData | Export-Excel @excelParams
    $ws = $excelPkg.Workbook.Worksheets["General"]
    if ($reportData -and $reportData.Count -gt 0 -and $reportData[0]) {
        $lastColLetter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter(6)
        $headerRange = $ws.Cells["A1:$lastColLetter`1"]
        $headerRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $headerRange.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::RoyalBlue)
        $headerRange.Style.Font.Color.SetColor([System.Drawing.Color]::White)

        # Set background color for IsAvailable column based on value
        for ($row = 2; $row -le ($reportData.Count + 1); $row++) {
            $cell = $ws.Cells["F$row"]
            if ($cell.Value -eq $true) {
            $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::LightGreen)
            } elseif ($cell.Value -eq $false) {
            $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::LightCoral)
            }
        }
    }
    $excelPkg.Save()
} else {
    Write-Warning "Excel export skipped. 'ImportExcel' module not found. Install with: Install-Module -Name ImportExcel"
}
