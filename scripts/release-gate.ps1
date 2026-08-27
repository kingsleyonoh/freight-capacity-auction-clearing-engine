param(
  [string]$BaseUrl = $env:FCA_RELEASE_BASE_URL,
  [string]$ApiKey = $env:FCA_RELEASE_API_KEY,
  [string]$TenantId = $env:FCA_RELEASE_TENANT_ID,
  [string]$CarrierId = $env:FCA_RELEASE_CARRIER_ID,
  [string]$LaneId = $env:FCA_RELEASE_LANE_ID
)

$ErrorActionPreference = 'Stop'
foreach ($required in @('BaseUrl', 'ApiKey', 'TenantId', 'CarrierId', 'LaneId')) {
  if ([string]::IsNullOrWhiteSpace((Get-Variable $required).Value)) {
    throw "FCA release gate requires `$required or its FCA_RELEASE_* environment variable."
  }
}

$headers = @{
  Authorization = "Bearer $ApiKey"
  'X-Tenant-Id' = $TenantId
}

function Convert-Json($value) {
  return ($value | ConvertTo-Json -Compress -Depth 12)
}

function Invoke-Fca($Method, $Path, $Body = $null) {
  $params = @{
    Method = $Method
    Uri = "$BaseUrl$Path"
    Headers = $headers
    ErrorAction = 'Stop'
  }
  if ($null -ne $Body) {
    $params.ContentType = 'application/json'
    $params.Body = Convert-Json $Body
  }
  return Invoke-RestMethod @params
}

$name = "Release gate $(Get-Date -Format 'yyyyMMddHHmmss')"
$auction = Invoke-Fca POST '/api/auctions' @{ name = $name; mode = 'single_round_spot'; bid_open_at = '2099-09-01T00:00:00Z'; bid_close_at = '2099-09-02T00:00:00Z' }
$auctionId = $auction.id
$load = Invoke-Fca POST "/api/auctions/$auctionId/loads" @{ lane_id = $LaneId; external_ref = "load-$($auctionId.Substring(0, 8))"; pickup_start = '2099-09-03T00:00:00Z'; pickup_end = '2099-09-03T02:00:00Z'; delivery_start = '2099-09-04T00:00:00Z'; delivery_end = '2099-09-04T04:00:00Z'; weight_lbs = 1000; equipment_type = 'dry_van' }
$firstBid = Invoke-Fca POST "/api/auctions/$auctionId/bids" @{ load_id = $load.id; carrier_id = $CarrierId; idempotency_key = "release-win-$auctionId"; bid_amount_cents = 12500; service_score_milli = 950; submitted_at = '2099-09-01T01:00:00Z' }
$secondCarrier = Invoke-Fca POST '/api/carriers' @{ legal_name = "Release Gate Carrier $($auctionId.Substring(0, 8)) LLC"; display_name = "Release Gate Carrier $($auctionId.Substring(0, 8))"; mc_number = "MC-$((Get-Random) + 10000)"; dot_number = "DOT-$((Get-Random) + 10000)"; equipment_type = 'dry_van'; status = 'active' }
$secondBid = Invoke-Fca POST "/api/auctions/$auctionId/bids" @{ load_id = $load.id; carrier_id = $secondCarrier.id; idempotency_key = "release-lose-$auctionId"; bid_amount_cents = 13000; service_score_milli = 900; submitted_at = '2099-09-01T01:01:00Z' }
Invoke-Fca POST "/api/auctions/$auctionId/close-bidding" @{}
$clear = Invoke-Fca POST "/api/auctions/$auctionId/clear" @{}

$job = $null
for ($attempt = 0; $attempt -lt 60; $attempt++) {
  Start-Sleep -Seconds 1
  $job = Invoke-Fca GET "/api/clearing-jobs/$($clear.job_id)"
  if ($job.status -in @('succeeded', 'failed', 'infeasible', 'cancelled')) { break }
}
if ($job.status -ne 'succeeded') { throw "Release gate clearing ended in $($job.status)." }

$decisions = Invoke-Fca GET "/api/auctions/$auctionId/explanations"
$decisionCount = if ($null -eq $decisions) { 0 } else { @($decisions).Count }
if ($decisionCount -lt 2) { throw 'Release gate expected awarded and rejected clearing decisions.' }
$awards = Invoke-Fca GET "/api/auctions/$auctionId/awards"
$awardCount = if ($null -eq $awards) { 0 } else { @($awards).Count }
if ($awardCount -ne 1) { throw 'Release gate expected exactly one award.' }

$preApprovalStatus = 0
try {
  Invoke-Fca POST "/api/auctions/$auctionId/export" @{ format = 'json' } | Out-Null
} catch {
  $preApprovalStatus = [int]$_.Exception.Response.StatusCode.value__
}
if ($preApprovalStatus -ne 409) { throw "Expected HTTP 409 before approval, received $preApprovalStatus." }

$approval = Invoke-Fca POST "/api/awards/$($awards[0].id)/approve" @{ note = 'release gate approval' }
$export = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$BaseUrl/api/auctions/$auctionId/export" -Headers $headers -ContentType 'application/json' -Body (Convert-Json @{ format = 'json' })
if ([int]$export.StatusCode -ne 200) { throw "Expected HTTP 200 after approval, received $($export.StatusCode)." }

[pscustomobject]@{
  auction_id = $auctionId
  job_id = $clear.job_id
  job_status = $job.status
  solver_version = $job.solver_version
  solver_input_uri = $job.solver_input_uri
  solver_output_uri = $job.solver_output_uri
  decision_count = $decisionCount
  award_count = $awardCount
  preapproval_export_http = $preApprovalStatus
  approval_status = $approval.status
  postapproval_export_http = [int]$export.StatusCode
  postapproval_export_bytes = $export.RawContentLength
} | ConvertTo-Json -Compress
