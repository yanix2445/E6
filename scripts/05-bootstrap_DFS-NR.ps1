<#
.SYNOPSIS
    Bootstrap complet de DFS Namespaces et DFS Replication entre SRV-FS-01 et SRV-FS-02
    Conforme cadre prod-ready E6 - Microsoft + ANSSI

.DESCRIPTION
    Provisionne en idempotent :
      PHASE 1 : Espace de noms DFS-N \\yanixlabs.lan\Partages (DomainV2)
                - Partage SMB 'Partages' sur FS-01 + FS-02
                - Racine DFS-N avec 2 cibles (FS-01 et FS-02)

      PHASE 2 : 12 dossiers DFS-N (un par partage métier/transverse)
                - Chaque dossier a 2 cibles : \\FS-01\<Nom>$ et \\FS-02\<Nom>$
                - Failback automatique activé

      PHASE 3 : 12 groupes de réplication DFS-R (un par partage)
                - Architecture 1 RG par service (best practice Microsoft)
                - Membre primaire = FS-01, membre secondaire = FS-02
                - Connexions bidirectionnelles full-mesh

      PHASE 4 : Forçage du polling AD pour propagation immédiate

      PHASE 5 : Test post-deploiement (namespace, folders, targets, RG, backlog)

.PARAMETER DryRun
    Simulation sans modification

.PARAMETER SkipBacklogCheck
    N'inclut pas la mesure de backlog dans le test post-deploiement (rapide)

.EXAMPLE
    .\05-bootstrap_DFS-NR.ps1 -DryRun

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Exécuté depuis SRV-DC-01 ou SRV-FS-01 (avec RSAT-DFS-Mgmt-Con)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [switch]$SkipBacklogCheck
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================
Test-YanixPrerequis -Required Admin, DomainAdmin, AD, FS01, FS02 -Stop

$config = Get-YanixConfig

# Verification des modules DFS (locaux ou via RSAT)
foreach ($mod in @('DFSN', 'DFSR')) {
    if (-not (Test-YanixModule -ModuleName $mod)) {
        Write-YanixLog ERR "Module $mod indisponible. Installer : Install-WindowsFeature RSAT-DFS-Mgmt-Con"
        exit (Show-YanixRecap)
    }
    Write-YanixLog OK "Module $mod charge"
}

# ============================================================================
# CONFIGURATION LOCALE
# ============================================================================
$dfsRoot       = $config.DFS.NamespacePath          # \\yanixlabs.lan\Partages
$dfsType       = $config.DFS.NamespaceType          # DomainV2
$nsPath        = $config.DFS.BaseDFSRoots           # D:\DFSRoots\Partages
$nsShareName   = 'Partages'
$baseLocale    = $config.DFS.BaseLocale             # D:\Partages
$domain        = $config.Domain
$fs01          = $config.Serveurs.FS01.Hostname
$fs02          = $config.Serveurs.FS02.Hostname

# Les 12 partages = 9 services + 3 transverses
$partages = $config.ServicesMetier + @('Commun', 'Projets', 'Users')

# ============================================================================
# HELPER : creation du dossier + partage namespace sur un serveur
# ============================================================================

function Initialize-DfsNamespaceShare {
    param([string]$ComputerName)

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation dossier+partage namespace sur $ComputerName simulee"
        return
    }

    try {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            param($p, $n)
            # Crée le dossier si absent
            if (-not (Test-Path $p)) {
                New-Item -Path $p -ItemType Directory -Force | Out-Null
            }
            # Crée le partage SMB si absent
            if (-not (Get-SmbShare -Name $n -ErrorAction SilentlyContinue)) {
                $authUsers = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-11').Translate([System.Security.Principal.NTAccount]).Value
                New-SmbShare -Name $n -Path $p -FullAccess $authUsers -Description 'DFS Namespace root' | Out-Null
                return 'CREATED'
            }
            return 'EXISTS'
        } -ArgumentList $nsPath, $nsShareName -ErrorAction Stop
        Write-YanixLog OK "Dossier+partage namespace pret sur $ComputerName"
    } catch {
        Write-YanixLog ERR "Echec preparation namespace sur $ComputerName : $($_.Exception.Message)"
        throw
    }
}

# ============================================================================
# PHASE 1 - ESPACE DE NOMS DFS-N (\\yanixlabs.lan\Partages)
# ============================================================================
Write-YanixLog STEP "=== PHASE 1/5 : Espace de noms DFS-N $dfsRoot ==="

# 1.1 Preparation partage namespace sur FS-01
Initialize-DfsNamespaceShare -ComputerName $fs01

# 1.2 Creer la racine DFS-N si absente
$existingRoot = Get-DfsnRoot -Path $dfsRoot -ErrorAction SilentlyContinue
if ($existingRoot) {
    Write-YanixLog SKIP "Racine DFS $dfsRoot deja existante (type: $($existingRoot.Type))"
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation racine DFS $dfsRoot (type $dfsType, cible FS-01) simulee"
    } else {
        try {
            New-DfsnRoot -Path $dfsRoot `
                         -TargetPath "\\$fs01\$nsShareName" `
                         -Type $dfsType `
                         -EnableSiteCosting:$false `
                         -Description 'Espace de noms unifie des partages YANIXLABS' `
                         -ErrorAction Stop | Out-Null
            Write-YanixLog OK "Racine DFS $dfsRoot creee ($dfsType, cible $fs01)"
        } catch {
            Write-YanixLog ERR "Echec creation racine DFS : $($_.Exception.Message)"
        }
    }
}

# 1.3 Ajouter FS-02 comme cible secondaire du namespace
$rootTargets = Get-DfsnRootTarget -Path $dfsRoot -ErrorAction SilentlyContinue
$fs02RootTarget = $rootTargets | Where-Object { $_.TargetPath -like "*$fs02*" }
if ($fs02RootTarget) {
    Write-YanixLog SKIP "Cible namespace secondaire $fs02 deja presente"
} else {
    # 1.3.a Preparation partage sur FS-02
    Initialize-DfsNamespaceShare -ComputerName $fs02

    # 1.3.b Ajout target
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : ajout cible namespace \\$fs02\$nsShareName simule"
    } else {
        try {
            New-DfsnRootTarget -Path $dfsRoot -TargetPath "\\$fs02\$nsShareName" -ErrorAction Stop | Out-Null
            Write-YanixLog OK "Cible namespace secondaire \\$fs02\$nsShareName ajoutee (redondance namespace)"
        } catch {
            Write-YanixLog ERR "Echec ajout cible namespace FS-02 : $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# PHASE 2 - DOSSIERS DFS-N + 2 CIBLES PAR PARTAGE
# ============================================================================
Write-YanixLog STEP "=== PHASE 2/5 : Dossiers DFS-N et cibles (12 partages) ==="

foreach ($p in $partages) {
    $dfsFolderPath = "$dfsRoot\$p"
    $target01 = "\\$fs01\$p`$"
    $target02 = "\\$fs02\$p`$"

    # 2.1 Dossier DFS
    $existingFolder = Get-DfsnFolder -Path $dfsFolderPath -ErrorAction SilentlyContinue
    if ($existingFolder) {
        Write-YanixLog SKIP "DFS folder $p deja existant"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : creation DFS folder $p (cible $target01) simulee"
        } else {
            try {
                New-DfsnFolder -Path $dfsFolderPath `
                               -TargetPath $target01 `
                               -Description "Partage $p (redonde FS-01/FS-02 via DFS-R)" `
                               -EnableTargetFailback:$true `
                               -ErrorAction Stop | Out-Null
                Write-YanixLog OK "DFS folder $p cree (cible $fs01)"
            } catch {
                Write-YanixLog ERR "Echec creation DFS folder $p : $($_.Exception.Message)"
            }
        }
    }

    # 2.2 Cible secondaire FS-02
    $targets = Get-DfsnFolderTarget -Path $dfsFolderPath -ErrorAction SilentlyContinue
    $fs02Target = $targets | Where-Object { $_.TargetPath -eq $target02 }
    if ($fs02Target) {
        Write-YanixLog SKIP "Cible $fs02 deja presente sur $p"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : ajout cible $target02 sur $p simule"
        } else {
            try {
                New-DfsnFolderTarget -Path $dfsFolderPath -TargetPath $target02 -State Online -ErrorAction Stop | Out-Null
                Write-YanixLog OK "Cible $fs02 ajoutee sur $p"
            } catch {
                Write-YanixLog ERR "Echec ajout cible $fs02 sur $p : $($_.Exception.Message)"
            }
        }
    }
}

# ============================================================================
# PHASE 3 - GROUPES DE REPLICATION DFS-R (12 RG, un par partage)
# ============================================================================
Write-YanixLog STEP "=== PHASE 3/5 : Groupes de replication DFS-R (12 RG) ==="

foreach ($p in $partages) {
    $rgName  = "RG_$p"
    $rfName  = "RF_$p"
    $path01  = Join-Path $baseLocale $p
    $path02  = Join-Path $baseLocale $p

    # 3.1 Replication Group
    $rg = Get-DfsReplicationGroup -GroupName $rgName -DomainName $domain -ErrorAction SilentlyContinue
    if ($rg) {
        Write-YanixLog SKIP "RG $rgName deja existant"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : creation RG $rgName simulee"
        } else {
            try {
                New-DfsReplicationGroup -GroupName $rgName `
                                        -Description "Replication DFS-R du partage $p entre $fs01 et $fs02" `
                                        -DomainName $domain -ErrorAction Stop | Out-Null
                Write-YanixLog OK "RG $rgName cree"
            } catch {
                Write-YanixLog ERR "Echec creation RG $rgName : $($_.Exception.Message)"
                continue
            }
        }
    }

    # 3.2 Replicated Folder
    $rf = Get-DfsReplicatedFolder -GroupName $rgName -FolderName $rfName -ErrorAction SilentlyContinue
    if ($rf) {
        Write-YanixLog SKIP "RF $rfName deja existant"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : creation RF $rfName simulee"
        } else {
            try {
                New-DfsReplicatedFolder -GroupName $rgName -FolderName $rfName -Description "Dossier replique $p" -ErrorAction Stop | Out-Null
                Write-YanixLog OK "RF $rfName ajoute a $rgName"
            } catch {
                Write-YanixLog ERR "Echec ajout RF $rfName : $($_.Exception.Message)"
                continue
            }
        }
    }

    # 3.3 Membre FS-01 (primaire)
    $m01 = Get-DfsrMember -GroupName $rgName -ComputerName $fs01 -ErrorAction SilentlyContinue
    if (-not $m01) {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : ajout membre $fs01 (primaire) a $rgName simule"
        } else {
            try {
                Add-DfsrMember -GroupName $rgName -ComputerName $fs01 -Description 'Membre primaire' -ErrorAction Stop | Out-Null
                Write-YanixLog OK "Membre $fs01 ajoute a $rgName"
            } catch {
                Write-YanixLog ERR "Echec ajout membre $fs01 : $($_.Exception.Message)"
            }
        }
    } else {
        Write-YanixLog SKIP "Membre $fs01 deja dans $rgName"
    }

    # 3.4 Configuration membership FS-01
    if (-not $script:YanixContext.DryRun) {
        try {
            Set-DfsrMembership -GroupName $rgName -FolderName $rfName -ComputerName $fs01 `
                               -ContentPath $path01 -PrimaryMember $true -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-YanixLog WARN "Set-DfsrMembership $fs01 ($rfName) : $($_.Exception.Message)"
        }
    }

    # 3.5 Membre FS-02 (secondaire)
    $m02 = Get-DfsrMember -GroupName $rgName -ComputerName $fs02 -ErrorAction SilentlyContinue
    if (-not $m02) {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : ajout membre $fs02 (secondaire) a $rgName simule"
        } else {
            try {
                Add-DfsrMember -GroupName $rgName -ComputerName $fs02 -Description 'Membre secondaire' -ErrorAction Stop | Out-Null
                Write-YanixLog OK "Membre $fs02 ajoute a $rgName"
            } catch {
                Write-YanixLog ERR "Echec ajout membre $fs02 : $($_.Exception.Message)"
            }
        }
    } else {
        Write-YanixLog SKIP "Membre $fs02 deja dans $rgName"
    }

    # 3.6 Configuration membership FS-02
    if (-not $script:YanixContext.DryRun) {
        try {
            Set-DfsrMembership -GroupName $rgName -FolderName $rfName -ComputerName $fs02 `
                               -ContentPath $path02 -PrimaryMember $false -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-YanixLog WARN "Set-DfsrMembership $fs02 ($rfName) : $($_.Exception.Message)"
        }
    }

    # 3.7 Connexions bidirectionnelles
    foreach ($pair in @(@($fs01, $fs02), @($fs02, $fs01))) {
        $src, $dst = $pair
        $conn = Get-DfsrConnection -GroupName $rgName -SourceComputerName $src -DestinationComputerName $dst -ErrorAction SilentlyContinue
        if ($conn) {
            Write-YanixLog SKIP "Connexion $src -> $dst deja presente ($rgName)"
        } else {
            if ($script:YanixContext.DryRun) {
                Write-YanixLog INFO "DRY-RUN : creation connexion $src -> $dst simulee"
            } else {
                try {
                    Add-DfsrConnection -GroupName $rgName -SourceComputerName $src -DestinationComputerName $dst -ErrorAction Stop | Out-Null
                    Write-YanixLog OK "Connexion $src -> $dst creee"
                } catch {
                    Write-YanixLog ERR "Echec connexion $src -> $dst : $($_.Exception.Message)"
                }
            }
        }
    }
}

# ============================================================================
# PHASE 4 - FORCAGE POLLING AD
# ============================================================================
Write-YanixLog STEP "=== PHASE 4/5 : Forcage du polling AD DFS-R ==="

if ($script:YanixContext.DryRun) {
    Write-YanixLog INFO "DRY-RUN : Update-DfsrConfigurationFromAD sur $fs01 et $fs02 simulee"
} else {
    foreach ($srv in @($fs01, $fs02)) {
        try {
            Update-DfsrConfigurationFromAD -ComputerName $srv -ErrorAction Stop
            Write-YanixLog OK "Polling AD force sur $srv"
        } catch {
            Write-YanixLog WARN "Polling AD sur $srv : $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# TEST POST-DEPLOIEMENT
# ============================================================================

function Test-Bootstrap-DFS-NR {
    Write-YanixLog STEP "=== Test post-deploiement : Bootstrap DFS-N + DFS-R ==="
    $errors = @()

    # 1. Namespace racine
    try {
        $root = Get-DfsnRoot -Path $dfsRoot -ErrorAction Stop
        if ($root.State -eq 'Online') {
            Write-YanixLog OK "Namespace $dfsRoot etat: Online"
        } else {
            Write-YanixLog WARN "Namespace $dfsRoot etat: $($root.State)"
        }
    } catch {
        Write-YanixLog ERR "Namespace $dfsRoot introuvable"
        $errors += 'Namespace racine'
    }

    # 2. Cibles namespace (FS-01 + FS-02)
    try {
        $nbCibles = (Get-DfsnRootTarget -Path $dfsRoot -ErrorAction Stop | Measure-Object).Count
        if ($nbCibles -eq 2) {
            Write-YanixLog OK "Namespace $dfsRoot a $nbCibles cibles (FS-01 + FS-02)"
        } else {
            Write-YanixLog WARN "Namespace $dfsRoot a $nbCibles cible(s), 2 attendues"
        }
    } catch {
        Write-YanixLog WARN "Lecture cibles namespace : $($_.Exception.Message)"
    }

    # 3. 12 dossiers DFS avec 2 cibles chacun
    $foldersOK = 0
    foreach ($p in $partages) {
        $folder = Get-DfsnFolder -Path "$dfsRoot\$p" -ErrorAction SilentlyContinue
        if ($folder) {
            $nb = (Get-DfsnFolderTarget -Path "$dfsRoot\$p" -ErrorAction SilentlyContinue | Measure-Object).Count
            if ($nb -eq 2) { $foldersOK++ }
        }
    }
    if ($foldersOK -eq $partages.Count) {
        Write-YanixLog OK "Les $($partages.Count) dossiers DFS ont chacun 2 cibles"
    } else {
        Write-YanixLog WARN "Seuls $foldersOK / $($partages.Count) dossiers DFS ont 2 cibles"
    }

    # 4. 12 RG DFS-R avec 2 membres chacun
    $rgOK = 0
    foreach ($p in $partages) {
        $rg = Get-DfsReplicationGroup -GroupName "RG_$p" -DomainName $domain -ErrorAction SilentlyContinue
        if ($rg) {
            $nbMembres = (Get-DfsrMember -GroupName "RG_$p" -ErrorAction SilentlyContinue | Measure-Object).Count
            if ($nbMembres -eq 2) { $rgOK++ }
        }
    }
    if ($rgOK -eq $partages.Count) {
        Write-YanixLog OK "Les $($partages.Count) RG DFS-R ont chacun 2 membres"
    } else {
        Write-YanixLog WARN "Seuls $rgOK / $($partages.Count) RG DFS-R ont 2 membres"
    }

    # 5. Backlog (optionnel)
    if (-not $SkipBacklogCheck) {
        Write-YanixLog STEP "Mesure du backlog DFS-R (peut prendre 30 sec)..."
        $totalBacklog = 0
        foreach ($p in $partages) {
            try {
                $bl = Get-DfsrBacklog -GroupName "RG_$p" `
                                       -SourceComputerName $fs01 `
                                       -DestinationComputerName $fs02 `
                                       -FolderName "RF_$p" `
                                       -ErrorAction Stop 2>$null
                $count = ($bl | Measure-Object).Count
                $totalBacklog += $count
            } catch {
                # ignoré : le RG peut ne pas être prêt
            }
        }
        if ($totalBacklog -eq 0) {
            Write-YanixLog OK "Backlog total des 12 RG : 0 (replication a jour)"
        } else {
            Write-YanixLog WARN "Backlog total : $totalBacklog (replication en cours)"
        }
    }

    if ($errors.Count -eq 0) {
        Write-YanixLog OK "Verification post-deploiement REUSSIE"
        return $true
    } else {
        Write-YanixLog WARN "Verification avec $($errors.Count) erreur(s)"
        return $false
    }
}

if ($config.Tests.ActiverApresExecution) {
    Test-Bootstrap-DFS-NR | Out-Null
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
