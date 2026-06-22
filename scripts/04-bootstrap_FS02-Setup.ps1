<#
.SYNOPSIS
    Bootstrap complet de SRV-FS-02 (serveur de fichiers réplica)
    Conforme cadre prod-ready E6 - Microsoft + ANSSI

.DESCRIPTION
    Script idempotent en 2 passes, détection automatique de l'état :

    PASSE 1 (machine hors domaine) :
      1. Renommage des cartes réseau (LAN_SERVERS, et optionnellement LAN_BACKUP)
      2. Configuration des IP statiques + DNS (vers les 2 DC)
      3. Désactivation IPv6 sur les cartes
      4. Renommage de la machine en SRV-FS-02
      5. Jonction au domaine yanixlabs.lan
      6. Reboot automatique
    -> Au reboot, se relogger en YANIXLABS\Administrateur et relancer le script

    PASSE 2 (machine jointe au domaine) :
      7. Installation des rôles FS, DFS-N, DFS-R, FSRM, RSAT-DFS
      8. Démontage du CD-ROM en Z:
      9. Initialisation + formatage du disque DATA en D: NTFS 64KB
      10. Création de la racine D:\Partages
      11. Test post-deploiement complet

.PARAMETER DryRun
    Simulation (ne modifie pas la config réseau, ne joint pas le domaine, ne formate pas)

.PARAMETER WithBackupNic
    Active la configuration de la 2e carte réseau LAN_BACKUP (réseau dédié backup)

.PARAMETER ServersMAC
    MAC address de la carte SERVERS (optionnel, sinon détection par index)

.PARAMETER BackupMAC
    MAC address de la carte BACKUP (optionnel)

.EXAMPLE
    .\04-bootstrap_FS02-Setup.ps1 -DryRun
    Simulation (utile pour vérifier l'état actuel)

.EXAMPLE
    .\04-bootstrap_FS02-Setup.ps1
    Bootstrap réel (interactif pour le mot de passe domaine si Passe 1)

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : SRV-FS-02 (script lancé directement sur cette machine)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [switch]$WithBackupNic,
    [string]$ServersMAC,
    [string]$BackupMAC
)

# ============================================================================
# CHARGEMENT DE LA BIBLIOTHEQUE COMMUNE
# ============================================================================
. $PSScriptRoot\_common\Common.ps1

Initialize-YanixContexte -ScriptName $MyInvocation.MyCommand.Name -DryRun:$DryRun

# ============================================================================
# CONFIGURATION LOCALE
# ============================================================================
$config = Get-YanixConfig
$cible  = $config.Serveurs.FS02
$dc01   = $config.Serveurs.DC01
$dc02   = $config.Serveurs.DC02
$dnsServeurs = @($dc01.IP, $dc02.IP)

$targetHostname = $cible.Hostname
$domain         = $config.Domain
$domainNetBIOS  = $config.DomainNetBIOS

# Réseau LAN_SERVERS (toujours)
$serversIP     = $cible.IP
$serversPrefix = 24
$serversGW     = $config.VLANs.SRV.Passerelle

# Réseau LAN_BACKUP (optionnel via -WithBackupNic)
$backupIP     = '10.0.50.21'
$backupPrefix = 24

# ============================================================================
# PRE-FLIGHT CHECKS (adaptes a la passe)
# ============================================================================
Test-YanixPrerequis -Required Admin -Stop

$isDomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
$currentHostname = $env:COMPUTERNAME

Write-YanixLog INFO "Hostname actuel : $currentHostname"
Write-YanixLog INFO "Joint au domaine : $isDomainJoined"

# ============================================================================
# HELPER : recuperation de la carte reseau cible
# ============================================================================

function Get-YanixCarteReseau {
    param([string]$MacAddress, [int]$Ordre)

    if ($MacAddress) {
        $mac = $MacAddress.Replace(':', '-').ToUpper()
        return Get-NetAdapter | Where-Object { $_.MacAddress -eq $mac } | Select-Object -First 1
    }
    $physiques = Get-NetAdapter | Where-Object { $_.HardwareInterface -and -not $_.Virtual } | Sort-Object IfIndex
    return $physiques | Select-Object -Index $Ordre
}

# ============================================================================
# PASSE 1 : RESEAU + JONCTION DOMAINE (machine hors domaine)
# ============================================================================

if (-not $isDomainJoined) {
    Write-YanixLog STEP "=== PASSE 1 : Configuration reseau et jonction domaine ==="

    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : actions Passe 1 simulees (rien ne sera modifie)"
    }

    # --- 1.1 Detection des cartes ---
    $carteServeurs = Get-YanixCarteReseau -MacAddress $ServersMAC -Ordre 0
    if (-not $carteServeurs) {
        Write-YanixLog ERR "Carte SERVERS introuvable"
        exit (Show-YanixRecap)
    }
    Write-YanixLog OK "Carte SERVERS detectee : $($carteServeurs.Name) [$($carteServeurs.MacAddress)]"

    $carteBackup = $null
    if ($WithBackupNic) {
        $carteBackup = Get-YanixCarteReseau -MacAddress $BackupMAC -Ordre 1
        if (-not $carteBackup) {
            Write-YanixLog ERR "Option -WithBackupNic active mais carte BACKUP introuvable"
            exit (Show-YanixRecap)
        }
        Write-YanixLog OK "Carte BACKUP detectee : $($carteBackup.Name) [$($carteBackup.MacAddress)]"
    }

    # --- 1.2 Renommage des cartes ---
    if ($carteServeurs.Name -ne 'LAN_SERVERS') {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : renommage $($carteServeurs.Name) -> LAN_SERVERS"
        } else {
            Rename-NetAdapter -Name $carteServeurs.Name -NewName 'LAN_SERVERS'
            Write-YanixLog OK "Carte renommee : LAN_SERVERS"
        }
    } else {
        Write-YanixLog SKIP "Carte LAN_SERVERS deja nommee correctement"
    }

    if ($WithBackupNic -and $carteBackup.Name -ne 'LAN_BACKUP') {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : renommage $($carteBackup.Name) -> LAN_BACKUP"
        } else {
            Rename-NetAdapter -Name $carteBackup.Name -NewName 'LAN_BACKUP'
            Write-YanixLog OK "Carte renommee : LAN_BACKUP"
        }
    }

    # --- 1.3 Configuration IP LAN_SERVERS ---
    $deja = Get-NetIPAddress -InterfaceAlias 'LAN_SERVERS' -IPAddress $serversIP -ErrorAction SilentlyContinue
    if ($deja) {
        Write-YanixLog SKIP "IP $serversIP deja configuree sur LAN_SERVERS"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : config IP $serversIP/$serversPrefix GW $serversGW sur LAN_SERVERS"
        } else {
            # Purge IPs existantes
            Get-NetIPAddress -InterfaceAlias 'LAN_SERVERS' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceAlias 'LAN_SERVERS' -ErrorAction SilentlyContinue |
                Where-Object DestinationPrefix -eq '0.0.0.0/0' |
                Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

            New-NetIPAddress -InterfaceAlias 'LAN_SERVERS' -IPAddress $serversIP `
                             -PrefixLength $serversPrefix -DefaultGateway $serversGW | Out-Null
            Write-YanixLog OK "IP $serversIP/$serversPrefix + GW $serversGW configures"
        }
    }

    if (-not $script:YanixContext.DryRun) {
        Set-DnsClientServerAddress -InterfaceAlias 'LAN_SERVERS' -ServerAddresses $dnsServeurs
        Disable-NetAdapterBinding -Name 'LAN_SERVERS' -ComponentID ms_tcpip6
    }
    Write-YanixLog OK "DNS configures ($($dnsServeurs -join ', ')) + IPv6 desactive sur LAN_SERVERS"

    # --- 1.4 IP LAN_BACKUP (optionnel) ---
    if ($WithBackupNic) {
        $dejaB = Get-NetIPAddress -InterfaceAlias 'LAN_BACKUP' -IPAddress $backupIP -ErrorAction SilentlyContinue
        if ($dejaB) {
            Write-YanixLog SKIP "IP $backupIP deja configuree sur LAN_BACKUP"
        } else {
            if ($script:YanixContext.DryRun) {
                Write-YanixLog INFO "DRY-RUN : config IP $backupIP/$backupPrefix sur LAN_BACKUP (sans GW)"
            } else {
                Get-NetIPAddress -InterfaceAlias 'LAN_BACKUP' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                New-NetIPAddress -InterfaceAlias 'LAN_BACKUP' -IPAddress $backupIP -PrefixLength $backupPrefix | Out-Null
                Disable-NetAdapterBinding -Name 'LAN_BACKUP' -ComponentID ms_tcpip6
                Write-YanixLog OK "IP $backupIP/$backupPrefix sur LAN_BACKUP (pas de GW, IPv6 off)"
            }
        }
    }

    # --- 1.5 Test connectivite + jonction ---
    if (-not $script:YanixContext.DryRun) {
        Write-YanixLog STEP "Tests connectivite vers DC-01 avant jonction"
        if (-not (Test-YanixConnectivite -ComputerName $dc01.IP -Port 53 -TimeoutMs 3000)) {
            Write-YanixLog ERR "DC-01 ($($dc01.IP)) injoignable, jonction annulee"
            exit (Show-YanixRecap)
        }
        Write-YanixLog OK "DC-01 joignable, jonction du domaine $domain..."

        $cred = Get-Credential -UserName "$domainNetBIOS\Administrateur" -Message "Compte admin du domaine $domain"
        try {
            Add-Computer -DomainName $domain -NewName $targetHostname -Credential $cred -Restart -Force
            Write-YanixLog OK "Jonction reussie, redemarrage en cours..."
        } catch {
            Write-YanixLog ERR "Echec jonction : $($_.Exception.Message)"
            exit (Show-YanixRecap)
        }
    } else {
        Write-YanixLog INFO "DRY-RUN : jonction au domaine $domain en tant que $targetHostname simulee"
    }

    exit (Show-YanixRecap)
}

# ============================================================================
# PASSE 2 : ROLES + DISQUE + RACINE PARTAGES (machine jointe)
# ============================================================================

Write-YanixLog STEP "=== PASSE 2 : Roles, disque et racine partages ==="

# --- 2.1 Verification hostname ---
if ($currentHostname -ne $targetHostname) {
    Write-YanixLog WARN "Hostname '$currentHostname' != attendu '$targetHostname'"
    if (-not $script:YanixContext.DryRun) {
        Rename-Computer -NewName $targetHostname -Restart -Force
        Write-YanixLog OK "Renommage effectue, redemarrage en cours..."
        exit (Show-YanixRecap)
    } else {
        Write-YanixLog INFO "DRY-RUN : renommage en $targetHostname simule"
    }
}

# --- 2.2 Installation des roles ---
Write-YanixLog STEP "Phase 2.2 : Installation des roles FS / DFS / FSRM"
$rolesAttendus = @('FS-FileServer', 'FS-Resource-Manager', 'FS-DFS-Namespace', 'FS-DFS-Replication', 'RSAT-DFS-Mgmt-Con')
foreach ($f in $rolesAttendus) {
    $installed = (Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue).Installed
    if ($installed) {
        Write-YanixLog SKIP "Role $f deja installe"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : installation role $f simulee"
        } else {
            try {
                Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
                Write-YanixLog OK "Role $f installe"
            } catch {
                Write-YanixLog ERR "Echec installation $f : $($_.Exception.Message)"
            }
        }
    }
}

# --- 2.3 Demonter le CD-ROM en Z: ---
Write-YanixLog STEP "Phase 2.3 : Demontage du CD-ROM en Z:"
$cd = Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType=5' -ErrorAction SilentlyContinue
if ($cd -and $cd.DriveLetter -ne 'Z:') {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : passage du CD-ROM ($($cd.DriveLetter)) en Z: simule"
    } else {
        Set-CimInstance -InputObject $cd -Property @{DriveLetter = 'Z:'} -ErrorAction SilentlyContinue
        Write-YanixLog OK "CD-ROM passe en Z:"
    }
} elseif ($cd) {
    Write-YanixLog SKIP "CD-ROM deja en Z:"
} else {
    Write-YanixLog SKIP "Aucun CD-ROM detecte"
}

# --- 2.4 Disque DATA -> D: ---
Write-YanixLog STEP "Phase 2.4 : Disque DATA -> D:"
$disk1 = Get-Disk -Number 1 -ErrorAction SilentlyContinue
if (-not $disk1) {
    Write-YanixLog ERR "Disk 1 introuvable. Ajouter un 2e disque dans VMware Fusion."
} else {
    if ($disk1.PartitionStyle -eq 'RAW') {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : initialisation Disk 1 GPT simulee"
        } else {
            Initialize-Disk -Number 1 -PartitionStyle GPT
            Write-YanixLog OK "Disk 1 initialise GPT"
        }
    } else {
        Write-YanixLog SKIP "Disk 1 deja initialise ($($disk1.PartitionStyle))"
    }

    $volD = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    if ($volD -and $volD.FileSystemLabel -eq 'DATA') {
        Write-YanixLog SKIP "Volume D: DATA NTFS deja present ($(($volD.Size / 1GB).ToString('N1')) Go)"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : creation partition + formatage D: NTFS 64KB simules"
        } else {
            try {
                $part = Get-Partition -DiskNumber 1 -ErrorAction SilentlyContinue | Where-Object Type -eq 'Basic' | Select-Object -First 1
                if (-not $part) {
                    $part = New-Partition -DiskNumber 1 -DriveLetter D -UseMaximumSize
                    Write-YanixLog OK "Partition creee -> D:"
                } elseif (-not $part.DriveLetter) {
                    $part | Set-Partition -NewDriveLetter D
                    Write-YanixLog OK "Lettre D: assignee"
                }
                Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel 'DATA' -AllocationUnitSize 64KB -Confirm:$false -Force | Out-Null
                Write-YanixLog OK "Volume D: formate NTFS 64KB / Label DATA"
            } catch {
                Write-YanixLog ERR "Echec formatage : $($_.Exception.Message)"
            }
        }
    }
}

# --- 2.5 Racine D:\Partages ---
Write-YanixLog STEP "Phase 2.5 : Racine D:\Partages"
if (Test-Path 'D:\Partages') {
    Write-YanixLog SKIP "Dossier D:\Partages deja present"
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation D:\Partages simulee (DFS-R repliquera depuis FS-01)"
    } else {
        New-Item -Path 'D:\Partages' -ItemType Directory -Force | Out-Null
        Write-YanixLog OK "Dossier D:\Partages cree (vide - DFS-R repliquera depuis FS-01)"
    }
}

# ============================================================================
# TEST POST-DEPLOIEMENT
# ============================================================================

function Test-Bootstrap-FS02 {
    Write-YanixLog STEP "=== Test post-deploiement : Bootstrap FS-02 ==="
    $errors = @()

    # 1. Hostname et domaine
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain -and $cs.Domain -eq $domain) {
        Write-YanixLog OK "Machine jointe au domaine $domain"
    } else {
        Write-YanixLog ERR "Machine NON jointe au bon domaine (current: $($cs.Domain), attendu: $domain)"
        $errors += 'Domain join'
    }

    if ($env:COMPUTERNAME -eq $targetHostname) {
        Write-YanixLog OK "Hostname correct : $targetHostname"
    } else {
        Write-YanixLog WARN "Hostname : $env:COMPUTERNAME (attendu: $targetHostname)"
    }

    # 2. IP correcte
    $ip = Get-NetIPAddress -InterfaceAlias 'LAN_SERVERS' -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ip.IPAddress -eq $serversIP) {
        Write-YanixLog OK "IP LAN_SERVERS = $serversIP"
    } else {
        Write-YanixLog WARN "IP LAN_SERVERS = $($ip.IPAddress) (attendu: $serversIP)"
    }

    # 3. Roles installes
    foreach ($f in $rolesAttendus) {
        $i = (Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue).Installed
        if ($i) {
            Write-YanixLog OK "Role $f installe"
        } else {
            Write-YanixLog ERR "Role $f MANQUANT"
            $errors += $f
        }
    }

    # 4. Volume D:
    $v = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    if ($v -and $v.FileSystemLabel -eq 'DATA' -and $v.FileSystem -eq 'NTFS') {
        Write-YanixLog OK "Volume D: DATA NTFS ($(($v.Size / 1GB).ToString('N1')) Go, $(($v.SizeRemaining / 1GB).ToString('N1')) Go libres)"
    } else {
        Write-YanixLog ERR "Volume D: DATA NTFS manquant ou incorrect"
        $errors += 'Volume D:'
    }

    # 5. Connectivite vers DC + FS-01
    foreach ($srv in @($dc01, $config.Serveurs.FS01)) {
        if (Test-YanixConnectivite -ComputerName $srv.IP -Port 445 -TimeoutMs 2000) {
            Write-YanixLog OK "$($srv.Hostname) ($($srv.IP)) joignable"
        } else {
            Write-YanixLog WARN "$($srv.Hostname) injoignable"
        }
    }

    if ($errors.Count -eq 0) {
        Write-YanixLog OK "Verification post-deploiement REUSSIE - FS-02 pret pour DFS"
        return $true
    } else {
        Write-YanixLog WARN "Verification avec $($errors.Count) erreur(s)"
        return $false
    }
}

if ($config.Tests.ActiverApresExecution) {
    Test-Bootstrap-FS02 | Out-Null
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
