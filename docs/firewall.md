# Pare-feu UFW (SCRUM-55)

Le rôle `firewall` ferme tout ce qui entre sur le VPS, sauf les ports utiles. Ce fichier
explique comment **tester** le rôle et comment **passer SSH en VPN uniquement** le jour où
OpenVPN (SCRUM-58) sera déployé.

Détails techniques du rôle : [`roles/firewall/README.md`](../roles/firewall/README.md).

## 1. Ce qui est ouvert

| Port | Pour quoi | Ouvert à |
|---|---|---|
| 443/tcp | Site web (HTTPS, Caddy) | Internet |
| 80/tcp | Redirection HTTP → HTTPS et certificats (ACME) | Internet (`firewall_http_enabled`) |
| 1194/udp | OpenVPN | Internet |
| 22/tcp | SSH | VPN (`tun0`) **et** Internet tant que `firewall_ssh_vpn_only: false` |
| tout le reste | — | refusé |

Le sortant est entièrement autorisé (mises à jour, images Docker, Discord…).

### L'interrupteur `firewall_ssh_vpn_only`

| Valeur | SSH depuis Internet | Vérifie que le VPN existe |
|---|---|---|
| `false` (production aujourd'hui) | ✅ ouvert | non |
| `true` (valeur par défaut du rôle) | ❌ fermé | oui, et s'arrête s'il manque |

Il est réglé dans
[`inventories/production/group_vars/all/vars.yml`](../inventories/production/group_vars/all/vars.yml).

## 2. Tester le rôle

Toutes les commandes `make` se lancent depuis la racine du dépôt, venv activé
(`. .venv/bin/activate`).

Le Makefile ne fixe pas le compte SSH : il le lit dans `~/.ssh/config`. Sans ce fichier,
SSH utilise ton nom d'utilisateur local et échoue avec `Permission denied (publickey)`.
Il faut y mettre ton compte de `group_vars/all/users.yml` :

```
Host 51.255.169.129
    User <ton-compte>        # ex. ocorral
    IdentityFile ~/.ssh/id_ed25519
```

### 2.1 Vérifications locales (sans toucher au serveur)

```bash
yamllint roles/firewall inventories/
ansible-lint --exclude .venv
ansible-playbook -i inventories/production/hosts.yml site.yml --syntax-check
```

Attendu : aucune erreur, `Profile 'production' was required, and it passed`.

### 2.2 Simulation sur la production (rien n'est modifié)

```bash
make check ENV=production ARGS="--tags firewall"
```

`--check` montre ce qui **serait** changé, sans rien appliquer. Attendu : les tâches
`Allow …` en `changed`, aucune en `failed`.

> Si UFW n'est pas encore installé sur le serveur, les tâches après `Install UFW` peuvent
> échouer en simulation (`ufw` introuvable) : l'installation n'a pas vraiment eu lieu.
> C'est normal en `--check`, pas en déploiement réel.

### 2.3 Test du garde-fou anti-blocage (rien n'est modifié)

On force l'interrupteur sur `true` alors que le VPN n'existe pas :

```bash
make check ENV=production ARGS="--tags firewall -e firewall_ssh_vpn_only=true"
```

Attendu : la **première** tâche échoue avec
`firewall_ssh_vpn_only is true but interface tun0 does not exist …`, et aucune autre tâche
ne s'exécute. `-e` passe devant la valeur de l'inventaire, uniquement pour cette commande.

### 2.4 Déploiement réel

Précautions, au cas où :

1. **Garder un terminal SSH ouvert** sur le serveur pendant le déploiement. Une connexion
   déjà ouverte n'est pas coupée par UFW.
2. Savoir où se trouve la **console de secours de l'hébergeur** (KVM / rescue), qui ne
   passe pas par SSH (voir §4).

```bash
make deploy ENV=production ARGS="--tags firewall"
```

Puis, **dans un nouveau terminal**, vérifier qu'on peut toujours se connecter en SSH avant
de fermer l'ancien.

### 2.5 Vérifications sur le serveur

```bash
sudo ufw status verbose
```

Attendu :

```
Status: active
Default: deny (incoming), allow (outgoing), ...

To                         Action      From
--                         ------      ----
22/tcp on tun0             ALLOW IN    Anywhere
22/tcp                     ALLOW IN    Anywhere      ← disparaît en VPN uniquement
443/tcp                    ALLOW IN    Anywhere
1194/udp                   ALLOW IN    Anywhere
80/tcp                     ALLOW IN    Anywhere
(+ les mêmes lignes en (v6))
```

Ports Docker : seuls des ports en `127.0.0.1` doivent apparaître pour `docker-proxy`
(Docker contourne UFW, donc rien ne doit écouter sur `0.0.0.0` côté conteneurs) :

```bash
sudo ss -tlnp | grep -E 'docker-proxy|caddy'
```

Attendu : `docker-proxy` sur `127.0.0.1:8080` (gateway) et `127.0.0.1:3000` (Grafana),
`caddy` sur `*:80` et `*:443`.

### 2.6 Scan externe (depuis ton PC, pas depuis le serveur)

```bash
sudo apt install nmap                          # une fois, dans WSL
nmap -Pn -p 22,80,443,3000,5432,8080 51.255.169.129
sudo nmap -Pn -sU -p 1194 51.255.169.129
```

| Port | Aujourd'hui (`false`) | Après le VPN (`true`) |
|---|---|---|
| 22/tcp | `open` | `filtered` |
| 80/tcp, 443/tcp | `open` | `open` |
| 3000, 5432, 8080 | `filtered` | `filtered` |
| 1194/udp | `closed` (rien n'écoute encore) | `open\|filtered` |

`filtered` = le pare-feu jette le paquet sans répondre : c'est le résultat voulu pour un
port fermé.

### 2.7 Idempotence

Relancer le même déploiement une deuxième fois :

```bash
make deploy ENV=production ARGS="--tags firewall"
```

Attendu dans le récapitulatif : `changed=0`. Si une tâche repasse en `changed` à chaque
fois, le rôle n'est pas idempotent.

### Correspondance avec le ticket

| Critère SCRUM-55 | Test |
|---|---|
| Seuls 443, 1194 (+80) ouverts, default deny, sortant autorisé | §2.5 `ufw status verbose`, §2.6 nmap |
| Port 22 fermé sur le WAN, SSH via le VPN | §2.6 après la bascule (§3) ; avant : §2.3 |
| Scan externe : 443/80 open, 1194/udp, 22 filtered | §2.6 |
| Seul Caddy publie 80/443, services internes non publiés | §2.5 `ss -tlnp` |
| Rôle idempotent, aucune config manuelle | §2.7 |

## 3. Passer SSH en VPN uniquement (après SCRUM-58)

À faire **dans cet ordre**. Cocher au fur et à mesure.

- [ ] **1. Le VPN est déployé** et l'interface existe sur le serveur :
  ```bash
  ip link show tun0        # sur le serveur : doit afficher l'interface
  ```
- [ ] **2. Se connecter au VPN depuis son PC** et vérifier qu'on joint le serveur par son
  IP VPN :
  ```bash
  ssh <ton-compte>@<IP-VPN-du-serveur>
  ```
- [ ] **3. Faire passer Ansible par le VPN** : dans
  [`inventories/production/hosts.yml`](../inventories/production/hosts.yml), remplacer
  l'IP publique par l'IP VPN (et mettre à jour le commentaire au-dessus) :
  ```yaml
  ansible_host: <IP-VPN-du-serveur>   # au lieu de 51.255.169.129
  ```
  Puis vérifier :
  ```bash
  make ping ENV=production
  ```
- [ ] **4. Basculer l'interrupteur** : dans
  [`inventories/production/group_vars/all/vars.yml`](../inventories/production/group_vars/all/vars.yml),
  supprimer le bloc `firewall_ssh_vpn_only: false` et son commentaire (la valeur par défaut
  du rôle, `true`, s'applique alors).
- [ ] **5. Simuler** :
  ```bash
  make check ENV=production ARGS="--tags firewall"
  ```
  Attendu : la règle `22/tcp` publique apparaît comme supprimée, aucune erreur.
- [ ] **6. Déployer**, avec un terminal SSH (par le VPN) ouvert à côté :
  ```bash
  make deploy ENV=production ARGS="--tags firewall"
  ```
- [ ] **7. Vérifier** : refaire le scan du §2.6 **VPN coupé** (22 doit être `filtered`), puis
  se reconnecter en SSH **VPN allumé**.
- [ ] **8. Mettre à jour la doc** : dans ce fichier, la ligne SSH du §1 et le commentaire de
  `hosts.yml`.

> ⚠️ **Ne pas sauter l'étape 3.** Le garde-fou vérifie seulement que `tun0` existe. Si le
> VPN tourne mais qu'Ansible passe encore par l'IP publique, le déploiement ferme le SSH
> public et le **déploiement suivant** ne pourra plus se connecter. On répare en faisant
> l'étape 3 (pas besoin de la console de secours).

**Les deux fichiers à modifier pour la bascule :**

| Fichier | Avant | Après |
|---|---|---|
| `inventories/production/hosts.yml` | `ansible_host: 51.255.169.129` | `ansible_host: <IP-VPN>` |
| `inventories/production/group_vars/all/vars.yml` | `firewall_ssh_vpn_only: false` | ligne supprimée |

## 4. En cas de blocage

Si plus personne ne peut se connecter en SSH :

1. Ouvrir la **console de secours** depuis l'espace client de l'hébergeur (KVM / rescue).
2. Se connecter avec un compte local, puis rouvrir SSH :
   ```bash
   sudo ufw allow 22/tcp
   ```
   En dernier recours : `sudo ufw disable` (coupe tout le pare-feu).
3. Corriger la configuration dans le dépôt (en général l'étape 3 ou 4 du §3), puis
   redéployer. Le rôle remet les bonnes règles tout seul.
