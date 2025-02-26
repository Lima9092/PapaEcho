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

# Blob Migration GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global variables
$global:azCopyProcess = $null
$global:currentRunLogFiles = @()
$global:currentRunSummaries = @()
$global:csvPath = ".\Blob-Migrate-Active.csv" # CSV file path
$global:masterSummaryPath = ".\Blob-Master-Summary.csv" # Master summary CSV file path

# Helper function to extract values from log content
function Get-LogValue {
    param (
        [string]$content,
        [string]$pattern,
        [string]$default = "N/A"
    )
    $match = [regex]::Match($content, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $default
}

# Function to execute the initial AzCopy for a given migration (without blob tags)
function Run-AzCopy {
    param (
        $siteId,
        $name,
        $source,
        $storageAccount,
        $AzureContainer,  # Container for the initial copy (source container)
        $sasToken,
        $tagName,    # Not used in the initial copy
        $tagValue    # Not used in the initial copy
    )
    try {
        $currentDateTime = Get-Date -Format "ddMMyy-HHmm"
        # Build destination URL for the initial copy using AzureContainer
        $destination = "https://$storageAccount.blob.core.windows.net/$AzureContainer"
        $fullDestination = "$destination`?$sasToken"
        # Set AzCopy log location per SiteID
        $logFolder = Join-Path -Path $PSScriptRoot -ChildPath "Logs\$siteId\Blob-VerboseLogs"
        if (-not (Test-Path $logFolder)) {
            New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
        }
        $env:AZCOPY_LOG_LOCATION = $logFolder
        # Build the AzCopy arguments for the initial copy (note: no blob-tags)
        $azCopyArgs = @(
            "cp",
            "`"$source\*`"",
            "`"$fullDestination`"",
            "--recursive",
            "--overwrite=ifSourceNewer",
            "--log-level=INFO"
        )
        $outputBox.AppendText("Executing initial AzCopy..." + [Environment]::NewLine)
        $outputBox.AppendText("azcopy $($azCopyArgs -join ' ')" + [Environment]::NewLine)
        $startTime = Get-Date
        $azCopyOutput = & azcopy $azCopyArgs 2>&1
        $endTime = Get-Date
        $outputBox.AppendText($azCopyOutput + [Environment]::NewLine)
        # Extract job details from the output
        $jobId = [regex]::Match($azCopyOutput, "Job ([a-f0-9-]+) has started").Groups[1].Value
        $duration = ($endTime - $startTime).TotalMinutes
        $totalFiles = [regex]::Match($azCopyOutput, "Number of File Transfers: (\d+)").Groups[1].Value
        $totalTransfers = [regex]::Match($azCopyOutput, "Total Number of Transfers: (\d+)").Groups[1].Value
        $finalJobStatus = [regex]::Match($azCopyOutput, "Final Job Status: (\w+)").Groups[1].Value
        # Create a summary object for the initial copy
        $summary = [PSCustomObject]@{
            SiteID            = $siteId
            JobName           = $name
            JobId             = $jobId
            Source            = $source
            Destination       = $AzureContainer
            MigrationType     = "AZcopy CP (Initial)"
            StartDate         = $startTime.ToString("yyyy/MM/dd")
            StartTime         = $startTime.ToString("HH:mm:ss")
            EndDate           = $endTime.ToString("yyyy/MM/dd")
            EndTime           = $endTime.ToString("HH:mm:ss")
            "Duration (Mins)" = [math]::Round($duration, 4)
            TotalFiles        = $totalFiles
            TotalTransfers    = $totalTransfers
            FinalJobStatus    = $finalJobStatus
        }
        $global:currentRunSummaries += $summary
        $outputBox.AppendText("Initial AzCopy job completed." + [Environment]::NewLine)
    }
    catch {
        $errorMessage = "Error executing initial AzCopy: $_"
        $outputBox.AppendText($errorMessage + [Environment]::NewLine)
        [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", `
            [System.Windows.Forms.MessageBoxButtons]::OK, `
            [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

# Function to perform the subsequent copy using the initial copy’s destination as the source.
function Run-SubsequentCopy {
    param (
        $siteId,
        $storageAccount,
        $sasToken,
        $AzureContainer,  # Source container (where the initial copy landed)
        $ActiveContainer, # Destination container for subsequent copy
        $tagName,
        $tagValue
    )
    try {
        # Set verbose log location for subsequent copy (same as for initial copy)
        $logFolder = Join-Path -Path $PSScriptRoot -ChildPath "Logs\$siteId\Blob-VerboseLogs"
        if (-not (Test-Path $logFolder)) {
            New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
        }
        $env:AZCOPY_LOG_LOCATION = $logFolder

        # Build the source URL from the initial copy destination (using AzureContainer)
        $sourceUrl = "https://$storageAccount.blob.core.windows.net/$AzureContainer`?$sasToken"
        # Build the destination URL using the ActiveContainer variable
        $destinationUrl = "https://$storageAccount.blob.core.windows.net/$ActiveContainer`?$sasToken"
        $outputBox.AppendText("Executing subsequent copy..." + [Environment]::NewLine)
        $outputBox.AppendText("Source: $sourceUrl" + [Environment]::NewLine)
        $outputBox.AppendText("Destination: $destinationUrl" + [Environment]::NewLine)
        $startTime = Get-Date
        $azCopySubsequentArgs = @(
            "cp",
            "`"$sourceUrl`"",
            "`"$destinationUrl`"",
            "--recursive",
            "--overwrite=ifSourceNewer",
            "--include-pattern=*.zip;*.pdf;*.flv;*.ppt;*.html;*.jpeg;*.png;*.pptx;*.xls;*.xlsx;*.txt;*.rtf;*.doc;*.docx;*.odp;*.ods;*.odt;*.mp3;*.mp4;*.epub;*.wav;*.pps;*.odf;*.pub;*.jpg;*.dot;*.dotx;*.htm;*.mht;*.mhtml;*.xml;*.xps;*.csv;*.dbf;*.dif;*.prn;*.slk;*.xla;*.xlam;*.xlsb;*.xlt;*.xltx;*.xlw;*.bmp;*.emf;*.gif;*.pot;*.potx;*.ppa;*.ppam;*.ppsx;*.thmx;*.tif;*.wmf;*.wmv;*.bdr;*.cag;*.mph;*.ols;*.pbr;*.prv;*.pubhtml;*.pubmhtml;*.puz;*.wiz;*.wps;*.ps;*.ai;*.eps;*.psd;*.svg;*.tga;*.heif;*.jp2;*.jk2;*.webp;*.exr;*.hdr;*.afphoto;*.afdesign;*.aftemplate;*.cad;*.dwg;*.dxf;*.aup3;*.aif;*.aiff;*.amr;*.apu;*.au;*.caf;*.flac;*.htb;*.lof;*.m4a;*.mogg;*.ogg;*.tun;*.vst;*.wma;*.emelody;*.asf;*.wm;*.wvx;*.asx;*.wax;*.wmx;*.wpl;*.dvr-ms;*.wmd;*.avi;*.mpg;*.mpeg;*.;*.*.;*.mp2;*.mpa;*.mpe;*.m3u;*.mid;*.midi;*.rmi;*.aifc;*.snd;*.cda;*.ivf;*.wmz;*.wms;*.mov;*.m4v;*.mp4v;*.3g2;*.3gp2;*.3gp;*.3gpp;*.aac;*.adt;*.adts;*.m2ts;*.ico;*.raw;*.tiff;*.dib;*.heic;*.jqz;*.jcl;*.jcw;*.jmx;*.jmt;*.jms;*.sb3;*.afpub;*.afselection;*.jfif;*.peak;*.rpp;*.rpp-bak;*.download",
            "--blob-tags=`"$tagName=$tagValue`"",
            "--log-level=INFO"
        )
        $outputBox.AppendText("azcopy $($azCopySubsequentArgs -join ' ')" + [Environment]::NewLine)
        $azCopySubsequentOutput = & azcopy $azCopySubsequentArgs 2>&1
        $endTime = Get-Date
        $duration = ($endTime - $startTime).TotalMinutes
        $outputBox.AppendText($azCopySubsequentOutput + [Environment]::NewLine)
        # Extract job details from the subsequent copy output
        $jobId = [regex]::Match($azCopySubsequentOutput, "Job ([a-f0-9-]+) has started").Groups[1].Value
        $totalFiles = [regex]::Match($azCopySubsequentOutput, "Number of File Transfers: (\d+)").Groups[1].Value
        $totalTransfers = [regex]::Match($azCopySubsequentOutput, "Total Number of Transfers: (\d+)").Groups[1].Value
        $finalJobStatus = [regex]::Match($azCopySubsequentOutput, "Final Job Status: (\w+)").Groups[1].Value
        # Create a summary object for the subsequent copy
        $subsequentSummary = [PSCustomObject]@{
            SiteID            = $siteId
            JobName           = "Subsequent Copy"
            JobId             = $jobId
            Source            = $AzureContainer
            Destination       = $ActiveContainer
            MigrationType     = "AZcopy CP (Subsequent)"
            StartDate         = $startTime.ToString("yyyy/MM/dd")
            StartTime         = $startTime.ToString("HH:mm:ss")
            EndDate           = $endTime.ToString("yyyy/MM/dd")
            EndTime           = $endTime.ToString("HH:mm:ss")
            "Duration (Mins)" = [math]::Round($duration, 4)
            TotalFiles        = $totalFiles
            TotalTransfers    = $totalTransfers
            FinalJobStatus    = $finalJobStatus
        }
        $global:currentRunSummaries += $subsequentSummary
        $outputBox.AppendText("Subsequent copy completed." + [Environment]::NewLine)
    }
    catch {
        $errorMessage = "Error executing subsequent copy: $_"
        $outputBox.AppendText($errorMessage + [Environment]::NewLine)
        [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", `
            [System.Windows.Forms.MessageBoxButtons]::OK, `
            [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

# Function for logging
function Summarize-Logs {
    try {
        $outputBox.AppendText("Entering Summarize-Logs function." + [Environment]::NewLine)
        if ($global:currentRunSummaries.Count -eq 0) {
            $outputBox.AppendText("No AzCopy operations found for the current run." + [Environment]::NewLine)
            return
        }
        $currentDateTime = Get-Date -Format "ddMMyy-HHmm"
        $logsFolder = Join-Path $PSScriptRoot "Logs"
        if (-not (Test-Path $logsFolder)) {
            $outputBox.AppendText("Creating logs directory at: $logsFolder" + [Environment]::NewLine)
            New-Item -ItemType Directory -Path $logsFolder -Force | Out-Null
        }
        $summaryFileName = "Blob-Sync-Summary-$currentDateTime.csv"
        # Group summaries by Site ID
        $groupedSummaries = $global:currentRunSummaries | Group-Object -Property SiteID
        foreach ($group in $groupedSummaries) {
            $siteId = $group.Name
            $sitePath = Join-Path $logsFolder $siteId
            if (-not (Test-Path $sitePath)) {
                $outputBox.AppendText("Creating site directory at: $sitePath" + [Environment]::NewLine)
                New-Item -ItemType Directory -Path $sitePath -Force | Out-Null
            }
            $summaryPath = Join-Path $sitePath $summaryFileName
            $outputBox.AppendText("Saving site summary to: $summaryPath" + [Environment]::NewLine)
            $group.Group | Export-Csv -Path $summaryPath -NoTypeInformation
            $outputBox.AppendText("Detailed summary for Site ID $siteId saved to $summaryPath" + [Environment]::NewLine)
        }
        # Append to master summary CSV in the root folder
        $masterSummaryPath = Join-Path $PSScriptRoot "Blob-Master-Summary.csv"
        if (-not (Test-Path $masterSummaryPath)) {
            $outputBox.AppendText("Master summary file does not exist. Creating a new one." + [Environment]::NewLine)
            $emptyMasterSummary = @"
SiteID,LogFileName,JobName,JobId,Source,Destination,MigrationType,StartDate,StartTime,EndDate,EndTime,Duration (Mins),TotalFiles,TotalTransfers,FinalJobStatus
"@
            $emptyMasterSummary | Out-File -FilePath $masterSummaryPath -Encoding UTF8
            $existingMasterSummary = @()
        } else {
            $outputBox.AppendText("Master summary file exists at $masterSummaryPath" + [Environment]::NewLine)
            $existingMasterSummary = Import-Csv $masterSummaryPath
        }
        $newEntries = @()
        foreach ($summary in $global:currentRunSummaries) {
            $summaryWithLogFileName = [PSCustomObject]@{
                SiteID            = $summary.SiteID
                LogFileName       = $summaryFileName
                JobName           = $summary.JobName
                JobId             = $summary.JobId
                Source            = $summary.Source
                Destination       = $summary.Destination
                MigrationType     = $summary.MigrationType
                StartDate         = $summary.StartDate
                StartTime         = $summary.StartTime
                EndDate           = $summary.EndDate
                EndTime           = $summary.EndTime
                "Duration (Mins)" = $summary.'Duration (Mins)'
                TotalFiles        = $summary.TotalFiles
                TotalTransfers    = $summary.TotalTransfers
                FinalJobStatus    = $summary.FinalJobStatus
            }
            $jobKey = "$($summary.JobId)-$($summary.StartDate)-$($summary.StartTime)"
            if (-not ($existingMasterSummary | Where-Object { "$($_.JobId)-$($_.StartDate)-$($_.StartTime)" -eq $jobKey })) {
               $newEntries += $summaryWithLogFileName
            }
        }
        if ($newEntries.Count -gt 0) {
            $outputBox.AppendText("Appending $($newEntries.Count) new entries to master summary." + [Environment]::NewLine)
            $newEntries | Export-Csv -Path $masterSummaryPath -NoTypeInformation -Append
            $outputBox.AppendText("$($newEntries.Count) new entries appended to $masterSummaryPath" + [Environment]::NewLine)
        } else {
            $outputBox.AppendText("No new entries to append to master summary." + [Environment]::NewLine)
        }
        # Display a brief summary in the output box
        foreach ($item in $global:currentRunSummaries) {
            $outputBox.AppendText("Site ID: $($item.SiteID)" + [Environment]::NewLine)
            $outputBox.AppendText("Job Name: $($item.JobName)" + [Environment]::NewLine)
            $outputBox.AppendText("  Job ID: $($item.JobId)" + [Environment]::NewLine)
            $outputBox.AppendText("  Source: $($item.Source)" + [Environment]::NewLine)
            $outputBox.AppendText("  Destination: $($item.Destination)" + [Environment]::NewLine)
            $outputBox.AppendText("  Migration Type: $($item.MigrationType)" + [Environment]::NewLine)
            $outputBox.AppendText("  Start: $($item.StartDate) $($item.StartTime)" + [Environment]::NewLine)
            $outputBox.AppendText("  End: $($item.EndDate) $($item.EndTime)" + [Environment]::NewLine)
            $outputBox.AppendText("  Duration (Mins): $($item.'Duration (Mins)')" + [Environment]::NewLine)
            $outputBox.AppendText("  Files: Total=$($item.TotalFiles), Transferred=$($item.TotalTransfers)" + [Environment]::NewLine)
            $outputBox.AppendText("  Final Job Status: $($item.FinalJobStatus)" + [Environment]::NewLine)
            $outputBox.AppendText([Environment]::NewLine)
            if ($item.ErrorMessages) {
               $outputBox.AppendText("Errors:" + [Environment]::NewLine)
                foreach ($error in $item.ErrorMessages) {
                    $outputBox.AppendText("  - $error" + [Environment]::NewLine)
                }
            }
            $outputBox.AppendText("========================================" + [Environment]::NewLine + [Environment]::NewLine)
            $outputBox.ScrollToCaret()
        }
        $outputBox.AppendText("Exiting Summarize-Logs function." + [Environment]::NewLine)
    } catch {
        $errorMessage = "Error in Summarize-Logs: $_"
        $outputBox.AppendText($errorMessage + [Environment]::NewLine)
        [System.Windows.Forms.MessageBox]::Show($errorMessage, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

# Create main form
$form = New-Object system.Windows.Forms.Form
$form.Text = "Blob Migration: Active (New Process)"
$form.Size = New-Object System.Drawing.Size(620,600)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# Create ListBox with vertical and horizontal scrolling
$migrationListBox = New-Object System.Windows.Forms.ListBox
$migrationListBox.SelectionMode = "MultiExtended"
$migrationListBox.HorizontalScrollbar = $true  # Enable horizontal scrolling
$migrationListBox.Location = New-Object System.Drawing.Point(20, 20)
$migrationListBox.Size = New-Object System.Drawing.Size(560, 150)
$form.Controls.Add($migrationListBox)

# When loading the CSV, also display the ExcludeActive flag for clarity.
try {
    # Check for Active.csv
    $migrations = Import-Csv $global:csvPath
    foreach ($migration in $migrations) {
        $migrationListBox.Items.Add("Site ID: $($migration.'Site ID'), Name: $($migration.Name), Source: $($migration.Source), Azure Container: $($migration.AzureContainer), Active Container: $($migration.ActiveContainer), ExcludeActive: $($migration.ExcludeActive)")
    }
}
catch {
    [System.Windows.Forms.MessageBox]::Show("Error loading CSV file: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

$tagNameLabel = New-Object System.Windows.Forms.Label
$tagNameLabel.Text = "Tag Name:"
$tagNameLabel.Location = New-Object System.Drawing.Point(20,180)
$tagNameLabel.Size = New-Object System.Drawing.Size(100,20)
$form.Controls.Add($tagNameLabel)

$tagNameBox = New-Object System.Windows.Forms.TextBox
$tagNameBox.Text = "Meganexus"
$tagNameBox.Location = New-Object System.Drawing.Point(130,180)
$tagNameBox.Size = New-Object System.Drawing.Size(200,20)
$form.Controls.Add($tagNameBox)

$tagValueLabel = New-Object System.Windows.Forms.Label
$tagValueLabel.Text = "Tag Value:"
$tagValueLabel.Location = New-Object System.Drawing.Point(20,210)
$tagValueLabel.Size = New-Object System.Drawing.Size(100,20)
$form.Controls.Add($tagValueLabel)

$tagValueBox = New-Object System.Windows.Forms.TextBox
$tagValueBox.Text = "No"
$tagValueBox.Location = New-Object System.Drawing.Point(130,210)
$tagValueBox.Size = New-Object System.Drawing.Size(200,20)
$form.Controls.Add($tagValueBox)

$scheduledStartCheckBox = New-Object System.Windows.Forms.CheckBox
$scheduledStartCheckBox.Text = "Scheduled Start"
$scheduledStartCheckBox.Location = New-Object System.Drawing.Point(350, 180)
$scheduledStartCheckBox.Size = New-Object System.Drawing.Size(120, 20)
$form.Controls.Add($scheduledStartCheckBox)

$startTimeLabel = New-Object System.Windows.Forms.Label
$startTimeLabel.Text = "Start Time:"
$startTimeLabel.Location = New-Object System.Drawing.Point(350, 210)
$startTimeLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($startTimeLabel)

$startTimeBox = New-Object System.Windows.Forms.TextBox
$startTimeBox.Text = "20:30"
$startTimeBox.Location = New-Object System.Drawing.Point(450, 210)
$startTimeBox.Size = New-Object System.Drawing.Size(100, 20)
$startTimeBox.Enabled = $false
$form.Controls.Add($startTimeBox)

$scheduledStartCheckBox.Add_CheckedChanged({
    $startTimeBox.Enabled = $scheduledStartCheckBox.Checked
})

$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.Size = New-Object System.Drawing.Size(560,200)
$outputBox.Location = New-Object System.Drawing.Point(20,240)
$outputBox.ReadOnly = $true
$form.Controls.Add($outputBox)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Location = New-Object System.Drawing.Point(20,450)
$runButton.Size = New-Object System.Drawing.Size(100,30)
$runButton.Text = "Run"
$form.Controls.Add($runButton)

$runAllButton = New-Object System.Windows.Forms.Button
$runAllButton.Location = New-Object System.Drawing.Point(130,450)
$runAllButton.Size = New-Object System.Drawing.Size(100,30)
$runAllButton.Text = "Run All"
$form.Controls.Add($runAllButton)

$viewSummaryButton = New-Object System.Windows.Forms.Button
$viewSummaryButton.Location = New-Object System.Drawing.Point(240,450)
$viewSummaryButton.Size = New-Object System.Drawing.Size(100,30)
$viewSummaryButton.Text = "View Summary"
$form.Controls.Add($viewSummaryButton)

$helpButton = New-Object System.Windows.Forms.Button
$helpButton.Location = New-Object System.Drawing.Point(350,450)
$helpButton.Size = New-Object System.Drawing.Size(100,30)
$helpButton.Text = "Help"
$form.Controls.Add($helpButton)

$exitButton = New-Object System.Windows.Forms.Button
$exitButton.Location = New-Object System.Drawing.Point(460,450)
$exitButton.Size = New-Object System.Drawing.Size(100,30)
$exitButton.Text = "Exit"
$form.Controls.Add($exitButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Location = New-Object System.Drawing.Point(20,490)
$cancelButton.Size = New-Object System.Drawing.Size(100,30)
$cancelButton.Text = "Cancel"
$cancelButton.Enabled = $false
$form.Controls.Add($cancelButton)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(130,490)
$progressBar.Size = New-Object System.Drawing.Size(450,30)
$form.Controls.Add($progressBar)

# Function to wait until the scheduled start time
function Wait-ForScheduledStart {
   param (
        [string]$scheduledTime
    )
    $currentDateTime = Get-Date
    $scheduledDateTime = [datetime]::ParseExact($scheduledTime, "HH:mm", $null)
    if ($scheduledDateTime -lt $currentDateTime) {
        # If the scheduled time is in the past for today, set it to tomorrow
        $scheduledDateTime = $scheduledDateTime.AddDays(1)
    }
    $waitTime = $scheduledDateTime - $currentDateTime
    if ($waitTime.TotalSeconds -gt 0) {
        $outputBox.AppendText("Waiting for scheduled start time: $scheduledTime" + [Environment]::NewLine)
        Start-Sleep -Seconds $waitTime.TotalSeconds
        $outputBox.AppendText("Scheduled start time reached: $scheduledTime" + [Environment]::NewLine)
    }
}

# Run Button: Processes only the selected migrations
$runButton.Add_Click({
    if ($migrationListBox.SelectedIndices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select at least one migration from the list.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    if ($scheduledStartCheckBox.Checked) {
        Wait-ForScheduledStart -scheduledTime $startTimeBox.Text
    }
    $cancelButton.Enabled = $true
    $global:currentRunSummaries = @()
    # Set progress bar maximum to double the number of selected migrations (initial + subsequent)
    $progressBar.Value = 0
    $progressBar.Maximum = $migrationListBox.SelectedIndices.Count * 2
    foreach ($index in $migrationListBox.SelectedIndices) {
        $selectedMigration = $migrations[$index]
        # Run initial copy (without tags)
        Run-AzCopy -siteId $selectedMigration.'Site ID' `
                   -name $selectedMigration.Name `
                   -source $selectedMigration.Source `
                   -storageAccount $selectedMigration.StorageAccount `
                   -AzureContainer $selectedMigration.AzureContainer `
                   -sasToken $selectedMigration.'SAS Token' `
                   -tagName $tagNameBox.Text `
                   -tagValue $tagValueBox.Text
        $progressBar.Value += 1
        [System.Windows.Forms.Application]::DoEvents()
        # Only run subsequent copy if ExcludeActive is not set to Y/Yes
        if (-not ($selectedMigration.ExcludeActive -match '^(?i)(Y(es)?)$')) {
            Run-SubsequentCopy -siteId $selectedMigration.'Site ID' `
                               -storageAccount $selectedMigration.StorageAccount `
                               -sasToken $selectedMigration.'SAS Token' `
                               -AzureContainer $selectedMigration.AzureContainer `
                               -ActiveContainer $selectedMigration.ActiveContainer `
                               -tagName $tagNameBox.Text `
                               -tagValue $tagValueBox.Text
        }
        else {
            $outputBox.AppendText("Subsequent copy skipped for Site ID: $($selectedMigration.'Site ID') due to ExcludeActive flag." + [Environment]::NewLine)
        }
        $progressBar.Value += 1
        [System.Windows.Forms.Application]::DoEvents()
    }
    $cancelButton.Enabled = $false
    Summarize-Logs
})

# Run All Button: Processes all migrations from the CSV
$runAllButton.Add_Click({
    if ($scheduledStartCheckBox.Checked) {
        Wait-ForScheduledStart -scheduledTime $startTimeBox.Text
    }
    $cancelButton.Enabled = $true
    $global:currentRunSummaries = @()
    # Set progress bar maximum to double the number of migrations (initial + subsequent)
    $progressBar.Value = 0
    $progressBar.Maximum = $migrations.Count * 2
    foreach ($migration in $migrations) {
        Run-AzCopy -siteId $migration.'Site ID' `
                   -name $migration.Name `
                   -source $migration.Source `
                   -storageAccount $migration.StorageAccount `
                   -AzureContainer $migration.AzureContainer `
                   -sasToken $migration.'SAS Token' `
                   -tagName $tagNameBox.Text `
                   -tagValue $tagValueBox.Text
        $progressBar.Value += 1
        [System.Windows.Forms.Application]::DoEvents()
        # Check the ExcludeActive flag before running the subsequent copy
        if (-not ($migration.ExcludeActive -match '^(?i)(Y(es)?)$')) {
            Run-SubsequentCopy -siteId $migration.'Site ID' `
                               -storageAccount $migration.StorageAccount `
                               -sasToken $migration.'SAS Token' `
                               -AzureContainer $migration.AzureContainer `
                               -ActiveContainer $migration.ActiveContainer `
                               -tagName $tagNameBox.Text `
                               -tagValue $tagValueBox.Text
        }
        else {
            $outputBox.AppendText("Subsequent copy skipped for Site ID: $($migration.'Site ID') due to ExcludeActive flag." + [Environment]::NewLine)
        }
        $progressBar.Value += 1
        [System.Windows.Forms.Application]::DoEvents()
    }
    $cancelButton.Enabled = $false
    Summarize-Logs
})

$viewSummaryButton.Add_Click({
    $masterSummaryPath = Join-Path $PSScriptRoot "Blob-Master-Summary.csv"
    if (Test-Path $masterSummaryPath) {
        try {
            # Read the CSV file
            $csvData = Import-Csv $masterSummaryPath
            if ($csvData.Count -eq 0) {
                throw "The CSV file is empty."
            }
            # Create a new form for displaying the summary
            $summaryForm = New-Object System.Windows.Forms.Form
            $summaryForm.Text = "Blob Master Summary"
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
            $dataGridView.AutoGenerateColumns = $true
            # Add the DataGridView to the form
            $summaryForm.Controls.Add($dataGridView)
            # Attempt to set the DataSource
            $dataGridView.DataSource = [System.Collections.ArrayList]::new($csvData)
            # If DataSource method doesn't work, manually add columns and rows
            if ($dataGridView.Rows.Count -eq 0) {
                # Add columns
                foreach ($property in $csvData[0].PSObject.Properties) {
                    $dataGridView.Columns.Add($property.Name, $property.Name)
                }
                # Add rows
                foreach ($row in $csvData) {
                    $dataGridView.Rows.Add($row.PSObject.Properties.Value)
                }
            }
            # Show row count for debugging
            $rowCountLabel = New-Object System.Windows.Forms.Label
            $rowCountLabel.Text = "Rows: $($dataGridView.Rows.Count)"
            $rowCountLabel.Dock = "Top"
            $summaryForm.Controls.Add($rowCountLabel)
            # Show the form
            $summaryForm.ShowDialog()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Error loading or displaying CSV data: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Master summary file not found: $masterSummaryPath", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$helpButton.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "CSV File Requirements:" + [Environment]::NewLine +
        "--------------------------" + [Environment]::NewLine +
        "The CSV file should be named 'Active.csv' and placed in the same directory as this script." + [Environment]::NewLine +
        "It should have the following columns:" + [Environment]::NewLine +
        "1. Site ID: The unique identifier for the site." + [Environment]::NewLine +
        "2. Name: A unique name for the migration." + [Environment]::NewLine +
        "3. Source: The source path of the file share." + [Environment]::NewLine +
        "4. StorageAccount: The name of the Azure Storage account." + [Environment]::NewLine +
        "5. AzureContainer: The name of the container in the Azure Storage account for the initial copy (e.g. 'sitea')." + [Environment]::NewLine +
        "6. ActiveContainer: The name of the destination container for the subsequent copy (e.g. 'active')." + [Environment]::NewLine +
        "7. SAS Token: The Shared Access Signature (SAS) token for the container." + [Environment]::NewLine +
        "8. ExcludeActive: Set to 'Y' or 'Yes' to skip the subsequent (Active) copy for this job." + [Environment]::NewLine + [Environment]::NewLine +
        "How the GUI Works:" + [Environment]::NewLine +
        "--------------------------" + [Environment]::NewLine +
        "1. The list box displays all the available migrations from the CSV file." + [Environment]::NewLine +
        "2. Enter the Tag Name and Tag Value to be applied only to the subsequent copy operation." + [Environment]::NewLine +
        "3. Select one or more migrations from the list and click 'Run' to start the migration(s)." + [Environment]::NewLine +
        "4. To run all migrations in sequence, click 'Run All'." + [Environment]::NewLine +
        "5. The initial copy is performed first (copying everything to the AzureContainer), then a subsequent copy is done (filtering files and applying blob-tags) to the ActiveContainer (unless excluded via the ExcludeActive flag)." + [Environment]::NewLine +
        "6. The log output will be displayed in the text box below the list and saved in the specified verbose logs folder." + [Environment]::NewLine +
        "7. Click 'View Summary' to see details of the completed migrations." + [Environment]::NewLine +
        "8. Use the 'Cancel' button to stop the current operation." + [Environment]::NewLine +
        "9. The progress bar shows the overall progress of the operation." + [Environment]::NewLine +
        "10. Click 'Exit' to close the application." + [Environment]::NewLine +
        "11. Verbose logs are saved in the 'Logs\<SiteID>\Blob-VerboseLogs' subfolder." + [Environment]::NewLine +
        "12. A summary log is created as 'Blob-Sync-Summary-[DateTime].csv' in the 'Logs' folder." + [Environment]::NewLine +
        "13. A master summary is maintained in 'Blob-Master-Summary.csv' in the script directory.",
        "Help"
    )
})

$exitButton.Add_Click({ $form.Close() })

$cancelButton.Add_Click({
    if ($global:azCopyProcess -ne $null -and -not $global:azCopyProcess.HasExited) {
        $global:azCopyProcess.Kill()
        $outputBox.AppendText("Operation cancelled by user." + [Environment]::NewLine)
    }
    $cancelButton.Enabled = $false
})

# Show the form
$form.Add_Shown({$form.Activate()})
[void]$form.ShowDialog()
