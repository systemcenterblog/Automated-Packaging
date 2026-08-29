<#
.SYNOPSIS
    Enumerates the AppsAnywhere Packaging Portal catalog and resolves the final
    .stp package URL for every app that exposes a "Download App" action, along
    with the app description and package date shown in the app detail modal.

.DESCRIPTION
    For each app the portal exposes GET /apps/{guid}/download, which returns a
    302 whose Location header is the real .stp file on packages.appsanywhere.com.

    This script uses HttpClient with AllowAutoRedirect disabled, so the redirect
    is never followed and no package bytes are ever transferred. Requests also
    use ResponseHeadersRead, so response bodies are not buffered.

    Descriptions are read from the per-app detail modals, which the portal
    pre-renders into the catalog page. No extra request per app is needed.

    Authentication is by session cookie. See NOTES for how to obtain it.

.PARAMETER Cookie
    The full Cookie header value for an authenticated packaging.appsanywhere.com
    session. If omitted, the script prompts for it.

.PARAMETER OutFile
    Path for the CSV output. Defaults to .\appsanywhere_stp_urls.csv

.PARAMETER DelayMs
    Delay between requests, to stay polite to the portal. Default 150.

.PARAMETER IncludeType
    Adds a Type column (core / aal) to the output.

.PARAMETER NoDescription
    Omits the Description and Package Date columns.

.PARAMETER StripBoilerplate
    Removes the two generic sentences that appear on nearly every app
    ("This app has been packaged with default configuration..." and
    "You may also request a customised version...") so the Description column
    holds only app-specific notes. Useful when diffing runs.

.EXAMPLE
    .\Get-AppsAnywhereStpUrls.ps1

.EXAMPLE
    .\Get-AppsAnywhereStpUrls.ps1 -Cookie $env:AAW_COOKIE -IncludeType -StripBoilerplate

.NOTES
    Getting the cookie:
      1. Sign in to https://packaging.appsanywhere.com/Index in Chrome or Edge.
      2. F12 -> Network -> reload the page -> click the "Index" document request.
      3. Under Request Headers, copy the entire value of the "Cookie:" header.

    The session cookie is a credential. Do not hardcode it in this file, commit
    it, or paste it into a chat or ticket. Prefer passing it via an environment
    variable that you clear afterwards.

    Works on Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [string] $Cookie,
    [string] $OutFile    = ".\Output\appsanywhere_stp_urls.csv",
    [int]    $DelayMs    = 150,
    [string] $CatalogUrl = "https://packaging.appsanywhere.com/Index",
    [switch] $IncludeType,
    [switch] $NoDescription,
    [switch] $StripBoilerplate
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

if (-not $Cookie) {
    $Cookie = Read-Host "Paste the Cookie header for packaging.appsanywhere.com"
}
if ([string]::IsNullOrWhiteSpace($Cookie)) { throw "No cookie supplied." }

$baseUri = [Uri]$CatalogUrl
$origin  = "{0}://{1}" -f $baseUri.Scheme, $baseUri.Authority

$Boilerplate = @(
    'This app has been packaged with default configuration according to our packaging service conventions.'
    'You may also request a customised version of this app by using a subscription allocation.'
)

# --- HTTP client: never follow redirects, never buffer bodies ------------------
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseCookies        = $false   # we set the Cookie header ourselves
$client  = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(60)
$null = $client.DefaultRequestHeaders.TryAddWithoutValidation('Cookie', $Cookie)
$null = $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')

function ConvertFrom-HtmlFragment {
    <# Strips tags, collapses whitespace, decodes entities. #>
    param([string] $Fragment)
    if (-not $Fragment) { return '' }
    $t = $Fragment -replace '(?s)<br\s*/?>', ' '
    $t = $t -replace '(?s)<[^>]+>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    ($t -replace '\s+', ' ').Trim()
}

function Get-BalancedDivContent {
    <#
        Returns the inner HTML of the <div> that opens at index $OpenStart in
        $Html, matching its true closing </div> by tracking nesting depth.

        A naive "<div ...>(.*?)</div>" regex closes on the FIRST </div> it
        sees, regardless of nesting - and rich-text modal bodies routinely
        wrap a code sample or callout in its own inner <div>. That closes the
        naive match early and silently truncates everything after it, which
        is exactly what was happening to the Abaqus-style "License Template
        Configuration" blocks (the code box and everything after it fell off).
    #>
    param(
        [string] $Html,
        [int]    $OpenStart
    )
    $openTagEnd = $Html.IndexOf('>', $OpenStart)
    if ($openTagEnd -lt 0) { return '' }

    $tagRx = [regex]'(?i)<div\b[^>]*>|</div\s*>'
    $depth = 1
    $m     = $tagRx.Match($Html, $openTagEnd + 1)
    while ($m.Success) {
        if ($m.Value.StartsWith('</')) { $depth-- } else { $depth++ }
        if ($depth -eq 0) {
            return $Html.Substring($openTagEnd + 1, $m.Index - ($openTagEnd + 1))
        }
        $m = $tagRx.Match($Html, $m.Index + $m.Length)
    }
    # Unterminated (malformed HTML) - fall back to the rest of the string.
    return $Html.Substring($openTagEnd + 1)
}

function Get-Html {
    param([string] $Url)
    $r = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseContentRead).GetAwaiter().GetResult()
    if ([int]$r.StatusCode -in 301,302,303,307,308) {
        throw "Catalog request was redirected (HTTP $([int]$r.StatusCode)) - the session cookie is probably expired or wrong."
    }
    if (-not $r.IsSuccessStatusCode) {
        throw "Catalog request failed: HTTP $([int]$r.StatusCode) $($r.ReasonPhrase)"
    }
    $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
}

function Resolve-StpUrl {
    <# Returns a hashtable with Location / Status. Never follows the redirect. #>
    param([string] $Url)
    try {
        $r = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            $code = [int]$r.StatusCode
            $loc  = $null
            if ($r.Headers.Location) { $loc = $r.Headers.Location.AbsoluteUri }
            return @{ Location = $loc; Status = $code }
        }
        finally { $r.Dispose() }   # discards the unread body; nothing hits disk
    }
    catch {
        return @{ Location = $null; Status = "ERROR: $($_.Exception.Message)" }
    }
}

# --- Fetch ---------------------------------------------------------------------
Write-Host "Fetching catalog..." -ForegroundColor Cyan
$html = Get-Html -Url $CatalogUrl

# --- Parse the per-app detail modals (description + package date) --------------
# Each app renders <div id="app-modal-{guid-without-dashes}"> containing
# <div class="portal-copy-block__content ql-editor">...</div>, which can mix
# <p>, <h1-6>, <li>, <pre>/<blockquote> and further nested <div>s (e.g. a code
# sample box) in any combination - so the content div is located by balanced
# tag matching (Get-BalancedDivContent) rather than a naive "up to the first
# </div>" regex, and every block-level tag is treated as a line boundary.
$meta = @{}
if (-not $NoDescription) {
    $modalRx = [regex]'(?s)id="app-modal-([0-9a-fA-F]{32})"(.*?)(?=id="app-modal-[0-9a-fA-F]{32}"|$)'
    foreach ($m in $modalRx.Matches($html)) {
        $key   = $m.Groups[1].Value.ToLower()
        $chunk = $m.Groups[2].Value

        $openMatch = [regex]::Match($chunk, '(?s)<div\b[^>]*\bportal-copy-block__content\b[^>]*>')
        if (-not $openMatch.Success) { continue }
        $body = Get-BalancedDivContent -Html $chunk -OpenStart $openMatch.Index
        if (-not $body) { continue }

        # Break on every block-level boundary (paragraphs, headings, list
        # items, code/quote blocks, nested divs) - not just <p> - so a
        # heading like "License Template" or a code sample in its own <pre>
        # becomes its own line instead of being silently dropped.
        $marked = $body    -replace '(?i)<br\s*/?>', "`n"
        $marked = $marked  -replace '(?i)</(p|div|h[1-6]|li|pre|blockquote|tr)\s*>', "`n"
        $marked = $marked  -replace '(?s)<[^>]+>', ''
        $lines  = [System.Net.WebUtility]::HtmlDecode($marked) -split "`n" |
                  ForEach-Object { ($_ -replace '\s+', ' ').Trim() } |
                  Where-Object { $_ }

        $pkgDate = ''
        $keep    = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            if ($line -match '^Package Date:\s*(.+)$') { $pkgDate = $Matches[1] }
            else { $keep.Add($line) }
        }

        $desc = ($keep -join ' | ').Trim()
        if ($StripBoilerplate) {
            foreach ($b in $Boilerplate) { $desc = $desc.Replace($b, ' ') }
            $desc = ($desc -replace '\s+', ' ').Trim()
        }

        $meta[$key] = @{ Description = $desc; PackageDate = $pkgDate }
    }
    Write-Host ("Parsed {0} app detail modals." -f $meta.Count) -ForegroundColor Cyan
}

# --- Parse the catalog cards ---------------------------------------------------
$cardRx = [regex]'(?s)<article\b[^>]*\bdata-app-card\b.*?</article>'
$cards  = $cardRx.Matches($html)
if ($cards.Count -eq 0) {
    throw "No app cards found. Either the session is not authenticated, or the portal markup has changed (expected <article data-app-card ...>)."
}
Write-Host ("Found {0} app cards." -f $cards.Count) -ForegroundColor Cyan

$apps = foreach ($c in $cards) {
    $h = $c.Value

    $guid = $null
    if ($h -match '/apps/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/download') {
        $guid = $Matches[1]
    }

    $name = $null
    if ($h -match 'data-download-app-name="([^"]*)"')      { $name = $Matches[1] }
    elseif ($h -match '(?s)<h2[^>]*>(.*?)</h2>')           { $name = $Matches[1] }
    $name = ConvertFrom-HtmlFragment $name

    $version = ''
    if ($h -match '(?s)<dt[^>]*>\s*Version\s*</dt>\s*<dd[^>]*>(.*?)</dd>') {
        $version = ConvertFrom-HtmlFragment $Matches[1]
    }

    $type = ''
    if ($h -match 'data-type="([^"]*)"') { $type = $Matches[1] }

    $desc = ''; $pkg = ''
    if ($guid) {
        $mk = $guid.Replace('-', '').ToLower()
        if ($meta.ContainsKey($mk)) { $desc = $meta[$mk].Description; $pkg = $meta[$mk].PackageDate }
    }

    [pscustomobject]@{
        Name = $name; Version = $version; Type = $type; Guid = $guid
        Description = $desc; PackageDate = $pkg
    }
}

$targets = @($apps | Where-Object Guid)
$skipped = [System.Collections.Generic.List[object]]::new()

foreach ($a in ($apps | Where-Object { -not $_.Guid })) {
    $skipped.Add([pscustomobject]@{ Name = $a.Name; Version = $a.Version; Reason = 'No Download App action on the card' })
}

Write-Host ("{0} with a download action, {1} without." -f $targets.Count, $skipped.Count) -ForegroundColor Cyan

if (-not $NoDescription) {
    $missing = @($targets | Where-Object { -not $_.Description }).Count
    if ($missing) { Write-Host ("{0} app(s) had no description in their modal." -f $missing) -ForegroundColor Yellow }
}

# --- Resolve each redirect ------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
$i = 0

foreach ($a in $targets) {
    $i++
    Write-Progress -Activity 'Resolving .stp URLs' -Status ("[{0}/{1}] {2}" -f $i, $targets.Count, $a.Name) `
                   -PercentComplete ($i / $targets.Count * 100)

    $r = Resolve-StpUrl -Url ("{0}/apps/{1}/download" -f $origin, $a.Guid)

    if ($r.Location) {
        $row = [ordered]@{ 'App Name' = $a.Name; 'Version' = $a.Version }
        if ($IncludeType) { $row['Type'] = $a.Type }
        $row['STP URL'] = $r.Location
        if (-not $NoDescription) {
            $row['Package Date'] = $a.PackageDate
            $row['Description']  = $a.Description
        }
        $results.Add([pscustomobject]$row)
    }
    else {
        $skipped.Add([pscustomobject]@{
            Name    = $a.Name
            Version = $a.Version
            Reason  = "No Location header (HTTP $($r.Status))"
        })
    }

    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
}

Write-Progress -Activity 'Resolving .stp URLs' -Completed
$client.Dispose()

# --- Output ---------------------------------------------------------------------
$results | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host ("Resolved {0} of {1}. CSV written to {2}" -f $results.Count, $targets.Count, (Resolve-Path $OutFile)) -ForegroundColor Green

if ($skipped.Count) {
    Write-Host ""
    Write-Host ("Skipped {0}:" -f $skipped.Count) -ForegroundColor Yellow
    $skipped | Format-Table -AutoSize
}

# Non-.stp targets are worth eyeballing - usually a login redirect from an
# expired session rather than a real package.
$odd = @($results | Where-Object { $_.'STP URL' -notmatch '\.stp$' })
if ($odd.Count) {
    Write-Host "Resolved to something that is not a .stp:" -ForegroundColor Yellow
    $odd | Format-Table -AutoSize
}

$results