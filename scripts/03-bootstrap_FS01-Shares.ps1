<#
.SYNOPSIS
    Bootstrap des partages de fichiers SMB sur SRV-FS-01
    Conforme cadre prod-ready E6 - Microsoft + ANSSI

.DESCRIPTION
    Provisionne 12 partages SMB cachés sur SRV-FS-01 :
      - 9 partages métier (un par service)
      - 3 partages transverses (Commun, Projets, Users)

    Pour chaque partage :
      - Crée le dossier physique D:\Partages\<Nom>
      - Crée le partage SMB caché \\SRV-FS-01\<Nom>$ (FullAccess = Authenticated Users)
      - Applique les ACL NTFS strictes selon le modèle AGDLP :
          * Admins du domaine + SYSTEM + CreatorOwner : Full Control
          * GDL_Partage_<Service>_L  : ReadAndExecute
          * GDL_Partage_<Service>_M  : Modify
          * GDL_Partage_<Service>_CT : FullControl
          * Héritage désactivé

    Cas spécial 'Users' : pas d'ACL AGDLP (les homes individuels seront
    provisionnés en Phase suivante avec ACL par utilisateur).

    SIDs intégrés résolus dynamiquement pour compatibilité Windows FR/EN.

.PARAMETER DryRun
    Simulation sans modification

.EXAMPLE
    .\03-bootstrap_FS01-Shares.ps1 -DryRun

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Doit être exécuté SUR SRV-FS-01 (lecture des SIDs locaux)
    Prérequis : Domain Admin (résolution des groupes GDL_*)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================
Test-YanixPrerequis -Required Admin, DomainAdmin -Stop

$config = Get-YanixConfig

# Verification : on doit etre sur SRV-FS-01
if ($env:COMPUTERNAME -ne $config.Serveurs.FS01.Hostname) {
    Write-YanixLog WARN "Script execute sur $env:COMPUTERNAME mais cible attendue : $($config.Serveurs.FS01.Hostname)"
    Write-YanixLog WARN "Continuer ? Les partages seront crees localement sur cette machine."
    $rep = Read-Host "Confirmer l'execution sur $env:COMPUTERNAME ? (O/N)"
    if ($rep -notmatch '^[OoYy]') {
        Write-YanixLog INFO "Execution annulee par l'operateur"
        exit 0
    }
}

# ============================================================================
# CONFIGURATION LOCALE
# ============================================================================
$rootPath      = $config.DFS.BaseLocale
$domainNetBIOS = $config.DomainNetBIOS
$services      = $config.ServicesMetier   # 9 services
$transverses   = @('Commun', 'Projets', 'Users')

# ============================================================================
# RESOLUTION DES SIDS INTEGRES (compatibilite FR/EN)
# ============================================================================

function Resolve-YanixSid {
    param([string]$Sid)
    try {
        return (New-Object System.Security.Principal.SecurityIdentifier $Sid).Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        return $null
    }
}

# SIDs universels
$authenticatedUsers = Resolve-YanixSid 'S-1-5-11'   # Utilisateurs authentifies
$localSystem        = Resolve-YanixSid 'S-1-5-18'   # SYSTEM
$creatorOwner       = Resolve-YanixSid 'S-1-3-0'    # CREATOR OWNER

# Domain Admins (RID 512) via SID du domaine courant
try {
    $domainSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.AccountDomainSid).Value
    $domainAdmins = Resolve-YanixSid "$domainSid-512"
    if (-not $domainAdmins) { throw "Domain Admins introuvable" }
} catch {
    $domainAdmins = "$domainNetBIOS\Admins du domaine"
    Write-YanixLog WARN "Resolution Domain Admins par SID echouee, fallback : $domainAdmins"
}

Write-YanixLog INFO "Comptes integres resolus :"
Write-YanixLog INFO "  Authenticated Users -> $authenticatedUsers"
Write-YanixLog INFO "  LocalSystem         -> $localSystem"
Write-YanixLog INFO "  CREATOR OWNER       -> $creatorOwner"
Write-YanixLog INFO "  Domain Admins       -> $domainAdmins"

# ============================================================================
# HELPERS LOCAUX (idempotents, DryRun-aware)
# ============================================================================

function New-YanixDossier {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path $Path) {
        Write-YanixLog SKIP "Dossier deja present : $Path"
        return
    }
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation dossier '$Path' simulee"
        return
    }
    try {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-YanixLog OK "Dossier cree : $Path"
    } catch {
        Write-YanixLog ERR "Echec creation dossier $Path : $($_.Exception.Message)"
    }
}

function New-YanixPartageMetier {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Description = ''
    )

    $existing = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Path -ne $Path) {
            Write-YanixLog WARN "Partage $Name pointe sur $($existing.Path), attendu : $Path"
            if ($script:YanixContext.DryRun) {
                Write-YanixLog INFO "DRY-RUN : re-creation du partage simulee"
                return
            }
            Remove-SmbShare -Name $Name -Force -Confirm:$false -ErrorAction Stop
            New-SmbShare -Name $Name -Path $Path -Description $Description -FullAccess $authenticatedUsers | Out-Null
            Write-YanixLog OK "Partage $Name re-cree -> $Path"
        } else {
            Write-YanixLog SKIP "Partage $Name deja present"
        }
        return
    }

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation partage '$Name' -> '$Path' simulee"
        return
    }
    try {
        New-SmbShare -Name $Name -Path $Path -Description $Description -FullAccess $authenticatedUsers -ErrorAction Stop | Out-Null
        Write-YanixLog OK "Partage cree : $Name -> $Path"
    } catch {
        Write-YanixLog ERR "Echec creation partage $Name : $($_.Exception.Message)"
    }
}

function Set-YanixAclMetier {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ServiceName,
        [switch]$WithCT   # ajoute le niveau CT (par défaut oui pour les services métier, non pour Commun/Projets)
    )

    if (-not (Test-Path $Path)) {
        Write-YanixLog WARN "Chemin inexistant pour ACL : $Path"
        return
    }
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : application ACL AGDLP sur '$Path' pour service '$ServiceName' simulee"
        return
    }

    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)
        @($acl.Access | Where-Object { -not $_.IsInherited }) |
            ForEach-Object { [void]$acl.RemoveAccessRule($_) }

        # ACE preservées
        $keepRules = @(
            @{ User = $domainAdmins; Rights = 'FullControl'; Prop = 'None' }
            @{ User = $localSystem;  Rights = 'FullControl'; Prop = 'None' }
            @{ User = $creatorOwner; Rights = 'FullControl'; Prop = 'InheritOnly' }
        )

        # ACE AGDLP (3 niveaux ou 2 selon le service)
        $agdlpRules = @(
            @{ User = "$domainNetBIOS\GDL_Partage_${ServiceName}_L"; Rights = 'ReadAndExecute, Synchronize' }
            @{ User = "$domainNetBIOS\GDL_Partage_${ServiceName}_M"; Rights = 'Modify, Synchronize' }
        )
        if ($WithCT) {
            $agdlpRules += @{ User = "$domainNetBIOS\GDL_Partage_${ServiceName}_CT"; Rights = 'FullControl' }
        }

        foreach ($r in $keepRules) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $r.User, $r.Rights, 'ContainerInherit,ObjectInherit', $r.Prop, 'Allow'
            )
            $acl.AddAccessRule($rule)
        }
        foreach ($r in $agdlpRules) {
            try {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $r.User, $r.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
                )
                $acl.AddAccessRule($rule)
            } catch {
                Write-YanixLog WARN "Groupe GDL introuvable, ACE ignore : $($r.User)"
            }
        }
        Set-Acl -Path $Path -AclObject $acl
        Write-YanixLog OK "ACL AGDLP appliquees sur $Path ($ServiceName)"
    } catch {
        Write-YanixLog ERR "Echec ACL $Path : $($_.Exception.Message)"
    }
}

# ============================================================================
# PHASE 1 - RACINE D:\Partages
# ============================================================================
Write-YanixLog STEP "=== PHASE 1/3 : Racine $rootPath ==="
New-YanixDossier -Path $rootPath

# ============================================================================
# PHASE 2 - PARTAGES METIER (9 services x dossier + share + ACL AGDLP)
# ============================================================================
Write-YanixLog STEP "=== PHASE 2/3 : Partages metier (9 services) ==="

foreach ($svc in $services) {
    $folder    = Join-Path $rootPath $svc
    $shareName = "$svc`$"   # partage caché

    New-YanixDossier -Path $folder
    New-YanixPartageMetier -Name $shareName -Path $folder -Description "Partage du service $svc"
    Set-YanixAclMetier -Path $folder -ServiceName $svc -WithCT
}

# ============================================================================
# PHASE 3 - PARTAGES TRANSVERSES (Commun, Projets, Users)
# ============================================================================
Write-YanixLog STEP "=== PHASE 3/3 : Partages transverses ==="

foreach ($t in $transverses) {
    $folder    = Join-Path $rootPath $t
    $shareName = "$t`$"

    New-YanixDossier -Path $folder
    New-YanixPartageMetier -Name $shareName -Path $folder -Description "Partage transverse $t"

    if ($t -eq 'Users') {
        Write-YanixLog INFO "Users : ACL specifiques (homes individuels en Phase suivante)"
        # Pour Users, on garde une ACL de base : Admins + SYSTEM (les homes individuels seront créés ailleurs)
        if (-not $script:YanixContext.DryRun) {
            try {
                $acl = Get-Acl $folder
                $acl.SetAccessRuleProtection($true, $false)
                @($acl.Access | Where-Object { -not $_.IsInherited }) |
                    ForEach-Object { [void]$acl.RemoveAccessRule($_) }
                foreach ($id in @($domainAdmins, $localSystem)) {
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
                    )
                    $acl.AddAccessRule($rule)
                }
                # Tous les utilisateurs authentifiés peuvent lister/traverser le conteneur (pour atteindre leur home)
                $traverseRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $authenticatedUsers, 'ReadAndExecute, Synchronize', 'None', 'None', 'Allow'
                )
                $acl.AddAccessRule($traverseRule)
                Set-Acl -Path $folder -AclObject $acl
                Write-YanixLog OK "ACL Users : Admins+SYSTEM (FullControl) + Auth Users (Traverse)"
            } catch {
                Write-YanixLog ERR "Echec ACL Users : $($_.Exception.Message)"
            }
        }
    } else {
        # Commun et Projets : AGDLP avec niveaux L et M seulement (pas de CT)
        Set-YanixAclMetier -Path $folder -ServiceName $t
    }
}

# ============================================================================
# TEST POST-DEPLOIEMENT
# ============================================================================

function Test-Bootstrap-FS01-Shares {
    Write-YanixLog STEP "=== Test post-deploiement : Bootstrap FS01-Shares ==="

    $errors = @()
    $attendus = @($services + $transverses) | ForEach-Object { "$_`$" }

    # 1. Tous les partages existent
    $existants = Get-SmbShare | Where-Object { $_.Name -in $attendus } | Select-Object -ExpandProperty Name
    foreach ($a in $attendus) {
        if ($existants -contains $a) {
            Write-YanixLog OK "Partage present : $a"
        } else {
            Write-YanixLog ERR "Partage manquant : $a"
            $errors += $a
        }
    }

    # 2. Verification ACL AGDLP sur un echantillon
    $exemple = Join-Path $rootPath 'Ressources-Humaines'
    if (Test-Path $exemple) {
        $acl = (Get-Acl $exemple).Access | Where-Object { $_.IdentityReference -like "*GDL_Partage*" }
        if ($acl.Count -ge 3) {
            Write-YanixLog OK "ACL AGDLP detectees sur RH : $($acl.Count) ACEs GDL"
        } else {
            Write-YanixLog WARN "ACL AGDLP : seulement $($acl.Count) ACEs GDL sur RH"
        }
    }

    # 3. Statistiques finales
    $nbShares = (Get-SmbShare | Where-Object { $_.Path -like "$rootPath\*" } | Measure-Object).Count
    $totalSize = (Get-ChildItem $rootPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-YanixLog INFO "--- Statistiques ---"
    Write-YanixLog INFO ("  Partages sous {0,-12} : {1}" -f $rootPath, $nbShares)
    Write-YanixLog INFO ("  Taille cumulee donnees    : {0:N1} Mo" -f ($totalSize / 1MB))

    if ($errors.Count -eq 0) {
        Write-YanixLog OK "Verification post-deploiement REUSSIE"
        return $true
    } else {
        Write-YanixLog WARN "Verification avec $($errors.Count) erreur(s)"
        return $false
    }
}

if ($config.Tests.ActiverApresExecution) {
    Test-Bootstrap-FS01-Shares | Out-Null
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
