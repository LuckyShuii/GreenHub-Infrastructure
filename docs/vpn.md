# VPN de l'équipe — procédures

Ce document est la **procédure opérationnelle** : donner un accès, le livrer, le retirer,
tester. Pour le strict nécessaire et le message à envoyer à la personne, voir
[`vpn-acces-rapide.md`](vpn-acces-rapide.md) ; le « pourquoi » des choix de conception est
dans [`roles/openvpn/README.md`](../roles/openvpn/README.md).

Serveur : OpenVPN sur **UDP 1194**, sous-réseau **10.8.0.0/24**, le serveur est **10.8.0.1**.
Chiffrement AES-256-GCM, TLS 1.2 minimum, `tls-crypt` sur le canal de contrôle.

---

## 1. Donner un accès à quelqu'un

**Il n'y a pas de commande « ajouter un utilisateur VPN ».** La liste des accès est dérivée
de [`group_vars/all/users.yml`](../group_vars/all/users.yml), la même source de vérité que
les comptes système. Un accès VPN est donc une PR, comme le reste.

- [ ] **1. Ajouter `vpn: true`** au compte dans `users.yml` :
  ```yaml
  - name: ecouy
    state: present
    groups: [greener, docker]
    sudo: false
    grafana: Editor
    vpn: true
  ```
- [ ] **2. PR, revue, merge** dans `staging`.
- [ ] **3. Rejouer** :
  ```bash
  make deploy ENV=production ARGS="--tags openvpn"
  ```
  Le certificat est émis et le profil `.ovpn` construit sur le serveur. Les certificats déjà
  émis ne sont **jamais** réémis : rejouer ne casse pas les profils déjà distribués.
- [ ] **4. Récupérer les profils** sur son poste, explicitement :
  ```bash
  make vpn-profiles ENV=production
  ```
  Ils arrivent dans `vpn-clients/` (gitignoré), en 0600.

  C'est un playbook à part (`vpn-profiles.yml`), pas un tag du rôle : un `.ovpn` contient une
  clé privée et ne doit jamais descendre au passage d'un simple replay de provisioning.

### Livrer le fichier

> ⚠️ **Un `.ovpn` contient la clé privée du client.** Quiconque l'obtient est sur le VPN,
> sous l'identité de la personne. Il se transmet comme un mot de passe : main à main, ou par
> un canal chiffré à destinataire unique. **Jamais** sur un canal d'équipe, jamais en pièce
> jointe à une liste, jamais dans un ticket.

Côté destinataire :

| OS | Quoi faire du fichier |
|---|---|
| Linux | `sudo openvpn --config <nom>.ovpn`, ou l'importer dans NetworkManager |
| macOS | Tunnelblick ou OpenVPN Connect : double-clic sur le `.ovpn` |
| Windows | OpenVPN GUI : placer le `.ovpn` dans `%USERPROFILE%\OpenVPN\config\` |
| Android / iOS | OpenVPN Connect, import du fichier |

---

## 2. Retirer un accès

- [ ] **1. Passer le compte à `state: absent`** (départ de l'équipe) **ou retirer la ligne
  `vpn: true`** (la personne reste, mais perd le VPN).
- [ ] **2. PR, revue, merge.**
- [ ] **3. Rejouer** `make deploy ENV=production ARGS="--tags openvpn"`.

Ce que fait le replay : le certificat est **révoqué**, ajouté à la CRL, son `.ovpn` est
supprimé du serveur, et **le service redémarre** — donc la session en cours de la personne
tombe immédiatement.

> Effet de bord assumé : le redémarrage déconnecte **tout le monde** pendant ~2 s. Les clients
> se reconnectent seuls. Une révocation est un acte rare et délibéré ; prévenir le canal
> d'équipe avant est une politesse, pas une obligation.

Le profil reste sur le poste de la personne, mais il ne sert plus à rien : le serveur refuse
un certificat révoqué.

---

## 3. Vérifier que ça marche

Sur le serveur :

```bash
systemctl status openvpn-server@greener
ip link show tun0                                # l'interface doit exister
sudo ss -lunp | grep 1194                        # le service écoute en UDP
cat /run/openvpn-server/status-greener.log       # qui est connecté en ce moment
journalctl -u openvpn-server@greener -n 50       # qui s'est connecté, qui a été refusé
```

Depuis son poste, VPN monté :

```bash
ping -c2 10.8.0.1                                # le serveur répond sur son IP VPN
ssh <ton-compte>@10.8.0.1                        # SSH par le VPN
ip route | grep 10.8.0                           # SEULE cette route passe par le tunnel
```

Ce dernier point est le contrôle du **split tunneling** : si une route par défaut
(`0.0.0.0/1` ou `default via ... tun0`) apparaît, tout le trafic de la personne passerait par
le VPS, ce qui n'est ni voulu ni dimensionné.

---

## 4. Joindre Grafana et PostgreSQL

**Grafana est derrière le VPN.** Une fois connecté :

```
http://10.8.0.1:3000
```

Il n'y a plus de vhost public : `grafana.<domaine>` ne répond plus.

C'est volontairement en **HTTP** : aucune autorité publique ne certifie une adresse privée, et
le tunnel chiffre déjà (AES-256-GCM) et authentifie le serveur. Le navigateur affichera donc un
avertissement sur le formulaire de connexion — c'est attendu, pas un symptôme. Le détail du
raisonnement et la voie de sortie sont dans `roles/monitoring/README.md`.

Grafana publie aussi sur la loopback, ce qui laisse une porte de secours le jour où c'est le
VPN lui-même qui est cassé :

```bash
ssh -L 3000:127.0.0.1:3000 <ton-compte>@<IP-publique-du-VPS>   # puis http://localhost:3000
```

**PostgreSQL ne publie aucun port**, volontairement. On passe par le conteneur :

```bash
ssh <ton-compte>@10.8.0.1
docker compose -f /opt/greener/docker-compose.yml exec postgres psql -U greener
```

## 5. Rotation et expiration

| Quoi | Durée | Si ça expire |
|---|---|---|
| Certificat client | 825 jours | la personne ne peut plus se connecter — réémettre |
| Certificat serveur | 825 jours | **plus personne ne se connecte** |
| CA | 10 ans | tout est à refaire |
| CRL | 10 ans | ⚠️ **plus personne ne se connecte**, révoqué ou non |

Réémettre un certificat arrivé à expiration : supprimer le certificat concerné du serveur
(`/etc/openvpn/easy-rsa/pki/issued/<nom>.crt` et la clé associée), puis rejouer — le rôle
réémet ce qui manque. C'est volontairement manuel : la suppression d'un certificat valide
n'est pas une chose qu'un replay doit pouvoir faire tout seul.

---

## 6. Et après : fermer SSH sur Internet

Le VPN est le prérequis de la bascule `firewall_ssh_vpn_only`, qui n'est **pas** automatique :
la checklist en six étapes est dans [`firewall.md`](firewall.md) §3, et elle
impose de faire passer `ansible_host` sur l'IP VPN. À faire avec une session SSH ouverte à
côté, jamais à l'aveugle.
