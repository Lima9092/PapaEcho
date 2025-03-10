# Minimize the PowerShell command prompt
Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    public class Win32 {
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("kernel32.dll", ExactSpelling = true)]
        public static extern IntPtr GetConsoleWindow();
    }
"@

$consolePtr = [Win32]::GetConsoleWindow()
if ($consolePtr -ne [IntPtr]::Zero) {
    # 6 = Minimize the window
    [Win32]::ShowWindow($consolePtr, 6)
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global variables
$global:robocopyProcess = $null
$global:currentRunLogFiles = @()
$global:currentRunSummaries = @()
$global:csvPath = ".\File-Migrate-First-Midweek.csv" # CSV file path
$global:masterSummaryPath = ".\File-Master-Summary.csv" # Master summary CSV file path

# Set Logs Folder Location
$logsFolder = Join-Path $PSScriptRoot "Logs"

# Ensure the Logs folder is created
if (-not (Test-Path $logsFolder)) {
    New-Item -ItemType Directory -Path $logsFolder -Force | Out-Null
}

# Function to safely append text to the output box
function Append-OutputBoxText {
    param($text)
    if ($outputBox.InvokeRequired) {
        $outputBox.Invoke([Action]{ 
            $outputBox.AppendText($text)
            $outputBox.ScrollToCaret()
        })
    } else {
        $outputBox.AppendText($text)
        $outputBox.ScrollToCaret()
    }
}

# Function to handle scheduled start
function Wait-ForScheduledStart {
    param ($scheduledTime)

    $currentDateTime = Get-Date
    $scheduledDateTime = [datetime]::ParseExact($scheduledTime, "HH:mm", $null)

    if ($scheduledDateTime -lt $currentDateTime) {
        # If the scheduled time is in the past for today, set it to tomorrow
        $scheduledDateTime = $scheduledDateTime.AddDays(1)
    }

    $waitTime = $scheduledDateTime - $currentDateTime

    if ($waitTime.TotalSeconds -gt 0) {
        Append-OutputBoxText("Waiting for scheduled start time: $scheduledTime" + [Environment]::NewLine)
        Start-Sleep -Seconds $waitTime.TotalSeconds
        Append-OutputBoxText("Scheduled start time reached: $scheduledTime" + [Environment]::NewLine)
    }
}

# Function to run Robocopy
function Run-Robocopy {
    param (
        $name,
        $siteId,
        $source,
        $destination
    )

    try {
        $startTime = Get-Date  # Capture start time
        $currentDateTime = $startTime.ToString("ddMMyy-HHmm")

        # Set up log folders specific to the SiteID
        $siteLogsFolder = Join-Path $logsFolder $siteId
        $verboseLogsFolder = Join-Path $siteLogsFolder "File-VerboseLogs"

        # Ensure the site-specific log folders are created
        if (-not (Test-Path $siteLogsFolder)) {
            New-Item -ItemType Directory -Path $siteLogsFolder -Force | Out-Null
        }
        if (-not (Test-Path $verboseLogsFolder)) {
            New-Item -ItemType Directory -Path $verboseLogsFolder -Force | Out-Null
        }

        # Set the log file path
        $logFile = "File-$siteId-$name-$currentDateTime.log"
        $logFilePath = Join-Path $verboseLogsFolder $logFile

        # Base Robocopy command arguments as an array
        $robocopyArgs = @(
            "`"$source`"", "`"$destination`"",
            "/E", "/COPY:DAT", "/R:10", "/W:5", "/V", "/XO", "/MT:32", "/RH:2030-0700", "/LOG:`"$logFilePath`""
        )

        # Add /MIR if the Mirror checkbox is checked
        if ($mirrorCheckBox.Checked) {
            $robocopyArgs += "/MIR"
        }

        # Start Robocopy and capture the output
        $outputBox.AppendText("Executing Robocopy for Site ID ${siteId}, Job: ${name}..." + [Environment]::NewLine)
        $outputBox.AppendText("robocopy $($robocopyArgs -join ' ')" + [Environment]::NewLine)

        # Run Robocopy and capture output
        $robocopyOutput = robocopy @robocopyArgs 2>&1

        # Append output to outputBox
        $outputBox.AppendText($robocopyOutput + [Environment]::NewLine)

        $endTime = Get-Date  # Capture end time
        $duration = ($endTime - $startTime).ToString("hh\:mm\:ss")

        # Format the end date and time as DDMMYY-HHMM
        $formattedEndDateTime = $endTime.ToString("ddMMyy-HHmm")

        # Parse the log file for details
        $logSummary = Parse-RobocopyLog -logFilePath $logFilePath
        if ($logSummary -eq $null) {
            throw "Failed to parse Robocopy log."
        }

        # Create a summary object with the new FormattedEndDateTime
        $summary = [PSCustomObject]@{
            SiteID                = $siteId
            Name                  = $name
            Source                = $source
            Destination           = $destination
            LogFileName           = $logFile
            Command               = $($robocopyArgs -join ' ')
            StartDate             = $startTime.ToString("dd MMMM yyyy")
            StartTime             = $startTime.ToString("HH:mm:ss")
            EndDate               = $endTime.ToString("dd MMMM yyyy")
            EndTime               = $endTime.ToString("HH:mm:ss")
            FormattedEndDateTime  = $formattedEndDateTime
            Duration              = $duration
            TotalFiles            = $logSummary.TotalFiles
            TotalDirs             = $logSummary.TotalDirs
            TotalSizeGB           = $logSummary.TotalSizeGB
            Skipped               = $logSummary.Skipped
            Failed                = $logSummary.Failed
            SpeedMbps             = $logSummary.SpeedMbps
            SpeedGBperHour        = $logSummary.SpeedGBperHour
            ErrorMessages         = $logSummary.ErrorMessages -join "; "
        }

        $global:currentRunSummaries += $summary

        $outputBox.AppendText("Robocopy job completed for $siteId." + [Environment]::NewLine)
    } catch {
        $errorMessage = "Error executing Robocopy: $_"
        $outputBox.AppendText($errorMessage + [Environment]::NewLine)
        [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } finally {
        $cancelButton.Enabled = $false
    }
}

# Parse Robocopy Log function
function Parse-RobocopyLog {
    param ($logFilePath)

    $logContent = Get-Content $logFilePath

    $summary = @{
        TotalFiles       = 0
        TotalDirs        = 0
        TotalSizeGB      = 0
        Skipped          = 0
        Failed           = 0
        SpeedBytesPerSec = 0
        SpeedMbps        = 0
        SpeedGBperHour   = 0
        ErrorMessages    = @()
    }

    foreach ($line in $logContent) {
        # Extract total files, directories, and skipped files from Files and Dirs lines
        if ($line -match "^\s*Files\s+:\s+\d+\s+(\d+)\s+(\d+)\s+\d+") {
            $summary.TotalFiles = [int]$matches[1]
            $summary.Skipped = [int]$matches[2]
        }
        if ($line -match "^\s*Dirs\s+:\s+\d+\s+(\d+)\s+(\d+)\s+\d+") {
            $summary.TotalDirs = [int]$matches[1]
        }

        # Extract total size (Total column only) from the Bytes line
        if ($line -match "^\s*Bytes\s+:\s+(.*)") {
            # Split the part after the colon into columns
            $columns = $matches[1].Trim() -split "\s+"
            if ($columns.Length -ge 2) {
                $sizeValue = $columns[0] -replace ",", ""
                $sizeUnit = $columns[1].ToLower()

                if ($sizeUnit -eq "g") {
                    # Value already in gigabytes
                    $summary.TotalSizeGB = [math]::Round([double]$sizeValue, 2)
                }
                elseif ($sizeUnit -eq "m") {
                    # Convert megabytes to gigabytes
                    $summary.TotalSizeGB = [math]::Round([double]$sizeValue / 1024, 2)
                }
                elseif ($sizeUnit -eq "k") {
                    # Convert kilobytes to gigabytes
                    $summary.TotalSizeGB = [math]::Round([double]$sizeValue / (1024 * 1024), 2)
                }
                else {
                    # If no unit is specified, assume the value is in bytes
                    $totalBytes = [int64]$sizeValue
                    $summary.TotalSizeGB = [math]::Round($totalBytes / 1GB, 2)
                }
            }
        }

        # Extract failed files and directories from Files line
        if ($line -match "^\s*Files\s+:\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)") {
            $summary.Failed = [int]$matches[1]
        }

        # Extract speed in Bytes/sec
        if ($line -match "^\s*Speed\s*:\s*([\d,]+) Bytes/sec") {
            $summary.SpeedBytesPerSec = [int]($matches[1] -replace ",", "")
            $summary.SpeedMbps = [math]::Round($summary.SpeedBytesPerSec * 8 / 1MB, 2)
            $summary.SpeedGBperHour = [math]::Round($summary.SpeedBytesPerSec * 3600 / 1GB, 2)
        }

        # Capture error messages
        if ($line -match "ERROR") {
            $summary.ErrorMessages += $line
        }
    }

    return $summary
}
# Summarize logs
function Summarize-Logs {
    if ($global:currentRunSummaries.Count -eq 0) {
        $outputBox.AppendText("No Robocopy operations found for the current run." + [Environment]::NewLine)
        return
    }

    $outputBox.AppendText("Summary of Robocopy operations:" + [Environment]::NewLine)

    # Create a new entries array for the master summary
    $newEntries = $global:currentRunSummaries

    # Display summary details in the output box
    foreach ($summary in $global:currentRunSummaries) {
        $outputBox.AppendText("========================================" + [Environment]::NewLine)
        $outputBox.AppendText("Site ID       : $($summary.SiteID)" + [Environment]::NewLine)
        $outputBox.AppendText("Name          : $($summary.Name)" + [Environment]::NewLine)
        $outputBox.AppendText("Source        : $($summary.Source)" + [Environment]::NewLine)
        $outputBox.AppendText("Destination   : $($summary.Destination)" + [Environment]::NewLine)
        $outputBox.AppendText("Start Time    : $($summary.StartDate) $($summary.StartTime)" + [Environment]::NewLine)
        $outputBox.AppendText("End Time      : $($summary.EndDate) $($summary.EndTime)" + [Environment]::NewLine)
        $outputBox.AppendText("Duration      : $($summary.Duration)" + [Environment]::NewLine)
        $outputBox.AppendText("Total Files   : $($summary.TotalFiles)" + [Environment]::NewLine)
        $outputBox.AppendText("Total Dirs    : $($summary.TotalDirs)" + [Environment]::NewLine)
        $outputBox.AppendText("Total Size GB : $($summary.TotalSizeGB)" + [Environment]::NewLine)
        $outputBox.AppendText("Files Skipped : $($summary.Skipped)" + [Environment]::NewLine)
        $outputBox.AppendText("Files Failed  : $($summary.Failed)" + [Environment]::NewLine)
        $outputBox.AppendText("Speed (Mbps)  : $($summary.SpeedMbps)" + [Environment]::NewLine)
        $outputBox.AppendText("Speed (GB/hr) : $($summary.SpeedGBperHour)" + [Environment]::NewLine)
        if ($summary.ErrorMessages) {
            $outputBox.AppendText("Errors        :" + [Environment]::NewLine)
            foreach ($error in $summary.ErrorMessages) {
                $outputBox.AppendText("  - $error" + [Environment]::NewLine)
            }
        }
        $outputBox.AppendText("========================================" + [Environment]::NewLine + [Environment]::NewLine)
        $outputBox.ScrollToCaret()
    }

    # Check if Master Summary CSV exists, if not create it
    if (-not (Test-Path $masterSummaryPath)) {
        $newEntries | Export-Csv -Path $masterSummaryPath -NoTypeInformation
        $outputBox.AppendText("Master summary created at $masterSummaryPath" + [Environment]::NewLine)
    }
    else {
        # Append new entries to the master summary
        $newEntries | Export-Csv -Path $masterSummaryPath -NoTypeInformation -Append -Force
        $outputBox.AppendText("$($newEntries.Count) new entries appended to $masterSummaryPath" + [Environment]::NewLine)
    }

    # Loop through each summary and create individual summary files with the desired naming convention
    foreach ($summary in $global:currentRunSummaries) {
        $siteId = $summary.SiteID
        $sitePath = Join-Path $logsFolder $siteId

        if (-not (Test-Path $sitePath)) {
            New-Item -ItemType Directory -Path $sitePath -Force | Out-Null
        }

        # Use the SiteID, Name, and FormattedEndDateTime for the filename
        $shareName = $summary.Name
        $shareNameSanitized = $shareName -replace '[\\/:*?"<>|]', '_'  # Replace invalid filename characters
        $siteSummaryFile = "File-$($summary.SiteID)-$shareNameSanitized-$($summary.FormattedEndDateTime).csv"
        $siteSummaryPath = Join-Path $sitePath $siteSummaryFile

        # Export the summary for the current share
        $summary | Export-Csv -Path $siteSummaryPath -NoTypeInformation
        $outputBox.AppendText("Summary saved to $siteSummaryPath" + [Environment]::NewLine)
    }
}

# Create main form
$form = New-Object system.Windows.Forms.Form
$form.Text = "File Migration: File-Migrations-First-Midweek.csv (Robocopy Run Hours 20:30-07:00)"
$form.Size = New-Object System.Drawing.Size(620, 600)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# Create ListBox with vertical and horizontal scrolling
$migrationListBox = New-Object System.Windows.Forms.ListBox
$migrationListBox.SelectionMode = "MultiExtended"
$migrationListBox.HorizontalScrollbar = $true
$migrationListBox.Location = New-Object System.Drawing.Point(20, 20)
$migrationListBox.Size = New-Object System.Drawing.Size(560, 150)
$form.Controls.Add($migrationListBox)

# Output Box
$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.Size = New-Object System.Drawing.Size(560, 200)
$outputBox.Location = New-Object System.Drawing.Point(20, 240)
$outputBox.ReadOnly = $true
$form.Controls.Add($outputBox)

# Scheduled Start Checkbox
$scheduledStartCheckBox = New-Object System.Windows.Forms.CheckBox
$scheduledStartCheckBox.Text = "Scheduled Start"
$scheduledStartCheckBox.Location = New-Object System.Drawing.Point(20, 180)
$form.Controls.Add($scheduledStartCheckBox)

# Start Time Label and TextBox
$startTimeLabel = New-Object System.Windows.Forms.Label
$startTimeLabel.Text = "Start Time (HH:mm):"
$startTimeLabel.Location = New-Object System.Drawing.Point(150, 180)
$startTimeLabel.Enabled = $false
$form.Controls.Add($startTimeLabel)

$startTimeBox = New-Object System.Windows.Forms.TextBox
$startTimeBox.Text = "20:30"  # Default value
$startTimeBox.Location = New-Object System.Drawing.Point(280, 180)
$startTimeBox.Enabled = $false
$form.Controls.Add($startTimeBox)

# Enable/Disable Start Time input when Scheduled Start checkbox is checked/unchecked
$scheduledStartCheckBox.Add_CheckedChanged({
    $startTimeLabel.Enabled = $scheduledStartCheckBox.Checked
    $startTimeBox.Enabled = $scheduledStartCheckBox.Checked
})

# Mirror (Delete Destination) Checkbox
$mirrorCheckBox = New-Object System.Windows.Forms.CheckBox
$mirrorCheckBox.Text = "Mirror (Delete Destination)"
$mirrorCheckBox.AutoSize = $true  # Ensure the checkbox text fits
$mirrorCheckBox.Location = New-Object System.Drawing.Point(20, 210)
$form.Controls.Add($mirrorCheckBox)

# Run button
$runButton = New-Object System.Windows.Forms.Button
$runButton.Location = New-Object System.Drawing.Point(20, 450)
$runButton.Size = New-Object System.Drawing.Size(100, 30)
$runButton.Text = "Run"
$form.Controls.Add($runButton)

# Run All button
$runAllButton = New-Object System.Windows.Forms.Button
$runAllButton.Location = New-Object System.Drawing.Point(130, 450)
$runAllButton.Size = New-Object System.Drawing.Size(100, 30)
$runAllButton.Text = "Run All"
$form.Controls.Add($runAllButton)

# View Summary button
$viewSummaryButton = New-Object System.Windows.Forms.Button
$viewSummaryButton.Location = New-Object System.Drawing.Point(240, 450)
$viewSummaryButton.Size = New-Object System.Drawing.Size(100, 30)
$viewSummaryButton.Text = "View Summary"
$form.Controls.Add($viewSummaryButton)

# Help button
$helpButton = New-Object System.Windows.Forms.Button
$helpButton.Location = New-Object System.Drawing.Point(350, 450)
$helpButton.Size = New-Object System.Drawing.Size(100, 30)
$helpButton.Text = "Help"
$form.Controls.Add($helpButton)

# Exit button
$exitButton = New-Object System.Windows.Forms.Button
$exitButton.Location = New-Object System.Drawing.Point(460, 450)
$exitButton.Size = New-Object System.Drawing.Size(100, 30)
$exitButton.Text = "Exit"
$form.Controls.Add($exitButton)

# Progress Bar
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(130, 490)
$progressBar.Size = New-Object System.Drawing.Size(450, 30)
$form.Controls.Add($progressBar)

# Add Cancel Button
$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Location = New-Object System.Drawing.Point(20, 490)
$cancelButton.Size = New-Object System.Drawing.Size(100, 30)
$cancelButton.Text = "Cancel"
$cancelButton.Enabled = $false
$form.Controls.Add($cancelButton)

# Load CSV data
try {
    # Check for File-Migrations.csv
    $migrations = Import-Csv $global:csvPath
    foreach ($migration in $migrations) {
        $migrationListBox.Items.Add("Site ID: $($migration.'Site ID'), Name: $($migration.Name), Source: $($migration.Source), Destination: $($migration.Destination)")
    }
}
catch {
    [System.Windows.Forms.MessageBox]::Show("Error loading CSV file: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

$runButton.Add_Click({
    try {
        if ($migrationListBox.SelectedIndices.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select at least one migration from the list.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }

        if ($scheduledStartCheckBox.Checked) {
            Wait-ForScheduledStart -scheduledTime $startTimeBox.Text
        }

        # Initialize progress bar values
        $progressBar.Minimum = 0
        $progressBar.Maximum = [Math]::Max(1, $migrationListBox.SelectedIndices.Count)
        $progressBar.Value = 0
        $global:currentRunSummaries = @()

        foreach ($index in $migrationListBox.SelectedIndices) {
            $selectedMigration = $migrations[$index]
            Run-Robocopy -siteId $selectedMigration.'Site ID' -name $selectedMigration.Name -source $selectedMigration.Source -destination $selectedMigration.Destination

            # Safely increment progress bar value
            $progressBar.Invoke([Action]{
                if ($progressBar.Value -lt $progressBar.Maximum) {
                    $progressBar.Value += 1
                }
            })
            [System.Windows.Forms.Application]::DoEvents()
        }

        Summarize-Logs
    } catch {
        $errorMessage = "An error occurred during execution: $_"
        $outputBox.Invoke([Action]{
            $outputBox.AppendText($errorMessage + [Environment]::NewLine)
            $outputBox.ScrollToCaret()
        })
        [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})


$runAllButton.Add_Click({
    try {
        if ($migrations.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No migrations available.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }

        if ($scheduledStartCheckBox.Checked) {
            Wait-ForScheduledStart -scheduledTime $startTimeBox.Text
        }

        # Initialize progress bar values
        $progressBar.Minimum = 0
        $progressBar.Maximum = [Math]::Max(1, $migrations.Count)
        $progressBar.Value = 0
        $global:currentRunSummaries = @()

        foreach ($migration in $migrations) {
            $outputBox.Invoke([Action]{
                $outputBox.AppendText("Running migration: $($migration.Name)" + [Environment]::NewLine)
                $outputBox.ScrollToCaret()
            })
            Run-Robocopy -siteId $migration.'Site ID' -name $migration.Name -source $migration.Source -destination $migration.Destination

            $outputBox.Invoke([Action]{
                $outputBox.AppendText("Completed: $($migration.Name)" + [Environment]::NewLine)
                $outputBox.ScrollToCaret()
            })

            # Safely increment progress bar value
            $progressBar.Invoke([Action]{
                if ($progressBar.Value -lt $progressBar.Maximum) {
                    $progressBar.Value += 1
                }
            })
            [System.Windows.Forms.Application]::DoEvents()
        }

        Summarize-Logs
    } catch {
        $errorMessage = "An error occurred during execution: $_"
        $outputBox.Invoke([Action]{
            $outputBox.AppendText($errorMessage + [Environment]::NewLine)
            $outputBox.ScrollToCaret()
        })
        [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$viewSummaryButton.Add_Click({
    try {
        $masterSummaryPath = Join-Path $PSScriptRoot "File-Master-Summary.csv"
        if (Test-Path $masterSummaryPath) {
            # Read the CSV file
            $csvData = Import-Csv $masterSummaryPath

            if ($csvData.Count -eq 0) {
                throw "The CSV file is empty."
            }

            # Convert CSV data to DataTable for DataGridView
            $dataTable = New-Object System.Data.DataTable

            # Add columns to DataTable based on CSV headers
            foreach ($property in $csvData[0].PSObject.Properties) {
                $dataTable.Columns.Add($property.Name) | Out-Null
            }

            # Add rows to DataTable
            foreach ($row in $csvData) {
                $dataRow = $dataTable.NewRow()
                foreach ($property in $row.PSObject.Properties) {
                    $dataRow[$property.Name] = $property.Value
                }
                $dataTable.Rows.Add($dataRow)
            }

            # Create a new form for displaying the summary
            $summaryForm = New-Object System.Windows.Forms.Form
            $summaryForm.Text = "File Master Summary"
            $summaryForm.Size = New-Object System.Drawing.Size(1000,600)
            $summaryForm.StartPosition = "CenterScreen"

            # Create a DataGridView to display the summary content
            $dataGridView = New-Object System.Windows.Forms.DataGridView
            $dataGridView.Dock = "Fill"
            $dataGridView.AllowUserToAddRows = $false
            $dataGridView.AllowUserToDeleteRows = $false
            $dataGridView.ReadOnly = $true
            $dataGridView.AutoSizeColumnsMode = "Fill"
            $dataGridView.ColumnHeadersHeightSizeMode = "AutoSize"
            $dataGridView.DataSource = $dataTable  # Set DataTable as DataSource

            # Add the DataGridView to the form
            $summaryForm.Controls.Add($dataGridView)

            # Show the form
            $summaryForm.ShowDialog()
        }
        else {
            throw "Master summary file not found: $masterSummaryPath"
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error loading or displaying CSV data: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$helpButton.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Instructions for File Migration GUI:" + [Environment]::NewLine +
        "1. CSV Requirements: The input CSV file should have the following format:" + [Environment]::NewLine +
        "   - Site ID, Name, Source, Destination" + [Environment]::NewLine +
        "   Example: ABC, Alpha, C:\source\alpha, C:\destination\alpha" + [Environment]::NewLine + [Environment]::NewLine +
        "2. Running Migrations:" + [Environment]::NewLine +
        "   - Select a migration from the list and click 'Run' to execute the migration for that specific entry." + [Environment]::NewLine +
        "   - Alternatively, click 'Run All' to execute all migrations in the list." + [Environment]::NewLine + [Environment]::NewLine +
        "3. Scheduled Start:" + [Environment]::NewLine +
        "   - Enable the 'Scheduled Start' checkbox to set a start time for the migration." + [Environment]::NewLine +
        "   - Enter the time in HH:mm format (e.g., 18:00) in the 'Start Time' field." + [Environment]::NewLine + [Environment]::NewLine +
        "4. Mirror (Delete Destination):" + [Environment]::NewLine +
        "   - Check the 'Mirror (Delete Destination)' checkbox if you want to mirror the source directory to the destination." + [Environment]::NewLine +
        "   - This will delete files in the destination that are not present in the source." + [Environment]::NewLine + [Environment]::NewLine +
        "5. Log Files:" + [Environment]::NewLine +
        "   - Log files are saved in the 'Logs' folder, with verbose logs stored in 'Logs\<SiteID>\File-VerboseLogs'." + [Environment]::NewLine +
        "   - A summary CSV is saved for each SiteID and appended to the Master Summary.",
        "Help - File Migration"
    )
})

$exitButton.Add_Click({ $form.Close() })

# Show the form
$form.Add_Shown({$form.Activate()})
[void]$form.ShowDialog()
