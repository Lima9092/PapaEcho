# Configuration
$numberOfThreads = 6  # Configurable number of threads, default is 6
$pathtranslation = "\\storageaccount.files.core.windows.net\staffhomefolders\"
$fuzzyThreshold = 0.75

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
[Win32]::ShowWindow($consoleHandle, 2)  # 2 minimizes the window

# Add required .NET assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Ensure ThreadJob module is available
if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
    Install-Module -Name ThreadJob -Scope CurrentUser -Force
}
Import-Module ThreadJob

# Functions
function Get-LevenshteinDistance {
    param (
        [string]$s,
        [string]$t
    )
    if ($s.Length -eq 0) { return $t.Length }
    if ($t.Length -eq 0) { return $s.Length }
    $m = $s.Length + 1
    $n = $t.Length + 1
    $d = New-Object 'int[,]' $m, $n
    for ($i = 0; $i -lt $m; $i++) {
        $d[$i, 0] = $i
    }
    for ($j = 0; $j -lt $n; $j++) {
        $d[0, $j] = $j
    }
    for ($i = 1; $i -lt $m; $i++) {
        for ($j = 1; $j -lt $n; $j++) {
            if ($s[($i - 1)] -eq $t[($j - 1)]) { $cost = 0 } else { $cost = 1 }
            $deleteCost = $d[($i - 1), $j] + 1
            $insertCost = $d[$i, ($j - 1)] + 1
            $substituteCost = $d[($i - 1), ($j - 1)] + $cost
            $d[$i, $j] = [Math]::Min([Math]::Min($deleteCost, $insertCost), $substituteCost)
        }
    }
    return $d[$s.Length, $t.Length]
}

function Get-Similarity {
    param (
        [string]$s,
        [string]$t
    )
    $distance = Get-LevenshteinDistance -s $s -t $t
    $maxLen = [Math]::Max($s.Length, $t.Length)
    if ($maxLen -eq 0) { return 1 }
    return (1 - ($distance / $maxLen))
}

function Import-UserCsv {
    param (
        [string]$Path
    )
    $firstLine = Get-Content -Path $Path -TotalCount 1
    if ($firstLine -match "@") {
        return Import-Csv -Path $Path -Header "UPN","OneDrive"
    }
    else {
        return Import-Csv -Path $Path
    }
}

function Remove-TrailingNumbers {
    param (
        [string]$text
    )
    return ($text.Trim() -replace "\d+$", "")
}

function Extract-NameParts {
    param (
        [string]$fullName
    )
    $fullName = $fullName.Trim()
    $parts = $fullName.Split(".")
    if ($parts.Length -ge 2) {
        $firstName = $parts[0].Trim()
        $lastName = $parts[1].Trim()
        $firstInitial = $firstName.Substring(0,1)
        $lastInitial = $lastName.Substring(0,1)
        return @{
            FirstName    = $firstName;
            LastName     = $lastName;
            FirstInitial = $firstInitial;
            LastInitial  = $lastInitial
        }
    }
    else {
        return @{
            FirstName    = $fullName;
            LastName     = "";
            FirstInitial = $fullName.Substring(0,1);
            LastInitial  = ""
        }
    }
}

function IsMatch {
    param (
        [string]$folderName,
        [hashtable]$nameParts
    )
    $folderNameNormalized = ($folderName.Trim().ToLower()) -replace "\s+", ""
    $firstName  = $nameParts.FirstName.ToLower()
    $lastName   = $nameParts.LastName.ToLower()
    $firstInit  = $nameParts.FirstInitial.ToLower()
    $lastInit   = $nameParts.LastInitial.ToLower()
    
    if ($folderNameNormalized -eq "$firstInit$lastName") { return $true }
    if ($folderNameNormalized -eq "$firstName$lastName") { return $true }
    if ($folderNameNormalized -eq "$lastName$firstName") { return $true }
    if ($folderNameNormalized -eq "$firstInit.$lastName") { return $true }
    if ($folderNameNormalized -eq "$firstName.$lastName") { return $true }
    for ($i = 1; $i -le 4; $i++) {
         $pattern = "^" + [regex]::Escape($firstInit) + ".{1,$i}" + [regex]::Escape($lastName) + "$"
         if ($folderNameNormalized -match $pattern) { return $true }
    }
    if ($folderNameNormalized -eq "$lastName$firstInit") { return $true }
    if ($folderNameNormalized -eq "$firstName$lastInit") { return $true }
    return $false
}

function Get-DirectoriesUpToDepth {
    param(
       [string]$Path,
       [int]$maxDepth = 2,
       [int]$currentLevel = 1
    )
    if ($currentLevel -gt $maxDepth) { return @() }
    $dirs = Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue
    $result = @()
    foreach ($dir in $dirs) {
         $result += $dir
         $result += Get-DirectoriesUpToDepth -Path $dir.FullName -maxDepth $maxDepth -currentLevel ($currentLevel + 1)
    }
    return $result
}

# Build the GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = "Home Drive Mapping (Multithreaded)"
$form.Size = New-Object System.Drawing.Size(800,680)
$form.StartPosition = "CenterScreen"

# Site Metadata DropDown
$labelSelectSite = New-Object System.Windows.Forms.Label
$labelSelectSite.Location = New-Object System.Drawing.Point(10,20)
$labelSelectSite.Size = New-Object System.Drawing.Size(120,20)
$labelSelectSite.Text = "Select Site:"
$form.Controls.Add($labelSelectSite)

$comboBoxSite = New-Object System.Windows.Forms.ComboBox
$comboBoxSite.Location = New-Object System.Drawing.Point(140,20)
$comboBoxSite.Size = New-Object System.Drawing.Size(250,20)
$comboBoxSite.DropDownStyle = 'DropDownList'
$form.Controls.Add($comboBoxSite)

# Global variables for site metadata and selection
$global:siteMetadata = @()
$global:selectedSite = $null
$global:knownHomes = ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$metadataPath = Join-Path $scriptDir "site-metadata.csv"
if (Test-Path $metadataPath) {
    $global:siteMetadata = Import-Csv -Path $metadataPath
    foreach ($site in $global:siteMetadata) {
        $comboBoxSite.Items.Add($site.'Site-Name') | Out-Null
    }
}
else {
    [System.Windows.Forms.MessageBox]::Show("site-metadata.csv not found in $scriptDir", "Error", "OK", "Error")
}

$comboBoxSite.Add_SelectedIndexChanged({
    $selectedSiteName = $comboBoxSite.SelectedItem
    $matchSite = $global:siteMetadata | Where-Object { $_."Site-Name" -eq $selectedSiteName }
    if ($matchSite) {
        $global:selectedSite = $matchSite
        $legacyRoot = $matchSite.'Legacy-Root'
        $legacyShare = $matchSite.'Legacy-Share'
        if (-not $legacyRoot.EndsWith("\")) { $legacyRoot += "\" }
        $basePath = ($legacyRoot.TrimEnd("\") + $legacyShare).Replace("\\\\", "\")
        $textBoxDir.Text = $basePath
        $global:knownHomes = $matchSite.'Known-Homes'
    }
})

# CSV File Selection
$labelCSV = New-Object System.Windows.Forms.Label
$labelCSV.Location = New-Object System.Drawing.Point(10,60)
$labelCSV.Size = New-Object System.Drawing.Size(120,20)
$labelCSV.Text = "Select CSV File:"
$form.Controls.Add($labelCSV)

$textBoxCSV = New-Object System.Windows.Forms.TextBox
$textBoxCSV.Location = New-Object System.Drawing.Point(140,60)
$textBoxCSV.Size = New-Object System.Drawing.Size(500,20)
$form.Controls.Add($textBoxCSV)

$buttonBrowseCSV = New-Object System.Windows.Forms.Button
$buttonBrowseCSV.Location = New-Object System.Drawing.Point(650,58)
$buttonBrowseCSV.Size = New-Object System.Drawing.Size(100,24)
$buttonBrowseCSV.Text = "Browse CSV"
$form.Controls.Add($buttonBrowseCSV)

# Directory Selection
$labelDir = New-Object System.Windows.Forms.Label
$labelDir.Location = New-Object System.Drawing.Point(10,100)
$labelDir.Size = New-Object System.Drawing.Size(120,20)
$labelDir.Text = "Select Directory:"
$form.Controls.Add($labelDir)

$textBoxDir = New-Object System.Windows.Forms.TextBox
$textBoxDir.Location = New-Object System.Drawing.Point(140,100)
$textBoxDir.Size = New-Object System.Drawing.Size(500,20)
$form.Controls.Add($textBoxDir)

$buttonBrowseDir = New-Object System.Windows.Forms.Button
$buttonBrowseDir.Location = New-Object System.Drawing.Point(650,98)
$buttonBrowseDir.Size = New-Object System.Drawing.Size(100,24)
$buttonBrowseDir.Text = "Browse Dir"
$form.Controls.Add($buttonBrowseDir)

# Checkboxes
$checkBoxFileCount = New-Object System.Windows.Forms.CheckBox
$checkBoxFileCount.Location = New-Object System.Drawing.Point(140,140)
$checkBoxFileCount.Size = New-Object System.Drawing.Size(150,20)
$checkBoxFileCount.Text = "Include File Count"
$form.Controls.Add($checkBoxFileCount)

$checkBoxFolderSize = New-Object System.Windows.Forms.CheckBox
$checkBoxFolderSize.Location = New-Object System.Drawing.Point(300,140)
$checkBoxFolderSize.Size = New-Object System.Drawing.Size(150,20)
$checkBoxFolderSize.Text = "Include Folder Size"
$form.Controls.Add($checkBoxFolderSize)

# Run and Save Buttons
$buttonRun = New-Object System.Windows.Forms.Button
$buttonRun.Location = New-Object System.Drawing.Point(10,180)
$buttonRun.Size = New-Object System.Drawing.Size(100,30)
$buttonRun.Text = "Run"
$form.Controls.Add($buttonRun)

$buttonSave = New-Object System.Windows.Forms.Button
$buttonSave.Location = New-Object System.Drawing.Point(120,180)
$buttonSave.Size = New-Object System.Drawing.Size(100,30)
$buttonSave.Text = "Save CSV"
$form.Controls.Add($buttonSave)

# DataGridView
$dataGrid = New-Object System.Windows.Forms.DataGridView
$dataGrid.Location = New-Object System.Drawing.Point(10,220)
$dataGrid.Size = New-Object System.Drawing.Size(760,380)
$dataGrid.AutoSizeColumnsMode = "Fill"
$dataGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$dataGrid.SelectionMode = "FullRowSelect"
$dataGrid.MultiSelect = $true
$form.Controls.Add($dataGrid)

# Right-click selection behavior
$dataGrid.add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $hitTestInfo = $dataGrid.HitTest($e.X, $e.Y)
        if ($hitTestInfo.RowIndex -ge 0) {
            if (-not $dataGrid.Rows[$hitTestInfo.RowIndex].Selected) {
                $dataGrid.ClearSelection()
                $dataGrid.Rows[$hitTestInfo.RowIndex].Selected = $true
            }
        }
    }
})

$global:results = @()

# Context Menu for Copy
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuItemCopyAsCSV = New-Object System.Windows.Forms.ToolStripMenuItem("Copy as CSV")
$menuItemCopyAsExcel = New-Object System.Windows.Forms.ToolStripMenuItem("Copy as Excel")
$contextMenu.Items.Add($menuItemCopyAsCSV)
$contextMenu.Items.Add($menuItemCopyAsExcel)
$dataGrid.ContextMenuStrip = $contextMenu

$menuItemCopyAsCSV.add_Click({
    $selectedRows = @($dataGrid.SelectedRows) | Sort-Object { $_.Index }
    if ($selectedRows.Count -eq 0) { return }
    # Build CSV text with headers.
    $headers = $dataGrid.Columns | ForEach-Object { $_.HeaderText }
    $csvContent = @()
    $csvContent += [string]::Join(",", $headers)
    foreach ($row in $selectedRows) {
        $values = @()
        foreach ($col in $dataGrid.Columns) {
            $cellValue = $row.Cells[$col.Index].Value
            if ($cellValue -eq $null) { $cellValue = "" }
            $escapedValue = $cellValue.ToString().Replace('"','""')
            if ($escapedValue.Contains(",") -or $escapedValue.Contains('"') -or $escapedValue.Contains("`n")) {
                $escapedValue = '"' + $escapedValue + '"'
            }
            $values += $escapedValue
        }
        $csvContent += [string]::Join(",", $values)
    }
    $csvText = $csvContent -join "`r`n"
    [System.Windows.Forms.Clipboard]::SetText($csvText)
})

$menuItemCopyAsExcel.add_Click({
    $selectedRows = @($dataGrid.SelectedRows) | Sort-Object { $_.Index }
    if ($selectedRows.Count -eq 0) { return }
    $excelContent = @()
    foreach ($row in $selectedRows) {
        $values = @()
        foreach ($col in $dataGrid.Columns) {
            $cellValue = $row.Cells[$col.Index].Value
            if ($cellValue -eq $null) { $cellValue = "" }
            $values += $cellValue.ToString()
        }
        $excelContent += [string]::Join("`t", $values)
    }
    $excelText = $excelContent -join "`r`n"
    [System.Windows.Forms.Clipboard]::SetText($excelText)
})

# Event Handlers for Browse Buttons
$buttonBrowseCSV.Add_Click({
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    if ($openFileDialog.ShowDialog() -eq "OK") {
         $textBoxCSV.Text = $openFileDialog.FileName
    }
})

$buttonBrowseDir.Add_Click({
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderBrowser.ShowDialog() -eq "OK") {
         $textBoxDir.Text = $folderBrowser.SelectedPath
    }
})

# Run Button
$buttonRun.Add_Click({
    $global:results = @()
    if (-not (Test-Path $textBoxCSV.Text)) { return }
    try {
         $users = Import-UserCsv -Path $textBoxCSV.Text
    }
    catch { return }
    if (-not (Test-Path $textBoxDir.Text)) { return }
    
    # Build folder list
    $folderInfoList = @()
    if ($global:knownHomes -and $global:knownHomes.Trim() -ne "") {
         $knownHomesList = $global:knownHomes.Split(";") | ForEach-Object { $_.Trim() }
         foreach ($homeFolder in $knownHomesList) {
             $homePath = Join-Path $textBoxDir.Text $homeFolder
             if (Test-Path $homePath) {
                 $folders = Get-DirectoriesUpToDepth -Path $homePath -maxDepth 2
                 foreach ($folder in $folders) {
                     $folderInfoList += [PSCustomObject]@{
                         FolderName    = $folder.Name
                         UNCPath       = $folder.FullName
                         "File Count"  = $null
                         "Folder Size" = $null
                     }
                 }
             }
         }
    }
    else {
         $basePath = $textBoxDir.Text
         if (Test-Path $basePath) {
             $folders = Get-DirectoriesUpToDepth -Path $basePath -maxDepth 3
             foreach ($folder in $folders) {
                 $folderInfoList += [PSCustomObject]@{
                     FolderName    = $folder.Name
                     UNCPath       = $folder.FullName
                     "File Count"  = $null
                     "Folder Size" = $null
                 }
             }
         }
    }
    
    # Process users using ThreadJob
    $jobs = @()
    $userBatchSize = [math]::Ceiling($users.Count / $numberOfThreads)
    $userBatches = $users | Group-Object -Property { [math]::Floor([array]::IndexOf($users, $_) / $userBatchSize) }

    foreach ($batch in $userBatches) {
        $batchUsers = $batch.Group
        $jobs += Start-ThreadJob -ScriptBlock {
            param($users, $folderInfoList, $pathtranslation, $textBoxDir, $fuzzyThreshold, $selectedSite)
            
            # Re-import functions into the thread scope
            function Get-LevenshteinDistance {
                param (
                    [string]$s,
                    [string]$t
                )
                if ($s.Length -eq 0) { return $t.Length }
                if ($t.Length -eq 0) { return $s.Length }
                $m = $s.Length + 1
                $n = $t.Length + 1
                $d = New-Object 'int[,]' $m, $n
                for ($i = 0; $i -lt $m; $i++) {
                    $d[$i, 0] = $i
                }
                for ($j = 0; $j -lt $n; $j++) {
                    $d[0, $j] = $j
                }
                for ($i = 1; $i -lt $m; $i++) {
                    for ($j = 1; $j -lt $n; $j++) {
                        if ($s[($i - 1)] -eq $t[($j - 1)]) { $cost = 0 } else { $cost = 1 }
                        $deleteCost = $d[($i - 1), $j] + 1
                        $insertCost = $d[$i, ($j - 1)] + 1
                        $substituteCost = $d[($i - 1), ($j - 1)] + $cost
                        $d[$i, $j] = [Math]::Min([Math]::Min($deleteCost, $insertCost), $substituteCost)
                    }
                }
                return $d[$s.Length, $t.Length]
            }

            function Get-Similarity {
                param (
                    [string]$s,
                    [string]$t
                )
                $distance = Get-LevenshteinDistance -s $s -t $t
                $maxLen = [Math]::Max($s.Length, $t.Length)
                if ($maxLen -eq 0) { return 1 }
                return (1 - ($distance / $maxLen))
            }

            function Remove-TrailingNumbers {
                param (
                    [string]$text
                )
                return ($text.Trim() -replace "\d+$", "")
            }

            function Extract-NameParts {
                param (
                    [string]$fullName
                )
                $fullName = $fullName.Trim()
                $parts = $fullName.Split(".")
                if ($parts.Length -ge 2) {
                    $firstName = $parts[0].Trim()
                    $lastName = $parts[1].Trim()
                    $firstInitial = $firstName.Substring(0,1)
                    $lastInitial = $lastName.Substring(0,1)
                    return @{
                        FirstName    = $firstName;
                        LastName     = $lastName;
                        FirstInitial = $firstInitial;
                        LastInitial  = $lastInitial
                    }
                }
                else {
                    return @{
                        FirstName    = $fullName;
                        LastName     = "";
                        FirstInitial = $fullName.Substring(0,1);
                        LastInitial  = ""
                    }
                }
            }

            function IsMatch {
                param (
                    [string]$folderName,
                    [hashtable]$nameParts
                )
                $folderNameNormalized = ($folderName.Trim().ToLower()) -replace "\s+", ""
                $firstName  = $nameParts.FirstName.ToLower()
                $lastName   = $nameParts.LastName.ToLower()
                $firstInit  = $nameParts.FirstInitial.ToLower()
                $lastInit   = $nameParts.LastInitial.ToLower()
                
                if ($folderNameNormalized -eq "$firstInit$lastName") { return $true }
                if ($folderNameNormalized -eq "$firstName$lastName") { return $true }
                if ($folderNameNormalized -eq "$lastName$firstName") { return $true }
                if ($folderNameNormalized -eq "$firstInit.$lastName") { return $true }
                if ($folderNameNormalized -eq "$firstName.$lastName") { return $true }
                for ($i = 1; $i -le 4; $i++) {
                    $pattern = "^" + [regex]::Escape($firstInit) + ".{1,$i}" + [regex]::Escape($lastName) + "$"
                    if ($folderNameNormalized -match $pattern) { return $true }
                }
                if ($folderNameNormalized -eq "$lastName$firstInit") { return $true }
                if ($folderNameNormalized -eq "$firstName$lastInit") { return $true }
                return $false
            }

            $results = @()
            foreach ($user in $users) {
                if ($user.UPN) {
                    $email = $user.UPN.Trim()
                    $localPart = ($email.Split("@")[0]).Trim()
                    $localPart = Remove-TrailingNumbers $localPart
                    $nameParts = Extract-NameParts $localPart
                    
                    $matchesForUser = @()
                    foreach ($folder in $folderInfoList) {
                        if (IsMatch $folder.FolderName $nameParts) {
                            $basePath = $textBoxDir.Trim()
                            if (-not $basePath.EndsWith("\")) { $basePath += "\" }
                            $relativePath = $folder.UNCPath.Substring($basePath.Length)
                            if ($relativePath.StartsWith("\")) { $relativePath = $relativePath.Substring(1) }
                            $siteCode = ($selectedSite.'Site-Code').Trim()
                            $newSource = $pathtranslation + $siteCode + "\" + $relativePath
                            
                            $matchesForUser += [PSCustomObject]@{
                                "Email"       = $email
                                "Source"      = $newSource
                                "OneDrive"    = $user.OneDrive
                                "UNCPath"     = $folder.UNCPath
                                "File Count"  = $null
                                "Folder Size" = $null
                                "Errors"      = ""
                            }
                        }
                    }
                    
                    if ($matchesForUser.Count -eq 0) {
                        $bestMatch = $null
                        $bestScore = 0
                        $reference = $localPart.ToLower()
                        foreach ($folder in $folderInfoList) {
                            $folderName = ($folder.FolderName.Trim().ToLower()) -replace "\s+", ""
                            $score = Get-Similarity -s $folderName -t $reference
                            if ($score -gt $bestScore) {
                                $bestScore = $score
                                $bestMatch = $folder
                            }
                        }
                        if ($bestScore -ge $fuzzyThreshold -and $bestMatch -ne $null) {
                            $basePath = $textBoxDir.Trim()
                            if (-not $basePath.EndsWith("\")) { $basePath += "\" }
                            $relativePath = $bestMatch.UNCPath.Substring($basePath.Length)
                            if ($relativePath.StartsWith("\")) { $relativePath = $relativePath.Substring(1) }
                            $siteCode = ($selectedSite.'Site-Code').Trim()
                            $newSource = $pathtranslation + $siteCode + "\" + $relativePath
                            
                            $results += [PSCustomObject]@{
                                "Email"       = $email
                                "Source"      = $newSource
                                "OneDrive"    = $user.OneDrive
                                "UNCPath"     = $bestMatch.UNCPath
                                "File Count"  = $null
                                "Folder Size" = $null
                                "Errors"      = ("Fuzzy Match (score: {0:N2})" -f $bestScore)
                            }
                        }
                        else {
                            $results += [PSCustomObject]@{
                                "Email"       = $email
                                "Source"      = ""
                                "OneDrive"    = $user.OneDrive
                                "UNCPath"     = ""
                                "File Count"  = ""
                                "Folder Size" = ""
                                "Errors"      = "Home Folder Not Found"
                            }
                        }
                    }
                    else {
                        if ($matchesForUser.Count -gt 1) {
                            foreach ($match in $matchesForUser) {
                                $match.Errors = "Duplicate"
                            }
                        }
                        $results += $matchesForUser
                    }
                }
            }
            return $results
        } -ArgumentList @($batchUsers, $folderInfoList, $pathtranslation, $textBoxDir.Text, $fuzzyThreshold, $global:selectedSite)
    }

    # Wait for all jobs to complete and collect results
    $global:results = $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job

    # Process File Count and Folder Size using ThreadJob
    if ($checkBoxFileCount.Checked -or $checkBoxFolderSize.Checked) {
        $resultBatches = $global:results | Group-Object -Property { [math]::Floor([array]::IndexOf($global:results, $_) / $userBatchSize) }
        $processingJobs = @()

        foreach ($batch in $resultBatches) {
            $batchResults = $batch.Group
            $processingJobs += Start-ThreadJob -ScriptBlock {
                param($results, $checkFileCount, $checkFolderSize)
                foreach ($result in $results) {
                    if ($result.UNCPath -and $result.UNCPath -ne "") {
                        if ($checkFileCount) {
                            try {
                                $files = Get-ChildItem -Path $result.UNCPath -Recurse -File -ErrorAction SilentlyContinue
                                $result."File Count" = $files.Count
                            }
                            catch {
                                $result."File Count" = "Error"
                            }
                        }
                        if ($checkFolderSize) {
                            try {
                                $files = Get-ChildItem -Path $result.UNCPath -Recurse -File -ErrorAction SilentlyContinue
                                $sizeBytes = ($files | Measure-Object -Property Length -Sum).Sum
                                $result."Folder Size" = [math]::Round($sizeBytes / 1MB, 2)
                            }
                            catch {
                                $result."Folder Size" = "Error"
                            }
                        }
                    }
                }
                return $results
            } -ArgumentList @($batchResults, $checkBoxFileCount.Checked, $checkBoxFolderSize.Checked)
        }

        $global:results = $processingJobs | Wait-Job | Receive-Job
        $processingJobs | Remove-Job
    }
    
    # Build DataTable
    $dt = New-Object System.Data.DataTable
    $dt.Columns.Add("Site") | Out-Null
    $dt.Columns.Add("Email") | Out-Null
    $dt.Columns.Add("Source") | Out-Null
    $dt.Columns.Add("OneDrive") | Out-Null
    $dt.Columns.Add("File Count") | Out-Null
    $dt.Columns.Add("Folder Size (MB)") | Out-Null
    $dt.Columns.Add("Errors") | Out-Null
    
    foreach ($item in $global:results) {
         $row = $dt.NewRow()
         $row["Site"] = $global:selectedSite."Site-Name"
         $row["Email"] = $item.Email
         $row["Source"] = $item.Source
         $row["OneDrive"] = $item.OneDrive
         $row["File Count"] = $item."File Count"
         $row["Folder Size (MB)"] = $item."Folder Size"
         $row["Errors"] = $item.Errors
         $dt.Rows.Add($row)
    }
    
    # Sort by Errors in ascending order
    $dt.DefaultView.Sort = "Errors ASC"
    $dataGrid.DataSource = $dt.DefaultView
    $dataGrid.Refresh()
})

# Save Button
$buttonSave.Add_Click({
    if ($global:results.Count -eq 0) { return }
    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    if ($saveFileDialog.ShowDialog() -eq "OK") {
         try {
              $global:results | Export-Csv -Path $saveFileDialog.FileName -NoTypeInformation
         }
         catch { }
    }
})

# Highlight Rows with Errors
$dataGrid.add_RowPrePaint({
    param($sender, $e)
    $row = $sender.Rows[$e.RowIndex]
    if ($row.Cells["Errors"].Value -and $row.Cells["Errors"].Value.ToString().Trim() -ne "") {
         $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightPink
    }
})

# Display the Form
[void]$form.ShowDialog()
