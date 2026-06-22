<#
.SYNOPSIS
    Nettoyage des anomalies AD detectees par 20-maintenance_Audit-Duplicates.ps1
    Conforme cadre prod-ready E6 - operation DESTRUCTIVE avec confirmations

.DESCRIPTION
    Traite les anomalies detectees par l'audit, organise en 4 categories
    interactives. Chaque categorie demande une confirmation explicite avant
    execution. Mode -DryRun obligatoire en premier passage.

    Categorie 1 : FUSION doublons GG_* (convention canonique : underscore)
                  Ex: GG_Tous-Salaries -> fusionne dans GG_TousSalaries
                  Migre les membres uniques avant de supprimer le doublon.

    Categorie 2 : DEPLACEMENT serveurs hors CN=Computers
                  SRV-FS-01/FS-02 -> OU=Serveurs-Fichiers
                  SRV-BCK-01 -> OU=Serveurs-Sauvegarde

    Categorie 3 : CREATION comptes de service (svc-dfsr, svc-backup)
                  Avec PasswordNeverExpires + CannotChangePassword

    Categorie 4 : CREATION user demo-helpdesk + adhesion GG_Helpdesk

    100% idempotent : peut etre relance sans danger.
    En mode DryRun, simule toutes les actions sans modifier l'AD.

.PARAMETER DryRun
    Simulation sans modification - mode recommande pour premier passage

.PARAMETER SkipCategorie
    Saute une categorie : 1, 2, 3 ou 4 (ex: -SkipCategorie 3,4)

.EXAMPLE
    .\21-maintenance_Cleanup-Duplicates.ps1 -DryRun
    Simulation complete avec affichage des actions qui seraient executees

.EXAMPLE
    .\21-maintenance_Cleanup-Duplicates.ps1
    Execution reelle avec confirmation interactive par categorie

.EXAMPLE
    .\21-maintenance_Cleanup-Duplicates.ps1 -SkipCategorie 3,4
    Ne traite que les categories 1 et 2

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : SRV-DC-01 en Domain Admin
    Prerequis : Avoir lance l'audit 20-* au prealable pour confirmer les anomalies
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [int[]]$SkipCategorie
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1
. $PSScriptRoot\_common\AD-Helpers.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT
# ============================================================================
Test-YanixPrerequis -Required Admin, DomainAdmin, AD -Stop

$config = Get-YanixConfig

$ouServeurFichiers = "OU=Serveurs-Fichiers,OU=Serveurs,$($config.OUs.Racine)"
$ouServeurBackup   = "OU=Serveurs-Sauvegarde,OU=Serveurs,$($config.OUs.Racine)"
$ouComptesService  = "OU=Comptes-Services,$($config.OUs.Racine)"
$ouSI              = "OU=Systeme-Information,$($config.OUs.Utilisateurs)"

$pwdServ = ConvertTo-SecureString $config.MotDePasse.DefautBienvenue -AsPlainText -Force

# ============================================================================
# HELPER : confirmation interactive par categorie
# ============================================================================

function Confirm-Categorie {
    param([Parameter(Mandatory)][string]$Titre)

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : confirmation auto-validee pour '$Titre'"
        return $true
    }

    Write-Host ""
    $rep = Read-Host "Executer '$Titre' ? (O/N)"
    if ($rep -match '^[OoYy]') {
        return $true
    }
    Write-YanixLog SKIP "Categorie ignoree par l'operateur : $Titre"
    return $false
}

function Invoke-CleanupAction {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : $Description"
        return
    }

    try {
        & $Action
        Write-YanixLog OK $Description
    } catch {
        Write-YanixLog ERR "$Description - echec : $($_.Exception.Message)"
    }
}

# ============================================================================
# CATEGORIE 1 - FUSION DOUBLONS GG_*
# ============================================================================
if (1 -notin $SkipCategorie) {
    Write-YanixLog STEP "=== CATEGORIE 1/4 : Fusion doublons GG_* (convention underscore) ==="

    $fusions = @(
        @{ Source = 'GG_Tous-Salaries'; Target = 'GG_TousSalaries' }
        @{ Source = 'GG_Admins-Tier0';  Target = 'GG_Admins_Tier0' }
    )

    $aTraiter = $fusions | Where-Object { Test-YanixGroupe -Name $_.Source }

    if ($aTraiter.Count -eq 0) {
        Write-YanixLog SKIP "Aucun doublon GG_* a traiter (deja nettoye)"
    } elseif (Confirm-Categorie -Titre "Fusionner $($aTraiter.Count) doublon(s) GG_*") {
        foreach ($f in $aTraiter) {
            Write-YanixLog STEP "Fusion : $($f.Source) -> $($f.Target)"

            if (-not (Test-YanixGroupe -Name $f.Target)) {
                Write-YanixLog ERR "Cible '$($f.Target)' INEXISTANTE - fusion impossible, source preservee"
                continue
            }

            # Migrer membres uniques
            try {
                $srcMembers = @(Get-ADGroupMember -Identity $f.Source -ErrorAction SilentlyContinue)
                $tgtMembers = @(Get-ADGroupMember -Identity $f.Target -ErrorAction SilentlyContinue)
                $tgtSids    = $tgtMembers | ForEach-Object { $_.SID.Value }
                $toMigrate  = $srcMembers | Where-Object { $tgtSids -notcontains $_.SID.Value }

                if ($toMigrate.Count -eq 0) {
                    Write-YanixLog SKIP "Aucun membre unique a migrer"
                } else {
                    foreach ($m in $toMigrate) {
                        Invoke-CleanupAction -Description "Migrer $($m.SamAccountName) -> $($f.Target)" -Action {
                            Add-ADGroupMember -Identity $f.Target -Members $m.SID -ErrorAction Stop
                        }
                    }
                }

                # Supprimer la source
                Invoke-CleanupAction -Description "Supprimer doublon '$($f.Source)'" -Action {
                    Remove-ADGroup -Identity $f.Source -Confirm:$false -ErrorAction Stop
                }
            } catch {
                Write-YanixLog ERR "Echec fusion $($f.Source) : $($_.Exception.Message)"
            }
        }
    }
}

# ============================================================================
# CATEGORIE 2 - DEPLACEMENT SERVEURS HORS HIERARCHIE
# ============================================================================
if (2 -notin $SkipCategorie) {
    Write-YanixLog STEP "=== CATEGORIE 2/4 : Deplacement serveurs vers OU=Serveurs ==="

    $deplacements = @(
        @{ Name = 'SRV-FS-01';  Target = $ouServeurFichiers }
        @{ Name = 'SRV-FS-02';  Target = $ouServeurFichiers }
        @{ Name = 'SRV-BCK-01'; Target = $ouServeurBackup   }
    )

    $aDeplacer = @()
    foreach ($s in $deplacements) {
        $c = Get-ADComputer -Filter "Name -eq '$($s.Name)'" -ErrorAction SilentlyContinue
        if ($c -and ($c.DistinguishedName -notlike "*$($s.Target)")) {
            $aDeplacer += @{ Name = $s.Name; Current = $c.DistinguishedName; Target = $s.Target; DN = $c.DistinguishedName }
        }
    }

    if ($aDeplacer.Count -eq 0) {
        Write-YanixLog SKIP "Aucun serveur a deplacer (deja en bonne position)"
    } elseif (Confirm-Categorie -Titre "Deplacer $($aDeplacer.Count) serveur(s)") {
        foreach ($d in $aDeplacer) {
            Invoke-CleanupAction -Description "$($d.Name) -> $($d.Target)" -Action {
                Move-ADObject -Identity $d.DN -TargetPath $d.Target -ErrorAction Stop
            }
        }
    }
}

# ============================================================================
# CATEGORIE 3 - CREATION COMPTES DE SERVICE
# ============================================================================
if (3 -notin $SkipCategorie) {
    Write-YanixLog STEP "=== CATEGORIE 3/4 : Comptes de service svc-* ==="

    $svcAccounts = @(
        @{
            Sam = 'svc-dfsr'
            Name = 'Service DFS Replication'
            Desc = 'Compte de service DFS-R entre SRV-FS-01 et SRV-FS-02'
        }
        @{
            Sam = 'svc-backup'
            Name = 'Service Windows Backup'
            Desc = 'Compte de service Windows Server Backup (SRV-BCK-01)'
        }
    )

    $aCreer = $svcAccounts | Where-Object { -not (Test-YanixUtilisateur -SamAccountName $_.Sam) }

    if ($aCreer.Count -eq 0) {
        Write-YanixLog SKIP "Tous les comptes svc-* existent deja"
    } elseif (Confirm-Categorie -Titre "Creer $($aCreer.Count) compte(s) de service") {
        foreach ($svc in $aCreer) {
            Invoke-CleanupAction -Description "Creer $($svc.Sam) dans $ouComptesService" -Action {
                New-ADUser -Name $svc.Sam `
                           -SamAccountName $svc.Sam `
                           -UserPrincipalName "$($svc.Sam)@$($config.Domain)" `
                           -DisplayName $svc.Name `
                           -Description $svc.Desc `
                           -Path $ouComptesService `
                           -AccountPassword $pwdServ `
                           -Enabled $true `
                           -PasswordNeverExpires $true `
                           -CannotChangePassword $true `
                           -ErrorAction Stop
            }
        }
    }
}

# ============================================================================
# CATEGORIE 4 - CREATION demo-helpdesk + GG_Helpdesk
# ============================================================================
if (4 -notin $SkipCategorie) {
    Write-YanixLog STEP "=== CATEGORIE 4/4 : Compte demo-helpdesk + GG_Helpdesk ==="

    $samHd = 'demo-helpdesk'
    $existeUser = Test-YanixUtilisateur -SamAccountName $samHd

    if ($existeUser) {
        Write-YanixLog SKIP "$samHd existe deja - verification appartenance groupes seulement"
    }

    if (Confirm-Categorie -Titre "Provisionner $samHd + adhesion GG_Helpdesk") {

        if (-not $existeUser) {
            Invoke-CleanupAction -Description "Creer user $samHd dans $ouSI" -Action {
                New-ADUser -Name $samHd `
                           -SamAccountName $samHd `
                           -UserPrincipalName "$samHd@$($config.Domain)" `
                           -DisplayName 'Demo Helpdesk' `
                           -GivenName 'Demo' `
                           -Surname 'Helpdesk' `
                           -Description 'Compte demo Helpdesk - validation GPO/ACL Support N1' `
                           -Path $ouSI `
                           -AccountPassword $pwdServ `
                           -Enabled $true `
                           -ChangePasswordAtLogon $false `
                           -ErrorAction Stop
            }
        }

        # Adhesion groupes (idempotent via Add-YanixGroupeMembre)
        foreach ($g in @('GG_Helpdesk', 'GG_TousSalaries')) {
            if (Test-YanixGroupe -Name $g) {
                Add-YanixGroupeMembre -GroupName $g -MemberName $samHd
            } else {
                Write-YanixLog WARN "Groupe $g introuvable - skip"
            }
        }
    }
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
Write-YanixLog STEP "=== Nettoyage termine ==="
Write-YanixLog INFO "Pour verifier l'effet : relance .\20-maintenance_Audit-Duplicates.ps1"

exit (Show-YanixRecap)
