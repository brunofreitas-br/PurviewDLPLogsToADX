param($Timer)
$currentUTCtime = (Get-Date).ToUniversalTime()
if ($Timer.IsPastDue) { Write-Host "PowerShell timer is running late!" }
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"

# === Login with MI (if available) ==========================================
if ($env:MSI_SECRET -and (Get-Module -ListAvailable Az.Accounts)) {
    Connect-AzAccount -Identity
}

# === Environment variables ==================================================
#region Environment Variables
$Office365ContentTypes    = $env:contentTypes
$Office365RecordTypes     = $env:recordTypes
$AADAppClientId           = $env:clientID 
$AADAppClientSecret       = $env:clientSecret 
$AADAppClientDomain       = $env:domain
$AADAppPublisher          = $env:publisher
$AzureTenantId            = $env:tenantGuid
$AzureAADLoginUri         = $env:AzureAADLoginUri
$OfficeLoginUri           = $env:OfficeLoginUri

# Storage for last execution control
$azstoragestring          = $env:WEBSITE_CONTENTAZUREFILECONNECTIONSTRING
$storageAccountTableName  = "o365managementapiexecutions"
#endregion

# --- Global Buffer for Event Hub (aggregates everything to the end) ---
$script:EH_OUT = [System.Collections.Generic.List[object]]::new()

# === Helpers ================================================================
function Convert-ObjectToHashTable {
    [CmdletBinding()]
    param([parameter(Mandatory=$true,ValueFromPipeline=$true)][pscustomobject] $Object)
    $HashTable     = @{}
    $ObjectMembers = Get-Member -InputObject $Object -MemberType *Property
    foreach ($Member in $ObjectMembers) { $HashTable.$($Member.Name) = $Object.$($Member.Name) }
    return $HashTable
}

# === Auth for O365 =========================================================
function Get-AuthToken {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)][string]$ClientID,
        [Parameter(Mandatory=$true,Position=1)][string]$ClientSecret,
        [Parameter(Mandatory=$true,Position=2)][string]$tenantdomain,
        [Parameter(Mandatory=$true,Position=3)][string]$TenantGUID
    )
    $body = @{
        grant_type    = "client_credentials"
        resource      = $OfficeLoginUri
        client_id     = $ClientID
        client_secret = $ClientSecret
    }
    $oauth = Invoke-RestMethod -Method Post -Uri "$AzureAADLoginUri/$tenantdomain/oauth2/token?api-version=1.0" -Body $body
    $headerParams = @{ 'Authorization' = "$($oauth.token_type) $($oauth.access_token)" }
    return $headerParams 
}

# === Send to Event Hub (Output binding) ====================================
$BatchSize = 200  # adjust as needed

function Flush-EventHubBatch {
    param([string[]]$Messages)
    if (-not $Messages -or $Messages.Count -eq 0) { return }
    foreach ($m in $Messages) {
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        [void]$script:EH_OUT.Add($m)
    }
    Write-Host "EH buffer: +$($Messages.Count) (total=$($script:EH_OUT.Count))"
}

function Send-EventHubOut {
    param([int]$Chunk = 0)  # 0 = a single push; >0 = in slices
    $total = $script:EH_OUT.Count
    if ($total -eq 0) { Write-Host "INFORMATION: EH buffer vazio (nada a enviar)"; return }

    $arr = $script:EH_OUT.ToArray()

    if ($Chunk -le 0) {
        Push-OutputBinding -Name outEh -Value ([object[]]$arr)
        Write-Host "EventHub: enviados $total eventos (push único)"
    } else {
        for ($i=0; $i -lt $total; $i += $Chunk) {
            $j = [Math]::Min($total-1, $i+$Chunk-1)
            $slice = $arr[$i..$j]
            Push-OutputBinding -Name outEh -Value ([object[]]$slice)
            Write-Host "EventHub: enviados $($slice.Length) eventos (chunk $i..$j)"
        }
    }

    try {
        $v = Get-OutputBinding -Name outEh
        $cnt = if ($v -is [System.Collections.ICollection]) { $v.Count } else { 1 }
        Write-Host "EH snapshot: Count=$cnt"
    } catch { }
}

# === Collect and send =========================================================
function Get-O365Data {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0)][string]$startTime,
        [Parameter(Mandatory=$true,Position=1)][string]$endTime,
        [Parameter(Mandatory=$true,Position=2)][psobject]$headerParams,
        [Parameter(Mandatory=$true,Position=3)][string]$tenantGuid
    )

    $contentTypes = $Office365ContentTypes.Split(",")

    # GCC-High
    if ($OfficeLoginUri.Split('.')[2] -eq 'us') { $OfficeLoginUri = 'https://manage.office365.us' }

    $outBuffer = New-Object System.Collections.Generic.List[string]

    # --------- filters & Parameters ----------
    $recordTypesSetting = (($Office365RecordTypes) ?? "").Trim()
    $includeAll = [string]::IsNullOrWhiteSpace($recordTypesSetting) -or $recordTypesSetting -eq "0"

    $allowedNums = @()
    $allowedStrs = @()
    if (-not $includeAll) {
        foreach ($t in $recordTypesSetting.Split(",")) {
            $t2 = $t.Trim()
            if ($t2 -ne "") {
                $allowedStrs += $t2
                $n = 0
                if ([int]::TryParse($t2, [ref]$n)) { $allowedNums += $n }
            }
        }
    }
    $excludeMcas = ($env:EXCLUDE_MCAS -eq "true")   # optional
    # -----------------------------------------

    foreach ($contentType in $contentTypes) {
        $contentType = $contentType.Trim()
        $listAvailableContentUri = "$OfficeLoginUri/api/v1.0/$tenantGUID/activity/feed/subscriptions/content?contentType=$contentType&PublisherIdentifier=$AADAppPublisher&startTime=$startTime&endTime=$endTime"

        Write-Output $listAvailableContentUri

        do {
            # List packages
            $contentResult = Invoke-RestMethod -Method GET -Headers $headerParams -Uri $listAvailableContentUri
            Write-Output $contentResult.Count

            foreach ($obj in $contentResult) {
                # Download package contents (event array)
                $data = Invoke-RestMethod -Method GET -Headers $headerParams -Uri ($obj.contentUri)
                Write-Output $data.Count

                $seen=0; $added=0; $skipType=0; $skipSrc=0

                foreach ($event in $data) {
                    $seen++

                    # RecordType can come as int/long/string/null
                    $rtStr = "$($event.RecordType)"
                    $rtNum = $null; [void][int]::TryParse($rtStr, [ref]$rtNum)
                    $src   = "$($event.Source)"

                    $inByNum = ($rtNum -ne $null) -and ($allowedNums -contains $rtNum)
                    $inByStr = ($allowedStrs -contains $rtStr)

                    $shouldAdd = $includeAll -or $inByNum -or $inByStr
                    if ($excludeMcas -and $src -eq "Cloud App Security") { $shouldAdd = $false; $skipSrc++ }

                    if ($shouldAdd) {
                        $json = ((Convert-ObjectToHashTable $event) | ConvertTo-Json -Depth 50 -Compress)
                        $outBuffer.Add($json)
                        $added++

                        if ($outBuffer.Count -ge $BatchSize) {
                            Flush-EventHubBatch -Messages $outBuffer.ToArray()
                            $outBuffer.Clear()
                        }
                    } else {
                        $skipType++
                    }
                }

                Write-Host ("INFORMATION: EH debug: seen={0} added={1} skipType={2} skipSrc={3} includeAll={4} allowedNums=[{5}] allowedStrs=[{6}]" -f `
                    $seen, $added, $skipType, $skipSrc, $includeAll, ($allowedNums -join ","), ($allowedStrs -join ","))

                # packet flush (avoids losing events if something fails later)
                if ($outBuffer.Count -gt 0) {
                    Flush-EventHubBatch -Messages $outBuffer.ToArray()
                    $outBuffer.Clear()
                }
            }

            # Pagination
            $nextPageResult = Invoke-WebRequest -Method GET -Headers $headerParams -Uri $listAvailableContentUri
            if ($null -ne ($nextPageResult.Headers.NextPageUrl)) {
                $nextPage = $true
                $listAvailableContentUri = $nextPageResult.Headers.NextPageUrl
            } else {
                $nextPage = $false
            }
        } until ($nextPage -eq $false)
    }

    # Flush the rest (defensive)
    Flush-EventHubBatch -Messages $outBuffer.ToArray()
    $outBuffer.Clear()

    # Update last run control
    $endTime = $currentUTCtime | Get-Date -Format yyyy-MM-ddTHH:mm:ss
    Add-AzTableRow -table $o365TimeStampTbl -PartitionKey "Office365" -RowKey "lastExecutionEndTime" -property @{ "lastExecutionEndTimeValue" = $endTime } -UpdateExisting
}

# === Control table in Storage =========================================
$storageAccountContext = New-AzStorageContext -ConnectionString $azstoragestring
$StorageTable          = Get-AzStorageTable -Name $storageAccountTableName -Context $storageAccountContext -ErrorAction Ignore

if ($null -eq $StorageTable.Name) {
    $startTime = $currentUTCtime.AddSeconds(-300) | Get-Date -Format yyyy-MM-ddTHH:mm:ss
    New-AzStorageTable -Name $storageAccountTableName -Context $storageAccountContext
    $o365TimeStampTbl = (Get-AzStorageTable -Name $storageAccountTableName -Context $storageAccountContext.Context).cloudTable    
    Add-AzTableRow -table $o365TimeStampTbl -PartitionKey "Office365" -RowKey "lastExecutionEndTime" -property @{ "lastExecutionEndTimeValue" = $startTime } -UpdateExisting
} else {
    $o365TimeStampTbl = (Get-AzStorageTable -Name $storageAccountTableName -Context $storageAccountContext.Context).cloudTable
}

# Retrieve last run
$lastExecutionEndTime = Get-azTableRow -table $o365TimeStampTbl -partitionKey "Office365" -RowKey "lastExecutionEndTime" -ErrorAction Ignore
$lastlogTime = $($lastExecutionEndTime.lastExecutionEndTimeValue)
$startTime   = $lastlogTime    | Get-Date -Format yyyy-MM-ddTHH:mm:ss
$endTime     = $currentUTCtime | Get-Date -Format yyyy-MM-ddTHH:mm:ss

# === Main execution =====================================================
$headerParams = Get-AuthToken $AADAppClientId $AADAppClientSecret $AADAppClientDomain $AzureTenantId
Get-O365Data $startTime $endTime $headerParams $AzureTenantId

# --- sends everything to Event Hub in one push (or in chunks, if you prefer) ---
Send-EventHubOut -Chunk 0   # 0 = unique push

Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"