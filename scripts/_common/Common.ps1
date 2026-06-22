<#
.SYNOPSIS
    Common.ps1 - Bibliothèque commune du projet E6 yanixlabs.lan
    Logger, pre-flight checks, helpers transverses

.DESCRIPTION
    Bibliothèque sourcée par tous les scripts du projet E6.
    Fournit :
    - Chargement de la configuration (E6-Config.psd1)
    - Logger structuré (console couleur + fichier + télémétrie)
    - Pre-flight checks (Admin, modules, connectivité, prérequis)
    - Helpers transverses (bannières, récap, identité de l'opérateur)

    Usage type dans un script métier :
        . $PSScriptRoot\_common\Common.ps1
        Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name
        Test-YanixPrerequis -Required AD
        Write-YanixLog STEP "Mon traitement..."
        # ... traitement ...
        Show-YanixRecap

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR
    Version : 1.0 - 2026-06-22
    Conforme : Microsoft Approved Verbs, ANSSI PA-022 (R.22 - traçabilité)
#>

# ============================================================================
# VARIABLES GLOBALES DE SESSION
# ============================================================================
$script:YanixContext = $null
$script:YanixConfig  = $null
$script:YanixCompteurs = @{
    Succes = 0
    Skip   = 0
    Warn   = 0
    Err    = 0
}

# ============================================================================
# CHARGEMENT DE LA CONFIG
# ============================================================================

function Get-YanixConfig {
    <#
    .SYNOPSIS
        Charge la configuration centralisée E6-Config.psd1
    .DESCRIPTION
        Recherche le fichier _config/E6-Config.psd1 et le retourne en tant qu'objet.
        Mémorise le résultat pour éviter les rechargements multiples.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:YanixConfig) {
        return $script:YanixConfig
    }

    # Chemin relatif au dossier _common
    $configPath = Join-Path (Split-Path $PSScriptRoot -Parent) '_config\E6-Config.psd1'

    if (-not (Test-Path $configPath)) {
        throw "Fichier de configuration introuvable : $configPath"
    }

    try {
        $script:YanixConfig = Import-PowerShellDataFile -Path $configPath -ErrorAction Stop
        return $script:YanixConfig
    }
    catch {
        throw "Erreur lors du chargement de la configuration : $($_.Exception.Message)"
    }
}

# ============================================================================
# INITIALISATION DU CONTEXTE
# ============================================================================

function Initialize-YanixContexte {
    <#
    .SYNOPSIS
        Initialise le contexte d'exécution d'un script (logger, dossiers, banner)
    .PARAMETER ScriptName
        Nom du script appelant (généralement $MyInvocation.MyCommand.Name)
    .PARAMETER DryRun
        Si présent, active le mode simulation (aucune écriture en télémétrie)
    .PARAMETER NoBanner
        Ne pas afficher la bannière de démarrage
    .EXAMPLE
        Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptName,
        [switch]$DryRun,
        [switch]$NoBanner
    )

    $config = Get-YanixConfig

    # Construction du contexte
    $scriptRoot = Split-Path $PSScriptRoot -Parent
    $logsDir    = Join-Path $scriptRoot $config.Logs.DossierLocal

    # Crée le dossier Logs s'il n'existe pas
    if (-not (Test-Path $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }

    # Nettoie le nom du script pour le fichier log (enlève .ps1 et caractères spéciaux)
    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptName)
    $stamp     = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $logFile   = Join-Path $logsDir "$cleanName`_$stamp.log"

    $script:YanixContext = [PSCustomObject]@{
        ScriptName     = $ScriptName
        ScriptCleanName = $cleanName
        StartTime      = Get-Date
        LogFile        = $logFile
        LogsDir        = $logsDir
        Hostname       = $env:COMPUTERNAME
        UserName       = $env:USERNAME
        UserDomain     = $env:USERDOMAIN
        ExecutionId    = [Guid]::NewGuid().ToString().Substring(0, 8)
        DryRun         = $DryRun.IsPresent
        Config         = $config
    }

    # Reset compteurs
    $script:YanixCompteurs.Succes = 0
    $script:YanixCompteurs.Skip   = 0
    $script:YanixCompteurs.Warn   = 0
    $script:YanixCompteurs.Err    = 0

    # En-tête du fichier de log
    $banner = @"
================================================================================
SCRIPT     : $ScriptName
EXECUTION  : $($script:YanixContext.ExecutionId)
DEMARRE    : $($script:YanixContext.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
OPERATEUR  : $($script:YanixContext.UserDomain)\$($script:YanixContext.UserName)
MACHINE    : $($script:YanixContext.Hostname)
MODE       : $(if ($DryRun) { 'DRY-RUN (simulation)' } else { 'EXECUTION REELLE' })
================================================================================

"@
    $banner | Out-File -FilePath $logFile -Encoding UTF8 -Append

    if (-not $NoBanner) {
        Show-YanixBanner -ScriptName $ScriptName -DryRun:$DryRun
    }

    return $script:YanixContext
}

# ============================================================================
# LOGGER
# ============================================================================

function Write-YanixLog {
    <#
    .SYNOPSIS
        Écrit un message dans le log (fichier + console + télémétrie optionnelle)
    .PARAMETER Niveau
        INFO | OK | WARN | ERR | SKIP | STEP
    .PARAMETER Message
        Texte du message
    .PARAMETER NoConsole
        Ne pas afficher en console (log fichier uniquement)
    .EXAMPLE
        Write-YanixLog STEP "Création de l'OU Utilisateurs"
        Write-YanixLog OK   "OU créée avec succès"
        Write-YanixLog SKIP "OU déjà existante - ignorée"
        Write-YanixLog ERR  "Échec de création : $($_.Exception.Message)"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [ValidateSet('INFO','OK','WARN','ERR','SKIP','STEP')]
        [string]$Niveau,

        [Parameter(Mandatory, Position=1)]
        [AllowEmptyString()]
        [string]$Message,

        [switch]$NoConsole
    )

    if ($null -eq $script:YanixContext) {
        throw "Contexte Yanix non initialisé. Appelez Initialize-YanixContexte d'abord."
    }

    # Compteurs
    switch ($Niveau) {
        'OK'   { $script:YanixCompteurs.Succes++ }
        'SKIP' { $script:YanixCompteurs.Skip++   }
        'WARN' { $script:YanixCompteurs.Warn++   }
        'ERR'  { $script:YanixCompteurs.Err++    }
    }

    # Construction de la ligne
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = $script:YanixContext.Config.Logs.Format -f $ts, $Niveau, $script:YanixContext.UserName, $script:YanixContext.Hostname, $Message

    # Écriture fichier
    $line | Out-File -FilePath $script:YanixContext.LogFile -Append -Encoding UTF8

    # Console (couleur selon niveau)
    if (-not $NoConsole) {
        $color = switch ($Niveau) {
            'OK'   { 'Green' }
            'INFO' { 'White' }
            'WARN' { 'Yellow' }
            'ERR'  { 'Red' }
            'SKIP' { 'DarkGray' }
            'STEP' { 'Cyan' }
        }
        $prefix = "[$Niveau]".PadRight(7)
        Write-Host "$prefix $Message" -ForegroundColor $color
    }
}

# ============================================================================
# BANNIÈRE DE DÉMARRAGE
# ============================================================================

function Show-YanixBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptName,
        [switch]$DryRun
    )

    $bar = '#' * 78
    Write-Host ''
    Write-Host $bar -ForegroundColor Magenta
    Write-Host ("#  PROJET E6 - yanixlabs.lan" + (' ' * 47) + "#") -ForegroundColor Magenta
    Write-Host ("#  Script : $ScriptName" + (' ' * [Math]::Max(1, 64 - $ScriptName.Length)) + "#") -ForegroundColor Magenta
    if ($DryRun) {
        Write-Host ("#  >>> MODE DRY-RUN - SIMULATION SANS MODIFICATION <<<" + (' ' * 22) + "#") -ForegroundColor Cyan
    }
    Write-Host $bar -ForegroundColor Magenta
    Write-Host ''
}

# ============================================================================
# RÉCAPITULATIF FINAL + TÉLÉMÉTRIE
# ============================================================================

function Show-YanixRecap {
    <#
    .SYNOPSIS
        Affiche le récapitulatif final, déclenche la télémétrie et retourne le code de sortie
    .DESCRIPTION
        - Affiche compteurs et durée
        - Copie le log vers la télémétrie centralisée si configurée
        - Retourne 0 (succès) / 1 (erreurs) / 2 (warnings sans erreur)
    .EXAMPLE
        exit (Show-YanixRecap)
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:YanixContext) {
        Write-Warning "Contexte non initialisé"
        return 1
    }

    $duration = (Get-Date) - $script:YanixContext.StartTime
    $durStr   = '{0:hh\:mm\:ss}' -f $duration

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Yellow
    Write-Host ' RECAPITULATIF' -ForegroundColor Yellow
    Write-Host ('=' * 78) -ForegroundColor Yellow
    Write-Host ('  Succes    : {0,4}' -f $script:YanixCompteurs.Succes) -ForegroundColor Green
    Write-Host ('  Ignores   : {0,4}' -f $script:YanixCompteurs.Skip) -ForegroundColor DarkGray
    $warnColor = if ($script:YanixCompteurs.Warn -eq 0) {'Green'} else {'Yellow'}
    Write-Host ('  Warnings  : {0,4}' -f $script:YanixCompteurs.Warn) -ForegroundColor $warnColor
    $errColor = if ($script:YanixCompteurs.Err -eq 0) {'Green'} else {'Red'}
    Write-Host ('  Erreurs   : {0,4}' -f $script:YanixCompteurs.Err) -ForegroundColor $errColor
    Write-Host ('  Duree     : {0}' -f $durStr) -ForegroundColor White
    Write-Host ('  Log local : {0}' -f $script:YanixContext.LogFile) -ForegroundColor DarkGray
    Write-Host ('=' * 78) -ForegroundColor Yellow
    Write-Host ''

    # Inscription du récap dans le fichier
    @"

================================================================================
RECAPITULATIF
================================================================================
  Succes    : $($script:YanixCompteurs.Succes)
  Ignores   : $($script:YanixCompteurs.Skip)
  Warnings  : $($script:YanixCompteurs.Warn)
  Erreurs   : $($script:YanixCompteurs.Err)
  Duree     : $durStr
  Termine   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
================================================================================
"@ | Out-File -FilePath $script:YanixContext.LogFile -Append -Encoding UTF8

    # Télémétrie centralisée
    if ($script:YanixContext.Config.Logs.TelemetrieActive -and -not $script:YanixContext.DryRun) {
        Invoke-YanixTelemetrie
    }

    # Code de sortie
    if ($script:YanixCompteurs.Err -gt 0)  { return 1 }
    if ($script:YanixCompteurs.Warn -gt 0) { return 2 }
    return 0
}

function Invoke-YanixTelemetrie {
    <#
    .SYNOPSIS
        Copie le log local vers la télémétrie centralisée (\\SRV-BCK-01\Logs$)
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:YanixContext) { return }

    $cibleBase = $script:YanixContext.Config.Logs.TelemetrieCible
    if ([string]::IsNullOrWhiteSpace($cibleBase)) { return }

    # Structure cible : \\SRV-BCK-01\Logs$\<hostname>\<filename>
    $cibleHost = Join-Path $cibleBase $script:YanixContext.Hostname

    try {
        # Test d'accessibilité de la cible
        if (-not (Test-Path $cibleBase -ErrorAction SilentlyContinue)) {
            Write-Host "  [INFO] Telemetrie ignoree : cible $cibleBase inaccessible" -ForegroundColor DarkGray
            return
        }

        # Crée le dossier hostname si absent
        if (-not (Test-Path $cibleHost)) {
            New-Item -Path $cibleHost -ItemType Directory -Force | Out-Null
        }

        # Copie le log
        Copy-Item -Path $script:YanixContext.LogFile -Destination $cibleHost -Force -ErrorAction Stop
        Write-Host "  [INFO] Telemetrie : log envoye vers $cibleHost" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  [WARN] Echec telemetrie : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

function Test-YanixIsAdmin {
    <#
    .SYNOPSIS
        Vérifie que la session courante a les droits Administrateur (élévation)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-YanixIsDomainAdmin {
    <#
    .SYNOPSIS
        Vérifie que l'utilisateur courant est membre de Domain Admins
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $groups = (whoami /groups) 2>$null
        return ($groups -match 'Domain Admins|Admins du domaine|Enterprise Admins|Admins de l.entreprise')
    } catch {
        return $false
    }
}

function Test-YanixModule {
    <#
    .SYNOPSIS
        Vérifie qu'un module PowerShell est disponible et le charge si possible
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName
    )

    if (Get-Module -Name $ModuleName) { return $true }

    if (Get-Module -Name $ModuleName -ListAvailable) {
        try {
            Import-Module $ModuleName -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
    return $false
}

function Test-YanixConnectivite {
    <#
    .SYNOPSIS
        Teste la connectivité TCP vers un hôte sur un port donné
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,
        [Parameter(Mandatory)]
        [int]$Port,
        [int]$TimeoutMs = 3000
    )

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($ComputerName, $Port, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $tcp.Connected) {
            $tcp.EndConnect($iar) | Out-Null
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    } catch {
        return $false
    }
}

function Test-YanixRemoting {
    <#
    .SYNOPSIS
        Vérifie que PowerShell Remoting est accessible vers un serveur
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    try {
        Test-WSMan -ComputerName $ComputerName -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-YanixPrerequis {
    <#
    .SYNOPSIS
        Effectue un ensemble de pré-vérifications avant exécution
    .PARAMETER Required
        Liste des prérequis à valider : Admin, DomainAdmin, AD, DC01, DC02, FS01, FS02, BCK01, Telemetrie
    .PARAMETER Stop
        Si présent, lève une exception en cas d'échec d'un prérequis
    .EXAMPLE
        Test-YanixPrerequis -Required Admin, AD, FS01 -Stop
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Required,
        [switch]$Stop
    )

    $config = Get-YanixConfig
    Write-YanixLog STEP "Pre-flight checks : $($Required -join ', ')"
    $allOk = $true

    foreach ($req in $Required) {
        switch ($req) {
            'Admin' {
                if (Test-YanixIsAdmin) {
                    Write-YanixLog OK "Session executee en tant qu'Administrateur"
                } else {
                    Write-YanixLog ERR "Session non elevee : execution en Administrateur requise"
                    $allOk = $false
                }
            }
            'DomainAdmin' {
                if (Test-YanixIsDomainAdmin) {
                    Write-YanixLog OK "Compte courant est Domain Admin"
                } else {
                    Write-YanixLog WARN "Compte courant n'est pas Domain Admin (verifier les droits)"
                }
            }
            'AD' {
                if (Test-YanixModule -ModuleName 'ActiveDirectory') {
                    Write-YanixLog OK "Module ActiveDirectory charge"
                    try {
                        $dom = Get-ADDomain -ErrorAction Stop
                        Write-YanixLog OK "Domaine $($dom.DNSRoot) accessible"
                    } catch {
                        Write-YanixLog ERR "Domaine inaccessible : $($_.Exception.Message)"
                        $allOk = $false
                    }
                } else {
                    Write-YanixLog ERR "Module ActiveDirectory introuvable (RSAT requis)"
                    $allOk = $false
                }
            }
            {$_ -in 'DC01','DC02','FS01','FS02','BCK01'} {
                $srv = $config.Serveurs[$_]
                if (Test-YanixConnectivite -ComputerName $srv.IP -Port 445 -TimeoutMs 2000) {
                    Write-YanixLog OK "$($srv.Hostname) ($($srv.IP)) joignable (SMB)"
                } else {
                    Write-YanixLog ERR "$($srv.Hostname) ($($srv.IP)) injoignable"
                    $allOk = $false
                }
            }
            'Telemetrie' {
                $cible = $config.Logs.TelemetrieCible
                if (Test-Path $cible -ErrorAction SilentlyContinue) {
                    Write-YanixLog OK "Telemetrie centralisee accessible ($cible)"
                } else {
                    Write-YanixLog WARN "Telemetrie centralisee inaccessible ($cible)"
                }
            }
            default {
                Write-YanixLog WARN "Prerequis inconnu : '$req' (ignore)"
            }
        }
    }

    if (-not $allOk -and $Stop) {
        throw "Pre-flight checks echoues : voir log $($script:YanixContext.LogFile)"
    }

    return $allOk
}

# ============================================================================
# HELPER : EXÉCUTION AVEC GESTION D'ERREUR + LOG AUTO
# ============================================================================

function Invoke-YanixAction {
    <#
    .SYNOPSIS
        Exécute un scriptblock avec gestion d'erreur et log automatique
    .PARAMETER Description
        Description de l'action (affichée en STEP + log)
    .PARAMETER Action
        Scriptblock à exécuter
    .PARAMETER OnSkip
        Scriptblock qui retourne $true si l'action doit être skippée (idempotence)
    .EXAMPLE
        Invoke-YanixAction -Description "Creation OU Utilisateurs" `
                           -OnSkip { (Get-ADOrganizationalUnit -Filter "Name -eq 'Utilisateurs'") -ne $null } `
                           -Action  { New-ADOrganizationalUnit -Name 'Utilisateurs' -Path 'DC=yanixlabs,DC=lan' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Description,
        [Parameter(Mandatory)]
        [scriptblock]$Action,
        [scriptblock]$OnSkip
    )

    Write-YanixLog STEP $Description

    # Skip check
    if ($OnSkip) {
        try {
            if (& $OnSkip) {
                Write-YanixLog SKIP "$Description - deja en place"
                return
            }
        } catch {
            Write-YanixLog WARN "Skip-check echoue pour '$Description' : $($_.Exception.Message)"
        }
    }

    # DryRun ?
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : action simulee (non executee)"
        return
    }

    # Exécution
    try {
        & $Action
        Write-YanixLog OK $Description
    } catch {
        Write-YanixLog ERR "$Description - echec : $($_.Exception.Message)"
        throw
    }
}

# ============================================================================
# EXPORT NON NÉCESSAIRE (script sourcé via dot-source)
# Les fonctions sont disponibles dans la portée appelante.
# ============================================================================
