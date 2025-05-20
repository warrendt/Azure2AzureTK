# Export Script

This script generates formatted Excel (`.xlsx`) and CSV reports based on the output from the previous check script. The reports provide detailed information for each service, including:

- **Resource type**
- **Resource count**
- **Implemented (origin) regions**
- **Implemented SKUs**
- **Selected (target) region**
- **Availability in the selected region**

These reports help you analyze service compatibility across different regions.

## Usage

1. Open a PowerShell command line.
2. Navigate to the `7-Export` folder.
3. Run the script:

    ```powershell
    .\Get-Report.ps1 -InputPath "..\2-AvailabilityCheck\Availability_Mapping_Asia_Pacific.json"
    ```

The script generates `.xlsx` and `.csv` files in the `7-Export` folder, named `Availability_Report_CURRENTTIMESTAMP`.