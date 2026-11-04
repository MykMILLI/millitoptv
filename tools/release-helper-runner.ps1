param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
$transcribing=$false
try{
 $r=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
 Set-Location -LiteralPath $r.project
 Start-Transcript -Path $r.log -Append|Out-Null
 $transcribing=$true
 $arguments=@{}
 foreach($entry in $r.parameters.PSObject.Properties){$arguments[$entry.Name]=$entry.Value}
 $global:LASTEXITCODE=0
 & ([string]$r.helper) @arguments | Out-Host
 if($LASTEXITCODE -ne 0){throw "Helper native command exited with code $LASTEXITCODE."}
 Stop-Transcript|Out-Null
 $transcribing=$false
 exit 0
}catch{
 Write-Host ('STAGE_FAILED: '+$_.Exception.Message) -ForegroundColor Red
 if($transcribing){try{Stop-Transcript|Out-Null}catch{}}
 exit 1
}
