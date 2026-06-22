@{
    # ============================================================================
    # E6-Config.psd1
    # Configuration centralisée du projet E6 - Infrastructure PME yanixlabs.lan
    # Auteur : Yanis HARRAT - BTS SIO SISR
    # Version : 1.0 - 2026-06-22
    # ============================================================================
    # Ce fichier contient TOUTES les constantes du projet.
    # Aucun script ne doit hardcoder une valeur qui figure ici.
    # Chargement : $Config = Import-PowerShellDataFile "$PSScriptRoot\..\_config\E6-Config.psd1"
    # ============================================================================

    # ----- DOMAINE & FORÊT -----
    Domain          = 'yanixlabs.lan'
    DomainNetBIOS   = 'YANIXLABS'
    DomainDN        = 'DC=yanixlabs,DC=lan'
    Forest          = 'yanixlabs.lan'
    Company         = 'YanixLabs SARL'

    # ----- SERVEURS (FQDN + IP) -----
    Serveurs = @{
        DC01  = @{ Hostname = 'SRV-DC-01';  FQDN = 'SRV-DC-01.yanixlabs.lan';  IP = '10.0.20.10'; Role = 'AD-DNS-DHCP' }
        DC02  = @{ Hostname = 'SRV-DC-02';  FQDN = 'SRV-DC-02.yanixlabs.lan';  IP = '10.0.20.11'; Role = 'AD-DNS-DHCP' }
        FS01  = @{ Hostname = 'SRV-FS-01';  FQDN = 'SRV-FS-01.yanixlabs.lan';  IP = '10.0.20.20'; Role = 'FileServer-Primary' }
        FS02  = @{ Hostname = 'SRV-FS-02';  FQDN = 'SRV-FS-02.yanixlabs.lan';  IP = '10.0.20.21'; Role = 'FileServer-Replica' }
        BCK01 = @{ Hostname = 'SRV-BCK-01'; FQDN = 'SRV-BCK-01.yanixlabs.lan'; IP = '10.0.20.30'; Role = 'Backup' }
    }

    # ----- VLAN & RÉSEAUX -----
    VLANs = @{
        USR = @{ Id = 10; Reseau = '10.0.10.0/24'; Passerelle = '10.0.10.254'; Description = 'Réseau utilisateurs' }
        SRV = @{ Id = 20; Reseau = '10.0.20.0/24'; Passerelle = '10.0.20.254'; Description = 'Réseau serveurs' }
    }

    # ----- STRUCTURE OU AD -----
    OUs = @{
        Racine      = 'OU=YANIXLABS,DC=yanixlabs,DC=lan'
        Utilisateurs = 'OU=Utilisateurs,OU=YANIXLABS,DC=yanixlabs,DC=lan'
        Groupes     = 'OU=Groupes,OU=YANIXLABS,DC=yanixlabs,DC=lan'
        Ordinateurs = 'OU=Ordinateurs,OU=YANIXLABS,DC=yanixlabs,DC=lan'
        Serveurs    = 'OU=Serveurs,OU=YANIXLABS,DC=yanixlabs,DC=lan'
        Admins      = 'OU=Administration,OU=YANIXLABS,DC=yanixlabs,DC=lan'
    }

    # ----- SERVICES MÉTIER (utilisé partout) -----
    ServicesMetier = @(
        'Direction',
        'Administratif-Finance',
        'Ressources-Humaines',
        'Commercial',
        'Marketing-Communication',
        'Studio-Creation',
        'Developpement',
        'Systeme-Information',
        'Support-Client'
    )

    # ----- AGDLP - CONVENTION -----
    AGDLP = @{
        PrefixeGG      = 'GG_'
        PrefixeGDL     = 'GDL_Partage_'
        NiveauxAcces   = @('L', 'M', 'CT')   # Lecture, Modification, Contrôle Total
        DroitsNTFS = @{
            L  = 'ReadAndExecute'
            M  = 'Modify'
            CT = 'FullControl'
        }
        GroupesTransverses = @('GG_TousSalaries', 'GG_Admins_Tier0', 'GG_Helpdesk')
    }

    # ----- DFS -----
    DFS = @{
        NamespacePath  = '\\yanixlabs.lan\Partages'
        NamespaceType  = 'DomainV2'
        ServeursCibles = @('SRV-FS-01', 'SRV-FS-02')
        BaseLocale     = 'D:\Partages'
        BaseDFSRoots   = 'D:\DFSRoots\Partages'
    }

    # ----- DHCP -----
    DHCP = @{
        Etendues = @(
            @{
                Id           = '10.0.10.0'
                Nom          = 'VLAN10-USERS'
                Plage        = @{ Debut = '10.0.10.50'; Fin = '10.0.10.250' }
                MasqueReseau = '255.255.255.0'
                Passerelle   = '10.0.10.254'
                ServeursDNS  = @('10.0.20.10', '10.0.20.11')
                SuffixeDNS   = 'yanixlabs.lan'
                DureeBail    = 691200  # 8 jours en secondes
            }
        )
        Failover = @{
            Nom                  = 'DC01-DC02-Failover'
            Mode                 = 'LoadBalance'
            LoadBalancePercent   = 50
            MaxClientLeadTime    = '00:05:00'   # 5 min (recommandation Microsoft)
            AutoStateTransition  = $true
        }
    }

    # ----- SAUVEGARDE -----
    Sauvegarde = @{
        ServeurCentral     = 'SRV-BCK-01'
        PartageBackup      = '\\SRV-BCK-01\Backups'
        PartageLogs        = '\\SRV-BCK-01\Logs$'   # télémétrie centralisée
        VolumeLocalBackup  = 'D:\Backups'
        VolumeLocalLogs    = 'D:\Logs'
        HeurePlanification = '02:00'
        RetentionJours = @{
            SystemState = 7
            Fichiers    = 14
            Logs        = 30
        }
        Cibles = @(
            @{ Nom = 'SRV-DC-01';  Strategie = 'SystemState' }
            @{ Nom = 'SRV-DC-02';  Strategie = 'SystemState' }
            @{ Nom = 'SRV-FS-01';  Strategie = 'Dossier'; Source = 'D:\Partages' }
            @{ Nom = 'SRV-FS-02';  Strategie = 'Dossier'; Source = 'D:\Partages' }
        )
    }

    # ----- LOGS -----
    Logs = @{
        DossierLocal       = 'Logs'   # relatif au dossier scripts
        Format             = '[{0}] [{1,-4}] [{2}@{3}] {4}'  # timestamp, niveau, user, host, message
        Encoding           = 'UTF8'
        RetentionJours     = 30
        TelemetrieActive   = $true    # copie vers \\SRV-BCK-01\Logs$
        TelemetrieCible    = '\\SRV-BCK-01\Logs$'
    }

    # ----- POLITIQUES DE MOT DE PASSE -----
    MotDePasse = @{
        LongueurMin        = 14
        Categories         = 4   # maj, min, chiffre, special
        ExcluCaracteres    = 'IO0l1'   # caractères visuellement ambigus
        DefautBienvenue    = 'Bienvenue@2026'
    }

    # ----- CONTACTS -----
    Contacts = @{
        Helpdesk      = 'helpdesk@yanixlabs.lan'
        Administrateur = 'admin@yanixlabs.lan'
    }

    # ----- VÉRIFICATIONS POST-DÉPLOIEMENT (Test-* automatique) -----
    Tests = @{
        ActiverApresExecution = $true   # lance Test-* à la fin de chaque script bootstrap
        EchecBloque           = $false  # si test échoue, ne quitte pas en erreur (juste warning)
    }
}
