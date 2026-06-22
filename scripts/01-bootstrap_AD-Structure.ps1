<#
.SYNOPSIS
    Bootstrap de la structure Active Directory yanixlabs.lan
    Conforme cadre prod-ready E6 - Microsoft + ANSSI PA-022

.DESCRIPTION
    Provisionne la structure AD complète et idempotente :
      1. OU (par type d'objet + par service métier)
      2. Groupes globaux (GG_*) - 9 services + transverses
      3. Groupes Domain Local (GDL_*) - 9 services × 3 niveaux (L/M/CT)
      4. Comptes utilisateurs (nominal + admin Tier 0 + démo par service)
      5. Appartenances AGDLP (User -> GG_<Service>)
      6. Nettoyage des objets obsolètes (anciennes nomenclatures v1)

    100% IDEMPOTENT : relançable à volonté.
    Mode -DryRun pour simulation sans modification.
    Fonction Test-Bootstrap intégrée et appelée automatiquement en fin.
    Logs centralisés dans Logs/ + télémétrie SRV-BCK-01.

.PARAMETER DryRun
    Simulation sans modification (utile pour valider avant prod)

.PARAMETER SkipCleanup
    Ignore la phase 6 (nettoyage objets v1)

.PARAMETER MotDePasseInitial
    Mot de passe initial des comptes créés (défaut : depuis E6-Config.psd1)

.EXAMPLE
    .\01-bootstrap_AD-Structure.ps1 -DryRun
    Simulation complète sans modification

.EXAMPLE
    .\01-bootstrap_AD-Structure.ps1
    Exécution réelle (idempotente)

.NOTES
    Auteur  : Yanis HARRAT - BTS SIO SISR - Projet E6
    Version : 2.0 - 2026-06-22 (refonte cadre prod-ready)
    Conforme: Microsoft Approved Verbs, AGDLP, ANSSI PA-022 (R.16, R.22)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [switch]$SkipCleanup,
    [string]$MotDePasseInitial
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
Test-YanixPrerequis -Required Admin, DomainAdmin, AD -Stop

$config = Get-YanixConfig

# Mot de passe initial (paramètre > config)
if (-not $MotDePasseInitial) { $MotDePasseInitial = $config.MotDePasse.DefautBienvenue }
$pwdSecure = ConvertTo-SecureString $MotDePasseInitial -AsPlainText -Force

# ============================================================================
# DONNEES LOCALES AU SCRIPT (utilisateurs nominaux + demo)
# ============================================================================

# Sources de vérité construites depuis la config + spécifiques au bootstrap
$services = $config.ServicesMetier | ForEach-Object {
    @{ Name = $_; Desc = "Service $_" }
}
$domainDN = $config.DomainDN
$ouRoot   = $config.OUs.Racine
$ouUsers  = $config.OUs.Utilisateurs
$ouGroupes = $config.OUs.Groupes
$ouAdmins = $config.OUs.Admins

# Compte nominal Tier 1 + admin Tier 0 (à adapter selon ton identité réelle)
$comptesNominaux = @(
    @{
        Sam = 'nassim.harrat'
        Path  = "OU=Direction,$ouUsers"
        GivenName = 'Nassim'
        Surname   = 'HARRAT'
        Title     = 'Etudiant BTS SIO SISR'
        Department = 'Direction'
        Description = 'Compte nominal - utilisateur standard'
    }
)

$comptesAdmin = @(
    @{
        Sam = 'nassim.harrat.adm'
        Path  = "OU=Comptes-Admin,$ouAdmins"
        GivenName = 'Nassim'
        Surname   = 'HARRAT'
        DisplayName = 'Nassim HARRAT (Admin)'
        Title     = 'Administrateur Tier 0'
        Department = 'Systeme-Information'
        Description = 'Compte admin Tier 0 - usage admin uniquement'
    }
)

# Comptes démo (1 par service)
$comptesDemo = @(
    @{ Sam = 'demo-direction';  Surname = 'Direction';       OU = 'Direction' }
    @{ Sam = 'demo-daf';        Surname = 'Admin-Finance';   OU = 'Administratif-Finance' }
    @{ Sam = 'demo-rh';         Surname = 'RH';              OU = 'Ressources-Humaines' }
    @{ Sam = 'demo-commercial'; Surname = 'Commercial';      OU = 'Commercial' }
    @{ Sam = 'demo-marketing';  Surname = 'Marketing';       OU = 'Marketing-Communication' }
    @{ Sam = 'demo-studio';     Surname = 'Studio';          OU = 'Studio-Creation' }
    @{ Sam = 'demo-dev';        Surname = 'Developpement';   OU = 'Developpement' }
    @{ Sam = 'demo-dsi';        Surname = 'DSI';             OU = 'Systeme-Information' }
    @{ Sam = 'demo-support';    Surname = 'Support';         OU = 'Support-Client' }
)

# Niveaux d'accès AGDLP
$niveauxAGDLP = [ordered]@{ 'L' = 'Lecture seule'; 'M' = 'Modification'; 'CT' = 'Controle Total' }

# Partages transverses (niveaux limités à L/M, pas de CT)
$partagesTransverses = @('Commun', 'Projets')

# ============================================================================
# HELPER LOCAL : creation utilisateur (etend la lib commune)
# ============================================================================

function New-YanixUtilisateurBootstrap {
    param(
        [Parameter(Mandatory)][string]$Sam,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname,
        [string]$DisplayName,
        [string]$Title = '',
        [string]$Department = '',
        [string]$Description = ''
    )

    if (-not $DisplayName) { $DisplayName = "$GivenName $Surname" }
    $upn = "$Sam@$($config.Domain)"

    if (Test-YanixUtilisateur -SamAccountName $Sam) {
        # Existe : vérifier qu'il est au bon endroit
        $existing = Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue
        $parent = ($existing.DistinguishedName -split ',', 2)[1]
        if ($parent -ne $Path) {
            # Respect du mode DryRun
            if ($script:YanixContext -and $script:YanixContext.DryRun) {
                Write-YanixLog INFO "DRY-RUN : deplacement $Sam vers $Path simule"
                return
            }
            try {
                Move-ADObject -Identity $existing.DistinguishedName -TargetPath $Path -ErrorAction Stop
                Write-YanixLog OK "Utilisateur $Sam deplace vers $Path"
            } catch {
                Write-YanixLog ERR "Echec deplacement $Sam : $($_.Exception.Message)"
            }
        } else {
            Write-YanixLog SKIP "Utilisateur $Sam deja present au bon endroit"
        }
        return
    }

    # Respect du mode DryRun pour la creation
    if ($script:YanixContext -and $script:YanixContext.DryRun) {
        Write-YanixLog INFO "DRY-RUN : creation utilisateur '$Sam' dans '$Path' simulee"
        return
    }

    try {
        New-ADUser -Name $DisplayName `
                   -SamAccountName $Sam `
                   -UserPrincipalName $upn `
                   -GivenName $GivenName `
                   -Surname $Surname `
                   -DisplayName $DisplayName `
                   -Description $Description `
                   -Title $Title `
                   -Department $Department `
                   -Path $Path `
                   -AccountPassword $pwdSecure `
                   -ChangePasswordAtLogon $true `
                   -Enabled $true `
                   -ErrorAction Stop
        Write-YanixLog OK "Utilisateur cree : $Sam dans $Path"
    } catch {
        Write-YanixLog ERR "Echec creation $Sam : $($_.Exception.Message)"
    }
}

# ============================================================================
# PHASE 1 - STRUCTURE OU
# ============================================================================
Write-YanixLog STEP "=== PHASE 1/6 : Structure des OU ==="

# OU racine YANIXLABS
New-YanixOU -Name 'YANIXLABS' -Path $domainDN

# Conteneurs de niveau 1
$conteneurs = @(
    @{ Name = 'Utilisateurs'     ; Desc = 'Comptes utilisateurs par direction' }
    @{ Name = 'Ordinateurs'      ; Desc = 'Postes de travail par direction' }
    @{ Name = 'Groupes'          ; Desc = 'Groupes de securite (AGDLP)' }
    @{ Name = 'Serveurs'         ; Desc = 'Serveurs membres par role' }
    @{ Name = 'Comptes-Services' ; Desc = 'Comptes de service applicatifs (svc-*)' }
    @{ Name = 'Administration'   ; Desc = 'Administration Tier 0 (comptes et groupes a privileges)' }
)
foreach ($c in $conteneurs) {
    New-YanixOU -Name $c.Name -Path $ouRoot
}

# Sous-OU Utilisateurs et Ordinateurs (par service)
$ouOrdis = "OU=Ordinateurs,$ouRoot"
foreach ($s in $services) {
    New-YanixOU -Name $s.Name -Path $ouUsers
    New-YanixOU -Name $s.Name -Path $ouOrdis
}

# Sous-OU Groupes
New-YanixOU -Name 'Globaux'     -Path $ouGroupes
New-YanixOU -Name 'DomainLocal' -Path $ouGroupes

# Sous-OU Serveurs
$ouServs = "OU=Serveurs,$ouRoot"
$ouServeurs = @(
    'Controleurs-Domaine', 'Serveurs-Fichiers', 'Serveurs-Sauvegarde', 'Serveurs-Applicatifs'
)
foreach ($o in $ouServeurs) { New-YanixOU -Name $o -Path $ouServs }

# Sous-OU Admins
New-YanixOU -Name 'Comptes-Admin' -Path $ouAdmins
New-YanixOU -Name 'Groupes-Admin' -Path $ouAdmins

# ============================================================================
# PHASE 2 - GROUPES GLOBAUX (GG_*)
# ============================================================================
Write-YanixLog STEP "=== PHASE 2/6 : Groupes Globaux (GG_*) ==="

$ouGG = "OU=Globaux,$ouGroupes"
foreach ($s in $services) {
    New-YanixGroupe -Name "GG_$($s.Name)" -Path $ouGG -GroupScope Global -Description "Membres : $($s.Desc)"
}
New-YanixGroupe -Name 'GG_TousSalaries' -Path $ouGG -GroupScope Global -Description 'Tous les salaries (groupe transverse)'
New-YanixGroupe -Name 'GG_Helpdesk'      -Path $ouGG -GroupScope Global -Description 'Helpdesk (delegation reset mot de passe)'

# Groupe Admin Tier 0 dans Groupes-Admin
New-YanixGroupe -Name 'GG_Admins_Tier0' -Path "OU=Groupes-Admin,$ouAdmins" -GroupScope Global -Description 'Administrateurs de la foret (Tier 0)'

# ============================================================================
# PHASE 3 - GROUPES DOMAIN LOCAL (GDL_*)
# ============================================================================
Write-YanixLog STEP "=== PHASE 3/6 : Groupes Domain Local (GDL_*) ==="

$ouGDL = "OU=DomainLocal,$ouGroupes"
foreach ($s in $services) {
    foreach ($n in $niveauxAGDLP.Keys) {
        New-YanixGroupe -Name "GDL_Partage_$($s.Name)_$n" `
                        -Path $ouGDL `
                        -GroupScope DomainLocal `
                        -Description "Acces $($niveauxAGDLP[$n]) sur le partage $($s.Name)"
    }
}

# Partages transverses (L et M uniquement)
foreach ($p in $partagesTransverses) {
    foreach ($n in @('L', 'M')) {
        New-YanixGroupe -Name "GDL_Partage_${p}_$n" `
                        -Path $ouGDL `
                        -GroupScope DomainLocal `
                        -Description "Acces $($niveauxAGDLP[$n]) sur le partage $p"
    }
}

# ============================================================================
# PHASE 4 - UTILISATEURS (nominal + admin + demo)
# ============================================================================
Write-YanixLog STEP "=== PHASE 4/6 : Utilisateurs ==="

foreach ($u in $comptesNominaux) {
    New-YanixUtilisateurBootstrap @u
}

foreach ($u in $comptesAdmin) {
    New-YanixUtilisateurBootstrap @u
}

foreach ($u in $comptesDemo) {
    $params = @{
        Sam         = $u.Sam
        Path        = "OU=$($u.OU),$ouUsers"
        GivenName   = 'Demo'
        Surname     = $u.Surname
        Title       = 'Compte demo'
        Department  = $u.OU
        Description = "Compte demo pour tester GPO et ACL du service $($u.OU)"
    }
    New-YanixUtilisateurBootstrap @params
}

# ============================================================================
# PHASE 5 - APPARTENANCES AGDLP (User -> GG_<Service>)
# ============================================================================
Write-YanixLog STEP "=== PHASE 5/6 : Appartenances aux groupes (AGDLP) ==="

$mappingAGDLP = @(
    @{ Groupe = 'GG_Direction';               Membres = @('nassim.harrat', 'demo-direction') }
    @{ Groupe = 'GG_Administratif-Finance';   Membres = @('demo-daf') }
    @{ Groupe = 'GG_Ressources-Humaines';     Membres = @('demo-rh') }
    @{ Groupe = 'GG_Commercial';              Membres = @('demo-commercial') }
    @{ Groupe = 'GG_Marketing-Communication'; Membres = @('demo-marketing') }
    @{ Groupe = 'GG_Studio-Creation';         Membres = @('demo-studio') }
    @{ Groupe = 'GG_Developpement';           Membres = @('demo-dev') }
    @{ Groupe = 'GG_Systeme-Information';     Membres = @('demo-dsi') }
    @{ Groupe = 'GG_Support-Client';          Membres = @('demo-support') }
    @{ Groupe = 'GG_Admins_Tier0';            Membres = @('nassim.harrat.adm') }
    @{ Groupe = 'GG_TousSalaries';            Membres = @(
        'nassim.harrat', 'demo-direction', 'demo-daf', 'demo-rh', 'demo-commercial',
        'demo-marketing', 'demo-studio', 'demo-dev', 'demo-dsi', 'demo-support'
    )}
)
foreach ($m in $mappingAGDLP) {
    foreach ($membre in $m.Membres) {
        Add-YanixGroupeMembre -GroupName $m.Groupe -MemberName $membre
    }
}

# ============================================================================
# PHASE 6 - NETTOYAGE V1 (optionnel)
# ============================================================================
if (-not $SkipCleanup) {
    Write-YanixLog STEP "=== PHASE 6/6 : Nettoyage objets obsoletes v1 ==="

    # Anciens groupes GG_ et GDL_ (nomenclature v1)
    $groupesObsoletes = @(
        'GG_Compta_Finance', 'GG_RH', 'GG_Marketing', 'GG_Support',
        'GG_Studio_Crea', 'GG_Dev', 'GG_DSI',
        'GG_Tous-Salaries', 'GG_Admins-Tier0'   # remplacés par GG_TousSalaries et GG_Admins_Tier0
    )
    foreach ($g in $groupesObsoletes) {
        if (Test-YanixGroupe -Name $g) {
            if ($PSCmdlet.ShouldProcess($g, 'Suppression groupe obsolete v1')) {
                try {
                    Remove-ADGroup -Identity (Get-ADGroup -Filter "Name -eq '$g'").DistinguishedName -Confirm:$false -ErrorAction Stop
                    Write-YanixLog OK "Groupe obsolete supprime : $g"
                } catch {
                    Write-YanixLog WARN "Echec suppression $g : $($_.Exception.Message)"
                }
            }
        }
    }

    # Anciens GDL avec services v1
    $oldGdlServices = @('Compta_Finance', 'RH', 'Marketing', 'Support', 'Studio_Crea', 'Dev', 'DSI')
    foreach ($svc in $oldGdlServices) {
        foreach ($n in @('L', 'M', 'CT')) {
            $nom = "GDL_Partage_${svc}_$n"
            if (Test-YanixGroupe -Name $nom) {
                if ($PSCmdlet.ShouldProcess($nom, 'Suppression GDL obsolete v1')) {
                    try {
                        Remove-ADGroup -Identity (Get-ADGroup -Filter "Name -eq '$nom'").DistinguishedName -Confirm:$false -ErrorAction Stop
                        Write-YanixLog OK "GDL obsolete supprime : $nom"
                    } catch {
                        Write-YanixLog WARN "Echec suppression $nom : $($_.Exception.Message)"
                    }
                }
            }
        }
    }

    # Comptes obsolètes (ex: demo-compta renommé en demo-daf)
    $usersObsoletes = @('demo-compta')
    foreach ($u in $usersObsoletes) {
        if (Test-YanixUtilisateur -SamAccountName $u) {
            if ($PSCmdlet.ShouldProcess($u, 'Suppression utilisateur obsolete v1')) {
                try {
                    Remove-ADUser -Identity (Get-ADUser -Filter "SamAccountName -eq '$u'").DistinguishedName -Confirm:$false -ErrorAction Stop
                    Write-YanixLog OK "Utilisateur obsolete supprime : $u"
                } catch {
                    Write-YanixLog WARN "Echec suppression $u : $($_.Exception.Message)"
                }
            }
        }
    }
} else {
    Write-YanixLog INFO "Phase 6 (nettoyage) ignoree (parametre -SkipCleanup)"
}

# ============================================================================
# TEST POST-DEPLOIEMENT (auto-appele si Tests.ActiverApresExecution = $true)
# ============================================================================

function Test-Bootstrap-AD-Structure {
    <#
    .SYNOPSIS
        Verifie que la structure AD attendue est en place.
    .OUTPUTS
        $true si tout est conforme, $false sinon.
    #>
    Write-YanixLog STEP "=== Test post-deploiement : Bootstrap AD-Structure ==="

    $errors = @()

    # 1. Vérifier les OUs principales
    $ousAttendues = @($ouRoot, $ouUsers, $ouGroupes, $ouAdmins,
                       "OU=Ordinateurs,$ouRoot", "OU=Serveurs,$ouRoot",
                       "OU=Globaux,$ouGroupes", "OU=DomainLocal,$ouGroupes")
    foreach ($ou in $ousAttendues) {
        if (Test-YanixOU -DistinguishedName $ou) {
            Write-YanixLog OK "OU presente : $ou"
        } else {
            Write-YanixLog ERR "OU manquante : $ou"
            $errors += $ou
        }
    }

    # 2. Vérifier le nombre de GG (9 services + 3 transverses = 12)
    $nbGG = (Get-ADGroup -Filter "Name -like 'GG_*'" | Measure-Object).Count
    if ($nbGG -ge 12) {
        Write-YanixLog OK "Nombre de GG_ correct : $nbGG (>= 12 attendu)"
    } else {
        Write-YanixLog ERR "Nombre de GG_ insuffisant : $nbGG (< 12 attendu)"
        $errors += "GG_ count = $nbGG"
    }

    # 3. Vérifier le nombre de GDL (9 services × 3 + 2 transverses × 2 = 31)
    $nbGDL = (Get-ADGroup -Filter "Name -like 'GDL_*'" | Measure-Object).Count
    if ($nbGDL -ge 31) {
        Write-YanixLog OK "Nombre de GDL_ correct : $nbGDL (>= 31 attendu)"
    } else {
        Write-YanixLog WARN "Nombre de GDL_ : $nbGDL (< 31 attendu, verifier)"
    }

    # 4. Vérifier un échantillon AGDLP (un utilisateur dans son GG)
    if (Test-YanixUtilisateur -SamAccountName 'demo-rh') {
        $membres = Get-ADGroupMember -Identity 'GG_Ressources-Humaines' -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty SamAccountName
        if ($membres -contains 'demo-rh') {
            Write-YanixLog OK "AGDLP fonctionnel : demo-rh est membre de GG_Ressources-Humaines"
        } else {
            Write-YanixLog WARN "demo-rh n'est pas membre de GG_Ressources-Humaines"
        }
    }

    # 5. Statistiques finales
    $stats = @{
        'OU sous YANIXLABS'    = (Get-ADOrganizationalUnit -Filter * -SearchBase $ouRoot | Measure-Object).Count
        'Groupes GG_'           = (Get-ADGroup -Filter "Name -like 'GG_*'" | Measure-Object).Count
        'Groupes GDL_'          = (Get-ADGroup -Filter "Name -like 'GDL_*'" | Measure-Object).Count
        'Utilisateurs'          = (Get-ADUser -Filter * -SearchBase $ouUsers | Measure-Object).Count
        'Comptes admin (Tier0)' = (Get-ADUser -Filter * -SearchBase $ouAdmins | Measure-Object).Count
    }
    Write-YanixLog INFO "--- Statistiques finales ---"
    foreach ($k in $stats.Keys) {
        Write-YanixLog INFO ("  {0,-25} : {1}" -f $k, $stats[$k])
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
    Test-Bootstrap-AD-Structure | Out-Null
}

# ============================================================================
# RECAP + TELEMETRIE + EXIT CODE
# ============================================================================
exit (Show-YanixRecap)
