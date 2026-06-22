<#
.SYNOPSIS
    Bootstrap Shadow Copies (VSS) sur serveur de fichiers - PRA Niveau 1
    Conforme cadre prod-ready E6

.DESCRIPTION
    Active la stratégie "ceinture + bretelles" du Plan de Reprise d'Activité :

    Niveau 1 (CE SCRIPT) : Shadow Copies horaires (RPO 1h, RTO 30s, self-service user)
    Niveau 2 : Windows Server Backup quotidien (RPO 24h, RTO 5-30min)
    Niveau 3 : Snapshots VM VMware Fusion (RPO 30j, restau Disaster Recovery)

    Configuration appliquée :
      - Allocation 20% du volume D: pour shadow storage
      - 1 snapshot initial (test)
      - Tâche planifiée VSS-Snapshot-D-Hourly : 12 snapshots/jour ouvré (8h-19h L-V)
      - Conservation : ~5 jours ouvrés (60 snapshots, sous la limite Microsoft de 64)

.PARAMETER DryRun
    Simulation sans modification

.PARAMETER Volume
    Volume cible (défaut : D:)

.PARAMETER MaxSizePercent
    Pourcentage du volume alloué aux snapshots (défaut : 20)

.EXAMPLE
    .\06-bootstrap_Shadow-Copies.ps1 -DryRun

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : À exécuter SUR LE SERVEUR DE FICHIERS (SRV-FS-01 et SRV-FS-02)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [string]$Volume = 'D:',
    [int]$MaxSizePercent = 20
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT
# ============================================================================
Test-YanixPrerequis -Required Admin -Stop
$config = Get-YanixConfig

# Verifier que le volume cible existe
if (-not (Test-Path $Volume)) {
    Write-YanixLog ERR "Volume $Volume introuvable sur cette machine"
    exit (Show-YanixRecap)
}
Write-YanixLog OK "Volume $Volume present"

# Verifier le service VSS
$vss = Get-Service -Name VSS -ErrorAction SilentlyContinue
if (-not $vss) {
    Write-YanixLog ERR "Service VSS introuvable (cette fonctionnalite est manquante sur ce serveur)"
    exit (Show-YanixRecap)
}
if ($vss.Status -ne 'Running') {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : demarrage du service VSS simule"
    } else {
        try {
            Start-Service -Name VSS -ErrorAction Stop
            Write-YanixLog OK "Service VSS demarre"
        } catch {
            Write-YanixLog ERR "Echec demarrage VSS : $($_.Exception.Message)"
        }
    }
} else {
    Write-YanixLog OK "Service VSS actif"
}

$vssStartup = (Get-CimInstance -ClassName Win32_Service -Filter "Name='VSS'").StartMode
Write-YanixLog INFO "Mode de demarrage VSS : $vssStartup (Manuel ou Auto OK, demarrage a la demande)"

# ============================================================================
# CONFIGURATION LOCALE
# ============================================================================
$taskName      = 'VSS-Snapshot-D-Hourly'
$scheduleHours = 8..19   # 12 snapshots par jour
$scheduleDays  = 'Monday','Tuesday','Wednesday','Thursday','Friday'
$shadowStorage = $Volume

# ============================================================================
# PHASE 1 - ALLOCATION DU SHADOW STORAGE
# ============================================================================
Write-YanixLog STEP "=== PHASE 1/4 : Allocation Shadow Storage ($MaxSizePercent% de $Volume) ==="

# Verifier l'allocation actuelle
$currentAlloc = vssadmin list shadowstorage /for=$Volume 2>&1
$alreadyAllocated = $currentAlloc -match 'Volume de stockage'

if ($alreadyAllocated) {
    # Verifier le pourcentage actuel et l'ajuster si necessaire
    Write-YanixLog INFO "Shadow storage deja alloue sur $Volume"
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : ajustement allocation a $MaxSizePercent% simule"
    } else {
        try {
            $out = vssadmin resize shadowstorage /for=$Volume /on=$shadowStorage /maxsize=$MaxSizePercent% 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-YanixLog OK "Allocation shadow ajustee a $MaxSizePercent% sur $Volume"
            } else {
                Write-YanixLog WARN "Resize : $($out -join ' ')"
            }
        } catch {
            Write-YanixLog WARN "Resize a echoue : $($_.Exception.Message)"
        }
    }
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation allocation shadow $MaxSizePercent% sur $Volume simulee"
    } else {
        try {
            $out = vssadmin add shadowstorage /for=$Volume /on=$shadowStorage /maxsize=$MaxSizePercent% 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-YanixLog OK "Allocation shadow creee : $MaxSizePercent% de $Volume"
            } else {
                Write-YanixLog ERR "Echec allocation : $($out -join ' ')"
            }
        } catch {
            Write-YanixLog ERR "Allocation : $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# PHASE 2 - SNAPSHOT INITIAL (test)
# ============================================================================
Write-YanixLog STEP "=== PHASE 2/4 : Snapshot initial (test) ==="

if ($script:YanixContext.DryRun) {
    Write-YanixLog INFO "DRY-RUN : creation snapshot initial sur $Volume simulee"
} else {
    try {
        $out = vssadmin create shadow /for=$Volume 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-YanixLog OK "Snapshot initial cree avec succes"
        } else {
            Write-YanixLog WARN "Snapshot initial : $($out -join ' ')"
        }
    } catch {
        Write-YanixLog ERR "Snapshot : $($_.Exception.Message)"
    }
}

# ============================================================================
# PHASE 3 - TACHE PLANIFIEE HORAIRE
# ============================================================================
Write-YanixLog STEP "=== PHASE 3/4 : Tache planifiee '$taskName' ==="

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask) {
    # Verifier qu'elle a le bon nombre de triggers
    $nbTriggers = $existingTask.Triggers.Count
    if ($nbTriggers -eq $scheduleHours.Count) {
        Write-YanixLog SKIP "Tache '$taskName' deja existante avec $nbTriggers triggers (recreation evitee)"
    } else {
        Write-YanixLog WARN "Tache '$taskName' a $nbTriggers triggers (attendu : $($scheduleHours.Count))"
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : recreation propre de la tache simulee"
        } else {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-YanixLog OK "Ancienne tache supprimee, recreation..."
            $existingTask = $null
        }
    }
}

if (-not $existingTask -and -not $script:YanixContext.DryRun) {
    try {
        # Action : vssadmin create shadow
        $action = New-ScheduledTaskAction `
            -Execute 'vssadmin.exe' `
            -Argument "create shadow /for=$Volume /AutoRetry=3"

        # 12 triggers (8h-19h, L-V)
        $triggers = @()
        foreach ($h in $scheduleHours) {
            $time = '{0:00}:00:00' -f $h
            $triggers += New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleDays -At $time
        }

        # Principal SYSTEM avec privileges max
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

        # Settings
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $taskName `
                               -Action $action `
                               -Trigger $triggers `
                               -Principal $principal `
                               -Settings $settings `
                               -Description "VSS Shadow Copy hourly snapshot (8h-19h L-V) - PRA Niveau 1 yanixlabs.lan" | Out-Null
        Write-YanixLog OK "Tache '$taskName' creee : $($scheduleHours.Count) declenchements/jour x 5 jours ouvres"
    } catch {
        Write-YanixLog ERR "Echec creation tache : $($_.Exception.Message)"
    }
} elseif ($script:YanixContext.DryRun -and -not $existingTask) {
    Write-YanixLog INFO "DRY-RUN : creation tache '$taskName' avec $($scheduleHours.Count) triggers/jour simulee"
}

# ============================================================================
# TEST POST-DEPLOIEMENT
# ============================================================================

function Test-Bootstrap-Shadow-Copies {
    Write-YanixLog STEP "=== Test post-deploiement : Bootstrap Shadow Copies ==="
    $errors = @()

    # 1. Allocation shadow storage existe
    $alloc = vssadmin list shadowstorage /for=$Volume 2>&1
    if ($alloc -match 'Volume de stockage') {
        Write-YanixLog OK "Allocation Shadow Storage active sur $Volume"
    } else {
        Write-YanixLog ERR "Allocation Shadow Storage manquante sur $Volume"
        $errors += 'Allocation manquante'
    }

    # 2. Au moins 1 snapshot existe
    $shadows = vssadmin list shadows /for=$Volume 2>&1
    $nbShadows = ($shadows -split "`n" | Where-Object { $_ -match 'Cliché instantané|Shadow Copy' }).Count
    if ($nbShadows -ge 1) {
        Write-YanixLog OK "$nbShadows snapshot(s) disponible(s) sur $Volume"
    } else {
        Write-YanixLog WARN "Aucun snapshot present sur $Volume"
    }

    # 3. Tache planifiée présente
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $nb = $task.Triggers.Count
        Write-YanixLog OK "Tache planifiee '$taskName' presente ($nb triggers, etat: $($task.State))"
    } else {
        Write-YanixLog ERR "Tache planifiee '$taskName' manquante"
        $errors += 'Tache manquante'
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
    Test-Bootstrap-Shadow-Copies | Out-Null
}

# ============================================================================
# PHASE 4 - RECAP PRA
# ============================================================================
Write-YanixLog STEP "=== PHASE 4/4 : Recapitulatif strategie PRA ==="

Write-YanixLog INFO "Strategie de sauvegarde 3 niveaux :"
Write-YanixLog INFO "  Niveau 1 (CE SCRIPT) : Shadow Copies horaires    RPO 1h    RTO 30s    Self-service user"
Write-YanixLog INFO "  Niveau 2             : Windows Server Backup 02h RPO 24h   RTO 5min   Helpdesk N1"
Write-YanixLog INFO "  Niveau 3             : Snapshots VM VMware       RPO 30j   RTO 10min  Admin senior"
Write-YanixLog INFO "Procedure de restauration utilisateur (PRA Niveau 1) :"
Write-YanixLog INFO "  1. Explorateur Windows -> clic droit sur le dossier"
Write-YanixLog INFO "  2. 'Restaurer les versions precedentes'"
Write-YanixLog INFO "  3. Choisir un snapshot dans la liste -> 'Ouvrir' ou 'Restaurer'"

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
