# VPN — donner un accès, en deux temps

La procédure complète est dans [`vpn.md`](vpn.md). Ici : le strict nécessaire, et le message
à coller dans Discord.

## 1. Côté admin — créer le certificat

```yaml
# group_vars/all/users.yml
- name: ecouy
  vpn: true          # ← ajouter cette ligne
```

```bash
# après merge de la PR
make deploy ENV=production ARGS="--tags openvpn"   # émet le certificat
make vpn-profiles ENV=production                  # récupère les .ovpn dans vpn-clients/
```

Envoyer `vpn-clients/ecouy.ovpn` **en message privé**, jamais dans un salon : le fichier
contient la clé privée, quiconque l'a est sur le VPN sous l'identité de la personne.

## 2. Côté utilisateur — le message Discord

À coller tel quel, en DM, avec le fichier en pièce jointe :

```
Salut ! Voici ton accès VPN. Garde ce fichier pour toi, c'est l'équivalent d'un mot de passe.

1. Installe un client OpenVPN :
   • Windows / macOS / Android / iOS → "OpenVPN Connect" (openvpn.net/client)
   • Linux → sudo apt install openvpn

2. Importe le fichier .ovpn joint :
   • OpenVPN Connect → "+" → Import → File → choisis le fichier
   • Linux → sudo openvpn --config <ton-nom>.ovpn

3. Connecte-toi, puis vérifie :
   ping 10.8.0.1
   Tu dois aussi avoir reçu une IP en 10.8.0.x (ifconfig | grep 10.8 ou ip a).

4. Ce que ça t'ouvre :
   • Grafana (dashboards) → http://10.8.0.1:3000
   • SSH sur le serveur    → ssh <ton-login>@10.8.0.1

   À la première connexion SSH, ton client demande de confirmer l'identité du serveur.
   Vérifie que l'empreinte affichée est EXACTEMENT :
   SHA256:COBzzN3ch49uTBkDAl65nVMKFDzvI67LkJwZiDmVPLE
   Si elle diffère, n'accepte pas et préviens-moi.

5. Deux choses à savoir :
   • Le VPN ne fait passer que le trafic vers le serveur (10.8.0.0/24). Ta navigation
     normale n'est pas redirigée et ne ralentit pas.
   • https://grafana.lucasboillot.fr ne répond plus : Grafana est désormais
     accessible uniquement par le VPN.

Si ça ne connecte pas, envoie-moi le log du client (OpenVPN Connect → Settings →
"Copy log to clipboard") et ping-moi.
```

### Pendant la transition

Tant que SSH public n'est pas fermé, `ssh <login>@51.255.169.129` fonctionne encore. Ne le
mets pas dans le message : c'est précisément l'accès qu'on veut voir disparaître, et le but de
la distribution est que chacun valide le chemin VPN. Garde-le comme secours à ton niveau.

## À savoir

- **L'IP du serveur sur le VPN est `10.8.0.1`.** Les clients reçoivent `10.8.0.2` et suivants.
- **Le certificat VPN donne le réseau, la clé SSH donne le shell.** Deux informations
  d'authentification différentes : être sur le VPN ne suffit pas à ouvrir une session, il faut
  aussi que le compte soit dans `users.yml` avec sa clé publique.
- **Ne ferme pas SSH public avant que les 7 aient confirmé** une connexion VPN réussie. Après
  la bascule, un profil qui ne marche pas enferme la personne dehors — et Ansible avec elle.
- Retirer un accès = `state: absent` (ou retirer `vpn: true`) + PR + replay. Le certificat est
  révoqué et la session en cours tombe.
