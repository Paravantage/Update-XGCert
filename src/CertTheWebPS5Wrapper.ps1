<#
    CertTheWebPS5Wrapper - PowerShell 5 bridge for cert management
    Copyright (C) 2021  Paravantage, LLC

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#>

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