<#
.SYNOPSIS
    Bootstrap du service DHCP avec Failover entre SRV-DC-01 et SRV-DC-02
    Conforme cadre prod-ready E6 - Microsoft + ANSSI

.DESCRIPTION
    Provisionne le DHCP complet et idempotent sur les deux contrôleurs :
      1. Installation du rôle DHCP sur DC-01 (local) et DC-02 (via Remoting)
      2. Autorisation des deux serveurs dans l'AD
      3. Création/vérification de l'étendue VLAN10-USERS
      4. Configuration des options (passerelle, DNS x2, domaine)
      5. Activation de la mise à jour dynamique DNS
      6. Création du Failover LoadBalance 50/50 avec MCLT = 5 minutes
      7. Vérification post-déploiement (étendue, options, état Failover)

    100% IDEMPOTENT : relançable à volonté, ne touche rien d'existant
    correctement configuré.

.PARAMETER DryRun
    Simulation sans modification

.PARAMETER MotDePassePartage
    Secret partagé du Failover (défaut : généré aléatoirement)

.EXAMPLE
    .\02-bootstrap_DHCP-Failover.ps1 -DryRun
    Simulation

.EXAMPLE
    .\02-bootstrap_DHCP-Failover.ps1
    Déploiement réel

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : SRV-DC-01 (script lancé ici, configure aussi DC-02 via Remoting)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [string]$MotDePassePartage
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1
. $PSScriptRoot\_common\AD-Helpers.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================
Test-YanixPrerequis -Required Admin, DomainAdmin, AD, DC01, DC02 -Stop

$config = Get-YanixConfig

# Configuration locale du script (extraite de la config psd1)
$dc01      = $config.Serveurs.DC01
$dc02      = $config.Serveurs.DC02
$etendue   = $config.DHCP.Etendues[0]
$failover  = $config.DHCP.Failover

if (-not $MotDePassePartage) {
    # Génère un secret aléatoire ANSSI (15 chars) pour le Failover
    $MotDePassePartage = New-YanixMotDePasseAnssi -Longueur 20
}

# ============================================================================
# HELPER : exécution d'une action sur un serveur DHCP distant ou local
# ============================================================================

function Invoke-DhcpAction {
    <#
    .SYNOPSIS
        Exécute un scriptblock soit en local soit via Remoting
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][scriptblock]$Action,
        [object[]]$ArgumentList
    )

    if ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq "$env:COMPUTERNAME.$env:USERDNSDOMAIN") {
        return (& $Action @ArgumentList)
    } else {
        return Invoke-Command -ComputerName $ComputerName -ScriptBlock $Action -ArgumentList $ArgumentList -ErrorAction Stop
    }
}

# ============================================================================
# PHASE 1 - INSTALLATION DU ROLE DHCP SUR LES 2 DC
# ============================================================================
Write-YanixLog STEP "=== PHASE 1/6 : Installation du role DHCP sur les 2 DC ==="

foreach ($dc in @($dc01, $dc02)) {
    $alreadyInstalled = $false
    try {
        $alreadyInstalled = Invoke-DhcpAction -ComputerName $dc.FQDN -Action {
            (Get-WindowsFeature -Name DHCP).Installed
        }
    } catch {
        Write-YanixLog ERR "Verification feature DHCP echouee sur $($dc.Hostname) : $($_.Exception.Message)"
        continue
    }

    if ($alreadyInstalled) {
        Write-YanixLog SKIP "Role DHCP deja installe sur $($dc.Hostname)"
        continue
    }

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : installation role DHCP sur $($dc.Hostname) simulee"
        continue
    }

    try {
        Invoke-DhcpAction -ComputerName $dc.FQDN -Action {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        }
        Write-YanixLog OK "Role DHCP installe sur $($dc.Hostname)"
    } catch {
        Write-YanixLog ERR "Echec installation DHCP sur $($dc.Hostname) : $($_.Exception.Message)"
    }
}

# ============================================================================
# PHASE 2 - AUTORISATION DANS L'AD
# ============================================================================
Write-YanixLog STEP "=== PHASE 2/6 : Autorisation des serveurs DHCP dans l'AD ==="

$autorises = @()
try {
    $autorises = Get-DhcpServerInDC -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DnsName
} catch {
    Write-YanixLog WARN "Lecture des serveurs DHCP autorises impossible : $($_.Exception.Message)"
}

foreach ($dc in @($dc01, $dc02)) {
    if ($autorises -contains $dc.FQDN.ToLower() -or $autorises -contains $dc.FQDN) {
        Write-YanixLog SKIP "$($dc.Hostname) deja autorise dans l'AD"
        continue
    }

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : autorisation DHCP de $($dc.Hostname) ($($dc.IP)) simulee"
        continue
    }

    try {
        Add-DhcpServerInDC -DnsName $dc.FQDN -IPAddress $dc.IP -ErrorAction Stop
        Write-YanixLog OK "$($dc.Hostname) autorise dans l'AD comme serveur DHCP"
    } catch {
        Write-YanixLog ERR "Echec autorisation $($dc.Hostname) : $($_.Exception.Message)"
    }
}

# Notification "post-install" sur DC-01 (suppresse le warning Server Manager)
if (-not $script:YanixContext.DryRun) {
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue
        $null = netsh dhcp add securitygroups 2>$null
    } catch {}
}

# ============================================================================
# PHASE 3 - CREATION/VERIFICATION DE L'ETENDUE
# ============================================================================
Write-YanixLog STEP "=== PHASE 3/6 : Etendue $($etendue.Nom) ($($etendue.Id)) ==="

$scopeExiste = $false
try {
    $scopeExiste = $null -ne (Get-DhcpServerv4Scope -ScopeId $etendue.Id -ErrorAction SilentlyContinue)
} catch {}

if ($scopeExiste) {
    Write-YanixLog SKIP "Etendue $($etendue.Id) ($($etendue.Nom)) deja presente"
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation etendue $($etendue.Id) simulee"
    } else {
        try {
            Add-DhcpServerv4Scope -Name $etendue.Nom `
                                  -StartRange $etendue.Plage.Debut `
                                  -EndRange $etendue.Plage.Fin `
                                  -SubnetMask $etendue.MasqueReseau `
                                  -State Active `
                                  -LeaseDuration (New-TimeSpan -Seconds $etendue.DureeBail) `
                                  -Description "Postes utilisateurs VLAN10 - servi via relais OPNsense" `
                                  -ErrorAction Stop
            Write-YanixLog OK "Etendue creee : $($etendue.Id) ($($etendue.Plage.Debut) - $($etendue.Plage.Fin))"
        } catch {
            Write-YanixLog ERR "Echec creation etendue : $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# PHASE 4 - OPTIONS DE L'ETENDUE (passerelle, DNS x2, domaine)
# ============================================================================
Write-YanixLog STEP "=== PHASE 4/6 : Options DHCP de l'etendue ==="

if ($script:YanixContext.DryRun) {
    Write-YanixLog INFO "DRY-RUN : configuration des options 3 (passerelle), 6 (DNS x2), 15 (domaine) simulee"
} else {
    try {
        # Option 3 : passerelle
        Set-DhcpServerv4OptionValue -ScopeId $etendue.Id -Router $etendue.Passerelle -Force -ErrorAction Stop
        Write-YanixLog OK "Option 3 (Routeur) : $($etendue.Passerelle)"

        # Option 6 : serveurs DNS (les 2 DC)
        Set-DhcpServerv4OptionValue -ScopeId $etendue.Id -DnsServer $etendue.ServeursDNS -Force -ErrorAction Stop
        Write-YanixLog OK "Option 6 (Serveurs DNS) : $($etendue.ServeursDNS -join ', ')"

        # Option 15 : nom de domaine
        Set-DhcpServerv4OptionValue -ScopeId $etendue.Id -DnsDomain $etendue.SuffixeDNS -Force -ErrorAction Stop
        Write-YanixLog OK "Option 15 (Domaine DNS) : $($etendue.SuffixeDNS)"
    } catch {
        Write-YanixLog ERR "Echec configuration options : $($_.Exception.Message)"
    }
}

# ============================================================================
# PHASE 5 - MISE A JOUR DYNAMIQUE DNS + OPTION 81
# ============================================================================
Write-YanixLog STEP "=== PHASE 5/6 : Mise a jour dynamique DNS (option 81) ==="

if ($script:YanixContext.DryRun) {
    Write-YanixLog INFO "DRY-RUN : activation DNS dynamique simulee"
} else {
    try {
        Set-DhcpServerv4DnsSetting -ScopeId $etendue.Id `
                                   -DynamicUpdates Always `
                                   -DeleteDnsRROnLeaseExpiry $true `
                                   -UpdateDnsRRForOlderClients $true `
                                   -ErrorAction Stop
        Write-YanixLog OK "DNS dynamique active (mise a jour A + PTR, suppression au bail expire)"
    } catch {
        Write-YanixLog ERR "Echec activation DNS dynamique : $($_.Exception.Message)"
    }
}

# ============================================================================
# PHASE 6 - FAILOVER LOADBALANCE 50/50 (MCLT 5 min)
# ============================================================================
Write-YanixLog STEP "=== PHASE 6/6 : Failover DHCP $($failover.Nom) ==="

$failoverExiste = $false
try {
    $failoverExiste = $null -ne (Get-DhcpServerv4Failover -Name $failover.Nom -ErrorAction SilentlyContinue)
} catch {}

if ($failoverExiste) {
    # Existe : vérifier que les paramètres sont conformes
    try {
        $current = Get-DhcpServerv4Failover -Name $failover.Nom -ErrorAction Stop
        $changes = @()

        if ($current.Mode -ne $failover.Mode) {
            $changes += "Mode : $($current.Mode) -> $($failover.Mode)"
        }
        if ($current.LoadBalancePercent -ne $failover.LoadBalancePercent) {
            $changes += "LoadBalancePercent : $($current.LoadBalancePercent) -> $($failover.LoadBalancePercent)"
        }
        $mcltAttendu = [TimeSpan]::Parse($failover.MaxClientLeadTime)
        if ($current.MaxClientLeadTime -ne $mcltAttendu) {
            $changes += "MCLT : $($current.MaxClientLeadTime) -> $mcltAttendu"
        }

        if ($changes.Count -eq 0) {
            Write-YanixLog SKIP "Failover $($failover.Nom) deja conforme"
        } else {
            if ($script:YanixContext.DryRun) {
                Write-YanixLog INFO "DRY-RUN : ajustement Failover simule : $($changes -join ' ; ')"
            } else {
                Set-DhcpServerv4Failover -Name $failover.Nom `
                                         -Mode $failover.Mode `
                                         -LoadBalancePercent $failover.LoadBalancePercent `
                                         -MaxClientLeadTime $mcltAttendu `
                                         -AutoStateTransition $failover.AutoStateTransition `
                                         -Force -ErrorAction Stop
                Write-YanixLog OK "Failover ajuste : $($changes -join ' ; ')"
            }
        }
    } catch {
        Write-YanixLog WARN "Verification Failover : $($_.Exception.Message)"
    }
} else {
    # N'existe pas : on le crée
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation Failover $($failover.Nom) simulee"
    } else {
        try {
            Add-DhcpServerv4Failover -ComputerName $dc01.FQDN `
                                     -PartnerServer $dc02.FQDN `
                                     -Name $failover.Nom `
                                     -ScopeId $etendue.Id `
                                     -Mode $failover.Mode `
                                     -LoadBalancePercent $failover.LoadBalancePercent `
                                     -MaxClientLeadTime ([TimeSpan]::Parse($failover.MaxClientLeadTime)) `
                                     -SharedSecret $MotDePassePartage `
                                     -AutoStateTransition $failover.AutoStateTransition `
                                     -Force -ErrorAction Stop
            Write-YanixLog OK "Failover cree : $($failover.Nom) [$($failover.Mode) $($failover.LoadBalancePercent)/$([int](100-$failover.LoadBalancePercent))]"
            Write-YanixLog INFO "Secret partage Failover : (genere aleatoirement, $($MotDePassePartage.Length) chars)"
        } catch {
            Write-YanixLog ERR "Echec creation Failover : $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# TEST POST-DEPLOIEMENT
# ============================================================================

function Test-Bootstrap-DHCP {
    <#
    .SYNOPSIS
        Verifie que le DHCP est correctement deploye sur les 2 DC
    #>
    Write-YanixLog STEP "=== Test post-deploiement : Bootstrap DHCP ==="

    $errors = @()

    # 1. Les 2 DC sont autorisés dans l'AD
    try {
        $autoDC = Get-DhcpServerInDC -ErrorAction Stop | Select-Object -ExpandProperty DnsName
        foreach ($dc in @($dc01, $dc02)) {
            if ($autoDC -contains $dc.FQDN -or $autoDC -contains $dc.FQDN.ToLower()) {
                Write-YanixLog OK "$($dc.Hostname) autorise dans l'AD"
            } else {
                Write-YanixLog ERR "$($dc.Hostname) NON autorise dans l'AD"
                $errors += "Auth DC $($dc.Hostname)"
            }
        }
    } catch {
        Write-YanixLog WARN "Verification autorisation AD impossible : $($_.Exception.Message)"
    }

    # 2. Etendue active
    try {
        $sc = Get-DhcpServerv4Scope -ScopeId $etendue.Id -ErrorAction Stop
        if ($sc.State -eq 'Active') {
            Write-YanixLog OK "Etendue $($etendue.Id) ($($etendue.Nom)) ACTIVE"
        } else {
            Write-YanixLog WARN "Etendue $($etendue.Id) etat : $($sc.State)"
        }
    } catch {
        Write-YanixLog ERR "Etendue $($etendue.Id) introuvable"
        $errors += "Etendue manquante"
    }

    # 3. Options conformes
    try {
        $opt6 = Get-DhcpServerv4OptionValue -ScopeId $etendue.Id -OptionId 6 -ErrorAction Stop
        if ($opt6.Value.Count -eq $etendue.ServeursDNS.Count) {
            Write-YanixLog OK "Option 6 (DNS) : $($opt6.Value.Count) serveur(s) configures"
        } else {
            Write-YanixLog WARN "Option 6 : $($opt6.Value.Count) DNS au lieu de $($etendue.ServeursDNS.Count) attendus"
        }
    } catch {
        Write-YanixLog WARN "Lecture option 6 : $($_.Exception.Message)"
    }

    # 4. Failover OK
    try {
        $fo = Get-DhcpServerv4Failover -Name $failover.Nom -ErrorAction Stop
        if ($fo.State -eq 'Normal') {
            Write-YanixLog OK "Failover $($fo.Name) en etat NORMAL (Mode=$($fo.Mode), MCLT=$($fo.MaxClientLeadTime))"
        } else {
            Write-YanixLog WARN "Failover etat : $($fo.State)"
        }
    } catch {
        Write-YanixLog ERR "Failover $($failover.Nom) introuvable"
        $errors += "Failover manquant"
    }

    if ($errors.Count -eq 0) {
        Write-YanixLog OK "Verification post-deploiement REUSSIE"
        return $true
    } else {
        Write-YanixLog WARN "Verification post-deploiement avec $($errors.Count) erreur(s)"
        return $false
    }
}

if ($config.Tests.ActiverApresExecution) {
    Test-Bootstrap-DHCP | Out-Null
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
