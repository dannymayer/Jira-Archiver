# JiraAttachmentArchiver

Download Jira issue attachments into a structured local archive. Designed for repeatable runs, automation, and selective syncs.

> **Requirements**
>
> - **PowerShell 7+**
> - **[JiraPS](https://github.com/AtlassianPS/JiraPS) module**
> - Jira Cloud or Server/DC access with appropriate permissions to read issues & attachments

---

## Features

- **Idempotent sync**: re‑runs only download files that are new or have a size mismatch.
- **Issue selection**:
  - Explicit keys: `-Issue PROJ-101, PROJ-205`
  - Contiguous range: `-StartIssue PROJ-100 -EndIssue PROJ-120`
  - **JQL** query: `-Jql "project = PROJ AND statusCategory != Done"`
- **Date filters** (combinable): `-Today`, `-UpdatedLastDays 7`, `-UpdatedAfter`, `-UpdatedBefore`
- **Attachment filters**: `-FileName` supports wildcards (e.g., `*.png`, `report-*.pdf`).
- **Structured archive**: each issue gets its own folder under `-ArchiveDir` (default: CWD).
- **JiraPS-first with REST fallback** for large result sets and resilience.

---

## Quick Start

```powershell
# 1) Install JiraPS (once per machine)
Install-Module JiraPS -Scope CurrentUser

# 2) (Option A) Use existing JiraPS config/session
Set-JiraConfigServer -Server 'https://your-domain.atlassian.net'
# Connect as needed (Server/DC typically uses basic/NTLM; Cloud uses API token as the "password")
$cred = Get-Credential  # username: your email (Cloud), password: API token
Connect-JiraServer -Credential $cred   # or Connect-JiraCloud if available in your environment

# 2) (Option B) Let the script handle auth by passing -JiraUrl and -Credential
$cred = Get-Credential  # username: your email (Cloud), password: API token
.\JiraAttachmentArchiver.ps1 -JiraUrl 'https://your-domain.atlassian.net' -Credential $cred -Issue PROJ-123

# 3) Download attachments for a single issue
.\JiraAttachmentArchiver.ps1 -Issue PROJ-123

# 4) Download a range and “recently updated”
.\JiraAttachmentArchiver.ps1 -StartIssue PROJ-100 -EndIssue PROJ-105 -UpdatedLastDays 3

# 5) Only PNGs, updated today, into a specific directory
.\JiraAttachmentArchiver.ps1 -Today -FileName '*.png' -ArchiveDir 'C:\JiraAttachments'
```

---

## Parameters

| Parameter          | Type           | Default              | Description                                                                                      |
| ------------------ | -------------- | -------------------- | ------------------------------------------------------------------------------------------------ |
| `-Issue`           | `string[]`     | —                    | One or more Jira issue keys (e.g., `PROJ-101`).                                                  |
| `-StartIssue`      | `string`       | —                    | First key of a contiguous range (must share project prefix with `-EndIssue`).                    |
| `-EndIssue`        | `string`       | —                    | Last key of a contiguous range (requires `-StartIssue`).                                         |
| `-Jql`             | `string`       | —                    | Custom JQL used to find matching issues. Combines with date filters if provided.                 |
| `-UpdatedLastDays` | `int`          | —                    | Include issues updated within the last _N_ days.                                                 |
| `-Today`           | `switch`       | `False`              | Include issues updated since the start of the current day.                                       |
| `-UpdatedAfter`    | `datetime?`    | —                    | Include issues updated on/after this timestamp.                                                  |
| `-UpdatedBefore`   | `datetime?`    | —                    | Include issues updated on/before this timestamp.                                                 |
| `-FileName`        | `string`       | —                    | Wildcard filter for attachment names (e.g., `*.pdf`).                                            |
| `-ArchiveDir`      | `string`       | Current directory    | Root path for the archive. Each issue’s files go under `.\<ISSUE-KEY>\`.                         |
| `-JiraUrl`         | `string`       | (from JiraPS config) | Base URL for Jira (e.g., `https://your-domain.atlassian.net`).                                   |
| `-Credential`      | `PSCredential` | (existing session)   | Credential for Jira. **Jira Cloud**: use email as username and an **API token** as the password. |

**Issue sources are merged**: you can specify `-Issue`, a range, and/or `-Jql` with date filters; duplicates are de‑duplicated automatically.

---

## Behavior & Implementation Notes

- **Archive structure**: `-ArchiveDir\<ISSUE-KEY>\AttachmentFile.ext` (preserves original attachment names).
- **Change detection**: existing files are compared by size before download. If size differs or file is missing, the file is (re)downloaded.
- **Filtering order**: issues are gathered first (Issue/Range/JQL + dates), then attachments are filtered by `-FileName` (if supplied).
- **Auth & connectivity**:
  - If `-JiraUrl`/`-Credential` are provided, the script can operate without a prior JiraPS session.
  - Otherwise it relies on your current JiraPS configuration (`Get-JiraConfigServer`) and session.
- **REST fallback**: the script uses JiraPS where possible and falls back to REST (with pagination) for robust searches in large projects.
- **Cloud vs. Server/DC**: Jira Cloud authentication typically requires an **API token** (as the password in `Get-Credential`).

---

## Examples

```powershell
# Specific issues
.\JiraAttachmentArchiver.ps1 -Issue PROJ-101, PROJ-205

# Range expansion
.\JiraAttachmentArchiver.ps1 -StartIssue PROJ-1 -EndIssue PROJ-25

# JQL + date window
.\JiraAttachmentArchiver.ps1 -Jql "project = WEB AND assignee = currentUser()" -UpdatedAfter '2025-08-01' -UpdatedBefore '2025-08-29'

# Only PDFs, last 14 days, into a fixed path
.\JiraAttachmentArchiver.ps1 -UpdatedLastDays 14 -FileName '*.pdf' -ArchiveDir 'D:\Jira\Docs'

# Fully explicit Cloud auth in one line
$cred = Get-Credential
.\JiraAttachmentArchiver.ps1 -JiraUrl 'https://your-domain.atlassian.net' -Credential $cred -Jql "project = OPS" -Today
```

---

## Troubleshooting

- **“Could not load JiraPS”**: ensure PowerShell 7+ and install the module: `Install-Module JiraPS -Scope CurrentUser`.
- **401/403**: verify user permissions to view issues and attachments; for Cloud ensure you’re using an **API token** as the password.
- **No issues found**: test your JQL in the Jira UI; try simplifying filters; confirm date/time zone assumptions (the script builds JQL using Jira’s `updated` field).
- **Files not updating**: remove a test file to force re‑download, or compare Jira’s attachment size vs your local file. If your proxy or WAF modifies downloads, sizes may differ.
- **Large projects**: prefer JQL+date filters to reduce result sets; the script paginates but narrower windows are faster/more reliable.

---

## Automation Tips

- Run on a schedule (Task Scheduler, cron via pwsh, Azure Automation) and point `-ArchiveDir` at a persistent share.
- Keep credentials out of plaintext: store in Windows Credential Manager or a secure secret vault, then retrieve with `Get-Credential` at runtime.
- For CI/CD or unattended jobs, consider using environment variables + a secure secret store to construct a `PSCredential` object at start.

---

## License & Contributions

- MIT-style licensing recommended (update as appropriate for your repo).
- Issues and PRs welcome. Please include **PowerShell version**, **Jira edition (Cloud/Server/DC)**, and **a minimal repro**.

---

## Changelog

- **1.0.0** – Initial release: explicit issues, ranges, JQL, date filters, filename filters, idempotent downloads, REST fallback.
