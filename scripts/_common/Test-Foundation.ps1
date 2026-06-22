<#
.SYNOPSIS
    Test-Foundation.ps1 - Valide que la bibliothèque commune fonctionne

.DESCRIPTION
    Mini script à lancer en premier sur n'importe quel serveur du projet.
    Vérifie :
    - Chargement de la config E6-Config.psd1
    - Logger fonctionne (fichier + console)
    - Pre-flight checks détectent correctement les prérequis
    - Helpers AD et FS sont chargés
    - Télémétrie centralisée accessible (si configurée)

.EXAMPLE
    .\_common\Test-Foundation.ps1
    .\_common\Test-Foundation.ps1 -DryRun

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR
    Version : 1.0 - 2026-06-22
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHÈQUE
# ============================================================================
. $PSScriptRoot\Common.ps1
. $PSScriptRoot\AD-Helpers.ps1
. $PSScriptRoot\FS-Helpers.ps1

# ============================================================================
# INITIALISATION DU CONTEXTE
# ============================================================================
Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# TESTS UNITAIRES BASIQUES DE LA LIB
# ============================================================================

$config = Get-YanixConfig

Write-YanixLog STEP "=== Test 1/6 : Chargement de la configuration ==="
Write-YanixLog OK "Domaine charge : $($config.Domain)"
Write-YanixLog OK "Serveurs definis : $($config.Serveurs.Keys -join ', ')"
Write-YanixLog OK "Services metier : $($config.ServicesMetier.Count) ($(($config.ServicesMetier | Select-Object -First 3) -join ', '), ...)"

Write-YanixLog STEP "=== Test 2/6 : Logger ==="
Write-YanixLog INFO "Message INFO de test"
Write-YanixLog OK   "Message OK de test"
Write-YanixLog WARN "Message WARN de test (non bloquant)"
Write-YanixLog SKIP "Message SKIP de test (operation idempotente)"

Write-YanixLog STEP "=== Test 3/6 : Helpers de pre-flight ==="
$tests = @{
    'Test-YanixIsAdmin' = (Test-YanixIsAdmin)
    'Test-YanixIsDomainAdmin' = (Test-YanixIsDomainAdmin)
    'Test-YanixModule ActiveDirectory' = (Test-YanixModule -ModuleName 'ActiveDirectory')
}
foreach ($t in $tests.GetEnumerator()) {
    if ($t.Value) { Write-YanixLog OK   "$($t.Key) -> True" }
    else          { Write-YanixLog WARN "$($t.Key) -> False" }
}

Write-YanixLog STEP "=== Test 4/6 : Connectivite vers les serveurs ==="
foreach ($key in @('DC01','DC02','FS01','FS02','BCK01')) {
    $srv = $config.Serveurs[$key]
    $ok  = Test-YanixConnectivite -ComputerName $srv.IP -Port 445 -TimeoutMs 2000
    if ($ok) { Write-YanixLog OK   "$($srv.Hostname) ($($srv.IP)) joignable" }
    else     { Write-YanixLog WARN "$($srv.Hostname) ($($srv.IP)) injoignable" }
}

Write-YanixLog STEP "=== Test 5/6 : Helpers AD charges ==="
$adFonctions = @('Test-YanixOU','Test-YanixGroupe','Test-YanixUtilisateur','New-YanixOU',
                 'New-YanixGroupe','Add-YanixGroupeMembre','Get-YanixDCActif',
                 'ConvertTo-YanixSansAccents','Get-YanixSamAccountName','New-YanixMotDePasseAnssi')
foreach ($f in $adFonctions) {
    if (Get-Command $f -ErrorAction SilentlyContinue) {
        Write-YanixLog OK "Fonction AD disponible : $f"
    } else {
        Write-YanixLog ERR "Fonction AD manquante : $f"
    }
}

Write-YanixLog STEP "=== Test 6/6 : Helpers FS charges ==="
$fsFonctions = @('Test-YanixPartage','New-YanixPartage','Set-YanixAclAGDLP',
                 'Test-YanixAclConformeAGDLP','New-YanixHomeDirectory')
foreach ($f in $fsFonctions) {
    if (Get-Command $f -ErrorAction SilentlyContinue) {
        Write-YanixLog OK "Fonction FS disponible : $f"
    } else {
        Write-YanixLog ERR "Fonction FS manquante : $f"
    }
}

Write-YanixLog STEP "=== Test bonus : Telemetrie ==="
if ($config.Logs.TelemetrieActive) {
    if (Test-Path $config.Logs.TelemetrieCible -ErrorAction SilentlyContinue) {
        Write-YanixLog OK "Telemetrie centralisee active et accessible : $($config.Logs.TelemetrieCible)"
    } else {
        Write-YanixLog WARN "Telemetrie configuree mais cible inaccessible (normal si BCK-01 down ou partage non cree)"
    }
} else {
    Write-YanixLog INFO "Telemetrie centralisee desactivee dans la config"
}

# ============================================================================
# RECAP + CODE DE SORTIE
# ============================================================================
exit (Show-YanixRecap)
