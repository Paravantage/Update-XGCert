<#
    Update-XGCert - for automating LE cert renewals in XG
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

<#
    .SYNOPSIS
    Performs Certificate Updates in Sophos XG Firewall

    .DESCRIPTION
    For appliance certificates or WAF certificates that are not used in any rules, this script will simply
    update the cert in XG. For in-use WAF certificates, the script will upload the new cert with a temporary
    name, modify the rules to use the temp cert, update the original cert, repoint the rules back to the
    original cert, fix rule groups, and then delete the temporary cert.

    .PARAMETER CertName
    Specifices the name of the Certificate in XG.

    .PARAMETER CertFile
    Specifies the full path of the new PFX Certificate file.

    .PARAMETER NoRuleCheck
    If used, the script will skip checking for impacted rules and just update the cert in-place. Use when
    the cert is not in use or when used only by appliance services such as user portal.

    .PARAMETER DeleteCert
    If used, the script will delete the PFX file identified in the CertFile parameter.

    .PARAMETER DryRun
    If used, only simulates the actions that would have been taken.

    .PARAMETER SendMail
    Sends log file in email. Mail variables in this script must be set.

    .INPUTS
    None.

    .OUTPUTS
    None.

    .EXAMPLE
    PS> .\Update-XGCert.ps1 -CertName "My WAF Certificate" -CertFile "C:\xg_certs\pfx\MyWAFCert.pfx"

    .EXAMPLE
    PS> .\Update-XGCert.ps1 -CertName "My XG Cert" -CertFile "C:\xg_certs\pfx\MyXGCert.pfx" -NoRuleCheck
#>

Param(
    [Parameter(Mandatory=$true)][string]$CertName,
    [Parameter(Mandatory=$true)][string]$CertFile,
    [switch]$NoRuleCheck,
    [switch]$DeleteCert,
    [switch]$DryRun,
    [switch]$SendMail
)


# -------------------------------------------------------------------------------------
# Start Of Script Variables

<#
 == Output Log File Variables ==
 $LogFile - Transaction log. Defaults is  "$(Split-Path $MyInvocation.MyCommand.Path -Parent)\$CertName.log".
 $ReuseLog - $true will truncate the log on each run, $false will simply append.
#>
$LogFile = "$(Split-Path $MyInvocation.MyCommand.Path -Parent)\$CertName.log"
$ReuseLog = $true

<#
== XG Login Variables ==
$XGURI - The name or IP and port of your XG instance
$XGUser - The api user name
$XGPass - The api user password
$XGPassEncrypted - $true to use "encrypt" or $false for "plain"
#>
$XGURI = 'https://xg.domain.name:4444'
$XGUser = 'api admin'
$XGPass = 'correcthorsebatterystaple'
$XGPassEncrypted = $false

<#
== Email Varables ==
$MailFrom - who is sending the mail
$MailTo - where to send the mail
$SMTPServer - the hostname or IP address of the relay SMTP server
#>
$MailFrom = "Some User some.user@domain.name"
$MailTo = "Another User another.user@domain.name"
$SMTPServer = "smtp.domain.name"

# End Of Script Variables
# -------------------------------------------------------------------------------------

# Writes to the log file and mantains messages for emailing
function Write-Log {
    param (
        [string]$MSG,              # The log message
        [switch]$SkipStamp         # Skip Time Stamp
    )
    $logMsg = "$(-Not $SkipStamp ? "$(get-date -format u) : ": '')$MSG"
    $script:RunningLog += $logMsg
    Add-Content $LogFile -Value $logMsg
}

# Tests to see if a cert exists within XG
function Test-NewCert {    
    $cer = Get-XGObjects -XGObjectType Certificate -XGFilter (New-XGFilter $CertName)
    if($null -ne $cer) {
        Write-Log "This is a brand new certificate to XG."
        return $true
    } else {
        return $false
    }
}

# Generates XML used to add or update a certificate
function Get-XGCertXML {   
    param (
        [string]$Operation      # either 'add' or 'update' or 'new'
    )
    $script:LastXML = "<Set operation=`"$($Operation -eq 'new' ? 'add' : $Operation)`"><Certificate><Name>$CertName$($Operation -eq "add" ? $AppendText : '' )</Name><Action>UploadCertificate</Action><CertificateFormat>pkcs12</CertificateFormat><CertificateFile>$((Get-Item $CertFile).NameString)</CertificateFile></Certificate></Set>"
    return $LastXML
}

# Generic function to build the reqxml for XG
function Get-XGResult {
    param (
        [string]$XGXML,         # The XML string containing the XG command
        [switch]$CFile,         # when found, adds the certificate file to the form for submission to XG
        [switch]$LogOnly        # used for Dry Run executions
    )
    $script:LastXML = $XGXML
    $uri = "$XGURI/webconsole/APIController"
    $form = @{
        reqxml = "<?xml version=`"1.0`" encoding=`"UTF-8`"?><Request><Login><Username>$XGUser</Username><Password  passwordform=`"$($XGPassEncrypted ? 'encrypt' : 'plain')`">$XGPass</Password></Login>$XGXML</Request>"
    }
    if($CFile) { $form+= @{$((Get-Item $CertFile).BaseName) = Get-Item -Path $CertFile} }
    if($LogOnly) {
        Write-Log $LastXML -SkipStamp
        return $null
    } else {
        $raw = Invoke-WebRequest -Uri $uri -Method Get -Form $form
        $ctType = $raw.Headers["Content-Type"][0]
        if($ctType -match "octet-stream") { return $null } # we have a cert download!
        $result = ([xml]$raw.Content).Response
        if($result.Login.status -match "Failure") {
            throw $result.Login.status
        }
        $status = ($result.OuterXML | Select-Xml -Xpath "//Status[@code]").Node # easiest way I could think of to find failure status codes since parent node name changes
        if($status -and $status.code -ne "200") {
            throw "$($status.code): $($status.InnerText)"
        }
        return $result        
    }
}

# creates a filter for GET actions, not used but kept for reference
function New-XGFilter {
    param (
        [string]$FilterName,        # the object name you are looking for
        [string]$FilterType = "="   # filter criteria of '=', '!=', or 'like'
    )
    "<Filter><key name=`"Name`" criteria=`"$FilterType`">$FilterName</key></Filter>"
}

# creates a simple GET request
function Get-XGObjects {
    param (
        [string]$XGObjectType,      # The XG Object Type such as FirewallRule or FirewallRuleGroup
        [string]$XGFilter,           # Optional XG Filter created by New-XGFilter function
        [switch]$SkipGrab           # Don't bother pulling out the specific item's XML
    )
    $result = Get-XGResult -XGXML "<Get><$XGObjectType>$XGFilter</$XGObjectType></Get>"
    if($XGObjectType -eq "Certificate") {return $result}
    return $result.SelectNodes($XGObjectType)
}

# gets all the XG Firewall Rules so we can search them to find which ones use the certificate
function Get-XGRules {
    $rules = Get-XGObjects -XGObjectType "FirewallRule"
    $found = @{}
    foreach ($rule in $rules) {
        $cName = $rule.HTTPBasedPolicy.Certificate
        if($cName -and $cName -eq $CertName) {
            $found[$rule.Name] = $rule
        }
    }
    return $found
}

# gets all the XG Firewall Rule Groups so we can search them for impacted rules
function Get-XGGroups {
    param (
        [hashtable]$RuleHash        # the hashtable containing all the impacted rules where key = rule name
    )
    $groups = Get-XGObjects -XGObjectType "FirewallRuleGroup"
    $found = @{}
    foreach ($group in $groups) {
        $policies = $group.SecurityPolicyList.SelectNodes("SecurityPolicy")
        foreach ($policy in $policies) {
            if($RuleHash.ContainsKey($policy.InnerText)) {
                $found[$group.Name] = $group
            }
        }
    }
    return $found
}

# creates the XML to add or upload a certificate
function Set-XGRuleCert {
    param (
        [system.xml.xmlelement]$FWRule,     # the XML node for the Firewall Rule
        [switch]$Append                     # use for temp cert upload to add the $Append value to the end of the cert name
    )
    $FWRule.HTTPBasedPolicy.Certificate = "$CertName$($Append ? $AppendText : '')"
    Get-XGResult -XGXML "<Set operation=`"update`">$($FWRule.OuterXML)</Set>" -LogOnly:$DryRun | Out-Null
}

# In-Script Variables
$RunningLog = @()       # Holds the action messages for sending email
$LastXML = ""           # Holds the last XML command send to XG
$AppendText = "TEMP"    # Appended to certificate names for temp certificates
$Rules = @()            # Holds the rules using this certificate
$Groups = @()           # Holds the groups where impacted rules are found


if($ReuseLog -and (Test-Path -Path $LogFile -PathType Leaf)) { Clear-Content -Path $LogFile }
else { Write-Log "------------------------------------ BEGIN TRANSACTION ------------------------------------" }
Write-Log "Working certificate $CertName with file $CertFile and $($NoRuleCheck ? 'NO ' : '')rule check."
if($DryRun) { Write-Log "This is a DRY RUN execution."}
try {
    if(-Not (Test-Path -Path $CertFile -PathType Leaf)) { throw "Missing Cert File: $CertFile" }
    $NewCert = Test-NewCert
    
    if($NoRuleCheck -or $NewCert) {
        Write-Log "Skipping Rule Check"
    } else {
        Write-Log "Finding Matching Rules..."
        $Rules = Get-XGRules
        if($Rules.Count -gt 0) {
            Write-Log "   Found $($Rules.Count) Rule(s)"    
            Write-Log "Finding Matching Groups..."
            $Groups = Get-XGGroups -RuleHash $Rules
            Write-Log "   Found $($Groups.Count -gt 0 ? "$($Groups.Count) Group(s)" : "No Matching Groups")"
            Write-Log "Adding Temporary Certificate..."
            Get-XGResult -XGXML (Get-XGCertXML -Operation "add") -CFile -LogOnly:$DryRun | Out-Null
            Write-Log "   $CertName$AppendText Added."
            Write-Log "Updating Rules With Temporary Certificate..."
            foreach ($rule in $Rules.Keys) {
                Set-XGRuleCert -FWRule $Rules[$rule] -Append
                Write-Log "   Updated Rule $rule"
            }
        } else {
            Write-Log "   Found No Rules Using This Certificate"
        }
    }
    Write-Log "Updating Certificate $CertName..."
    Get-XGResult -XGXML (Get-XGCertXML -Operation ($NewCert ? 'new':'update')) -CFile -LogOnly:$DryRun| Out-Null
    Write-Log "   Certificate $($cert) Updated"
    if($Rules.Count -gt 0) {
        Write-Log "Reverting Rules..."
        foreach ($rule in $Rules.Keys) {
            Set-XGRuleCert -FWRule $Rules[$rule]
            Write-Log "   Updated Rule $rule"
        }
        Write-Log "Fixing Groups..."
        foreach ($group in $Groups.Keys) {
            Get-XGResult -XGXML "<Set operation=`"update`">$($Groups[$group].OuterXML)</Set>" -LogOnly:$DryRun | Out-Null
            Write-Log "   Fixed Group $group"
        }
        Write-Log "Removing Temporary Certificate..."
        Get-XGResult -XGXML "<Remove><Certificate><Name>$CertName$AppendText</Name></Certificate></Remove>" -LogOnly:$DryRun | Out-Null
        Write-Log "   $CertName$AppendText Removed."
    }
    if($DeleteCert) {
        Write-Log "Deleting source PFX certificate file..."
        if($DryRun) {Write-Log "   Dry Run so left in place."}
        else {
            Remove-Item $CertFile
            Write-Log "   $CertFile Deleted."
        }
    } else {
        Write-Log "Leaving source PFX certificate file in place."
    }
    Write-Log "Transaction Complete"
} catch {
    Write-Log "--- ERROR ---"
    if($_.ErrorDetails.Message) {
        Write-Host $_.ErrorDetails.Message
        Write-Log $_.ErrorDetails.Message
    } else {
        Write-Host $_
        Write-Log $_
    }
    Write-Log "Last XML Sent to XG:`r`n   $LastXML"
} finally {
    if($SendMail) { Send-MailMessage -From $MailFrom -To $MailTo -Subject 'XG Certificate Update' -Body $($RunningLog | Out-String) -SmtpServer $SMTPServer }
}