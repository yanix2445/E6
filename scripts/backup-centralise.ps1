<#
.SYNOPSIS
    Orchestrateur de sauvegarde centralise pour l'infrastructure yanixlabs.lan
    Conforme cadre prod-ready E6 - Microsoft + ANSSI

.DESCRIPTION
    Depuis SRV-BCK-01, declenche a distance via PowerShell Remoting (WinRM)
    les sauvegardes Windows Server Backup sur l'ensemble des serveurs cibles,
    et consolide les resultats dans un journal centralise + telemetrie.

    Strategie PULL simulee : un point d'orchestration unique, des executions
    distantes via Invoke-Command. Compatible avec WSB natif Microsoft.

    Cibles definies dans _config/E6-Config.psd1 (section Sauvegarde.Cibles) :
      - SRV-DC-01 (SystemState)
      - SRV-DC-02 (SystemState)
      - SRV-FS-01 (Dossier D:\Partages)
      - SRV-FS-02 (Dossier D:\Partages)

.PARAMETER DryRun
    Simulation : verifie la joignabilite mais ne declenche pas les sauvegardes

.EXAMPLE
    .\backup-centralise.ps1 -DryRun

.EXAMPLE
    .\backup-centralise.ps1
    Lance les sauvegardes en sequence (peut durer 30-60 min selon volumes)

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Execute sur SRV-BCK-01, planifie via tache Backup-Centralise-Quotidien
#>

#Requires -RunAsAdministrator
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
# PRE-FLIGHT
# ============================================================================
Test-YanixPrerequis -Required Admin, DomainAdmin -Stop

$config = Get-YanixConfig

$cibleBackup = $config.Sauvegarde.PartageBackup   # \\SRV-BCK-01\Backups
$cibles      = $config.Sauvegarde.Cibles

Write-YanixLog INFO "Cible centrale : $cibleBackup"
Write-YanixLog INFO "$($cibles.Count) serveur(s) a sauvegarder"

# ============================================================================
# PHASE 1 - VERIFICATION DE LA CIBLE CENTRALE
# ============================================================================
Write-YanixLog STEP "=== PHASE 1/3 : Verification du partage cible ==="

if (Test-Path $cibleBackup -ErrorAction SilentlyContinue) {
    Write-YanixLog OK "Partage $cibleBackup accessible"
} else {
    Write-YanixLog ERR "Partage $cibleBackup inaccessible - sauvegardes annulees"
    exit (Show-YanixRecap)
}

# ============================================================================
# PHASE 2 - VERIFICATION DE LA JOIGNABILITE DES CIBLES
# ============================================================================
Write-YanixLog STEP "=== PHASE 2/3 : Verification joignabilite des cibles ==="

$ciblesOK = @()
foreach ($c in $cibles) {
    if (Test-YanixRemoting -ComputerName $c.Nom) {
        Write-YanixLog OK "$($c.Nom) joignable via WinRM"
        $ciblesOK += $c
    } else {
        Write-YanixLog ERR "$($c.Nom) INJOIGNABLE (WinRM) - skip"
    }
}

if ($ciblesOK.Count -eq 0) {
    Write-YanixLog ERR "Aucune cible joignable, abandon"
    exit (Show-YanixRecap)
}

# ============================================================================
# PHASE 3 - EXECUTION DES SAUVEGARDES (en serie)
# ============================================================================
Write-YanixLog STEP "=== PHASE 3/3 : Execution des sauvegardes ($($ciblesOK.Count) cibles) ==="

foreach ($c in $ciblesOK) {
    Write-YanixLog STEP "Backup $($c.Nom) [strategie : $($c.Strategie)]"

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : backup $($c.Nom) ($($c.Strategie)) simule (cible : $cibleBackup)"
        continue
    }

    try {
        $start = Get-Date

        if ($c.Strategie -eq 'SystemState') {
            Invoke-Command -ComputerName $c.Nom -ScriptBlock {
                param($target)
                wbadmin start systemstatebackup -backupTarget:$target -quiet
            } -ArgumentList $cibleBackup -ErrorAction Stop | Out-Null
            Write-YanixLog OK "$($c.Nom) : SystemState termine ($([int]((Get-Date) - $start).TotalSeconds) sec)"
        }
        elseif ($c.Strategie -eq 'Dossier') {
            $source = $c.Source
            Invoke-Command -ComputerName $c.Nom -ScriptBlock {
                param($target, $src)
                wbadmin start backup -backupTarget:$target -include:$src -quiet
            } -ArgumentList $cibleBackup, $source -ErrorAction Stop | Out-Null
            Write-YanixLog OK "$($c.Nom) : Backup '$source' termine ($([int]((Get-Date) - $start).TotalSeconds) sec)"
        }
        else {
            Write-YanixLog WARN "$($c.Nom) : strategie inconnue '$($c.Strategie)' - skip"
        }
    }
    catch {
        Write-YanixLog ERR "$($c.Nom) : echec sauvegarde : $($_.Exception.Message)"
    }
}

# ============================================================================
# RECAP + EXIT (la telemetrie envoie le log vers \\SRV-BCK-01\Logs$\<hostname>)
# ============================================================================
exit (Show-YanixRecap)
