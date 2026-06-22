<#
.SYNOPSIS
    Audit READ-ONLY des doublons et incoherences dans Active Directory
    Conforme cadre prod-ready E6 - usage maintenance/audit periodique

.DESCRIPTION
    Audit pur en lecture seule (zero modification). Genere :
      - Un log structure dans Logs/ (et telemetrie centralisee)
      - Un rapport TXT horodate dans Logs/ pour discussion humaine

    9 sections d'audit :
      1. Doublons probables - groupes globaux GG_* (noms similaires)
      2. Doublons probables - groupes Domain Local GDL_*
      3. Doublons probables - utilisateurs (sAMAccountName similaires)
      4. OU vides dans la hierarchie YANIXLABS
      5. Comptes utilisateurs desactives
      6. Comptes stales (sans connexion depuis 90 jours par defaut)
      7. Groupes custom (GG_*, GDL_*) sans membres
      8. Objets egares dans CN=Computers ou CN=Users (hors structure metier)
      9. AGDLP - groupes GG_* sans GDL_ correspondant (orphelins potentiels)

    Resultats : aucune action automatique - documente uniquement.
    Pour nettoyer apres analyse : utiliser 21-maintenance_Cleanup-Duplicates.ps1

.PARAMETER StaleAfterDays
    Nombre de jours sans connexion pour considerer un compte comme stale (defaut: 90)

.PARAMETER NoReportFile
    N'genere pas le rapport TXT separe (seul le log standard est conserve)

.EXAMPLE
    .\20-maintenance_Audit-Duplicates.ps1
    Audit complet avec rapport TXT

.EXAMPLE
    .\20-maintenance_Audit-Duplicates.ps1 -StaleAfterDays 30
    Audit avec seuil stale a 30 jours (plus strict)

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Execute sur SRV-DC-01 ou tout poste avec module AD
    Note    : LECTURE SEULE - aucune modification sur l'AD
#>

[CmdletBinding()]
param(
    [int]$StaleAfterDays = 90,
    [switch]$NoReportFile
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name

# ============================================================================
# PRE-FLIGHT (lecture seule - juste besoin d'accès AD)
# ============================================================================
Test-YanixPrerequis -Required AD -Stop

$config = Get-YanixConfig

$rootOU     = $config.OUs.Racine
$domainDN   = $config.DomainDN

# Rapport TXT separe (optionnel)
$reportFile = $null
if (-not $NoReportFile) {
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $reportFile = Join-Path $script:YanixContext.LogsDir "Audit-Duplicates-$stamp.txt"
    "Rapport d'audit AD - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $reportFile -Encoding UTF8
    "Domaine : $($config.Domain)" | Add-Content -Path $reportFile -Encoding UTF8
    "Operateur : $($script:YanixContext.UserDomain)\$($script:YanixContext.UserName)" | Add-Content -Path $reportFile -Encoding UTF8
    Write-YanixLog INFO "Rapport TXT : $reportFile"
}

function Write-SectionAudit {
    param([string]$Title)
    Write-YanixLog STEP "=== $Title ==="
    if ($reportFile) {
        $line = '=' * 78
        "`n$line`n  $Title`n$line" | Add-Content -Path $reportFile -Encoding UTF8
    }
}

function Write-FindingAudit {
    param([string]$Message, [string]$Severity = 'INFO')
    Write-YanixLog $Severity $Message
    if ($reportFile) {
        $line = '[{0,-4}] {1}' -f $Severity, $Message
        $line | Add-Content -Path $reportFile -Encoding UTF8
    }
}

function Get-NameNormalise {
    param([string]$Name)
    return ($Name -replace '[-_\s]', '').ToLower()
}

# ============================================================================
# 1) DOUBLONS GROUPES GLOBAUX GG_*
# ============================================================================
Write-SectionAudit '1) Doublons probables - Groupes globaux GG_*'

$ggGroups = Get-ADGroup -Filter "Name -like 'GG_*'" -Properties whenCreated, Members |
    Select-Object Name, DistinguishedName, whenCreated,
        @{N='NormalName'; E={ Get-NameNormalise $_.Name }},
        @{N='MemberCount'; E={ @($_.Members).Count }}

$ggDoublons = $ggGroups | Group-Object NormalName | Where-Object { $_.Count -gt 1 }

if (-not $ggDoublons) {
    Write-FindingAudit "Aucun doublon GG_* detecte ($($ggGroups.Count) groupes verifies)" 'OK'
} else {
    foreach ($g in $ggDoublons) {
        Write-FindingAudit "DOUBLON probable - pattern '$($g.Name)' : $($g.Count) variantes" 'WARN'
        foreach ($v in $g.Group) {
            Write-FindingAudit "    -> $($v.Name)  (Membres: $($v.MemberCount), Cree: $($v.whenCreated))" 'INFO'
        }
    }
}

# ============================================================================
# 2) DOUBLONS GDL_*
# ============================================================================
Write-SectionAudit '2) Doublons probables - Groupes Domain Local GDL_*'

$gdlGroups = Get-ADGroup -Filter "Name -like 'GDL_*'" -Properties whenCreated, Members |
    Select-Object Name, DistinguishedName, whenCreated,
        @{N='NormalName'; E={ Get-NameNormalise $_.Name }},
        @{N='MemberCount'; E={ @($_.Members).Count }}

$gdlDoublons = $gdlGroups | Group-Object NormalName | Where-Object { $_.Count -gt 1 }

if (-not $gdlDoublons) {
    Write-FindingAudit "Aucun doublon GDL_* detecte ($($gdlGroups.Count) groupes verifies)" 'OK'
} else {
    foreach ($g in $gdlDoublons) {
        Write-FindingAudit "DOUBLON probable - pattern '$($g.Name)' : $($g.Count) variantes" 'WARN'
        foreach ($v in $g.Group) {
            Write-FindingAudit "    -> $($v.Name)  (Membres: $($v.MemberCount))" 'INFO'
        }
    }
}

# ============================================================================
# 3) DOUBLONS UTILISATEURS
# ============================================================================
Write-SectionAudit '3) Doublons probables - Utilisateurs (sAM similaires)'

$users = Get-ADUser -Filter * -Properties whenCreated, Enabled, LastLogonDate |
    Where-Object {
        $_.SamAccountName -notlike 'krbtgt*' -and
        $_.SamAccountName -notlike 'svc-*' -and
        $_.SamAccountName -notin @('Administrateur','Administrator','Guest','Invite','Invité','DefaultAccount')
    } |
    Select-Object SamAccountName, DistinguishedName, Enabled, whenCreated, LastLogonDate,
        @{N='NormalSam'; E={ Get-NameNormalise $_.SamAccountName }}

$userDoublons = $users | Group-Object NormalSam | Where-Object { $_.Count -gt 1 }

if (-not $userDoublons) {
    Write-FindingAudit "Aucun doublon utilisateur detecte ($($users.Count) comptes humains)" 'OK'
} else {
    foreach ($u in $userDoublons) {
        Write-FindingAudit "DOUBLON probable - pattern '$($u.Name)' : $($u.Count) variantes" 'WARN'
        foreach ($v in $u.Group) {
            Write-FindingAudit "    -> $($v.SamAccountName)  (Enabled: $($v.Enabled), Cree: $($v.whenCreated))" 'INFO'
        }
    }
}

# ============================================================================
# 4) OU VIDES
# ============================================================================
Write-SectionAudit '4) OU vides dans la hierarchie YANIXLABS'

$allOUs = Get-ADOrganizationalUnit -Filter * -SearchBase $rootOU
$emptyOUs = @()
foreach ($ou in $allOUs) {
    $children = Get-ADObject -Filter * -SearchBase $ou.DistinguishedName -SearchScope OneLevel
    if ($children.Count -eq 0) {
        $emptyOUs += $ou
        Write-FindingAudit "OU VIDE : $($ou.DistinguishedName)" 'WARN'
    }
}
if ($emptyOUs.Count -eq 0) {
    Write-FindingAudit "Aucune OU vide ($($allOUs.Count) OUs verifiees)" 'OK'
} else {
    Write-FindingAudit "Total OU vides : $($emptyOUs.Count) / $($allOUs.Count)" 'WARN'
}

# ============================================================================
# 5) COMPTES DESACTIVES
# ============================================================================
Write-SectionAudit '5) Comptes utilisateurs desactives'

$disabled = $users | Where-Object { -not $_.Enabled }
if ($disabled.Count -eq 0) {
    Write-FindingAudit 'Aucun compte desactive' 'OK'
} else {
    foreach ($u in $disabled) {
        Write-FindingAudit "Desactive : $($u.SamAccountName)  (Cree: $($u.whenCreated))" 'WARN'
    }
}

# ============================================================================
# 6) COMPTES STALES
# ============================================================================
Write-SectionAudit "6) Comptes stales (sans connexion depuis $StaleAfterDays jours)"

$threshold = (Get-Date).AddDays(-$StaleAfterDays)
$stale = $users | Where-Object {
    $_.Enabled -and $_.LastLogonDate -and $_.LastLogonDate -lt $threshold
}
if ($stale.Count -eq 0) {
    Write-FindingAudit 'Aucun compte stale' 'OK'
} else {
    foreach ($u in $stale) {
        $days = [int]((Get-Date) - $u.LastLogonDate).TotalDays
        Write-FindingAudit "Stale ($days jours) : $($u.SamAccountName)" 'WARN'
    }
}

# ============================================================================
# 7) GROUPES CUSTOM VIDES
# ============================================================================
Write-SectionAudit '7) Groupes custom sans membres (GG_* et GDL_*)'

$customGroups = Get-ADGroup -Filter "Name -like 'GG_*' -or Name -like 'GDL_*'" -Properties Members
$emptyCustom = $customGroups | Where-Object { @($_.Members).Count -eq 0 }
if ($emptyCustom.Count -eq 0) {
    Write-FindingAudit "Tous les $($customGroups.Count) groupes custom ont des membres" 'OK'
} else {
    foreach ($g in $emptyCustom) {
        Write-FindingAudit "VIDE : $($g.Name)" 'WARN'
    }
    Write-FindingAudit "Total groupes vides : $($emptyCustom.Count) / $($customGroups.Count)" 'WARN'
}

# ============================================================================
# 8) OBJETS HORS HIERARCHIE METIER (CN=Computers, CN=Users)
# ============================================================================
Write-SectionAudit '8) Objets egares hors OU=YANIXLABS'

$strayComputers = Get-ADComputer -Filter * -SearchBase "CN=Computers,$domainDN" -ErrorAction SilentlyContinue
$strayUsers = Get-ADUser -Filter * -SearchBase "CN=Users,$domainDN" -ErrorAction SilentlyContinue | Where-Object {
    $_.SamAccountName -notlike 'krbtgt*' -and
    $_.SamAccountName -notin @('Administrateur','Administrator','Guest','Invite','Invité','DefaultAccount')
}

if ($strayComputers.Count -eq 0 -and $strayUsers.Count -eq 0) {
    Write-FindingAudit 'Aucun objet egare dans CN=Computers ou CN=Users' 'OK'
} else {
    foreach ($c in $strayComputers) {
        Write-FindingAudit "Ordinateur dans CN=Computers : $($c.Name) (devrait etre dans OU=Ordinateurs)" 'WARN'
    }
    foreach ($u in $strayUsers) {
        Write-FindingAudit "User dans CN=Users : $($u.SamAccountName) (devrait etre dans OU=Utilisateurs)" 'WARN'
    }
}

# ============================================================================
# 9) AGDLP - GG_ sans GDL_ correspondant
# ============================================================================
Write-SectionAudit '9) AGDLP - groupes GG_* sans GDL_ associe'

$gdlNamesNorm = $gdlGroups | ForEach-Object {
    Get-NameNormalise ($_.Name.Substring(4) -replace '_(l|m|ct)$', '')
}

$ggSansGdl = @()
foreach ($g in $ggGroups) {
    $base = Get-NameNormalise $g.Name.Substring(3)
    $match = $gdlNamesNorm | Where-Object { $_ -like "*$base*" -or $base -like "*$_*" }
    if (-not $match) { $ggSansGdl += $g }
}

if ($ggSansGdl.Count -eq 0) {
    Write-FindingAudit 'Tous les GG_* ont au moins un GDL_ associe' 'OK'
} else {
    foreach ($g in $ggSansGdl) {
        Write-FindingAudit "GG_ sans GDL_ : $($g.Name) (potentiel : groupe transverse sans ressource)" 'INFO'
    }
}

# ============================================================================
# RECAP STATS
# ============================================================================
Write-SectionAudit 'Recapitulatif des anomalies detectees'

$total = [ordered]@{
    GG_doublons        = @($ggDoublons).Count
    GDL_doublons       = @($gdlDoublons).Count
    User_doublons      = @($userDoublons).Count
    OU_vides           = @($emptyOUs).Count
    Comptes_desactives = @($disabled).Count
    Comptes_stales     = @($stale).Count
    Groupes_vides      = @($emptyCustom).Count
    Stray_computers    = @($strayComputers).Count
    Stray_users        = @($strayUsers).Count
    GG_orphelins_AGDLP = @($ggSansGdl).Count
}

$totalAnomalies = 0
foreach ($v in $total.Values) { $totalAnomalies += [int]$v }

foreach ($k in $total.Keys | Sort-Object) {
    Write-FindingAudit ('  {0,-22} : {1}' -f $k, $total[$k]) 'INFO'
}
Write-FindingAudit "TOTAL anomalies : $totalAnomalies" $(if ($totalAnomalies -gt 0) {'WARN'} else {'OK'})

if ($reportFile) {
    Write-YanixLog INFO ""
    Write-YanixLog INFO "Rapport TXT lisible : $reportFile"
    Write-YanixLog INFO "Log structure       : $($script:YanixContext.LogFile)"
}

Write-YanixLog INFO ""
Write-YanixLog INFO "Pour nettoyer apres analyse (avec confirmations) :"
Write-YanixLog INFO "  .\21-maintenance_Cleanup-Duplicates.ps1 -DryRun"

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
