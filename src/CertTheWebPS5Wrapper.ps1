param(
    $result,
    [string]$CertName = $result.ManagedItem.Name,
    [string]$CertFile = $result.ManagedItem.CertificatePath
)
$myPath = Split-Path $MyInvocation.MyCommand.Path -Parent
$myLog = "$myPath/Wrapper.log"
$myScript = "Update-XGCert.ps1"

function Write-MyLog($MSG) {
    Add-Content $myLog -Value $MSG    
}

if(Test-Path -Path $myLog -PathType Leaf) { Clear-Content $myLog }
Write-MyLog "------- path --------"
Write-MyLog "$myPath\$myScript"
Write-MyLog "------- args --------"
Write-MyLog "CertName   : $CertName"
Write-MyLog "CertFile   : $CertFile"
Write-MyLog "------- flags --------"
Write-MyLog $args

pwsh $myPath\$myScript -CertName $CertName -CertFile $CertFile @args