<#
.SYNOPSIS
    Bootstrap complet de SRV-BCK-01 (serveur de sauvegarde centralise)
    Conforme cadre prod-ready E6

.DESCRIPTION
    Script idempotent en 2 passes (auto-détection) :

    PASSE 1 (machine hors domaine) :
      1. Renommage cartes réseau (LAN_SERVERS et optionnellement LAN_BACKUP)
      2. Configuration IP statique + DNS (2 DC)
      3. Désactivation IPv6
      4. Renommage en SRV-BCK-01 + jonction domaine
      5. Reboot

    PASSE 2 (machine jointe au domaine) :
      6. Installation du rôle Windows Server Backup + outils
      7. Démontage du CD-ROM en Z:
      8. Initialisation + formatage du disque BACKUPS en D: NTFS 64KB
      9. Création racine D:\Backups + partage SMB \\SRV-BCK-01\Backups (cible sauvegardes)
      10. Création racine D:\Logs + partage SMB caché \\SRV-BCK-01\Logs$ (télémétrie scripts)
      11. ACL NTFS strictes sur les 2 dossiers (Domain Admins + SYSTEM + comptes machine FS/DC)
      12. Test post-deploiement

.PARAMETER DryRun
    Simulation sans modification

.PARAMETER WithBackupNic
    Active la 2e carte LAN_BACKUP (réseau dédié 10.0.50.0/24)

.EXAMPLE
    .\07-bootstrap_BCK01-Setup.ps1 -DryRun

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Cible   : Exécuté SUR SRV-BCK-01
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
# PRE-FLIGHT
# ============================================================================
Test-YanixPrerequis -Required Admin -Stop
$config = Get-YanixConfig

$cible          = $config.Serveurs.BCK01
$dc01           = $config.Serveurs.DC01
$dc02           = $config.Serveurs.DC02
$dnsServeurs    = @($dc01.IP, $dc02.IP)
$targetHostname = $cible.Hostname
$domain         = $config.Domain
$domainNetBIOS  = $config.DomainNetBIOS

# Réseau LAN_SERVERS
$serversIP     = $cible.IP
$serversPrefix = 24
$serversGW     = $config.VLANs.SRV.Passerelle

# Réseau LAN_BACKUP (optionnel)
$backupIP     = '10.0.50.30'
$backupPrefix = 24

# Cibles de stockage
$backupRoot       = 'D:\Backups'
$logsRoot         = 'D:\Logs'
$backupShareName  = 'Backups'
$logsShareName    = 'Logs$'   # partage caché pour télémétrie

# Comptes autorisés sur Backups$ (les sources de backup)
$allowedBackupSources = @('SRV-DC-01', 'SRV-DC-02', 'SRV-FS-01', 'SRV-FS-02')

$isDomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
$currentHostname = $env:COMPUTERNAME

Write-YanixLog INFO "Hostname actuel : $currentHostname"
Write-YanixLog INFO "Joint au domaine : $isDomainJoined"

# ============================================================================
# HELPERS LOCAUX
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

function Resolve-YanixSid {
    param([string]$Sid)
    try { return (New-Object System.Security.Principal.SecurityIdentifier $Sid).Translate([System.Security.Principal.NTAccount]).Value }
    catch { return $null }
}

# ============================================================================
# PASSE 1 : RESEAU + JONCTION DOMAINE (machine hors domaine)
# ============================================================================

if (-not $isDomainJoined) {
    Write-YanixLog STEP "=== PASSE 1 : Configuration reseau et jonction domaine ==="

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

    # Renommage carte SERVERS
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

    # IP LAN_SERVERS
    $deja = Get-NetIPAddress -InterfaceAlias 'LAN_SERVERS' -IPAddress $serversIP -ErrorAction SilentlyContinue
    if ($deja) {
        Write-YanixLog SKIP "IP $serversIP deja configuree sur LAN_SERVERS"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : config IP $serversIP/$serversPrefix GW $serversGW sur LAN_SERVERS"
        } else {
            Get-NetIPAddress -InterfaceAlias 'LAN_SERVERS' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceAlias 'LAN_SERVERS' -ErrorAction SilentlyContinue |
                Where-Object DestinationPrefix -eq '0.0.0.0/0' |
                Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceAlias 'LAN_SERVERS' -IPAddress $serversIP -PrefixLength $serversPrefix -DefaultGateway $serversGW | Out-Null
            Write-YanixLog OK "IP $serversIP/$serversPrefix + GW $serversGW configures"
        }
    }

    if (-not $script:YanixContext.DryRun) {
        Set-DnsClientServerAddress -InterfaceAlias 'LAN_SERVERS' -ServerAddresses $dnsServeurs
        Disable-NetAdapterBinding -Name 'LAN_SERVERS' -ComponentID ms_tcpip6
    }
    Write-YanixLog OK "DNS configures + IPv6 desactive sur LAN_SERVERS"

    # IP LAN_BACKUP optionnel
    if ($WithBackupNic) {
        $dejaB = Get-NetIPAddress -InterfaceAlias 'LAN_BACKUP' -IPAddress $backupIP -ErrorAction SilentlyContinue
        if ($dejaB) {
            Write-YanixLog SKIP "IP $backupIP deja configuree sur LAN_BACKUP"
        } else {
            if ($script:YanixContext.DryRun) {
                Write-YanixLog INFO "DRY-RUN : config IP $backupIP/$backupPrefix sur LAN_BACKUP"
            } else {
                Get-NetIPAddress -InterfaceAlias 'LAN_BACKUP' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                New-NetIPAddress -InterfaceAlias 'LAN_BACKUP' -IPAddress $backupIP -PrefixLength $backupPrefix | Out-Null
                Disable-NetAdapterBinding -Name 'LAN_BACKUP' -ComponentID ms_tcpip6
                Write-YanixLog OK "IP $backupIP/$backupPrefix sur LAN_BACKUP (pas de GW, IPv6 off)"
            }
        }
    }

    # Test + jonction
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
            Write-YanixLog OK "Jonction reussie, redemarrage..."
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
# PASSE 2 : ROLE WSB + DISQUE + PARTAGES (machine jointe)
# ============================================================================

Write-YanixLog STEP "=== PASSE 2 : Role WSB, disque et partages ==="

# 2.1 Verification hostname
if ($currentHostname -ne $targetHostname) {
    Write-YanixLog WARN "Hostname '$currentHostname' != attendu '$targetHostname'"
    if (-not $script:YanixContext.DryRun) {
        Rename-Computer -NewName $targetHostname -Restart -Force
        Write-YanixLog OK "Renommage effectue, redemarrage..."
        exit (Show-YanixRecap)
    }
}

# 2.2 Installation du role Windows Server Backup
Write-YanixLog STEP "Phase 2.2 : Installation Windows Server Backup"
$wsb = Get-WindowsFeature -Name Windows-Server-Backup -ErrorAction SilentlyContinue
if ($wsb.Installed) {
    Write-YanixLog SKIP "Role Windows-Server-Backup deja installe"
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : installation Windows-Server-Backup simulee"
    } else {
        try {
            Install-WindowsFeature -Name Windows-Server-Backup -IncludeManagementTools | Out-Null
            Write-YanixLog OK "Role Windows-Server-Backup installe"
        } catch {
            Write-YanixLog ERR "Echec installation WSB : $($_.Exception.Message)"
        }
    }
}

# 2.3 Demonter CD-ROM en Z:
Write-YanixLog STEP "Phase 2.3 : Demontage du CD-ROM en Z:"
$cd = Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType=5' -ErrorAction SilentlyContinue
if ($cd -and $cd.DriveLetter -ne 'Z:') {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : passage CD-ROM en Z: simule"
    } else {
        Set-CimInstance -InputObject $cd -Property @{DriveLetter = 'Z:'} -ErrorAction SilentlyContinue
        Write-YanixLog OK "CD-ROM passe en Z:"
    }
} elseif ($cd) {
    Write-YanixLog SKIP "CD-ROM deja en Z:"
} else {
    Write-YanixLog SKIP "Aucun CD-ROM detecte"
}

# 2.4 Disque BACKUPS -> D:
Write-YanixLog STEP "Phase 2.4 : Disque BACKUPS -> D:"
$disk1 = Get-Disk -Number 1 -ErrorAction SilentlyContinue
if (-not $disk1) {
    Write-YanixLog ERR "Disk 1 introuvable. Ajouter un 2e disque dans VMware Fusion."
} else {
    if ($disk1.PartitionStyle -eq 'RAW') {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : Initialize-Disk GPT simule"
        } else {
            Initialize-Disk -Number 1 -PartitionStyle GPT
            Write-YanixLog OK "Disk 1 initialise GPT"
        }
    } else {
        Write-YanixLog SKIP "Disk 1 deja initialise ($($disk1.PartitionStyle))"
    }

    $volD = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    if ($volD -and $volD.FileSystemLabel -eq 'BACKUPS') {
        Write-YanixLog SKIP "Volume D: BACKUPS NTFS deja present ($(($volD.Size / 1GB).ToString('N1')) Go)"
    } else {
        if ($script:YanixContext.DryRun) {
            Write-YanixLog INFO "DRY-RUN : creation partition + formatage D: NTFS 64KB BACKUPS simules"
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
                Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel 'BACKUPS' -AllocationUnitSize 64KB -Confirm:$false -Force | Out-Null
                Write-YanixLog OK "Volume D: formate NTFS 64KB / Label BACKUPS"
            } catch {
                Write-YanixLog ERR "Echec formatage : $($_.Exception.Message)"
            }
        }
    }
}

# 2.5 Resolution des SIDs (pour les ACL)
$authUsers   = Resolve-YanixSid 'S-1-5-11'
$localSystem = Resolve-YanixSid 'S-1-5-18'
try {
    $domainSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.AccountDomainSid).Value
    $domainAdmins = Resolve-YanixSid "$domainSid-512"
} catch {
    $domainAdmins = "$domainNetBIOS\Admins du domaine"
}

# ============================================================================
# 2.6 - DOSSIER + PARTAGE BACKUPS
# ============================================================================
Write-YanixLog STEP "Phase 2.6 : Dossier + partage SMB '$backupShareName' ($backupRoot)"

# 2.6.a Dossier
if (Test-Path $backupRoot) {
    Write-YanixLog SKIP "Dossier $backupRoot deja present"
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation $backupRoot simulee"
    } else {
        New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
        Write-YanixLog OK "Dossier $backupRoot cree"
    }
}

# 2.6.b ACL NTFS Backups
if ((Test-Path $backupRoot) -and -not $script:YanixContext.DryRun) {
    try {
        $acl = Get-Acl $backupRoot
        $acl.SetAccessRuleProtection($true, $false)
        @($acl.Access | Where-Object { -not $_.IsInherited }) |
            ForEach-Object { [void]$acl.RemoveAccessRule($_) }

        $rules = @(
            @{ Id = $domainAdmins;            Rights = 'FullControl' }
            @{ Id = $localSystem;             Rights = 'FullControl' }
            @{ Id = 'BUILTIN\Administrateurs'; Rights = 'FullControl'; AllowFail = $true }
        )
        foreach ($src in $allowedBackupSources) {
            $rules += @{ Id = "$domainNetBIOS\$src`$"; Rights = 'FullControl' }
        }

        foreach ($r in $rules) {
            try {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $r.Id, $r.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
                )
                $acl.AddAccessRule($rule)
            } catch { if (-not $r.AllowFail) { throw } }
        }
        Set-Acl -Path $backupRoot -AclObject $acl
        Write-YanixLog OK "ACL NTFS stricte appliquee sur $backupRoot"
    } catch {
        Write-YanixLog ERR "Echec ACL $backupRoot : $($_.Exception.Message)"
    }
}

# 2.6.c Partage SMB Backups
$existing = Get-SmbShare -Name $backupShareName -ErrorAction SilentlyContinue
if ($existing) {
    Write-YanixLog SKIP "Partage SMB '$backupShareName' deja present (-> $($existing.Path))"
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation partage '$backupShareName' simulee"
    } else {
        $fullAccess = @($domainAdmins) + ($allowedBackupSources | ForEach-Object { "$domainNetBIOS\$_`$" })
        try {
            New-SmbShare -Name $backupShareName -Path $backupRoot `
                         -FullAccess $fullAccess `
                         -Description 'Cible des sauvegardes Windows Server Backup' `
                         -ErrorAction Stop | Out-Null
            Write-YanixLog OK "Partage SMB '\\$env:COMPUTERNAME\$backupShareName' cree"
        } catch {
            Write-YanixLog ERR "Echec creation partage $backupShareName : $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# 2.7 - DOSSIER + PARTAGE LOGS$ (telemetrie centralisee)
# ============================================================================
Write-YanixLog STEP "Phase 2.7 : Dossier + partage SMB cache '$logsShareName' ($logsRoot)"

# 2.7.a Dossier
if (Test-Path $logsRoot) {
    Write-YanixLog SKIP "Dossier $logsRoot deja present"
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation $logsRoot simulee"
    } else {
        New-Item -Path $logsRoot -ItemType Directory -Force | Out-Null
        Write-YanixLog OK "Dossier $logsRoot cree"
    }
}

# 2.7.b ACL NTFS Logs
if ((Test-Path $logsRoot) -and -not $script:YanixContext.DryRun) {
    try {
        $acl = Get-Acl $logsRoot
        $acl.SetAccessRuleProtection($true, $false)
        @($acl.Access | Where-Object { -not $_.IsInherited }) |
            ForEach-Object { [void]$acl.RemoveAccessRule($_) }

        $rules = @(
            @{ Id = $domainAdmins;            Rights = 'FullControl' }
            @{ Id = $localSystem;             Rights = 'FullControl' }
            @{ Id = 'BUILTIN\Administrateurs'; Rights = 'FullControl'; AllowFail = $true }
        )
        foreach ($src in $allowedBackupSources) {
            $rules += @{ Id = "$domainNetBIOS\$src`$"; Rights = 'Modify' }
        }

        foreach ($r in $rules) {
            try {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $r.Id, $r.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
                )
                $acl.AddAccessRule($rule)
            } catch { if (-not $r.AllowFail) { throw } }
        }
        Set-Acl -Path $logsRoot -AclObject $acl
        Write-YanixLog OK "ACL NTFS stricte appliquee sur $logsRoot (FS/DC en Modify)"
    } catch {
        Write-YanixLog ERR "Echec ACL $logsRoot : $($_.Exception.Message)"
    }
}

# 2.7.c Partage SMB Logs$
$existingLogs = Get-SmbShare -Name $logsShareName -ErrorAction SilentlyContinue
if ($existingLogs) {
    Write-YanixLog SKIP "Partage SMB '$logsShareName' deja present"
} else {
    if ($script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation partage cache '$logsShareName' simulee"
    } else {
        $fullAccess = @($domainAdmins) + ($allowedBackupSources | ForEach-Object { "$domainNetBIOS\$_`$" })
        try {
            New-SmbShare -Name $logsShareName -Path $logsRoot `
                         -FullAccess $fullAccess `
                         -Description 'Telemetrie centralisee des scripts E6' `
                         -ErrorAction Stop | Out-Null
            Write-YanixLog OK "Partage SMB cache '\\$env:COMPUTERNAME\$logsShareName' cree"
        } catch {
            Write-YanixLog ERR "Echec creation partage $logsShareName : $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# TEST POST-DEPLOIEMENT
# ============================================================================

function Test-Bootstrap-BCK01 {
    Write-YanixLog STEP "=== Test post-deploiement : Bootstrap BCK-01 ==="
    $errors = @()

    # 1. Domaine + hostname
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain -and $cs.Domain -eq $domain) {
        Write-YanixLog OK "Machine jointe au domaine $domain"
    } else {
        Write-YanixLog ERR "Machine NON jointe au bon domaine"
        $errors += 'Domain'
    }
    if ($env:COMPUTERNAME -eq $targetHostname) {
        Write-YanixLog OK "Hostname : $targetHostname"
    } else {
        Write-YanixLog WARN "Hostname : $env:COMPUTERNAME (attendu: $targetHostname)"
    }

    # 2. Role WSB
    if ((Get-WindowsFeature Windows-Server-Backup -ErrorAction SilentlyContinue).Installed) {
        Write-YanixLog OK "Role Windows-Server-Backup installe"
    } else {
        Write-YanixLog ERR "Role Windows-Server-Backup MANQUANT"
        $errors += 'WSB role'
    }

    # 3. Volume D:
    $v = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    if ($v -and $v.FileSystemLabel -eq 'BACKUPS') {
        Write-YanixLog OK "Volume D: BACKUPS ($(($v.Size / 1GB).ToString('N1')) Go, $(($v.SizeRemaining / 1GB).ToString('N1')) Go libres)"
    } else {
        Write-YanixLog ERR "Volume D: BACKUPS manquant"
        $errors += 'Volume D:'
    }

    # 4. Partages SMB
    foreach ($s in @($backupShareName, $logsShareName)) {
        $sh = Get-SmbShare -Name $s -ErrorAction SilentlyContinue
        if ($sh) {
            Write-YanixLog OK "Partage SMB '$s' present (-> $($sh.Path))"
        } else {
            Write-YanixLog ERR "Partage SMB '$s' MANQUANT"
            $errors += "Partage $s"
        }
    }

    # 5. Connectivité vers DC
    if (Test-YanixConnectivite -ComputerName $dc01.IP -Port 445 -TimeoutMs 2000) {
        Write-YanixLog OK "$($dc01.Hostname) ($($dc01.IP)) joignable"
    } else {
        Write-YanixLog WARN "$($dc01.Hostname) injoignable"
    }

    if ($errors.Count -eq 0) {
        Write-YanixLog OK "Verification post-deploiement REUSSIE - BCK-01 pret"
        return $true
    } else {
        Write-YanixLog WARN "Verification avec $($errors.Count) erreur(s)"
        return $false
    }
}

if ($config.Tests.ActiverApresExecution) {
    Test-Bootstrap-BCK01 | Out-Null
}

# ============================================================================
# RECAP + EXIT
# ============================================================================
exit (Show-YanixRecap)
