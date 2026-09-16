# linux-config-ip

Configurer l'adresse IP d'une machine Linux **en statique ou en DHCP** en une commande, sans se demander s'il faut passer par `nmtui` ou par `/etc/network/interfaces`.

Le script détecte tout seul quel gestionnaire réseau pilote l'interface, puis écrit la configuration au bon endroit et l'applique immédiatement.

```
=== linux-config-ip 1.2.0 ===
[i] Système : Debian GNU/Linux 13 (trixie)
[i] Interface : ens18 (adresse actuelle : 192.168.10.37/24)
[i] Gestionnaire détecté : ifupdown (/etc/network/interfaces)

Que voulez-vous faire ?  (mode actuel : DHCP)
  1) Adresse IP statique
  2) Adresse automatique (DHCP)
Choix [1] :

Adresse IP : 192.168.10.1/24
Passerelle (tapez « aucune » pour ne pas en mettre) [192.168.10.254] :
Serveurs DNS (séparés par des espaces) [1.1.1.1 9.9.9.9] :

Récapitulatif
  Interface    : ens18
  Mode         : IP statique
  Adresse      : 192.168.10.1/24  (masque 255.255.255.0)
  Passerelle   : 192.168.10.254
  DNS          : 1.1.1.1 9.9.9.9
  Gestionnaire : ifupdown (/etc/network/interfaces)

Appliquer maintenant ? (O/n) [O] :
[OK] Adresse 192.168.10.1 présente sur ens18.
[OK] Passerelle 192.168.10.254 joignable.
[OK] Configuration appliquée et persistante au redémarrage.
```

## Distributions prises en charge

| Distribution | État |
|---|---|
| Debian 11, 12, 13 | ✅ Pris en charge |
| Ubuntu | 🔜 À venir |
| Autres distributions | 🔜 À venir |

## Pourquoi parfois `nmtui`, parfois `/etc/network/interfaces` ?

Ce n'est **pas la version de Debian** qui décide, c'est **la façon dont la machine a été installée** :

| Installation | Gestionnaire réseau | Où se configure l'IP |
|---|---|---|
| Avec un environnement de bureau (GNOME, KDE, Xfce…) | NetworkManager | `nmtui` / `nmcli` |
| Serveur / netinst sans bureau | ifupdown | `/etc/network/interfaces` |
| Images cloud, certaines installations minimales | systemd-networkd | `/etc/systemd/network/*.network` |

Point important : sur Debian, **NetworkManager ignore toute interface déclarée dans `/etc/network/interfaces`**. C'est pour ça que modifier le « mauvais » endroit semble ne rien faire.

Debian 11, 12 et 13 fonctionnent de la même façon sur ce point : un seul script couvre donc toutes ces versions. Comme NetworkManager et systemd-networkd sont aussi utilisés par d'autres distributions, le même script servira de base pour les prendre en charge.

## Installation et utilisation

Sur la machine, en root (`su -` si `sudo` n'est pas installé) :

```bash
apt install -y curl
curl -fsSL https://raw.githubusercontent.com/Remilulz91/linux-config-ip/main/linux-config-ip.sh -o linux-config-ip.sh
chmod +x linux-config-ip.sh
./linux-config-ip.sh
```

Ou avec git :

```bash
apt install -y git
git clone https://github.com/Remilulz91/linux-config-ip.git
cd linux-config-ip
./linux-config-ip.sh
```

### Choix du mode

Au lancement, le script propose :

1. **Adresse IP statique** : il demande l'adresse, la passerelle et les DNS.
2. **Adresse automatique (DHCP)** : il remet l'interface en DHCP, sans autre question.

### Saisie de l'adresse (mode statique)

Les deux formes sont acceptées :

```
Adresse IP : 192.168.10.1/24
```

```
Adresse IP : 192.168.10.1
Masque (ex : 255.255.255.0 ou 24) : 255.255.255.0
```

Le script vérifie que l'adresse est valide, que le masque est correct, que l'adresse n'est pas celle du réseau ou du broadcast et que la passerelle est dans le même réseau.

### Mode non interactif

```bash
./linux-config-ip.sh -i ens18 -a 192.168.10.1/24 -g 192.168.10.254 -d "1.1.1.1 9.9.9.9" -y
./linux-config-ip.sh -i ens18 -a 192.168.10.1 -m 255.255.255.0 -g aucune -d 192.168.10.53 -y
./linux-config-ip.sh -i ens18 --dhcp -y
```

| Option | Rôle |
|---|---|
| `-i`, `--interface` | Interface à configurer |
| `-s`, `--static` | Mode IP statique (implicite avec `-a`) |
| `-D`, `--dhcp` | Repasser l'interface en DHCP |
| `-a`, `--address` | Adresse, avec ou sans `/CIDR` |
| `-m`, `--mask` | Masque (`255.255.255.0` ou `24`) si absent de `-a` |
| `-g`, `--gateway` | Passerelle (`aucune` pour ne pas en mettre) |
| `-d`, `--dns` | DNS séparés par des espaces ou des virgules |
| `-b`, `--backend` | Forcer `networkmanager`, `ifupdown` ou `networkd` |
| `-y`, `--yes` | Pas de confirmation |
| `-n`, `--dry-run` | Affiche ce qui serait fait sans rien modifier |
| `-h`, `--help` | Aide |

Conseil : lancez d'abord avec `-n` pour voir exactement les fichiers qui seront écrits.

## Ce que fait le script

| Gestionnaire | Action |
|---|---|
| NetworkManager | Modifie le profil actif de l'interface avec `nmcli` (ou en crée un) en `manual` ou `auto`, puis le réactive. Le résultat est visible dans `nmtui`. |
| ifupdown | Remplace la déclaration IPv4 de l'interface **à sa place** par un bloc `inet static` ou `inet dhcp`. Les commentaires, l'IPv6 et les autres interfaces sont conservés. Puis relance l'interface. |
| systemd-networkd | Écrit `/etc/systemd/network/05-linux-config-ip-<if>.network` (`DHCP=no` + adresse, ou `DHCP=ipv4`), désactive les autres fichiers ciblant l'interface, puis `networkctl reload` + `reconfigure`. |

En statique, le DNS est écrit au bon endroit : profil NetworkManager, `systemd-resolved`, `resolvconf` ou `/etc/resolv.conf` (les lignes `search` / `domain` sont conservées). En DHCP, les DNS forcés par le script sont retirés et le serveur DHCP reprend la main.

## Sécurité

- **Sauvegarde** de tous les fichiers modifiés dans `/var/backups/linux-config-ip/<date>/`.
- **Retour arrière automatique** si l'activation de l'interface échoue.
- **Journal** dans `/var/log/linux-config-ip.log`.
- Le script **continue même si la session SSH coupe** pendant le changement d'adresse. Reconnectez-vous ensuite sur la nouvelle IP.
- Seul IPv4 est modifié.
- En DHCP via SSH, la nouvelle adresse n'est pas connue d'avance : prévoyez un accès console ou consultez les baux du serveur DHCP.

Restaurer une sauvegarde à la main (exemple ifupdown) :

```bash
cp -a /var/backups/linux-config-ip/20260916-121407/etc/network/interfaces /etc/network/interfaces
systemctl restart networking
```

## Limites

- IPv4 uniquement, une adresse par interface.
- Wi-Fi : uniquement avec NetworkManager et un profil déjà existant.
- Bonding, VLAN et bridges ne sont pas gérés.

## Licence

MIT — voir [LICENSE](LICENSE).
