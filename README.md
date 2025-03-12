I'll create comprehensive documentation for these PowerShell migration scripts for your GitHub repository. The documentation will include an overview of each script, prerequisites, input file requirements, and usage instructions.

# Data Migration Toolset

A collection of PowerShell GUI tools for discovering, mapping, and migrating file shares to Azure Storage.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Discovery Tools](#discovery-tools)
  - [Site Data Mapping Tool](#site-data-mapping-tool)
  - [Home Folder Mapping Tool](#home-folder-mapping-tool)
- [Migration Tools](#migration-tools)
  - [Blob Migration Tool](#blob-migration-tool)
  - [File Migration Tools](#file-migration-tools)
- [CSV Configuration Files](#csv-configuration-files)
- [Logging](#logging)

## Overview

This toolset provides a comprehensive solution for migrating file data from on-premises shares to Azure. It consists of two discovery tools to identify and map data sources, and multiple migration tools to handle different migration scenarios to both Azure Blob Storage and Azure File Shares.

The workflow is typically:
1. Use discovery tools to identify and map source data
2. Generate migration CSV files from discovery output
3. Use appropriate migration tools based on target storage type and migration requirements

## Prerequisites

- PowerShell 5.1 or higher
- Administrator rights on the machine running the scripts
- Network access to source file shares
- For Azure migrations:
  - AzCopy installed (for Blob migrations)
  - Robocopy (built into Windows, for File Share migrations)
  - Valid SAS tokens for target Azure storage

## Discovery Tools

### Site Data Mapping Tool

`Site-Data-Mapping.ps1` is designed to inventory and categorize site-specific file shares based on predefined data standards.

**Features:**
- GUI interface for easy operation
- Maps source paths to destination paths based on data standards
- Highlights non-standard shares and access issues
- Exports results to CSV for migration planning

**Required CSV Input Files:**
- `Site-Metadata.csv`: Contains site-specific information
  - Columns: `Site-Name`, `Site-Code`, `Legacy-Root`, `Legacy-Share`
- `Data-Standards.csv`: Defines standard folder structures and mapping rules
  - Columns: `Source-Path`, `Destination-Path`, `Data Type`, `ExcludeActive`

**Usage:**
1. Place the required CSV files in the same directory as the script
2. Run the script with PowerShell
3. Select a site from the dropdown
4. Click "Run" to analyze the site's data structure
5. Results will display in the grid with color-coding:
   - Red: Access issues
   - Light Coral: Non-standard shares
6. Click "Save CSV" to export the results for migration planning

### Home Folder Mapping Tool

`Home-Folder-Mapping.ps1` identifies and maps user home folders to their respective users based on UPN (User Principal Name).

**Features:**
- Multithreaded processing for improved performance
- Fuzzy matching capabilities to handle naming inconsistencies
- Support for various home folder naming conventions
- Path translation for migration planning

**Required CSV Input Files:**
- `site-metadata.csv`: Contains site information including known home folder locations
  - Columns: `Site-Name`, `Site-Code`, `Legacy-Root`, `Legacy-Share`, `Known-Homes`
- `data-standards.csv`: Used for path translation (same as Site Data Mapping tool)
- User CSV file (selected at runtime): Contains user information with UPN and OneDrive columns

**Usage:**
1. Place the required CSV files in the same directory as the script
2. Run the script with PowerShell
3. Select a site from the dropdown
4. Use "Browse CSV" to select a user list file
5. The tool will automatically populate the directory field based on site metadata
6. Optionally select "Include File Count" and "Include Folder Size" for more details
7. Click "Run" to process the selected site or "Run All" for batch processing
8. Results are displayed in the grid with error highlighting
9. Export results using "Save CSV"

## Migration Tools

### Blob Migration Tool

`Blob-Migrate-Active.ps1` migrates data to Azure Blob Storage with support for blob tagging.

**Features:**
- Two-phase migration process:
  1. Initial copy to a staging container
  2. Selective copy to the active container with blob tags
- Support for scheduled start times
- Comprehensive logging and summary reporting
- Support for the `ExcludeActive` flag to skip the second stage

**Required CSV Input File:**
- `Blob-Migrate-Active.csv`: Contains migration job details
  - Columns: `Site ID`, `Name`, `Source`, `StorageAccount`, `AzureContainer`, `ActiveContainer`, `SAS Token`, `ExcludeActive`

**Usage:**
1. Place the CSV file in the same directory as the script
2. Run the script with PowerShell
3. Select one or more migrations from the list
4. Configure blob tag name and value (defaults to "Meganexus: No")
5. Optionally set a scheduled start time
6. Click "Run" for selected jobs or "Run All" for all jobs
7. The tool performs:
   - Initial copy from source to AzureContainer
   - Filtered copy from AzureContainer to ActiveContainer with blob tags (unless ExcludeActive is set to Y/Yes)
8. View detailed summaries using the "View Summary" button

### File Migration Tools

Three specialized tools for Azure File Share migrations using Robocopy:

#### File-Migrate-FirstMidweek.ps1

Designed for initial large migrations with automatic scheduling to avoid business hours.

**Features:**
- Configures Robocopy to run between 20:30-07:00 to minimize impact
- Preserves file metadata (dates, attributes, timestamps)
- Comprehensive logging and progress tracking
- Optional mirroring to ensure destination matches source

**Required CSV Input File:**
- `File-Migrate-First-Midweek.csv`: Contains initial migration job details
  - Columns: `Site ID`, `Name`, `Source`, `Destination`

#### File-Migrate-Mirror.ps1

Used for complete synchronization including deletion of files at the destination that no longer exist at the source.

**Features:**
- Uses Robocopy's `/MIR` option (enabled by default)
- Ideal for weekend migrations or delta syncs
- Comprehensive logging and summary reporting

**Required CSV Input File:**
- `File-Migrate-Mirror.csv`: Contains mirror migration job details
  - Columns: `Site ID`, `Name`, `Source`, `Destination`

#### File-Migrate-Copy.ps1

Designed for ongoing synchronization without deleting files at the destination.

**Features:**
- Safe copy operation that only adds or updates files
- Ideal for maintaining synchronization after users have access
- Optional mirroring capability (disabled by default)

**Required CSV Input File:**
- `File-Migrate-Copy.csv`: Contains copy migration job details
  - Columns: `Site ID`, `Name`, `Source`, `Destination`

**Usage (for all File Migration Tools):**
1. Place the appropriate CSV file in the same directory as the script
2. Run the script with PowerShell
3. Select one or more migrations from the list
4. Configure options:
   - Enable/disable scheduled start
   - Enable/disable mirroring (already configured based on tool)
5. Click "Run" for selected jobs or "Run All" for all jobs
6. Monitor progress in the output window
7. View comprehensive summaries with the "View Summary" button

## CSV Configuration Files

### Common Files

- **Site-Metadata.csv**
  - `Site-Name`: Display name of the site
  - `Site-Code`: Unique identifier for the site
  - `Legacy-Root`: Root path of the legacy file system
  - `Legacy-Share`: Share path relative to the root
  - `Known-Homes`: Semicolon-separated list of home folder locations (for home folder mapping)

- **Data-Standards.csv**
  - `Source-Path`: Path pattern to match in the source
  - `Destination-Path`: Template for destination path (supports variables like `<sitecode>`)
  - `Data Type`: Category of data for reporting purposes
  - `ExcludeActive`: Flag (Y/Yes/N/No) to control active container migrations

### Migration-Specific Files

- **Blob-Migrate-Active.csv**
  - `Site ID`: Unique identifier for the site
  - `Name`: Descriptive name for the migration job
  - `Source`: Source file path
  - `StorageAccount`: Azure storage account name
  - `AzureContainer`: Initial container name (e.g., sitecode)
  - `ActiveContainer`: Destination container name (e.g., active)
  - `SAS Token`: Shared Access Signature token
  - `ExcludeActive`: Flag (Y/Yes) to skip second phase

- **File-Migrate-*.csv** (All File migration tools use the same format)
  - `Site ID`: Unique identifier for the site
  - `Name`: Descriptive name for the migration job
  - `Source`: Source file path
  - `Destination`: Destination file path (Azure File Share UNC path)

## Logging

All tools create comprehensive logs to track migration progress and troubleshoot issues:

- **Directory Structure**: `Logs\<SiteID>\<Tool-Type>-VerboseLogs\`
- **Summary Files**:
  - Individual job summaries: `<Tool-Type>-<SiteID>-<JobName>-<DateTime>.csv`
  - Master summaries: `<Tool-Type>-Master-Summary.csv`

The logs include detailed metrics such as:
- File counts and sizes
- Transfer speeds
- Duration
- Error messages
- Start and end times

Use the "View Summary" button in any tool to review the master summary in a grid view.
