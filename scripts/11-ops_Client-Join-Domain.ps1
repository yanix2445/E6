<#
.SYNOPSIS
    Jonction interactive d'un poste client Windows 11 au domaine yanixlabs.lan
    dans la BONNE OU metier (pas dans CN=Computers).
    Conforme cadre prod-ready E6

.DESCRIPTION
    Script interactif a lancer sur le POSTE CLIENT (pas sur un DC) qui :
      1. Pre-flight : Admin local, resolution DNS, ping DC-01
      2. Demande a l'operateur le nom du poste et le service metier (1-9)
      3. Saisit les credentials admin du domaine
      4. Si poste NON joint -> renomme + Add-Computer -OUPath <OU> -Restart
      5. Si poste DEJA joint -> verifie l'OU, propose deplacement + gpupdate /force

    Garantit que le poste arrive DIRECTEMENT dans son OU metier des la jonction,
    permettant l'application immediate des GPO ciblees (CN=Computers ne supporte pas les GPO).

.PARAMETER NewName
    Nouveau nom du poste (par defaut : garder le nom actuel)

.PARAMETER Service
    Service metier (TAB-completion contre liste config). Si non fourni, demande interactive.

.PARAMETER DomainCredential
    Credential admin du domaine (sinon Get-Credential interactif)

.PARAMETER DryRun
    Simulation sans modification (pas de Add-Computer ni Move-ADObject)

.EXAMPLE
    .\11-ops_Client-Join-Domain.ps1
    Mode interactif complet

.EXAMPLE
    .\11-ops_Client-Join-Domain.ps1 -NewName 'PC-USR-05' -Service Marketing-Communication

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Execute SUR LE POSTE CLIENT (en Admin local)
    Prerequis : Connectivite reseau OK (DNS yanixlabs.lan resolu, ping DC-01)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$NewName,
    [string]$Service,
    [pscredential]$DomainCredential,
    [switch]$DryRun
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT (poste client : Admin local seulement, pas DomainAdmin)
# ============================================================================
Test-YanixPrerequis -Required Admin -Stop

$config = Get-YanixConfig

$domain        = $config.Domain
$domainNetBIOS = $config.DomainNetBIOS
$dc01          = $config.Serveurs.DC01
$ouRoot        = "OU=Ordinateurs,OU=YANIXLABS,DC=yanixlabs,DC=lan"
$services      = $config.ServicesMetier

# ============================================================================
# VERIFICATIONS RESEAU
# ============================================================================
Write-YanixLog STEP "Verifications reseau"

try {
    $dnsResult = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop | Select-Object -First 1
    Write-YanixLog OK "DNS $domain resolu : $($dnsResult.IPAddress)"
} catch {
    Write-YanixLog ERR "DNS $domain ne resout pas - verifier la config IP du poste"
    exit (Show-YanixRecap)
}

if (Test-YanixConnectivite -ComputerName $dc01.IP -Port 445 -TimeoutMs 3000) {
    Write-YanixLog OK "$($dc01.Hostname) ($($dc01.IP)) joignable"
} else {
    Write-YanixLog ERR "$($dc01.Hostname) injoignable, jonction impossible"
    exit (Show-YanixRecap)
}

# ============================================================================
# SAISIE OPERATEUR
# ============================================================================
Write-YanixLog STEP '=== Configuration de la jonction ==='

# 1) Nom du poste
$currentName = $env:COMPUTERNAME
Write-YanixLog INFO "Nom actuel du poste : $currentName"

if (-not $NewName) {
    $input = Read-Host "Nouveau nom (Entree = garder '$currentName', convention: PC-USR-NN)"
    if ([string]::IsNullOrWhiteSpace($input)) {
        $NewName = $currentName
    } else {
        $NewName = $input.ToUpper().Trim()
    }
}
$NewName = $NewName.ToUpper().Trim()

# 2) Choix du service
if (-not $Service) {
    Write-Host "`nServices disponibles :" -ForegroundColor Cyan
    for ($i = 0; $i -lt $services.Count; $i++) {
        Write-Host ('  {0,2}. {1}' -f ($i + 1), $services[$i])
    }
    do {
        $choice = Read-Host 'Numero du service (1-9)'
    } while ($choice -notmatch "^[1-9]$" -or [int]$choice -gt $services.Count)
    $Service = $services[[int]$choice - 1]
}

if ($Service -notin $services) {
    Write-YanixLog ERR "Service '$Service' invalide. Valeurs : $($services -join ', ')"
    exit (Show-YanixRecap)
}

$targetOU = "OU=$Service,$ouRoot"
Write-YanixLog OK "Service choisi : $Service"
Write-YanixLog OK "OU cible : $targetOU"

# 3) Credentials admin du domaine
if (-not $DomainCredential) {
    Write-YanixLog INFO "Credentials admin du domaine requis (compte Domain Admins)"
    $DomainCredential = Get-Credential -UserName "$domainNetBIOS\Administrateur" -Message "Mot de passe d'un compte admin du domaine $domain"
}

if (-not $DomainCredential) {
    Write-YanixLog ERR 'Credentials annules par l''operateur'
    exit (Show-YanixRecap)
}

# ============================================================================
# ETAT ACTUEL DU POSTE
# ============================================================================
$cs = Get-CimInstance Win32_ComputerSystem
$alreadyJoined = $cs.PartOfDomain -and ($cs.Domain -eq $domain)
Write-YanixLog INFO "Etat actuel : PartOfDomain=$($cs.PartOfDomain), Domain=$($cs.Domain)"

# ============================================================================
# RECAP AVANT ACTION
# ============================================================================
Write-YanixLog STEP "=== Recap de l'operation ==="
Write-YanixLog INFO "  Hostname actuel : $currentName"
Write-YanixLog INFO "  Hostname cible  : $NewName"
Write-YanixLog INFO "  Domaine         : $domain"
Write-YanixLog INFO "  OU destination  : $targetOU"
Write-YanixLog INFO "  Compte admin    : $($DomainCredential.UserName)"
Write-YanixLog INFO "  Etat actuel     : $(if ($alreadyJoined) {'Deja joint'} else {'NON joint'})"

if ($script:YanixContext.DryRun) {
    Write-YanixLog INFO 'DRY-RUN : aucune jonction/renommage effectue. Verification uniquement.'
    exit (Show-YanixRecap)
}

# ============================================================================
# LOGIQUE PRINCIPALE
# ============================================================================

if (-not $alreadyJoined) {
    # --- CAS 1 : poste NON joint - renommer + joindre dans la bonne OU ---
    Write-YanixLog STEP '=== Jonction au domaine ==='
    Write-YanixLog INFO "Poste non joint, jonction vers $domain en cours..."

    try {
        if ($NewName -ne $currentName) {
            Write-YanixLog INFO "Renommage en meme temps : $currentName -> $NewName"
            Add-Computer -DomainName $domain `
                         -OUPath $targetOU `
                         -Credential $DomainCredential `
                         -NewName $NewName `
                         -Force `
                         -Restart `
                         -ErrorAction Stop
        } else {
            Add-Computer -DomainName $domain `
                         -OUPath $targetOU `
                         -Credential $DomainCredential `
                         -Force `
                         -Restart `
                         -ErrorAction Stop
        }
        Write-YanixLog OK "Jonction lancee, redemarrage automatique en cours..."
    } catch {
        Write-YanixLog ERR "Echec jonction : $($_.Exception.Message)"
        exit (Show-YanixRecap)
    }
    # Apres -Restart, on n'arrivera pas ici
}
else {
    # --- CAS 2 : poste deja joint - verifier OU + renommage eventuel ---
    Write-YanixLog STEP '=== Poste deja joint, verifications ==='
    Write-YanixLog SKIP "Poste deja membre de $domain"

    # Renommage demande ?
    if ($NewName -ne $currentName) {
        Write-YanixLog INFO "Renommage demande : $currentName -> $NewName"
        try {
            Rename-Computer -NewName $NewName -DomainCredential $DomainCredential -Force -ErrorAction Stop
            Write-YanixLog OK "Renommage planifie. Redemarrage requis pour appliquer."
        } catch {
            Write-YanixLog ERR "Echec renommage : $($_.Exception.Message)"
        }
    }

    # Verifier la position dans l'AD via le module RSAT-AD-PowerShell si dispo
    if (Test-YanixModule -ModuleName 'ActiveDirectory') {
        try {
            $adComp = Get-ADComputer -Identity $env:COMPUTERNAME `
                                      -Credential $DomainCredential `
                                      -Server $domain `
                                      -Properties DistinguishedName -ErrorAction Stop
            $currentOU = ($adComp.DistinguishedName -split ',', 2)[1]
            if ($currentOU -eq $targetOU) {
                Write-YanixLog OK "Poste deja dans la bonne OU"
            } else {
                Write-YanixLog WARN "Poste actuellement dans : $currentOU"
                Write-YanixLog INFO "Deplacement vers : $targetOU..."
                Move-ADObject -Identity $adComp.DistinguishedName `
                              -TargetPath $targetOU `
                              -Credential $DomainCredential `
                              -Server $domain -ErrorAction Stop
                Write-YanixLog OK "Poste deplace dans $targetOU"
            }
        } catch {
            Write-YanixLog ERR "Echec lecture/deplacement AD : $($_.Exception.Message)"
            Write-YanixLog INFO "Solution manuelle - sur un DC :"
            Write-YanixLog INFO "  Move-ADObject -Identity 'CN=$env:COMPUTERNAME,CN=Computers,DC=yanixlabs,DC=lan' -TargetPath '$targetOU'"
        }
    } else {
        Write-YanixLog WARN "Module ActiveDirectory non dispo (RSAT non installe sur ce poste)"
        Write-YanixLog INFO "Verification OU impossible. Si le poste n'est pas dans '$targetOU' :"
        Write-YanixLog INFO "  Sur SRV-DC-01 : Move-ADObject -Identity 'CN=$env:COMPUTERNAME,CN=Computers,DC=yanixlabs,DC=lan' -TargetPath '$targetOU'"
    }

    # Force gpupdate pour appliquer les nouvelles GPO
    Write-YanixLog STEP 'Application des GPO (gpupdate /force)'
    try {
        gpupdate /force | Out-Null
        Write-YanixLog OK "GPO mises a jour"
    } catch {
        Write-YanixLog WARN "gpupdate : $($_.Exception.Message)"
    }
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
$cs = Get-CimInstance Win32_ComputerSystem
Write-YanixLog STEP '=== Etat final ==='
Write-YanixLog INFO "  Hostname     : $env:COMPUTERNAME"
Write-YanixLog INFO "  Domaine      : $($cs.Domain)"
Write-YanixLog INFO "  PartOfDomain : $($cs.PartOfDomain)"
Write-YanixLog INFO "  OU cible     : $targetOU"
Write-YanixLog INFO ""
Write-YanixLog INFO "Verification GPO appliquees apres reboot : gpresult /r"

exit (Show-YanixRecap)
