# Dashboards Grafana & alertes Discord — état des lieux

> Document de travail (LBT). Sert de base à la synthèse qui sera postée sur Discord.
> Source de vérité du code : `roles/monitoring/` (dashboards, règles, routage) et
> `docs/uptime-externe.md` (sondes hors VPS).
> Dernière mise à jour : 22/09/2026 — après implémentation de D1→D8.

---

## 1. Accès

- URL : **`http://10.8.0.1:3000`, VPN monté.** L'exposition publique
  (`grafana.lucasboillot.fr`) a été fermée : Grafana n'est plus joignable que par le VPN.
  En HTTP et non HTTPS, volontairement — le tunnel chiffre déjà, et aucune autorité ne
  certifie une adresse privée (détail dans `roles/monitoring/README.md`).
- Porte de secours si le VPN lui-même est cassé : `ssh -L 3000:127.0.0.1:3000 <user>@<vps>`
  puis `http://localhost:3000` — mais SSH est aussi VPN-only désormais, donc cette porte
  suppose le pare-feu rouvert depuis la console de secours.
- Un compte nominatif par personne, piloté par `group_vars/all/users.yml` (2 Admin,
  5 Editor). Mot de passe individuel, au vault, restauré à chaque déploiement.
- Editor et pas Viewer pour les devs : Viewer n'a pas accès à *Explore*.
- Tout est dans le dossier **GREENER**, en lecture seule (provisionné par fichier : une
  modif faite dans l'UI ne survit pas à un redémarrage).
- Rafraîchissement 30 s, fenêtre par défaut 6 h.
- Sources de données : **Loki** (logs, rétention 7 j) et **Prometheus** (métriques,
  rétention 15 j).
- Un seul environnement réel : `production`. Pas de VPS staging.

---

## 2. Dashboards disponibles (6)

**Ils portent un marqueur violet à chaque déploiement**, avec la version
déployée. C'est la réponse d'un coup d'œil à « ça a commencé après quel déploiement ? ».

### `GREENER — Logs` (uid `greener-logs`)

- Filtres : service, niveau, source (conteneur / journal systemd), recherche texte libre.
- Compteurs : lignes totales, erreurs, avertissements, échecs de déploiement.
- Volume de logs par service / par niveau.
- Erreurs et avertissements par service.
- Flux de logs brut.

### `GREENER — Machine hôte` (uid `greener-host`)

- Capacité : vCPU, RAM totale, disque total, uptime, charge par cœur, reboots récents.
- Consommation : CPU, RAM, disque `/`.
- CPU par mode, mémoire (swap compris), espace libre par point de montage, débit disque,
  réseau, charge.

### `GREENER — Services` (uid `greener-services`)

- Filtres : projet compose, service.
- État : conteneurs actifs, depuis quand chacun tourne, redémarrages sur la plage.
- CPU / mémoire / réseau / écritures disque par service.
- Erreurs et avertissements par service.

### `GREENER — PostgreSQL` (uid `greener-postgres`) — **nouveau**

- État : supervision active, connexions ouvertes, part du maximum, taille des bases,
  uptime PostgreSQL.
- Connexions par base.
- Taux de succès du cache.
- Transactions (commit / rollback).
- Lignes lues, insérées, modifiées, supprimées.
- Verrous par type.
- Interblocages et conflits.
- Erreurs et avertissements PostgreSQL (logs).

### `GREENER — Bordure` (uid `greener-edge`) — **nouveau**

- Trafic : requêtes, 5xx, 4xx, latence médiane.
- Réponses par classe de code (empilées), requêtes par domaine.
- Latence p50 / p95 / p99 vue par Caddy.
- Chemins les plus servis (top 10).
- Jours avant expiration TLS, sondes au vert, latence des sondes.
- Disponibilité et temps de réponse des sondes.
- Erreurs et avertissements Caddy (logs) — c'est là que se voit un ACME en échec.

---

### `GREENER — Accès SSH` (uid `greener-ssh`) — **nouveau**

Qui se connecte au serveur, depuis quelle adresse VPN, et ce qui a été refusé. Source : le
journal systemd de `ssh.service`.

| Section | Ce qu'on y lit |
|---|---|
| Vue d'ensemble | acceptations, refus, nombre d'utilisateurs et d'adresses sources distinctes |
| **Journal lisible** | **les deux tableaux à lire en premier** (voir ci-dessous) |
| Qui se connecte | barres empilées par utilisateur, et les totaux `utilisateur / source / méthode` |
| Tentatives refusées | refus ventilés par motif, plus le journal brut |
| Journal sshd complet | replié par défaut : toutes les lignes, filtrables par le champ *Recherche* |

**Les deux tableaux de « Journal lisible »** remplacent la lecture du log brut, un événement
par ligne, le plus récent en haut, toutes les colonnes filtrables :

| Tableau | Colonnes | Couleurs |
|---|---|---|
| Authentifications | heure, utilisateur, méthode, statut, source | **vert** accepté, **rouge** refusé |
| Sessions | heure, utilisateur, statut | **vert** ouverture, **bleu** fermeture |

Deux pièges de lecture. La colonne **Méthode est vide sur un refus** survenu avant que le
client ne propose une clé — utilisateur inconnu, abandon pré-auth : il n'y a pas de méthode à
rapporter. Et **authentification n'est pas session** : une authentification acceptée ouvre une
session, dont la fermeture est la déconnexion ; une ouverture sans fermeture correspondante est
une session encore active.

Les colonnes ne sortent pas du log telles quelles : Loki range les champs extraits dans un
seul objet, c'est la transformation *extractFields* du panneau qui les éclate en colonnes.

Deux colonnes méritent un regard régulier. **`méthode`** doit toujours valoir `publickey` :
un `password` signalerait que le durcissement SSH a régressé. Et **`source`** doit toujours
être dans `10.8.0.0/24` : une adresse publique voudrait dire que SSH est joignable autrement
que par le tunnel.

Le journal de `sshd` n'était pas collecté avant : le port 22 étant ouvert sur Internet, il
était saturé de scans refusés (3 252 lignes en 24 h, essentiellement `root`, `ubuntu` et
`admin`). La fermeture du port public a fait disparaître ce bruit, ce qui rend la collecte
utile — chaque ligne décrit désormais une tentative d'un membre de l'équipe.

---

## 3. Alertes Discord

### Le canal — un seul salon, deux portes

- Destination unique : salon **#alerting**, un seul webhook. Les deux contact points
  postent au même endroit ; ce qui change, c'est le volume sonore.
- `severity = critical` → **ping `@lucasyaisy`**, jamais mis en sourdine.
- `severity = warning` → pas de ping, **silencieux de 23 h à 08 h** (Europe/Paris).
- Sans label `severity` → route racine, livré sans ping.
- Les retours à la normale sont notifiés (✅) et ne pinguent jamais.
- Regroupement par (règle, env, service) : une règle qui touche 6 conteneurs = 1 message.
- Délais : 30 s avant le 1er envoi, 5 min entre deux relances, **4 h** avant de
  re-notifier un problème toujours actif.

> **Deux choses à savoir, vérifiées et non supposées :**
> - Le message `critical` perd les liens cliquables (URL brutes, et 2 au lieu de 3). C'est
>   imposé par Grafana : son notifieur Discord vide `content` quand le message part dans
>   l'embed, et Discord ne notifie une mention que depuis `content`. Le titre rouge, lui,
>   est conservé.
> - La sourdine nocturne **supprime**, elle ne reporte pas. Un warning qui apparaît à
>   23 h 05 et se résout à 3 h n'est jamais annoncé.

### Les règles (22 au total)

**Logs (Loki)**

- `greener-error-rate` — 🟠 — plus de 10 erreurs en 5 min sur un service.
- `greener-edge-5xx` — 🟠 — plus de 10 réponses 5xx en 5 min servies par Caddy. ⭐ nouveau

**Machine (Prometheus)**

- `greener-disk-low` — 🔴 — disque `/` au-dessus de 85 %.
- `greener-disk-predict` — 🟠 — disque plein dans moins de 4 jours au rythme actuel. ⭐
- `greener-memory-high` — 🟠 — RAM de la machine au-dessus de 90 %.
- `greener-cpu-high` — 🟠 — charge par cœur au-dessus de 2 pendant 15 min. ⭐

**Conteneurs (Prometheus)**

- `greener-container-down-<service>` — 🔴 — 5 règles : gateway, backend, ai, postgres,
  qdrant.
- `greener-restart-loop` — 🔴 — plus de 3 démarrages en 15 min.
- `greener-unhealthy-<service>` — 🔴 — healthcheck en échec (postgres/backend/qdrant 5 min,
  ai 25 min).
- `greener-memory-container-critical` — 🔴 — **l'IA** au-dessus de 85 % de sa limite. ⭐
- `greener-memory-container` — 🟠 — un autre service au-dessus de 85 % de sa limite. ⭐

**Bordure (Prometheus, sondes blackbox)**

- `greener-tls-expiry-critical` — 🔴 — certificat expirant sous 7 jours. ⭐
- `greener-tls-expiry-warning` — 🟠 — certificat expirant sous 21 jours. ⭐

**PostgreSQL (Prometheus)**

- `greener-pg-connections` — 🟠 — plus de 80 % de `max_connections`. ⭐
- `greener-pg-down` — 🟠 — l'exporteur ne répond plus. ⭐

### Alertes hors Grafana (même salon)

- **UptimeRobot** — ✅ **en place** (LBT, 22/09/2026). Sondes HTTP externes toutes les
  5 min sur `/health/db` et le front, plus l'expiration TLS. C'est la seule chose qui voit
  la panne quand le VPS entier tombe.
- **healthchecks.io** — ⏸️ pas en place, attend SCRUM-54 (le rôle `backups` est un stub).

---

## 4. Ce qui a été implémenté (22/09/2026)

Tout D1→D8 est écrit et rendu. **Rien n'est encore déployé** : `make deploy` reste à faire.

| # | Quoi | Où |
|---|---|---|
| D1 | Alerte charge CPU | `roles/monitoring` (règle `greener-cpu-high`) |
| D2 | `mem_limit` sur les 5 services + alerte RAM par conteneur | `roles/app_stack` + `roles/monitoring` |
| D3 | Alerte disque prédictive | `roles/monitoring` |
| D4 | `postgres_exporter` + dashboard + 2 alertes | `roles/monitoring` |
| D5 | Sondes blackbox (TLS) + logs d'accès Caddy + dashboard Bordure | `roles/monitoring` + `roles/caddy` |
| D6 | Contact point `greener-discord-critical` avec ping | `roles/monitoring` |
| D7 | Sourdine nocturne des warnings | `roles/monitoring` |
| D8 | Annotations de déploiement | `deploy.yml` + les 5 dashboards |

### Limites mémoire posées (`app_stack_mem_limits`)

| Service | Limite |
|---|---|
| `ai` | 5 Go |
| `postgres` | 2 Go |
| `qdrant` | 1,5 Go |
| `backend` | 1 Go |
| `gateway` | 256 Mo |

~9,75 Go engagés sur 15. **Ce sont des estimations, pas des mesures.** Une limite trop
basse n'entraîne pas une lenteur : elle tue le conteneur (OOM). Le filet de sécurité est
`greener-restart-loop`, qui attrape la boucle en 15 min. `ai` est celui à surveiller.

---

## 5. À faire avant / pendant le déploiement

- [ ] **Créer le jeton d'annotation** : Grafana → Administration → Service accounts →
      rôle Editor → token, puis `make vault-edit ENV=production` et ajouter
      `vault_grafana_annotation_token`. Sans lui, tout se déploie normalement, il n'y a
      simplement pas de marqueur de déploiement.
- [ ] `make check ENV=production` puis `make deploy ENV=production`.
- [ ] **Vérifier le premier message `critical`** : c'est le seul point validé par lecture
      du code source de Grafana et non par un message réel. Il faut forcer une règle dont
      la sévérité EST `critical` — ni `greener-error-rate` ni `greener-cpu-high` ne
      conviennent, ce sont des `warning` et elles ne pingueraient personne. La bonne cible
      est `greener-disk-low` :

      ```bash
      ansible-playbook -i inventories/production/hosts.yml site.yml --tags monitoring \
        -e monitoring_alert_disk_threshold=0 -e monitoring_alert_disk_for=0s
      ```

      Une seule instance (un seul système de fichiers), donc un seul ping, et
      `service: host` exerce au passage la branche « pas de lien logs » du message.
      **Puis remettre l'état normal avec `make deploy ENV=production`** — sinon la règle
      reste à 0 et le salon crie en boucle. Le retour à la normale prouve le message ✅.
- [ ] **Surveiller la RAM de l'IA les premiers jours.** Si elle OOM, la limite est trop
      basse — regarder « Mémoire par service » et monter.
- [ ] Surveiller le volume Loki : les logs d'accès Caddy ajoutent une ligne par requête,
      sur un disque déjà à 77 %. Le levier est `monitoring_loki_retention`.

---

## 6. Écarté ou reporté

- **A1 (salons séparés critical / warning)** — ❌ refusé. Un seul salon. Seul le mécanisme
  de routage est repris, vers la même destination.
- **A3 (surveiller la stack de monitoring)** — ⏸️ non retenu. Angle mort restant : si Alloy
  meurt, plus aucune métrique n'arrive et **aucune alerte ne part**. À reproposer.
- **A5 (retuner le seuil d'erreurs)** — ⏸️ observation à faire après une semaine de trafic.
- **B1 (métriques API : latence, 5xx, trafic par route)** — ⏸️ reporté, dépend du repo
  backend. `greener-edge-5xx` et le dashboard Bordure en couvrent **une partie** depuis les
  logs Caddy, sans instrumenter le backend : on voit ce que le monde extérieur reçoit, pas
  ce qui se passe à l'intérieur.
- **C2 (lien « procédure » dans les messages)** — ⏸️ peu utile à une seule personne
  d'astreinte.
- **C4 (dashboards IA / Qdrant)** — ⏸️ dépend de HJM (SCRUM-67).
- **C5 (dashboard sauvegardes)** — ⏸️ arrive avec SCRUM-54.
- **C6 (séparer les alertes staging)** — ⏸️ sans objet : pas de VPS staging (SCRUM-91).
