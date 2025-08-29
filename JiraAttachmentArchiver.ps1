#Requires -Version 7.0
#Requires -Modules JiraPS

<###>
<#
    .SYNOPSIS
        Download Jira issue attachments into a structured local archive.

    .DESCRIPTION
        This script downloads attachments from one or more Jira issues and saves
        them into a local directory.  Each issue has its own subdirectory
        named after the issue key (e.g. `PROJ-123`).  Re‑running the script
        updates existing folders by comparing the size of each attachment and
        only downloading when the file is missing or different.

        Issues can be supplied directly via the `-Issue` parameter, expanded
        from a contiguous range (using `-StartIssue` and `-EndIssue`), or
        discovered via a JQL query built from date filters (e.g. issues
        updated in the last N days or updated since the start of today).
        A custom JQL string may be provided through `-Jql` and will be
        combined with any date filters.  Attachments can be filtered by
        filename using wildcards.

        The script sets `StrictMode` and `$ErrorActionPreference` to catch
        undefined variables and treat all errors as terminating, making
        exception handling consistent.  Commands are wrapped in try/catch
        blocks with `-ErrorAction Stop` to ensure proper error capture.

    .PARAMETER Issue
        One or more Jira issue keys to process (e.g. `PROJ-101`).

    .PARAMETER StartIssue
        The first issue key in a contiguous range.  Must be in the same project
        as `-EndIssue` (e.g. `PROJ-100`).

    .PARAMETER EndIssue
        The last issue key in a contiguous range (e.g. `PROJ-110`).  If
        specified, `-StartIssue` must also be provided.

    .PARAMETER Jql
        A custom JQL query used to find matching issues.  When combined with
        date filters, the resulting query is `(<Jql>) AND <date filters>`.

    .PARAMETER UpdatedLastDays
        Include issues updated within the last N days (e.g. `7`).

    .PARAMETER Today
        Switch that restricts results to issues updated since the start of
        the current day.

    .PARAMETER UpdatedAfter
        Include issues updated on or after this date (YYYY-MM-DD).

    .PARAMETER UpdatedBefore
        Include issues updated on or before this date (YYYY-MM-DD).

    .PARAMETER FileName
        Wildcard pattern to match attachment filenames (e.g. `*.pdf`).

    .PARAMETER ArchiveDir
        Directory where attachments are stored.  Defaults to the current
        working directory.  Each issue’s attachments are saved under a
        subdirectory named after the issue key.

    .PARAMETER JiraUrl
        Base URL of the Jira server (e.g. `https://your-domain.atlassian.net`).
        If omitted, the current JiraPS configuration will be used.

    .PARAMETER Credential
        PSCredential used to authenticate with Jira.  For Jira Cloud, the
        username should be your email address and the password should be an
        API token【330118541133109†L170-L182】.  If omitted, the script
        assumes an existing Jira session or anonymous access.

    .EXAMPLE
        PS> .\JiraAttachmentArchiver.ps1 -Issue PROJ-123

        Download attachments from the issue `PROJ-123` into a subdirectory of
        the current directory.

    .EXAMPLE
        PS> .\JiraAttachmentArchiver.ps1 -StartIssue PROJ-100 -EndIssue PROJ-105 -UpdatedLastDays 3

        Download attachments from issues PROJ-100 through PROJ-105 and any
        additional issues updated in the last three days.

    .EXAMPLE
        PS> .\JiraAttachmentArchiver.ps1 -Today -FileName '*.png' -ArchiveDir 'C:\JiraAttachments'

        Download only PNG attachments from issues updated today into the
        specified archive directory.

    .NOTES
        Author: Danny Mayer. Requires PowerShell 7+ and the JiraPS
        module.  The script uses `Get-JiraIssueAttachment` with filename
        filtering and `Get-JiraIssueAttachmentFile` to
        download attachments.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string[]]$Issue,

  [Parameter(Mandatory = $false)]
  [string]$StartIssue,

  [Parameter(Mandatory = $false)]
  [string]$EndIssue,

  [Parameter(Mandatory = $false)]
  [string]$Jql,

  [Parameter(Mandatory = $false)]
  [int]$UpdatedLastDays,

  [Parameter(Mandatory = $false)]
  [switch]$Today,

  [Parameter(Mandatory = $false)]
  [Nullable[datetime]]$UpdatedAfter,

  [Parameter(Mandatory = $false)]
  [Nullable[datetime]]$UpdatedBefore,

  [Parameter(Mandatory = $false)]
  [string]$FileName,

  [Parameter(Mandatory = $false)]
  [string]$ArchiveDir = (Get-Location).Path,

  [Parameter(Mandatory = $false)]
  [string]$JiraUrl,

  [Parameter(Mandatory = $false)]
  [PSCredential]$Credential
)

#region Helper Functions

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-IssueRange
{
  <#
        .SYNOPSIS
            Generate a list of contiguous Jira issue keys.

        .DESCRIPTION
            Given starting and ending issue keys (e.g. `PROJ-1` and `PROJ-3`),
            this function validates that both keys belong to the same project
            and returns an array containing each key in the numeric range.

        .PARAMETER Start
            The first issue key in the range.

        .PARAMETER End
            The last issue key in the range.

        .OUTPUTS
            System.String[]
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Start,
    [Parameter(Mandatory = $true)]
    [string]$End
  )
  $partsStart = $Start.Split('-', 2)
  $partsEnd = $End.Split('-', 2)
  if ($partsStart[0] -ne $partsEnd[0])
  {
    throw "StartIssue ($Start) and EndIssue ($End) must be in the same project."
  }
  $prefix = $partsStart[0]
  $numStart = [int]$partsStart[1]
  $numEnd = [int]$partsEnd[1]
  if ($numEnd -lt $numStart)
  {
    $tmp = $numStart; $numStart = $numEnd; $numEnd = $tmp
  }
  $range = for ($i = $numStart; $i -le $numEnd; $i++)
  {
    "$prefix-$i"
  }
  return $range
}

function Build-JqlFilter
{
  <#
        .SYNOPSIS
            Compose a JQL query from date filters and a base query.

        .DESCRIPTION
            Combines a custom JQL string with optional date filters.  Date
            conditions include updates within the last N days, since the start
            of today, and explicit after/before dates.  The resulting string
            can be passed to `Get-JiraIssue -Query` to retrieve matching
            issues.

        .PARAMETER BaseJql
            Existing JQL query.  May be empty or null.

        .PARAMETER UpdatedLastDays
            Include issues updated within the last N days.

        .PARAMETER Today
            Include issues updated since the start of the current day.

        .PARAMETER UpdatedAfter
            Include issues updated on or after this date.

        .PARAMETER UpdatedBefore
            Include issues updated on or before this date.

        .OUTPUTS
            System.String
    #>
  [CmdletBinding()]
  param(
    [string]$BaseJql,
    [int]$UpdatedLastDays,
    [switch]$Today,
    [Nullable[datetime]]$UpdatedAfter,
    [Nullable[datetime]]$UpdatedBefore
  )
  $clauses = @()
  if ($PSBoundParameters.ContainsKey('UpdatedLastDays'))
  {
    $clauses += "updated >= -$UpdatedLastDays`d"
  }
  if ($Today.IsPresent)
  {
    $clauses += 'updated >= startOfDay()'
  }
  if ($PSBoundParameters.ContainsKey('UpdatedAfter'))
  {
    $clauses += "updated >= $($UpdatedAfter.Value.ToString('yyyy-MM-dd'))"
  }
  if ($PSBoundParameters.ContainsKey('UpdatedBefore'))
  {
    $clauses += "updated <= $($UpdatedBefore.Value.ToString('yyyy-MM-dd'))"
  }
  $result = $BaseJql
  if ($clauses)
  {
    $dates = $clauses -join ' AND '
    if ([string]::IsNullOrWhiteSpace($result))
    {
      $result = $dates
    } else
    {
      $result = "($result) AND $dates"
    }
  }
  return $result
}

#endregion Helper Functions

#region Main Script Logic

try
{
  # Configure the Jira server if provided
  if ($PSBoundParameters.ContainsKey('JiraUrl'))
  {
    Set-JiraConfigServer -Server $JiraUrl -ErrorAction Stop | Out-Null
  }
  # --- Resolve Jira base URL for any REST fallbacks ---
  $baseUrl = $null

  if ($PSBoundParameters.ContainsKey('JiraUrl') -and -not [string]::IsNullOrWhiteSpace($JiraUrl))
  {
    $baseUrl = $JiraUrl
  } else
  {
    $cfg = $null
    try
    { $cfg = Get-JiraConfigServer 
    } catch
    { $cfg = $null 
    }
    if ($cfg)
    {
      if ($cfg -is [string])
      {
        $baseUrl = $cfg
      } elseif ($cfg.PSObject.Properties.Match('Server').Count -gt 0 -and $cfg.Server)
      {
        $baseUrl = $cfg.Server
      }
    }
  }

  if ($baseUrl)
  { $baseUrl = $baseUrl.TrimEnd('/') 
  }

  # Start a Jira session when credentials are supplied
  if ($PSBoundParameters.ContainsKey('Credential'))
  {
    New-JiraSession -Credential $Credential -ErrorAction Stop | Out-Null
  }
  # Construct the list of issue keys
  $issueKeys = @()
  if ($PSBoundParameters.ContainsKey('Issue'))
  {
    $issueKeys += $Issue
  }
  if ($PSBoundParameters.ContainsKey('StartIssue') -and $PSBoundParameters.ContainsKey('EndIssue'))
  {
    $issueKeys += Expand-IssueRange -Start $StartIssue -End $EndIssue
  }
  # Build JQL from custom query and date filters (avoid passing $null values)
  $jqlArgs = @{ BaseJql = $Jql }
  if ($PSBoundParameters.ContainsKey('UpdatedLastDays'))
  { $jqlArgs.UpdatedLastDays = $UpdatedLastDays 
  }
  if ($Today.IsPresent)
  { $jqlArgs.Today = $true 
  }
  if ($PSBoundParameters.ContainsKey('UpdatedAfter'))
  { $jqlArgs.UpdatedAfter = $UpdatedAfter 
  }
  if ($PSBoundParameters.ContainsKey('UpdatedBefore'))
  { $jqlArgs.UpdatedBefore = $UpdatedBefore 
  }
  $finalQuery = Build-JqlFilter @jqlArgs
  if (-not [string]::IsNullOrWhiteSpace($finalQuery))
  {
    Write-Verbose "Querying issues with JQL: $finalQuery"
    try
    {
      $queriedIssues = Get-JiraIssue -Query $finalQuery -Credential $Credential -ErrorAction Stop |
        Select-Object -ExpandProperty Key
    } catch
    {
      # Ensure we have a base URL
      if (-not $baseUrl)
      {
        throw "No Jira base URL available for REST fallback. Provide -JiraUrl or run Set-JiraConfigServer -Server 'https://<tenant>.atlassian.net'."
      }
      $searchUrl = "$baseUrl/rest/api/3/search/jql"

      # Basic auth (email:APIToken for Jira Cloud)
      if (-not $Credential)
      { throw "Credential is required for REST fallback." 
      }
      $pair  = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
      $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
      $hdrs  = @{ Authorization = "Basic $basic"; 'Accept'='application/json'; 'Content-Type'='application/json' }

      # Page through results using nextPageToken
      $queriedIssues = @()
      $nextPageToken = $null
      $pass = 0
      do
      {
        $pass++
        # Body for /search/jql; NO 'startAt', pagination via 'nextPageToken'
        $bodyHash = @{
          jql        = $finalQuery
          maxResults = 100              # tune as needed (Jira currently caps around 100)
          fields     = @('key')         # only request fields you need
        }
        if ($nextPageToken)
        { $bodyHash.nextPageToken = $nextPageToken 
        }

        $bodyJson = $bodyHash | ConvertTo-Json -Depth 5

        Write-Verbose "search/jql pass #$pass (token: $nextPageToken)"

        try
        {
          $resp = Invoke-RestMethod -Method Post -Uri $searchUrl -Headers $hdrs -Body $bodyJson -ErrorAction Stop
        } catch
        {
          # Optional: show server message for faster debugging
          try
          {
            $raw = $_.Exception.Response.Content | ConvertFrom-Json
            Write-Error ("search/jql failed: {0}" -f ($raw | ConvertTo-Json -Depth 6))
          } catch
          { Write-Error "search/jql failed: $($_.Exception.Message)" 
          }
          throw
        }

        if ($resp.issues)
        {
          $queriedIssues += @($resp.issues | ForEach-Object { $_.key })
        }

        # Safely read nextPageToken (may be absent on last/only page)
        if ($resp.PSObject.Properties.Match('nextPageToken').Count -gt 0) {
          $nextPageToken = $resp.nextPageToken
        } else {
          $nextPageToken = $null
        }
      }
      while ($nextPageToken -and -not [string]::IsNullOrWhiteSpace($nextPageToken))
    }
    $issueKeys += $queriedIssues
  }
  # De‑duplicate and sort the final list
  $issueKeys = ($issueKeys | Where-Object { $_ } | Sort-Object -Unique)
  if (-not $issueKeys)
  {
    Write-Verbose "No issues matched the provided criteria."
    return
  }
  # Ensure the archive directory exists
  if (-not (Test-Path -Path $ArchiveDir))
  {
    New-Item -ItemType Directory -Path $ArchiveDir -ErrorAction Stop | Out-Null
  }
  # --- Initialize Counters ---
  [int]$downloaded = 0
  [int]$skipped    = 0
  [int]$failed     = 0
  foreach ($key in $issueKeys)
  {
    # Retrieve the issue; continue if retrieval fails
    try
    {
      $issueObj = Get-JiraIssue -Key $key -Credential $Credential -ErrorAction Stop
    } catch
    {
      Write-Error "Could not retrieve issue ${key}: $($_.Exception.Message)"
      continue
    }
    # Create issue-specific subdirectory
    $subDir = Join-Path -Path $ArchiveDir -ChildPath $key
    if (-not (Test-Path -Path $subDir))
    {
      New-Item -ItemType Directory -Path $subDir -ErrorAction Stop | Out-Null
    }
    # Build parameters for attachment retrieval
    $params = @{ Issue = $issueObj; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('FileName'))
    {
      $params['FileName'] = $FileName
    }
    if ($PSBoundParameters.ContainsKey('Credential'))
    {
      $params['Credential'] = $Credential
    }
    # Fetch attachments
    $attachments = @()
    try
    {
      $attachments = Get-JiraIssueAttachment @params
    } catch
    {
      Write-Error "Failed to fetch attachments for ${key}: $($_.Exception.Message)"
      continue
    }
    foreach ($att in $attachments)
    {
      # Expecting: $subDir and $key are already defined outside this loop
      $name = $att.FileName
      $size = [int64]$att.Size
      $dest = Join-Path -Path $subDir -ChildPath $name

      # Determine if we need to (re)download
      $needsDownload = $true
      if (Test-Path -LiteralPath $dest)
      {
        try
        {
          $localSize = (Get-Item -LiteralPath $dest).Length
          if ($size -gt 0 -and $localSize -eq $size)
          {
            Write-Verbose "Skip existing (same size): ${key} -> $name"
            $skipped++
            $needsDownload = $false
          }
        } catch
        {
          # Could not read size; force re-download
          $needsDownload = $true
        }
      }
      if (-not $needsDownload)
      { continue 
      }

      if ($PSCmdlet.ShouldProcess($dest, "Download attachment from ${key}"))
      {
        try
        {
          # Preferred path: let JiraPS save the file
          Get-JiraIssueAttachmentFile -Attachment $att -Path $dest -ErrorAction Stop | Out-Null
          $downloaded++
          Write-Verbose "Downloaded via JiraPS: ${key} -> $name"
        } catch
        {
          Write-Verbose "JiraPS download failed; falling back to REST: $($_.Exception.Message)"

          # REST fallback requires Credential (Basic auth for Jira Cloud)
          if (-not $Credential)
          {
            $failed++
            Write-Error "Failed to download ${key} -> $name : JiraPS failed and no Credential available for REST fallback."
            continue
          }
          # Prefer direct content URL if available; else build from Id using $baseUrl
          $contentUrl = $null
          if ($att.PSObject.Properties.Match('Content').Count -gt 0 -and $att.Content)
          {
            $contentUrl = $att.Content
          } elseif ($att.PSObject.Properties.Match('Id').Count -gt 0 -and $att.Id)
          {
            if (-not $baseUrl)
            {
              $failed++
              Write-Error "Failed to resolve content URL for ${key} -> $name (no baseUrl and no Content property)."
              continue
            }
            $contentUrl = "$baseUrl/rest/api/3/attachment/$($att.Id)/content"
          }
          if (-not $contentUrl)
          {
            $failed++
            Write-Error "Failed to resolve content URL for ${key} -> $name"
            continue
          }

          try
          {
            # Basic auth header (email:APIToken for Jira Cloud)
            $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
            $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))

            Invoke-WebRequest -Uri $contentUrl -Headers @{ Authorization = "Basic $basic" } `
              -OutFile $dest -ErrorAction Stop

            $downloaded++
            Write-Verbose "Downloaded via REST: ${key} -> $name"
          } catch
          {
            $failed++
            Write-Error "Failed to download via REST for ${key} -> $name : $($_.Exception.Message)"
          }
        }
      }
    }
  }
  Write-Output "Successfully processed $($issueKeys.Count) issue(s)."
} catch
{
  Write-Error "Unhandled error: $($_.Exception.Message)"
  throw
}

#endregion Main Script Logic
