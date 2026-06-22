<#
.SYNOPSIS
    Provisionnement batch des dossiers home individuels sur SRV-FS-01
    pour tous les utilisateurs metier existants dans l'AD.
    Conforme cadre prod-ready E6

.DESCRIPTION
    A executer sur SRV-DC-01 (acces AD natif).

    Pipeline :
      1. Recupere la liste des users humains depuis AD (filtre svc-, system, etc.)
      2. Pour chaque user, via PowerShell Remoting sur SRV-FS-01 :
         - Cree D:\Partages\Users\<sAMAccountName>\ si absent
         - Applique ACL stricte (Domain Admins + SYSTEM + user en Modify)
      3. Verification post : enumere tous les dossiers crees

    Utilise pour le bootstrap initial (cree les homes des users existants)
    OU pour reconciler (utile apres import en masse via CSV).

.PARAMETER FsServer
    Hostname du serveur de fichiers (defaut : depuis E6-Config.psd1 = SRV-FS-01)

.PARAMETER OnlySam
    Limite le traitement a un sAMAccountName specifique (utile en test ciblé)

.PARAMETER DryRun
    Simulation sans creation ni modification

.EXAMPLE
    .\12-ops_Provision-Homes-Batch.ps1 -DryRun

.EXAMPLE
    .\12-ops_Provision-Homes-Batch.ps1 -OnlySam demo-rh

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Execute sur SRV-DC-01
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$FsServer,
    [string]$OnlySam,
    [switch]$DryRun
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT
# ============================================================================
Test-YanixPrerequis -Required Admin, DomainAdmin, AD, FS01 -Stop

$config = Get-YanixConfig

if (-not $FsServer) { $FsServer = $config.Serveurs.FS01.Hostname }

$usersRoot     = 'D:\Partages\Users'
$domainNetBIOS = $config.DomainNetBIOS
$ouRacine      = $config.OUs.Racine

# ============================================================================
# PHASE 1 - RECUPERATION DES USERS HUMAINS DEPUIS AD
# ============================================================================
Write-YanixLog STEP "=== PHASE 1/3 : Recuperation des users humains depuis AD ==="

$tousUsers = Get-ADUser -Filter * -SearchBase $ouRacine | Where-Object {
    $_.SamAccountName -notlike 'svc-*' -and
    $_.SamAccountName -notlike 'krbtgt*' -and
    $_.SamAccountName -ne 'Administrateur' -and
    $_.SamAccountName -ne 'Administrator' -and
    $_.SamAccountName -ne 'Invite' -and
    $_.SamAccountName -ne 'Guest' -and
    $_.SamAccountName -ne 'DefaultAccount'
}

if ($OnlySam) {
    $tousUsers = $tousUsers | Where-Object { $_.SamAccountName -eq $OnlySam }
    Write-YanixLog INFO "Filtre actif : seul le user '$OnlySam' sera traite"
}

$samList = $tousUsers | Select-Object -ExpandProperty SamAccountName

if ($samList.Count -eq 0) {
    Write-YanixLog ERR "Aucun user humain trouve a provisionner"
    exit (Show-YanixRecap)
}

Write-YanixLog OK "$($samList.Count) user(s) humain(s) a traiter"
$samList | Sort-Object | ForEach-Object { Write-YanixLog INFO "  - $_" }

# ============================================================================
# PHASE 2 - PROVISIONNEMENT DISTANT SUR FS-01
# ============================================================================
Write-YanixLog STEP "=== PHASE 2/3 : Provisionnement sur $FsServer via Remoting ==="

# Test du Remoting
if (-not (Test-YanixRemoting -ComputerName $FsServer)) {
    Write-YanixLog ERR "$FsServer injoignable via WinRM. Sur $FsServer : Enable-PSRemoting -Force"
    exit (Show-YanixRecap)
}
Write-YanixLog OK "Remoting actif sur $FsServer"

# Bloc execute SUR FS-01
$remoteBlock = {
    param($UsersRoot, $DomainNetBIOS, $UserList, $IsDryRun)

    function Resolve-Sid {
        param([string]$Sid)
        return (New-Object System.Security.Principal.SecurityIdentifier $Sid).Translate([System.Security.Principal.NTAccount]).Value
    }

    $domainSid    = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.AccountDomainSid).Value
    $domainAdmins = Resolve-Sid "$domainSid-512"
    $localSystem  = Resolve-Sid 'S-1-5-18'

    $resultats = @{
        DomainAdmins = $domainAdmins
        LocalSystem  = $localSystem
        Created      = 0
        Skipped      = 0
        Failed       = 0
        Errors       = @()
    }

    if (-not (Test-Path $UsersRoot)) {
        $resultats.Errors += "$UsersRoot inexistant sur $env:COMPUTERNAME"
        return $resultats
    }

    foreach ($sam in $UserList) {
        $homePath = Join-Path $UsersRoot $sam
        $domUser  = "$DomainNetBIOS\$sam"

        if (Test-Path $homePath) {
            $resultats.Skipped++
            continue
        }

        if ($IsDryRun) {
            $resultats.Created++   # compte comme aurait ete cree
            continue
        }

        try {
            New-Item -Path $homePath -ItemType Directory -Force | Out-Null

            # ACL stricte
            $acl = Get-Acl $homePath
            $acl.SetAccessRuleProtection($true, $false)
            @($acl.Access | Where-Object { -not $_.IsInherited }) |
                ForEach-Object { [void]$acl.RemoveAccessRule($_) }

            $rules = @(
                @{ Id = $domainAdmins; Rights = 'FullControl' }
                @{ Id = $localSystem;  Rights = 'FullControl' }
                @{ Id = $domUser;      Rights = 'Modify, Synchronize' }
            )
            foreach ($r in $rules) {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $r.Id, $r.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
                )
                $acl.AddAccessRule($rule)
            }
            Set-Acl -Path $homePath -AclObject $acl

            $resultats.Created++
        } catch {
            $resultats.Failed++
            $resultats.Errors += "$sam : $($_.Exception.Message)"
        }
    }

    return $resultats
}

# Execution distante
try {
    $r = Invoke-Command -ComputerName $FsServer -ScriptBlock $remoteBlock `
                        -ArgumentList $usersRoot, $domainNetBIOS, $samList, $script:YanixContext.DryRun.IsPresent `
                        -ErrorAction Stop

    Write-YanixLog INFO "Comptes integres FS-01 : Admins=$($r.DomainAdmins), SYSTEM=$($r.LocalSystem)"

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : $($r.Created) home(s) serai(ent) cree(s), $($r.Skipped) deja present(s)"
    } else {
        if ($r.Created -gt 0) { Write-YanixLog OK "$($r.Created) home(s) cree(s) avec ACL stricte" }
        if ($r.Skipped -gt 0) { Write-YanixLog SKIP "$($r.Skipped) home(s) deja present(s)" }
        if ($r.Failed -gt 0)  {
            Write-YanixLog ERR "$($r.Failed) echec(s)"
            $r.Errors | ForEach-Object { Write-YanixLog ERR "  $_" }
        }
    }
} catch {
    Write-YanixLog ERR "Echec Remoting : $($_.Exception.Message)"
    exit (Show-YanixRecap)
}

# ============================================================================
# TEST POST-DEPLOIEMENT
# ============================================================================

function Test-Provision-Homes {
    Write-YanixLog STEP "=== Test post-deploiement : Provision Homes ==="

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "Test SKIP en mode DryRun"
        return $true
    }

    $errors = @()
    foreach ($sam in $samList) {
        $expected = "\\$FsServer\D`$\Partages\Users\$sam"
        if (Test-Path $expected) {
            Write-YanixLog OK "Home present : $sam"
        } else {
            Write-YanixLog ERR "Home manquant : $sam"
            $errors += $sam
        }
    }

    if ($errors.Count -eq 0) {
        Write-YanixLog OK "Verification post-deploiement REUSSIE : $($samList.Count) home(s) prets"
        return $true
    } else {
        Write-YanixLog WARN "Verification avec $($errors.Count) home(s) manquant(s)"
        return $false
    }
}

if ($config.Tests.ActiverApresExecution) {
    Test-Provision-Homes | Out-Null
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
