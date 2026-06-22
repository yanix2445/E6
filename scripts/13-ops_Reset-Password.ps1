<#
.SYNOPSIS
    Reset de mot de passe utilisateur AD - operation ciblee ou en masse
    Conforme cadre prod-ready E6 - ANSSI PA-022

.DESCRIPTION
    Permet de reinitialiser le mot de passe d'un ou plusieurs utilisateurs AD,
    avec exclusions de securite systeme :
      - Administrator/Administrateur (compte de secours)
      - krbtgt (service Kerberos)
      - Guest/Invite, DefaultAccount
      - Comptes svc-* (comptes de service)

    3 modes d'execution :
      1. Cible -> -Sam <samAccountName>  : reset un seul user
      2. Tous  -> -All                   : reset tous les users humains (avec confirmation)
      3. Liste -> -SamList <a,b,c>       : reset une liste explicite

    3 modes de mot de passe :
      1. Defaut   -> mdp de E6-Config.psd1 (MotDePasse.DefautBienvenue)
      2. Explicite -> -MotDePasse <pwd>
      3. Random   -> -RandomPassword (genere un mdp ANSSI 15 chars unique par user)

    Par defaut : ChangePasswordAtLogon = true (recommandation ANSSI R.18).

.PARAMETER Sam
    sAMAccountName d'un seul user a resetter

.PARAMETER SamList
    Liste de sAMAccountNames

.PARAMETER All
    Reset tous les users humains (exclusions automatiques)

.PARAMETER MotDePasse
    Mot de passe explicite

.PARAMETER RandomPassword
    Genere un mdp random ANSSI par user (affiche en fin pour communication)

.PARAMETER NoForceChange
    Desactive l'obligation de changer le mdp au 1er logon (deconseille)

.PARAMETER DryRun
    Simulation sans modification

.EXAMPLE
    .\13-ops_Reset-Password.ps1 -Sam lea.bertrand -RandomPassword
    Reset le mdp de lea.bertrand avec un mdp random

.EXAMPLE
    .\13-ops_Reset-Password.ps1 -All -DryRun
    Simulation du reset de tous les users humains

.EXAMPLE
    .\13-ops_Reset-Password.ps1 -SamList demo-rh,demo-dev -MotDePasse 'Temp@2026!'
    Reset cible avec mdp explicite

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Execute sur SRV-DC-01 en Domain Admin
    Conforme: ANSSI PA-022 R.18 (rotation MDP, force change at logon)
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='Cible')]
param(
    [Parameter(ParameterSetName='Cible', Mandatory)]
    [string]$Sam,

    [Parameter(ParameterSetName='Liste', Mandatory)]
    [string[]]$SamList,

    [Parameter(ParameterSetName='Tous', Mandatory)]
    [switch]$All,

    [string]$MotDePasse,
    [switch]$RandomPassword,
    [switch]$NoForceChange,
    [switch]$DryRun
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

# Exclusions de securite
$excludedSam = @(
    'Administrator', 'Administrateur', 'krbtgt', 'Guest', 'Invite', 'Invité', 'DefaultAccount'
)
$excludedPrefixes = @('svc-', 'krbtgt')

function Test-YanixUserExclu {
    param([string]$SamName)
    if ($excludedSam -contains $SamName) { return $true }
    foreach ($p in $excludedPrefixes) {
        if ($SamName.ToLower().StartsWith($p.ToLower())) { return $true }
    }
    return $false
}

# ============================================================================
# CONSTITUTION DE LA LISTE A TRAITER
# ============================================================================
Write-YanixLog STEP "Constitution de la liste de comptes a traiter"

$cibles = @()

switch ($PSCmdlet.ParameterSetName) {
    'Cible' {
        if (Test-YanixUserExclu -SamName $Sam) {
            Write-YanixLog ERR "User '$Sam' est dans la liste d'exclusion safety (refuse pour la securite)"
            exit (Show-YanixRecap)
        }
        if (-not (Test-YanixUtilisateur -SamAccountName $Sam)) {
            Write-YanixLog ERR "User '$Sam' introuvable dans l'AD"
            exit (Show-YanixRecap)
        }
        $cibles = @($Sam)
    }
    'Liste' {
        foreach ($s in $SamList) {
            if (Test-YanixUserExclu -SamName $s) {
                Write-YanixLog WARN "Exclu (safety) : $s"
                continue
            }
            if (-not (Test-YanixUtilisateur -SamAccountName $s)) {
                Write-YanixLog WARN "Introuvable : $s"
                continue
            }
            $cibles += $s
        }
    }
    'Tous' {
        $tous = Get-ADUser -Filter * | Where-Object { -not (Test-YanixUserExclu -SamName $_.SamAccountName) }
        $cibles = $tous | Select-Object -ExpandProperty SamAccountName
        Write-YanixLog INFO "$($cibles.Count) compte(s) humain(s) eligibles (apres exclusions)"

        # Confirmation pour mode -All si pas DryRun
        if (-not $script:YanixContext.DryRun) {
            Write-Host ''
            Write-Host "ATTENTION : reset MDP de $($cibles.Count) comptes !" -ForegroundColor Red
            $rep = Read-Host "Taper 'OUI' pour confirmer"
            if ($rep -ne 'OUI') {
                Write-YanixLog INFO "Annulation par l'operateur"
                exit (Show-YanixRecap)
            }
        }
    }
}

if ($cibles.Count -eq 0) {
    Write-YanixLog ERR "Aucun compte a traiter"
    exit (Show-YanixRecap)
}

Write-YanixLog OK "$($cibles.Count) compte(s) seront traite(s)"

# ============================================================================
# DETERMINATION DU MOT DE PASSE
# ============================================================================
$pwdMode = 'defaut'
$pwdFixe = $null
if ($MotDePasse) {
    $pwdFixe = $MotDePasse
    $pwdMode = 'explicite'
} elseif ($RandomPassword) {
    $pwdMode = 'aleatoire-par-user'
} else {
    $pwdFixe = $config.MotDePasse.DefautBienvenue
}

Write-YanixLog INFO "Mode mot de passe : $pwdMode"
Write-YanixLog INFO "Force change at logon : $(-not $NoForceChange) (recommandation ANSSI)"

# ============================================================================
# EXECUTION DES RESETS
# ============================================================================
Write-YanixLog STEP "=== Reset des mots de passe ==="

$pwdGeneres = @{}  # pour mode random : memoriser les pwd a afficher en fin

foreach ($s in $cibles) {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : reset mdp pour $s simule (mode: $pwdMode)"
        continue
    }

    try {
        # Determination du mdp pour cette iteration
        if ($pwdMode -eq 'aleatoire-par-user') {
            $pwdActuel = New-YanixMotDePasseAnssi -Longueur 15
            $pwdGeneres[$s] = $pwdActuel
        } else {
            $pwdActuel = $pwdFixe
        }

        $secure = ConvertTo-SecureString $pwdActuel -AsPlainText -Force

        Set-ADAccountPassword -Identity $s -NewPassword $secure -Reset -ErrorAction Stop
        Set-ADUser -Identity $s -ChangePasswordAtLogon (-not $NoForceChange) -ErrorAction Stop

        # Deverouille le compte au passage
        try { Unlock-ADAccount -Identity $s -ErrorAction SilentlyContinue } catch {}

        Write-YanixLog OK "Reset OK : $s"
    } catch {
        Write-YanixLog ERR "Reset ECHEC : $s - $($_.Exception.Message)"
    }
}

# ============================================================================
# AFFICHAGE DES MDP RANDOM GENERES (mode aleatoire-par-user)
# ============================================================================
if ($pwdGeneres.Count -gt 0) {
    Write-YanixLog STEP "=== Mots de passe generes (a communiquer) ==="
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Yellow
    Write-Host ' MOTS DE PASSE GENERES - A COMMUNIQUER PAR CANAL SECURISE ' -ForegroundColor Yellow
    Write-Host ('=' * 60) -ForegroundColor Yellow
    $pwdGeneres.GetEnumerator() | Sort-Object Key | ForEach-Object {
        Write-Host ('  {0,-30} {1}' -f $_.Key, $_.Value) -ForegroundColor Cyan
    }
    Write-Host ('=' * 60) -ForegroundColor Yellow
    Write-YanixLog INFO "Mots de passe affiches uniquement en console (NON logges en clair - RGPD)"
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
