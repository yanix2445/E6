<#
.SYNOPSIS
    AD-Helpers.ps1 - Helpers Active Directory réutilisables

.DESCRIPTION
    Fonctions liées à l'AD utilisées par plusieurs scripts du projet E6.
    Toutes les fonctions sont idempotentes (les opérations New-* vérifient l'existence).

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR
    Version : 1.0 - 2026-06-22
    Dépend  : ActiveDirectory module
#>

# ============================================================================
# OBSERVATION
# ============================================================================

function Test-YanixOU {
    <#
    .SYNOPSIS
        Vérifie l'existence d'une OU par son DistinguishedName
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$DistinguishedName)

    try {
        $ou = Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction Stop
        return ($null -ne $ou)
    } catch {
        return $false
    }
}

function Test-YanixGroupe {
    <#
    .SYNOPSIS
        Vérifie l'existence d'un groupe AD par son nom
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $g = Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction Stop
        return ($null -ne $g)
    } catch {
        return $false
    }
}

function Test-YanixUtilisateur {
    <#
    .SYNOPSIS
        Vérifie l'existence d'un utilisateur AD par son sAMAccountName
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SamAccountName)

    try {
        $u = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction Stop
        return ($null -ne $u)
    } catch {
        return $false
    }
}

function Test-YanixOrdinateur {
    <#
    .SYNOPSIS
        Vérifie l'existence d'un objet ordinateur AD
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $c = Get-ADComputer -Filter "Name -eq '$Name'" -ErrorAction Stop
        return ($null -ne $c)
    } catch {
        return $false
    }
}

# ============================================================================
# CRÉATION IDEMPOTENTE
# ============================================================================

function New-YanixOU {
    <#
    .SYNOPSIS
        Crée une OU si elle n'existe pas (idempotent)
    .PARAMETER Name
        Nom court de l'OU (ex: 'Utilisateurs')
    .PARAMETER Path
        DN du parent (ex: 'OU=YANIXLABS,DC=yanixlabs,DC=lan')
    .PARAMETER ProtectFromDeletion
        Protège contre la suppression accidentelle (défaut $true, recommandé ANSSI)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [bool]$ProtectFromDeletion = $true
    )

    $dn = "OU=$Name,$Path"

    if (Test-YanixOU -DistinguishedName $dn) {
        Write-YanixLog SKIP "OU deja existante : $dn"
        return
    }

    # Respect du mode DryRun global (defini par Initialize-YanixContexte)
    if ($script:YanixContext -and $script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation OU '$dn' simulee (non executee)"
        return
    }

    if ($PSCmdlet.ShouldProcess($dn, "Creation OU")) {
        try {
            New-ADOrganizationalUnit -Name $Name -Path $Path `
                                     -ProtectedFromAccidentalDeletion $ProtectFromDeletion `
                                     -ErrorAction Stop
            Write-YanixLog OK "OU creee : $dn"
        } catch {
            Write-YanixLog ERR "Echec creation OU $dn : $($_.Exception.Message)"
            throw
        }
    }
}

function New-YanixGroupe {
    <#
    .SYNOPSIS
        Crée un groupe AD si inexistant (idempotent)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Global','DomainLocal','Universal')][string]$GroupScope,
        [ValidateSet('Security','Distribution')][string]$GroupCategory = 'Security',
        [string]$Description = ''
    )

    if (Test-YanixGroupe -Name $Name) {
        Write-YanixLog SKIP "Groupe deja existant : $Name"
        return
    }

    # Respect du mode DryRun global
    if ($script:YanixContext -and $script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation groupe '$Name' [$GroupScope] simulee"
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, "Creation groupe AD ($GroupScope)")) {
        try {
            New-ADGroup -Name $Name -Path $Path -GroupScope $GroupScope `
                        -GroupCategory $GroupCategory -Description $Description `
                        -ErrorAction Stop
            Write-YanixLog OK "Groupe cree : $Name [$GroupScope]"
        } catch {
            Write-YanixLog ERR "Echec creation groupe $Name : $($_.Exception.Message)"
            throw
        }
    }
}

function Add-YanixGroupeMembre {
    <#
    .SYNOPSIS
        Ajoute un membre à un groupe (idempotent : si déjà membre, skip)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$MemberName
    )

    # Vérifie l'appartenance actuelle
    try {
        $members = Get-ADGroupMember -Identity $GroupName -ErrorAction Stop | Select-Object -ExpandProperty SamAccountName
        if ($members -contains $MemberName -or $members -contains $MemberName.Split('\')[-1]) {
            Write-YanixLog SKIP "$MemberName deja membre de $GroupName"
            return
        }
    } catch {
        Write-YanixLog WARN "Lecture membres de $GroupName impossible : $($_.Exception.Message)"
    }

    # Respect du mode DryRun global
    if ($script:YanixContext -and $script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : ajout '$MemberName' au groupe '$GroupName' simule"
        return
    }

    if ($PSCmdlet.ShouldProcess("$GroupName <- $MemberName", "Ajout membre groupe")) {
        try {
            Add-ADGroupMember -Identity $GroupName -Members $MemberName -ErrorAction Stop
            Write-YanixLog OK "$MemberName ajoute a $GroupName"
        } catch {
            Write-YanixLog ERR "Echec ajout $MemberName a $GroupName : $($_.Exception.Message)"
            throw
        }
    }
}

# ============================================================================
# CONTRÔLEURS DE DOMAINE
# ============================================================================

function Get-YanixDCActif {
    <#
    .SYNOPSIS
        Retourne le premier DC actif joignable (utilise pour rediriger des commandes)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $dcs = Get-ADDomainController -Filter * -ErrorAction Stop
        foreach ($dc in $dcs) {
            if (Test-YanixConnectivite -ComputerName $dc.HostName -Port 389 -TimeoutMs 2000) {
                return $dc.HostName
            }
        }
    } catch {
        Write-YanixLog WARN "Impossible d'enumerer les DC : $($_.Exception.Message)"
    }
    return $null
}

function Test-YanixReplicationDC {
    <#
    .SYNOPSIS
        Vérifie l'état de réplication AD (basé sur repadmin /replsummary)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $out = repadmin /replsummary 2>&1
        # Si on voit "0 / 0 / 0" ou "0 0 0" dans la table = pas d'erreur
        # Si on voit des "non" erreurs ou des delta > X = problème
        $errors = $out | Select-String -Pattern '(\d+)\s+/\s+(\d+)\s+/\s+(\d+)' | ForEach-Object {
            $_.Matches[0].Groups[3].Value -as [int]
        }
        return (($errors | Measure-Object -Sum).Sum -eq 0)
    } catch {
        return $false
    }
}

# ============================================================================
# NORMALISATION DE NOMS
# ============================================================================

function ConvertTo-YanixSansAccents {
    <#
    .SYNOPSIS
        Supprime les accents d'une chaîne (Édouard -> Edouard)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Texte)

    $norm = $Texte.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $norm.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

function Get-YanixSamAccountName {
    <#
    .SYNOPSIS
        Construit un sAMAccountName conforme (lowercase, sans accent, max 20 chars)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prenom,
        [Parameter(Mandatory)][string]$Nom
    )

    $p = (ConvertTo-YanixSansAccents $Prenom).ToLower() -replace '[^a-z\-]',''
    $n = (ConvertTo-YanixSansAccents $Nom).ToLower()    -replace '[^a-z\-]',''
    $sam = "$p.$n"
    if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }
    return $sam
}

# ============================================================================
# GÉNÉRATION DE MOT DE PASSE ANSSI
# ============================================================================

function New-YanixMotDePasseAnssi {
    <#
    .SYNOPSIS
        Génère un mot de passe conforme ANSSI (14+ chars, 4 catégories, sans ambigus)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Longueur = 15)

    $config = Get-YanixConfig
    $exclus = $config.MotDePasse.ExcluCaracteres.ToCharArray()

    $maj  = ([char[]](65..90))  | Where-Object { $_ -notin $exclus }
    $min  = ([char[]](97..122)) | Where-Object { $_ -notin $exclus }
    $num  = ([char[]](50..57))  | Where-Object { $_ -notin $exclus }   # 2-9
    $spec = '@#%&!*'.ToCharArray()
    $all  = $maj + $min + $num + $spec

    $chars = @(
        ($maj  | Get-Random),
        ($min  | Get-Random),
        ($num  | Get-Random),
        ($spec | Get-Random)
    )
    while ($chars.Count -lt $Longueur) { $chars += ($all | Get-Random) }
    return -join ($chars | Get-Random -Count $chars.Count)
}
