<#
.SYNOPSIS
    FS-Helpers.ps1 - Helpers Système de Fichiers et ACL réutilisables

.DESCRIPTION
    Fonctions liées aux partages SMB, permissions NTFS, et application du modèle AGDLP.
    Toutes les fonctions sont idempotentes.

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR
    Version : 1.0 - 2026-06-22
    Conforme: Modèle AGDLP Microsoft + ANSSI (R.46 - ACL strictes)
#>

# ============================================================================
# PARTAGES SMB
# ============================================================================

function Test-YanixPartage {
    <#
    .SYNOPSIS
        Vérifie l'existence d'un partage SMB
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    try {
        if ($ComputerName -eq $env:COMPUTERNAME) {
            return ($null -ne (Get-SmbShare -Name $Name -ErrorAction Stop))
        } else {
            return Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                param($n) $null -ne (Get-SmbShare -Name $n -ErrorAction SilentlyContinue)
            } -ArgumentList $Name -ErrorAction Stop
        }
    } catch {
        return $false
    }
}

function New-YanixPartage {
    <#
    .SYNOPSIS
        Crée un partage SMB si inexistant (idempotent)
    .PARAMETER FullAccess
        Liste de comptes/groupes ayant FullAccess au niveau SMB
    .PARAMETER ChangeAccess
        Liste avec Change
    .PARAMETER ReadAccess
        Liste avec Read
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Description = '',
        [string[]]$FullAccess,
        [string[]]$ChangeAccess,
        [string[]]$ReadAccess,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    if (Test-YanixPartage -Name $Name -ComputerName $ComputerName) {
        Write-YanixLog SKIP "Partage SMB '$Name' deja existant sur $ComputerName"
        return
    }

    if (-not $PSCmdlet.ShouldProcess("\\$ComputerName\$Name", "Creation partage SMB")) {
        return
    }

    $createBlock = {
        param($n, $p, $d, $fa, $ca, $ra)
        if (-not (Test-Path $p)) {
            New-Item -Path $p -ItemType Directory -Force | Out-Null
        }
        $args = @{ Name = $n; Path = $p; Description = $d }
        if ($fa) { $args.FullAccess   = $fa }
        if ($ca) { $args.ChangeAccess = $ca }
        if ($ra) { $args.ReadAccess   = $ra }
        New-SmbShare @args | Out-Null
    }

    try {
        if ($ComputerName -eq $env:COMPUTERNAME) {
            & $createBlock $Name $Path $Description $FullAccess $ChangeAccess $ReadAccess
        } else {
            Invoke-Command -ComputerName $ComputerName -ScriptBlock $createBlock `
                           -ArgumentList $Name, $Path, $Description, $FullAccess, $ChangeAccess, $ReadAccess `
                           -ErrorAction Stop
        }
        Write-YanixLog OK "Partage cree : \\$ComputerName\$Name (-> $Path)"
    } catch {
        Write-YanixLog ERR "Echec creation partage \\$ComputerName\$Name : $($_.Exception.Message)"
        throw
    }
}

# ============================================================================
# ACL NTFS - APPLICATION DU MODÈLE AGDLP
# ============================================================================

function Set-YanixAclAGDLP {
    <#
    .SYNOPSIS
        Applique une ACL stricte conforme AGDLP sur un dossier
    .DESCRIPTION
        - Désactive l'héritage et supprime toutes les permissions héritées
        - Ajoute les permissions explicites :
          * Admins du domaine en FullControl
          * SYSTEM en FullControl
          * Pour chaque entrée Permissions : Groupe Domain Local avec droit NTFS adapté
    .PARAMETER Path
        Chemin du dossier (local ou UNC)
    .PARAMETER Permissions
        Hashtable[] avec @{ Identity = 'GROUPE'; Rights = 'Modify'|'ReadAndExecute'|'FullControl' }
    .EXAMPLE
        Set-YanixAclAGDLP -Path 'D:\Partages\RH' -Permissions @(
            @{ Identity = 'YANIXLABS\GDL_Partage_Ressources-Humaines_M';  Rights = 'Modify' }
            @{ Identity = 'YANIXLABS\GDL_Partage_Ressources-Humaines_L';  Rights = 'ReadAndExecute' }
            @{ Identity = 'YANIXLABS\GDL_Partage_Ressources-Humaines_CT'; Rights = 'FullControl' }
        )
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable[]]$Permissions,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$DomainNetBIOS = 'YANIXLABS'
    )

    if (-not $PSCmdlet.ShouldProcess($Path, "Application ACL AGDLP stricte")) { return }

    $applyBlock = {
        param($p, $perms, $netbios)

        if (-not (Test-Path $p)) {
            throw "Chemin inexistant : $p"
        }

        # Identités système toujours présentes
        $domainAdmins = "$netbios\Admins du domaine"
        # Fallback si traduction française manquante
        try { Resolve-DnsName . -ErrorAction SilentlyContinue | Out-Null } catch {}
        $sysAdminsEN = "$netbios\Domain Admins"

        $acl = Get-Acl -Path $p
        $acl.SetAccessRuleProtection($true, $false)   # héritage off, pas de copie héritées
        @($acl.Access | Where-Object { -not $_.IsInherited }) |
            ForEach-Object { [void]$acl.RemoveAccessRule($_) }

        # Construit la liste finale des règles
        $rules = @(
            @{ Id = 'NT AUTHORITY\SYSTEM';            Rights = 'FullControl' }
            @{ Id = 'BUILTIN\Administrateurs';        Rights = 'FullControl' }
        )
        # Tentative DA français puis anglais
        $rules += @{ Id = $domainAdmins; Rights = 'FullControl'; AllowFail = $true }
        $rules += @{ Id = $sysAdminsEN;  Rights = 'FullControl'; AllowFail = $true }
        # Permissions métier
        foreach ($perm in $perms) {
            $rules += @{ Id = $perm.Identity; Rights = $perm.Rights }
        }

        foreach ($r in $rules) {
            try {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $r.Id, $r.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
                )
                $acl.AddAccessRule($rule)
            } catch {
                if (-not $r.AllowFail) { throw }
            }
        }

        Set-Acl -Path $p -AclObject $acl
        return "OK"
    }

    try {
        if ($ComputerName -eq $env:COMPUTERNAME) {
            $r = & $applyBlock $Path $Permissions $DomainNetBIOS
        } else {
            $r = Invoke-Command -ComputerName $ComputerName -ScriptBlock $applyBlock `
                                -ArgumentList $Path, $Permissions, $DomainNetBIOS -ErrorAction Stop
        }
        Write-YanixLog OK "ACL AGDLP appliquee sur $Path ($($Permissions.Count) groupes)"
    } catch {
        Write-YanixLog ERR "Echec ACL AGDLP sur $Path : $($_.Exception.Message)"
        throw
    }
}

function Test-YanixAclConformeAGDLP {
    <#
    .SYNOPSIS
        Vérifie qu'une ACL respecte le modèle AGDLP (aucun utilisateur direct, aucun GG, que des GDL)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    $check = {
        param($p)
        $acl = Get-Acl -Path $p
        $nonConformes = @()
        foreach ($a in $acl.Access) {
            $id = $a.IdentityReference.Value
            # Tolère les identités systèmes
            if ($id -match '^(NT AUTHORITY|BUILTIN|CREATOR|\\)') { continue }
            if ($id -match '\\Admins? du domaine|\\Domain Admins|\\Administrators?') { continue }
            # Doit être un GDL_*
            if ($id -notmatch 'GDL_') {
                $nonConformes += $id
            }
        }
        return ,$nonConformes
    }

    try {
        if ($ComputerName -eq $env:COMPUTERNAME) {
            $bad = & $check $Path
        } else {
            $bad = Invoke-Command -ComputerName $ComputerName -ScriptBlock $check -ArgumentList $Path
        }
        if ($bad.Count -eq 0) { return $true }
        Write-YanixLog WARN "ACL non conforme AGDLP sur $Path : $($bad -join ', ')"
        return $false
    } catch {
        Write-YanixLog WARN "Test ACL impossible sur $Path : $($_.Exception.Message)"
        return $false
    }
}

# ============================================================================
# DOSSIERS UTILISATEURS
# ============================================================================

function New-YanixHomeDirectory {
    <#
    .SYNOPSIS
        Crée le dossier home d'un utilisateur avec ACL stricte
    .DESCRIPTION
        Permissions appliquées :
        - Admins du domaine : FullControl
        - SYSTEM : FullControl
        - L'utilisateur lui-même : Modify
        - Héritage : désactivé
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SamAccountName,
        [Parameter(Mandatory)][string]$BasePath,           # ex: 'D:\Partages\Users'
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$DomainNetBIOS = 'YANIXLABS'
    )

    $homePath = Join-Path $BasePath $SamAccountName

    if (-not $PSCmdlet.ShouldProcess($homePath, "Creation home directory utilisateur")) { return }

    $block = {
        param($home, $sam, $netbios)

        if (Test-Path $home) { return "SKIP: $home deja present" }

        New-Item -Path $home -ItemType Directory -Force | Out-Null

        $acl = Get-Acl $home
        $acl.SetAccessRuleProtection($true, $false)
        @($acl.Access | Where-Object { -not $_.IsInherited }) |
            ForEach-Object { [void]$acl.RemoveAccessRule($_) }

        $rules = @(
            @{ Id = 'NT AUTHORITY\SYSTEM';     Rights = 'FullControl' }
            @{ Id = 'BUILTIN\Administrateurs'; Rights = 'FullControl' }
            @{ Id = "$netbios\Admins du domaine"; Rights = 'FullControl'; AllowFail = $true }
            @{ Id = "$netbios\Domain Admins";     Rights = 'FullControl'; AllowFail = $true }
            @{ Id = "$netbios\$sam";              Rights = 'Modify' }
        )
        foreach ($r in $rules) {
            try {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $r.Id, $r.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
                )
                $acl.AddAccessRule($rule)
            } catch {
                if (-not $r.AllowFail) { throw }
            }
        }
        Set-Acl -Path $home -AclObject $acl
        return "OK: $home cree avec ACL stricte"
    }

    try {
        if ($ComputerName -eq $env:COMPUTERNAME) {
            $r = & $block $homePath $SamAccountName $DomainNetBIOS
        } else {
            $r = Invoke-Command -ComputerName $ComputerName -ScriptBlock $block `
                                -ArgumentList $homePath, $SamAccountName, $DomainNetBIOS -ErrorAction Stop
        }
        if ($r -like 'SKIP:*') { Write-YanixLog SKIP $r } else { Write-YanixLog OK $r }
    } catch {
        Write-YanixLog ERR "Echec creation home $homePath : $($_.Exception.Message)"
        throw
    }
}
