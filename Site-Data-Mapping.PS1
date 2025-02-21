# Global Variables
$GlobalStorageAccount       = "Storageaccount"
$GlobalSASToken             = "SASToken"
$GlobalStudentContainer     = "Container"
$GlobalStaffPersonalShare   = "Staffshare"

# CSV file paths
$DataStandardsCSV = "Data-Standards.csv"
$SiteMetadataCSV  = "Site-Metadata.csv"

# Minimize the Console Window
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
$consoleHandle = (Get-Process -Id $pid).MainWindowHandle
[Win32]::ShowWindow($consoleHandle, 2)

# Load required .NET assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Helper Functions
function Load-CSVFile($filePath) {
    try {
        return Import-Csv -Path $filePath
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to load CSV: $filePath", "Error", `
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $null
    }
}

function ReplaceTokens($template, $siteMetadata) {
    if ($null -eq $template) { return "" }
    $result = $template
    $result = $result.Replace("<storageAccount>", $GlobalStorageAccount)
    $result = $result.Replace("<studentcontainer>", $GlobalStudentContainer)
    $result = $result.Replace("<staffpersonalshare>", $GlobalStaffPersonalShare)
    $result = $result.Replace("<SASToken>", $GlobalSASToken)
    $result = $result.Replace("<sitecode>", $siteMetadata.'Site-Code')
    $result = $result.Replace("<sitename>", $siteMetadata.'Site-Name')
    return $result
}

# Build the GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = "Site Data Mapping Tool"
$form.Size = New-Object System.Drawing.Size(800,600)
$form.StartPosition = "CenterScreen"

# Top panel for controls
$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Location = New-Object System.Drawing.Point(10,10)
$pnlTop.Size = New-Object System.Drawing.Size(780,70)
$form.Controls.Add($pnlTop)

$lblSiteSelect = New-Object System.Windows.Forms.Label
$lblSiteSelect.Location = New-Object System.Drawing.Point(10,10)
$lblSiteSelect.Size = New-Object System.Drawing.Size(200,20)
$lblSiteSelect.Text = "Select Site:"
$pnlTop.Controls.Add($lblSiteSelect)

$cmbSite = New-Object System.Windows.Forms.ComboBox
$cmbSite.Location = New-Object System.Drawing.Point(10,35)
$cmbSite.Size = New-Object System.Drawing.Size(300,20)
$pnlTop.Controls.Add($cmbSite)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Location = New-Object System.Drawing.Point(320,30)
$btnRun.Size = New-Object System.Drawing.Size(75,25)
$btnRun.Text = "Run"
$pnlTop.Controls.Add($btnRun)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Location = New-Object System.Drawing.Point(410,30)
$btnSave.Size = New-Object System.Drawing.Size(100,25)
$btnSave.Text = "Save CSV"
$pnlTop.Controls.Add($btnSave)

# DataGridView for displaying results
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(10,100)
$grid.Size = New-Object System.Drawing.Size(760,400)
$grid.AutoSizeColumnsMode = "Fill"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false

# Set selection mode to full row select
$grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.MultiSelect = $true
$form.Controls.Add($grid)

# Create a DataTable as the grid's data source
$dt = New-Object System.Data.DataTable
$dt.Columns.Add("Site ID")       | Out-Null
$dt.Columns.Add("Name")          | Out-Null
$dt.Columns.Add("Source")        | Out-Null
$dt.Columns.Add("Destination")   | Out-Null

$grid.DataSource = $dt.DefaultView

# Row PrePaint Event: Highlight rows based on Destination value
$grid.add_RowPrePaint({
    param($sender, $e)
    $row = $sender.Rows[$e.RowIndex]
    $dest = $row.Cells["Destination"].Value
    if ($dest -and $dest.ToString().Trim() -eq "Access Denied") {
         $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Red
         $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::Red
    }
    elseif ($dest -and $dest.ToString().Trim() -eq "Non standard share found") {
         $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Black
         $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightCoral
    }
})

# Right-click selection behavior
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuItemCopyCSV = New-Object System.Windows.Forms.ToolStripMenuItem("Copy as CSV")
$contextMenu.Items.Add($menuItemCopyCSV) | Out-Null
$grid.ContextMenuStrip = $contextMenu

$menuItemCopyCSV.Add_Click({
    $csvText = ""
    foreach ($row in $grid.SelectedRows) {
        $cells = @()
        foreach ($cell in $row.Cells) {
            $val = $cell.Value
            if ($val -eq $null) { $val = "" }
            $cells += $val.ToString()
        }
        $csvText += ($cells -join ",") + "`r`n"
    }
    if ([string]::IsNullOrEmpty($csvText)) {
        [System.Windows.Forms.MessageBox]::Show("No rows selected to copy.", "Info", `
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
    else {
        [System.Windows.Forms.Clipboard]::SetText($csvText, 'Text')
    }
})

# Preload Site Metadata CSV and Populate the Dropdown
if (Test-Path $SiteMetadataCSV) {
    $sites = Load-CSVFile $SiteMetadataCSV
    if ($sites) {
        foreach ($s in $sites) {
            $cmbSite.Items.Add($s.'Site-Name')
        }
        if ($cmbSite.Items.Count -gt 0) { $cmbSite.SelectedIndex = 0 }
    }
}
else {
    [System.Windows.Forms.MessageBox]::Show("Site Metadata CSV not found at: $SiteMetadataCSV", "Error", `
         [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

# Run Button Event: Process the Data Migration
$btnRun.Add_Click({
    $dt.Clear()

    $dataStandards = Load-CSVFile $DataStandardsCSV
    $sites = Load-CSVFile $SiteMetadataCSV

    if (-not $dataStandards -or -not $sites) {
        [System.Windows.Forms.MessageBox]::Show("One or more CSV files could not be loaded.", "Error", `
             [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    $selectedSiteName = $cmbSite.SelectedItem
    $selectedSite = $sites | Where-Object { $_.'Site-Name' -eq $selectedSiteName } | Select-Object -First 1
    if (-not $selectedSite) {
        [System.Windows.Forms.MessageBox]::Show("Selected site not found in Site Metadata.", "Error", `
             [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

# Require both Legacy-Root and Legacy-Share
    $legacyRoot = $selectedSite.'Legacy-Root'
    $legacyShare = $selectedSite.'Legacy-Share'
    if ([string]::IsNullOrEmpty($legacyRoot)) {
        [System.Windows.Forms.MessageBox]::Show("Missing Legacy-Root for site $selectedSiteName", "Meta Data Error", `
             [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    if ([string]::IsNullOrEmpty($legacyShare)) {
        [System.Windows.Forms.MessageBox]::Show("Missing Legacy-Share for site $selectedSiteName", "Meta Data Error", `
             [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    $legacyRootTrim = $legacyRoot.TrimEnd("\")
    $legacyShareTrim = $legacyShare.TrimStart("\")
    $basePath = Join-Path $legacyRootTrim $legacyShareTrim

    if (-not (Test-Path $basePath)) {
        [System.Windows.Forms.MessageBox]::Show("Legacy base path $basePath does not exist.", "Error", `
             [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

# List directories directly in the share folder
    try {
        $subDirs = Get-ChildItem -Path $basePath -Directory -ErrorAction Stop
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to list directories in $basePath.", "Error", `
             [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    foreach ($subDir in $subDirs) {
        if ($subDir.Name -ieq "Home" -or $subDir.Name -ieq "Shares") {
            try {
                $innerDirs = Get-ChildItem -Path $subDir.FullName -Directory -ErrorAction Stop
            }
            catch {
                $dr = $dt.NewRow()
                $dr["Site ID"] = $selectedSite.'Site-Code'
                $dr["Name"] = "$($selectedSite.'Site-Name') Access Denied"
                $dr["Source"] = $subDir.FullName
                $dr["Destination"] = "Access Denied"
                $dt.Rows.Add($dr)
                continue
            }
            foreach ($innerDir in $innerDirs) {
                $sourcePath = $innerDir.FullName
                $relativePath = "\" + $subDir.Name + "\" + $innerDir.Name
                $match = $dataStandards | Where-Object { $_.'Source-Path'.Trim() -eq $relativePath }
                if ($match) {
                    foreach ($m in $match) {
                        $destTemplate = $m.'Destination-Path'
                        $destination = ReplaceTokens $destTemplate $selectedSite

                        $dataTypeReplaced = ReplaceTokens $m.'Data Type' $selectedSite
                        if ($dataTypeReplaced -and $dataTypeReplaced.StartsWith($selectedSite.'Site-Name')) {
                            $name = "$dataTypeReplaced Data"
                        }
                        else {
                            $name = "$($selectedSite.'Site-Name') $dataTypeReplaced Data"
                        }
                        $siteID = $selectedSite.'Site-Code'
                        $dr = $dt.NewRow()
                        $dr["Site ID"] = $siteID
                        $dr["Name"] = $name
                        $dr["Source"] = $sourcePath
                        $dr["Destination"] = $destination
                        $dt.Rows.Add($dr)
                    }
                }
                else {
                    $siteID = $selectedSite.'Site-Code'
                    $name = "$($selectedSite.'Site-Name') Unknown Data"
                    $dr = $dt.NewRow()
                    $dr["Site ID"] = $siteID
                    $dr["Name"] = $name
                    $dr["Source"] = $sourcePath
                    $dr["Destination"] = "Non standard share found"
                    $dt.Rows.Add($dr)
                }
            }
        }
        else {
            $sourcePath = $subDir.FullName
            $relativePath = "\" + $subDir.Name
            $match = $dataStandards | Where-Object { $_.'Source-Path'.Trim() -eq $relativePath }
            if ($match) {
                foreach ($m in $match) {
                    $destTemplate = $m.'Destination-Path'
                    $destination = ReplaceTokens $destTemplate $selectedSite

                    $dataTypeReplaced = ReplaceTokens $m.'Data Type' $selectedSite
                    if ($dataTypeReplaced -and $dataTypeReplaced.StartsWith($selectedSite.'Site-Name')) {
                        $name = "$dataTypeReplaced Data"
                    }
                    else {
                        $name = "$($selectedSite.'Site-Name') $dataTypeReplaced Data"
                    }
                    $siteID = $selectedSite.'Site-Code'
                    $dr = $dt.NewRow()
                    $dr["Site ID"] = $siteID
                    $dr["Name"] = $name
                    $dr["Source"] = $sourcePath
                    $dr["Destination"] = $destination
                    $dt.Rows.Add($dr)
                }
            }
            else {
                $siteID = $selectedSite.'Site-Code'
                $name = "$($selectedSite.'Site-Name') Unknown Data"
                $dr = $dt.NewRow()
                $dr["Site ID"] = $siteID
                $dr["Name"] = $name
                $dr["Source"] = $sourcePath
                $dr["Destination"] = "Non standard share found"
                $dt.Rows.Add($dr)
            }
        }
    }
    $dt.DefaultView.Sort = "Destination ASC"
    $grid.DataSource = $dt.DefaultView
})

# Save CSV Button Event: Export the DataTable to CSV
$btnSave.Add_Click({
    if ($dt.Rows.Count -eq 0) { return }
    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    if ($saveFileDialog.ShowDialog() -eq "OK") {
         try {
              $dt | Export-Csv -Path $saveFileDialog.FileName -NoTypeInformation
              [System.Windows.Forms.MessageBox]::Show("CSV saved successfully to $($saveFileDialog.FileName)", "Success", `
                  [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
         }
         catch {
              [System.Windows.Forms.MessageBox]::Show("Failed to save CSV.", "Error", `
                  [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
         }
    }
})

# Handle Form Resize to Adjust Grid Size
$form.Add_Resize({
    $grid.Width = $form.ClientSize.Width - 20
    $grid.Height = $form.ClientSize.Height - 120
})

[void]$form.ShowDialog()
