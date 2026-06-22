<#
.SYNOPSIS
    Bootstrap de l'orchestrateur de sauvegarde centralise sur SRV-BCK-01
    Conforme cadre prod-ready E6

.DESCRIPTION
    Met en place la chaine complete de sauvegarde automatisee :

      PHASE 1 : Installation du role Windows Server Backup sur les 4 cibles
                (DC-01, DC-02, FS-01, FS-02) via Invoke-Command/Remoting

      PHASE 2 : Verification que le partage \\SRV-BCK-01\Backups est accessible
                et que le script backup-centralise.ps1 est present sur BCK-01

      PHASE 3 : Creation/mise-a-jour de la tache planifiee
                'Backup-Centralise-Quotidien' sur BCK-01 (declenchement 02:00)

      PHASE 4 : Test post-deploiement (verification cible + tache + acces)

    Script idempotent : peut etre relance pour reconciler l'etat.

.PARAMETER DryRun
    Simulation sans modification

.PARAMETER HeureExecution
    Heure de declenchement quotidien (defaut: depuis E6-Config.psd1 = '02:00')

.EXAMPLE
    .\08-bootstrap_Backup-Orchestrator.ps1 -DryRun

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Execute depuis SRV-DC-01 (orchestrateur central est BCK-01)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [string]$HeureExecution
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT
# ============================================================================
Test-YanixPrerequis -Required Admin, DomainAdmin, AD, DC01, FS01, FS02, BCK01 -Stop

$config = Get-YanixConfig

$bck01Hostname    = $config.Serveurs.BCK01.Hostname
$cibleBackup      = $config.Sauvegarde.PartageBackup    # \\SRV-BCK-01\Backups
$cibles           = $config.Sauvegarde.Cibles           # 4 serveurs
if (-not $HeureExecution) { $HeureExecution = $config.Sauvegarde.HeurePlanification }

$taskName         = 'Backup-Centralise-Quotidien'
$scriptCible      = 'C:\Scripts\backup-centralise.ps1'  # sur BCK-01

Write-YanixLog INFO "Orchestrateur : $bck01Hostname"
Write-YanixLog INFO "Heure d'execution quotidienne : $HeureExecution"
Write-YanixLog INFO "Cibles de sauvegarde : $($cibles.Count)"

# ============================================================================
# PHASE 1 - INSTALLATION WSB SUR LES 4 CIBLES
# ============================================================================
Write-YanixLog STEP "=== PHASE 1/4 : Installation Windows Server Backup sur les cibles ==="

foreach ($c in $cibles) {
    $alreadyInstalled = $false
    try {
        $alreadyInstalled = Invoke-Command -ComputerName $c.Nom -ScriptBlock {
            (Get-WindowsFeature -Name Windows-Server-Backup).Installed
        } -ErrorAction Stop
    } catch {
        Write-YanixLog ERR "Verification WSB sur $($c.Nom) echouee : $($_.Exception.Message)"
        continue
    }

    if ($alreadyInstalled) {
        Write-YanixLog SKIP "WSB deja installe sur $($c.Nom)"
        continue
    }

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : installation WSB sur $($c.Nom) simulee"
        continue
    }

    try {
        Invoke-Command -ComputerName $c.Nom -ScriptBlock {
            Install-WindowsFeature -Name Windows-Server-Backup -IncludeManagementTools | Out-Null
        } -ErrorAction Stop
        Write-YanixLog OK "WSB installe sur $($c.Nom)"
    } catch {
        Write-YanixLog ERR "Echec installation WSB sur $($c.Nom) : $($_.Exception.Message)"
    }
}

# ============================================================================
# PHASE 2 - VERIFICATION DU PARTAGE CIBLE + SCRIPT ORCHESTRATEUR
# ============================================================================
Write-YanixLog STEP "=== PHASE 2/4 : Verification cible et script orchestrateur ==="

# 2.1 Partage Backups accessible
if (Test-Path $cibleBackup -ErrorAction SilentlyContinue) {
    Write-YanixLog OK "Partage $cibleBackup accessible"
} else {
    Write-YanixLog ERR "Partage $cibleBackup INACCESSIBLE - bootstrap impossible"
    Write-YanixLog ERR "Verifier que SRV-BCK-01 est configure (script 07-bootstrap_BCK01-Setup.ps1)"
    exit (Show-YanixRecap)
}

# 2.2 Script backup-centralise.ps1 present sur BCK-01
$scriptRemotePath = "\\$bck01Hostname\C$\Scripts\backup-centralise.ps1"
if (Test-Path $scriptRemotePath -ErrorAction SilentlyContinue) {
    Write-YanixLog OK "Script backup-centralise.ps1 present sur $bck01Hostname"
} else {
    Write-YanixLog ERR "Script backup-centralise.ps1 absent sur $bck01Hostname"
    Write-YanixLog ERR "Deployer : robocopy '\\SRV-DC-01\C\$\Scripts' '\\$bck01Hostname\C\$\Scripts' /E /XD Logs"
    exit (Show-YanixRecap)
}

# 2.3 Lib commune presente
$libRemotePath = "\\$bck01Hostname\C$\Scripts\_common\Common.ps1"
if (Test-Path $libRemotePath -ErrorAction SilentlyContinue) {
    Write-YanixLog OK "Bibliotheque commune presente sur $bck01Hostname"
} else {
    Write-YanixLog ERR "Bibliotheque commune absente sur $bck01Hostname"
    exit (Show-YanixRecap)
}

# ============================================================================
# PHASE 3 - CREATION DE LA TACHE PLANIFIEE SUR BCK-01
# ============================================================================
Write-YanixLog STEP "=== PHASE 3/4 : Tache planifiee '$taskName' sur $bck01Hostname ==="

# Vérifier l'état actuel via Remoting
$existingTask = $null
try {
    $existingTask = Invoke-Command -ComputerName $bck01Hostname -ScriptBlock {
        param($n)
        Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    } -ArgumentList $taskName -ErrorAction Stop
} catch {
    Write-YanixLog WARN "Lecture tache planifiee sur $bck01Hostname echouee : $($_.Exception.Message)"
}

$createTask = $false
if ($existingTask) {
    # Verifier que les triggers correspondent
    $currentTime = ($existingTask.Triggers | Select-Object -First 1).StartBoundary
    if ($currentTime -match $HeureExecution.Replace(':', ':')) {
        Write-YanixLog SKIP "Tache '$taskName' deja existante (declenchement: $HeureExecution)"
    } else {
        Write-YanixLog WARN "Tache '$taskName' existe mais horaire different - recreation"
        $createTask = $true
        if (-not $script:YanixContext.DryRun) {
            Invoke-Command -ComputerName $bck01Hostname -ScriptBlock {
                param($n)
                Unregister-ScheduledTask -TaskName $n -Confirm:$false
            } -ArgumentList $taskName
        }
    }
} else {
    $createTask = $true
}

if ($createTask) {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation tache '$taskName' sur $bck01Hostname (declenchement $HeureExecution) simulee"
    } else {
        try {
            Invoke-Command -ComputerName $bck01Hostname -ScriptBlock {
                param($name, $heure, $script)

                $action = New-ScheduledTaskAction `
                    -Execute 'powershell.exe' `
                    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""

                $trigger = New-ScheduledTaskTrigger -Daily -At $heure

                $principal = New-ScheduledTaskPrincipal `
                    -UserId 'YANIXLABS\Administrateur' `
                    -RunLevel Highest `
                    -LogonType Password

                $settings = New-ScheduledTaskSettingsSet `
                    -StartWhenAvailable `
                    -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
                    -RestartCount 0

                Register-ScheduledTask -TaskName $name `
                                       -Action $action `
                                       -Trigger $trigger `
                                       -Principal $principal `
                                       -Settings $settings `
                                       -Description "Orchestrateur de sauvegarde centralise yanixlabs.lan (script backup-centralise.ps1)" `
                                       -Force | Out-Null
            } -ArgumentList $taskName, $HeureExecution, $scriptCible -ErrorAction Stop
            Write-YanixLog OK "Tache '$taskName' creee sur $bck01Hostname (declenchement quotidien $HeureExecution)"
        } catch {
            Write-YanixLog ERR "Echec creation tache : $($_.Exception.Message)"
            Write-YanixLog INFO "Note : la tache doit etre cree avec un compte de service (mot de passe stocke)"
            Write-YanixLog INFO "Solution : creer manuellement via 'Planificateur de taches' avec credentials interactives"
        }
    }
}

# ============================================================================
# TEST POST-DEPLOIEMENT
# ============================================================================

function Test-Bootstrap-Backup-Orchestrator {
    Write-YanixLog STEP "=== Test post-deploiement : Bootstrap Backup-Orchestrator ==="
    $errors = @()

    # 1. WSB installe sur les 4 cibles
    foreach ($c in $cibles) {
        try {
            $i = Invoke-Command -ComputerName $c.Nom -ScriptBlock {
                (Get-WindowsFeature -Name Windows-Server-Backup -ErrorAction SilentlyContinue).Installed
            } -ErrorAction Stop
            if ($i) {
                Write-YanixLog OK "WSB installe sur $($c.Nom)"
            } else {
                Write-YanixLog ERR "WSB MANQUANT sur $($c.Nom)"
                $errors += "WSB $($c.Nom)"
            }
        } catch {
            Write-YanixLog WARN "Verification WSB $($c.Nom) impossible"
        }
    }

    # 2. Partage Backups accessible
    if (Test-Path $cibleBackup) {
        Write-YanixLog OK "Partage $cibleBackup accessible"
    } else {
        Write-YanixLog ERR "Partage $cibleBackup inaccessible"
        $errors += 'Partage Backups'
    }

    # 3. Tache planifiee presente
    try {
        $t = Invoke-Command -ComputerName $bck01Hostname -ScriptBlock {
            param($n) Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        } -ArgumentList $taskName -ErrorAction Stop
        if ($t) {
            Write-YanixLog OK "Tache planifiee '$taskName' active sur $bck01Hostname (etat: $($t.State))"
        } else {
            Write-YanixLog WARN "Tache planifiee '$taskName' non trouvee sur $bck01Hostname"
        }
    } catch {
        Write-YanixLog WARN "Verification tache planifiee impossible"
    }

    if ($errors.Count -eq 0) {
        Write-YanixLog OK "Verification post-deploiement REUSSIE - orchestrateur backup pret"
        return $true
    } else {
        Write-YanixLog WARN "Verification avec $($errors.Count) erreur(s)"
        return $false
    }
}

# ============================================================================
# PHASE 4 - RECAP
# ============================================================================
Write-YanixLog STEP "=== PHASE 4/4 : Recapitulatif ==="
Write-YanixLog INFO "Strategie de sauvegarde centralisee :"
Write-YanixLog INFO "  Orchestrateur : $bck01Hostname (BCK-01)"
Write-YanixLog INFO "  Cible commune : $cibleBackup"
Write-YanixLog INFO "  Planification : quotidien $HeureExecution"
Write-YanixLog INFO "  Cibles ($($cibles.Count)) :"
foreach ($c in $cibles) {
    $strategie = if ($c.Strategie -eq 'SystemState') { 'SystemState' } else { "Dossier $($c.Source)" }
    Write-YanixLog INFO "    - $($c.Nom) : $strategie"
}
Write-YanixLog INFO "Pour declencher une execution manuelle :"
Write-YanixLog INFO "  Invoke-Command -ComputerName $bck01Hostname -ScriptBlock { Start-ScheduledTask -TaskName '$taskName' }"

if ($config.Tests.ActiverApresExecution -and -not $script:YanixContext.DryRun) {
    Test-Bootstrap-Backup-Orchestrator | Out-Null
} elseif ($script:YanixContext.DryRun) {
    Write-YanixLog INFO "Test post-deploiement SKIP en mode DryRun (rien n'a ete modifie, le test serait fausse)"
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
